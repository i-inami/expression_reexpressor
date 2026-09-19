terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # bucket + region are account-specific, supplied at `terraform init` time via
  # -backend-config (see scripts/bootstrap_state_bucket.sh and the deploy workflow).
  backend "s3" {
    key          = "expression-reexpressor/terraform.tfstate"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
