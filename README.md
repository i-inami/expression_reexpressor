# expression-reexpressor

## Run locally

```
uv run uvicorn app.main:app --reload &
```

## Invoke

```
curl -X POST localhost:8000/reexpress \
  -H 'content-type: application/json' \
  -d '{"expressions":["y=a*x+b"],"variable":"x"}'
```

## Deploy

Infrastructure (Lambda behind an HTTP API Gateway, deployed as a container image)
lives in `terraform/`. GitHub Actions deploys automatically on every push to `main`,
authenticating via a GitHub OIDC federated role — no long-lived AWS keys are stored
anywhere.

One-time setup (needs your own AWS credentials locally). A brand-new ECR repo has no
image yet, so the Lambda function can't be created until one exists — push an initial
image before the full apply, same two-step order the deploy workflow uses:

```
./scripts/bootstrap_state_bucket.sh          # creates the S3 state bucket, prints the next commands
cd terraform
terraform init -backend-config="bucket=<printed above>" -backend-config="region=<printed above>"
terraform apply -target=aws_ecr_repository.app \
  -var tf_state_bucket=<printed above> -var github_repo=<org>/<repo> -auto-approve

repo_url=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${repo_url%/*}"
docker build -t "$repo_url:latest" ..
docker push "$repo_url:latest"

terraform apply -var tf_state_bucket=<printed above> -var github_repo=<org>/<repo>   # creates the OIDC role, among everything else
```

Copy the `gha_role_arn` output into a repo secret named `AWS_DEPLOY_ROLE_ARN`, and the
bucket name into one named `TF_STATE_BUCKET`. From then on, pushes to `main` deploy
automatically (tests/lint must pass first).

**Note:** the CI role (`gha_deploy`) has full read/write on its own IAM role and the
OIDC provider — a compromised PR can attach whatever it wants (even
`AdministratorAccess`), but `aws_iam_policy.ci_boundary` (a permissions boundary
attached to the role) caps its *effective* permissions to the same fixed whitelist
regardless, so that grant is a no-op in practice. The one thing that stays permanently
local-apply-only is the boundary policy itself, and detaching/replacing it on the role
(`terraform/main.tf`'s `ci_boundary` resource comment explains why) — routine CI runs
can freely manage everything else, including day-to-day changes to its own role.

Actions in `.github/workflows/test.yml` are pinned to a commit SHA (not a mutable tag)
via [pinact](https://github.com/suzuki-shunsuke/pinact), so a tag hijack upstream can't
silently change what CI runs. To bump a version: `pinact run --update`.
