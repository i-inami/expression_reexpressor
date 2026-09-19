output "api_endpoint" {
  description = "Base URL of the deployed API"
  value       = aws_api_gateway_stage.default.invoke_url
  sensitive   = true
}

output "api_key_value" {
  description = "Value for the x-api-key header required by /reexpress"
  value       = aws_api_gateway_api_key.app.value
  sensitive   = true
}

output "ecr_repository_url" {
  description = "ECR repository URL to build/push the Lambda image to"
  value       = aws_ecr_repository.app.repository_url
  sensitive   = true # contains the account ID; keep it out of plan/apply logs
}

output "gha_role_arn" {
  description = "Copy this into the AWS_DEPLOY_ROLE_ARN GitHub Actions secret"
  value       = aws_iam_role.gha_deploy.arn
  sensitive   = true # contains the account ID; keep it out of plan/apply logs
}
