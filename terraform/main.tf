locals {
  ecr_repo_name = var.project_name
  lambda_name   = var.project_name
}

# --- Container image storage --------------------------------------------

resource "aws_ecr_repository" "app" {
  name         = local.ecr_repo_name
  force_delete = false
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}

# --- Lambda ---------------------------------------------------------------

resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-exec"
  # Capped to exactly the one managed policy it's meant to have (below) --
  # ManageOwnDeployRoles (see gha_deploy's policy) grants CI AttachRolePolicy
  # on this role too, so without a boundary here a merged PR could attach
  # something broader (e.g. AdministratorAccess) and have it actually take
  # effect, since this role isn't otherwise capped like gha_deploy is.
  permissions_boundary = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_exec" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.lambda_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "app" {
  function_name = local.lambda_name
  role          = aws_iam_role.lambda_exec.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
  timeout       = 10
  memory_size   = 256

  depends_on = [aws_cloudwatch_log_group.lambda]
}

# --- REST API Gateway --------------------------------------------------
#
# A REST API, not the simpler HTTP API type: HTTP APIs have no API Key /
# Usage Plan support at all, and requiring a key on the endpoint is the
# whole point here. Like the ECR repo, creating this API/key/usage-plan for
# the first time has to happen via local bootstrap credentials -- see the
# ApiGatewayManage comment on gha_deploy's policy below for why.

resource "aws_api_gateway_rest_api" "app" {
  name = var.project_name
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.app.id
  parent_id   = aws_api_gateway_rest_api.app.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id      = aws_api_gateway_rest_api.app.id
  resource_id      = aws_api_gateway_resource.proxy.id
  http_method      = "ANY"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id             = aws_api_gateway_rest_api.app.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.app.invoke_arn
}

resource "aws_api_gateway_deployment" "app" {
  rest_api_id = aws_api_gateway_rest_api.app.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy.id,
      aws_api_gateway_integration.lambda.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "default" {
  rest_api_id   = aws_api_gateway_rest_api.app.id
  deployment_id = aws_api_gateway_deployment.app.id
  stage_name    = "prod"
}

resource "aws_api_gateway_api_key" "app" {
  name = "${var.project_name}-key"
}

resource "aws_api_gateway_usage_plan" "app" {
  name = "${var.project_name}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.app.id
    stage  = aws_api_gateway_stage.default.stage_name
  }
}

