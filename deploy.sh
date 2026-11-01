#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# Deploy script — detects AWS environment and configures Terraform accordingly.
#
# Two supported environments:
#   1. AWS Academy Learner Lab  -> uses existing "LabRole"      (Gautam's account)
#   2. Innovation Sandbox       -> creates IAM roles from scratch (Piyush's account)
#
# The script detects which account you're in by checking if "LabRole" exists.
# It then activates the correct IAM Terraform file before running `terraform init`.
#
# Usage:
#   ./deploy.sh          -> detect environment, run `terraform plan`
#   ./deploy.sh apply    -> detect environment, run `terraform apply`
#   ./deploy.sh destroy  -> detect environment, run `terraform destroy`
# ─────────────────────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$REPO_ROOT/infra"
ACTION="${1:-plan}"

echo "=============================================="
echo "RedisVsRaft deployment script"
echo "=============================================="
echo ""

# ── Step 1: Verify AWS credentials work ────────────────────────────────────
echo "Checking AWS credentials..."
if ! aws sts get-caller-identity > /dev/null 2>&1; then
  echo "ERROR: AWS credentials not working."
  echo "Make sure you have run 'aws configure' or set AWS_* env vars."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "  Account ID: $ACCOUNT_ID"
echo "  Caller ARN: $CALLER_ARN"
echo ""

# ── Step 2: Detect environment ─────────────────────────────────────────────
echo "Detecting AWS environment (Learner Lab vs Innovation Sandbox)..."

if aws iam get-role --role-name LabRole > /dev/null 2>&1; then
  ENV_TYPE="learnerlab"
  echo "  -> Found LabRole. This is an AWS Academy Learner Lab account."
else
  ENV_TYPE="sandbox"
  echo "  -> No LabRole found. This is an Innovation Sandbox account."
fi
echo ""

# ── Step 3: Activate the correct iam.tf ────────────────────────────────────
echo "Configuring Terraform for $ENV_TYPE environment..."

SOURCE_FILE="$INFRA_DIR/iam.tf.$ENV_TYPE"
TARGET_FILE="$INFRA_DIR/iam.tf"

if [ ! -f "$SOURCE_FILE" ]; then
  echo "ERROR: $SOURCE_FILE does not exist."
  echo "Expected one of: iam.tf.learnerlab, iam.tf.sandbox"
  exit 1
fi

# Remove any existing iam.tf first (might be a leftover from a previous run)
rm -f "$TARGET_FILE"
cp "$SOURCE_FILE" "$TARGET_FILE"
echo "  Copied $SOURCE_FILE -> $TARGET_FILE"
echo ""

# ── Step 4: Run Terraform ──────────────────────────────────────────────────
cd "$INFRA_DIR"

# Backend config — for Sandbox, use Piyush's bucket.
# For Learner Lab, use Gautam's bucket. Fall back to local state if either fails.
if [ "$ENV_TYPE" = "sandbox" ]; then
  BACKEND_BUCKET="redisvraft-tfstate-piyush-sandbox"
else
  BACKEND_BUCKET="redisvraft-tfstate"
fi

echo "Trying terraform init with S3 backend (bucket=$BACKEND_BUCKET)..."
if terraform init -input=false -reconfigure \
    -backend-config="bucket=$BACKEND_BUCKET" \
    -backend-config="key=benchmark/terraform.tfstate" \
    -backend-config="region=us-east-1" \
    -backend-config="dynamodb_table=terraform-locks" \
    -backend-config="encrypt=true"; then
  echo "  -> S3 backend OK"
else
  echo "  -> S3 backend failed, falling back to local state"
  # Remove the s3 backend block temporarily and re-init
  sed -i.bak 's/backend "s3" {}/# backend "s3" {}/' main.tf
  terraform init -input=false -reconfigure
  # Restore the backend block for next time
  sed -i.bak 's/# backend "s3" {}/backend "s3" {}/' main.tf
  rm -f main.tf.bak
fi
echo ""

case "$ACTION" in
  plan)
    echo "Running terraform plan..."
    terraform plan
    ;;
  apply)
    echo "Running terraform apply..."
    terraform apply
    ;;
  destroy)
    echo "Running terraform destroy..."
    terraform destroy
    ;;
  *)
    echo "Unknown action: $ACTION"
    echo "Usage: $0 [plan|apply|destroy]"
    exit 1
    ;;
esac
