output "api_endpoint" {
  description = "Base URL of the deployed API"
  value       = aws_apigatewayv2_api.http_api.api_endpoint
}

output "ecr_repository_url" {
  description = "ECR repository URL to build/push the Lambda image to"
  value       = aws_ecr_repository.app.repository_url
}

output "gha_role_arn" {
  description = "Copy this into the AWS_DEPLOY_ROLE_ARN GitHub Actions secret"
  value       = aws_iam_role.gha_deploy.arn
}
