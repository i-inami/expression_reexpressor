variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Name used to prefix all created resources"
  type        = string
  default     = "expression-reexpressor"
}

variable "tf_state_bucket" {
  description = "Name of the S3 bucket created by scripts/bootstrap_state_bucket.sh, used only to scope the GHA deploy role's S3 permissions (the backend block itself gets this via -backend-config)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repo allowed to assume the deploy role, as \"org/name\""
  type        = string
}

variable "image_tag" {
  description = "Tag of the Lambda container image to deploy"
  type        = string
  default     = "latest"
}
