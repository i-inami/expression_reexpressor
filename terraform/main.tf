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

# --- HTTP API Gateway -------------------------------------------------------

resource "aws_apigatewayv2_api" "http_api" {
  name          = var.project_name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.app.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
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
        # /apis/{id} for actions on the API resource itself (GetApi, UpdateApi,
        # DeleteApi, ...), /apis/{id}/* for its sub-resources (routes,
        # integrations, stages). CreateApi itself isn't covered -- the API is
        # created once via local bootstrap (human credentials, not this
        # policy), same as the ECR repo and Lambda function.
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/apis/${aws_apigatewayv2_api.http_api.id}",
          "arn:aws:apigateway:${var.aws_region}::/apis/${aws_apigatewayv2_api.http_api.id}/*",
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
