#!/usr/bin/env bash
# One-time setup: create the S3 bucket that holds Terraform state.
#
# The bucket name is a random opaque string, not derived from the project name
# or account id -- both of those are public (repo name, and account ids leak
# more easily than you'd like), and a guessable name lets anyone rack up S3
# request charges against you by probing it (S3 bills per request even for
# denied ones, but only when the bucket actually exists in your account).
#
# The chosen name is cached in .tf-state-bucket-name (gitignored) so re-running
# this script is idempotent. It's never written into any tracked file -- copy
# it into a GitHub secret named TF_STATE_BUCKET so CI can use it too.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-expression-reexpressor}"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo ap-northeast-1)}"
STATE_FILE="$(dirname "$0")/../.tf-state-bucket-name"

if [ -f "$STATE_FILE" ]; then
  BUCKET="$(cat "$STATE_FILE")"
else
  BUCKET="${PROJECT_NAME}-tfstate-$(openssl rand -hex 4)"
fi

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket $BUCKET already exists, skipping creation."
else
  echo "Creating bucket $BUCKET in $REGION..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "$BUCKET" > "$STATE_FILE"

echo "Done. Bucket: $BUCKET (region: $REGION)"
echo "Save this as a GitHub secret named TF_STATE_BUCKET so CI can find it."
echo "Next:"
echo "  cd terraform"
echo "  terraform init -backend-config=\"bucket=${BUCKET}\" -backend-config=\"region=${REGION}\""
echo "  terraform apply -var tf_state_bucket=${BUCKET} -var github_repo=<org>/<repo> ..."