resource "aws_api_gateway_usage_plan_key" "app" {
  key_id        = aws_api_gateway_api_key.app.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.app.id
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.app.execution_arn}/*/*"
}

# --- GitHub OIDC deploy role ------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Caps the MAXIMUM effective permissions gha_deploy can ever have, regardless
# of what its own identity policy grants. This is what makes it safe for that
# policy (below) to have full read/write on its own role: even if a merged PR
# attached AdministratorAccess to gha_deploy, AWS evaluates effective
# permissions as identity-policy INTERSECT boundary, so the actual result
# stays capped to this whitelist. gha_deploy is never granted iam:CreatePolicy/
# CreatePolicyVersion/DeletePolicy* (can't edit this policy's document) or
# iam:{Put,Delete}RolePermissionsBoundary (can't detach/replace this
# attachment) -- so widening this boundary always requires a local apply,
# same as the very first bootstrap. Deliberately coarse on Resource (a
# boundary is a ceiling, not a precise grant); the identity policy below
# stays the one doing precise per-resource scoping.
resource "aws_iam_policy" "ci_boundary" {
  name        = "${var.project_name}-ci-boundary"
  description = "Max effective permissions for the gha_deploy role"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Ecr"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:BatchGetImage", "ecr:DescribeRepositories", "ecr:CreateRepository", "ecr:PutLifecyclePolicy", "ecr:GetLifecyclePolicy"]
        Resource = "*"
      },
      {
        Sid      = "Lambda"
        Effect   = "Allow"
        Action   = ["lambda:GetFunction", "lambda:CreateFunction", "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:AddPermission", "lambda:RemovePermission", "lambda:GetPolicy", "lambda:TagResource", "lambda:ListTags"]
        Resource = "*"
      },
      {
        Sid      = "ApiGateway"
        Effect   = "Allow"
        Action   = "apigateway:*"
        Resource = "*"
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:PutRetentionPolicy", "logs:DescribeLogGroups", "logs:TagResource"]
        Resource = "*"
      },
      {
        Sid      = "PassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "*"
      },
      {
        Sid      = "ManageOwnRole"
        Effect   = "Allow"
        Action   = ["iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateAssumeRolePolicy", "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListRolePolicies", "iam:TagRole"]
        Resource = "*"
      },
      {
        Sid      = "OidcProvider"
        Effect   = "Allow"
        Action   = ["iam:GetOpenIDConnectProvider", "iam:CreateOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider"]
        Resource = "*"
      },
      {
        Sid      = "TerraformStateBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role" "gha_deploy" {
  name                 = "${var.project_name}-gha-deploy"
  permissions_boundary = aws_iam_policy.ci_boundary.arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "gha_deploy" {
  name = "${var.project_name}-gha-deploy"
  role = aws_iam_role.gha_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories",
          "ecr:CreateRepository",
          "ecr:PutLifecyclePolicy",
          "ecr:GetLifecyclePolicy",
        ]
        Resource = aws_ecr_repository.app.arn
      },
      {
        Sid    = "LambdaManage"
        Effect = "Allow"
        Action = [
          "lambda:GetFunction",
          "lambda:CreateFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:GetPolicy",
          "lambda:TagResource",
          "lambda:ListTags",
        ]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.lambda_name}"
      },
      {
        Sid    = "ApiGatewayManage"
        Effect = "Allow"
        Action = "apigateway:*"
        # /restapis/{id} for actions on the API resource itself, /restapis/{id}/*
        # for its sub-resources (resources, methods, integrations, deployments,
        # stages). /apikeys/{id} and /usageplans/{id}(/*) likewise for the key
        # and usage plan. Creating any of these from nothing isn't covered --
        # like the ECR repo, they're created once via local bootstrap (human
        # credentials, not this policy); this only lets CI manage the
        # already-existing, specifically-ID'd ones.
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/restapis/${aws_api_gateway_rest_api.app.id}",
          "arn:aws:apigateway:${var.aws_region}::/restapis/${aws_api_gateway_rest_api.app.id}/*",
          "arn:aws:apigateway:${var.aws_region}::/apikeys/${aws_api_gateway_api_key.app.id}",
          "arn:aws:apigateway:${var.aws_region}::/usageplans/${aws_api_gateway_usage_plan.app.id}",
          "arn:aws:apigateway:${var.aws_region}::/usageplans/${aws_api_gateway_usage_plan.app.id}/*",
        ]
      },
      {
        Sid      = "LogsManage"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:PutRetentionPolicy", "logs:DescribeLogGroups", "logs:TagResource"]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_name}*"
      },
      {
        Sid      = "PassLambdaExecRoleOnly"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.lambda_exec.arn
      },
      {
        # Full read/write on its own role is safe here: aws_iam_policy.ci_boundary
        # (attached to gha_deploy) caps the *effective* permissions regardless
        # of what this statement or any future PR grants -- see that resource's
        # comment for why. Excludes iam:{Put,Delete}RolePermissionsBoundary
        # deliberately, so CI can never detach/replace its own ceiling.
        Sid    = "ManageOwnDeployRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:TagRole",
        ]
        Resource = [aws_iam_role.lambda_exec.arn, aws_iam_role.gha_deploy.arn]
      },
      {
        Sid    = "ManageOidcProvider"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:CreateOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:TagOpenIDConnectProvider",
        ]
        Resource = aws_iam_openid_connect_provider.github.arn
      },
      {
        Sid      = "TerraformStateBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = ["arn:aws:s3:::${var.tf_state_bucket}", "arn:aws:s3:::${var.tf_state_bucket}/*"]
      },
    ]
  })
}
