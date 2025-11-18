#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Find repository root
REPO_ROOT=$(git rev-parse --show-toplevel || exit 1)
# These are hardcoded both here and in the main module
STATE_BUCKET="gel-exifstrip-terraform-state"
STATE_KEY="gel-exifstrip/terraform.tfstate"

# Check bucket existence first
if aws s3 ls "s3://${STATE_BUCKET}" &>/dev/null; then
  BUCKET_EXISTS=true
  if aws s3 ls "s3://${STATE_BUCKET}/${STATE_KEY}" &>/dev/null; then
    STATE_EXISTS=true
  else
    STATE_EXISTS=false
  fi
else
  BUCKET_EXISTS=false
  STATE_EXISTS=false
fi

# If both exist, exit early
if [ "${BUCKET_EXISTS}" = true ] && [ "${STATE_EXISTS}" = true ]; then
  echo "Bootstrap already run."
  exit 0
fi

# Create bucket if it doesn't exist
if [ "${BUCKET_EXISTS}" = false ]; then
  echo "Running bootstrap."
  cd "${REPO_ROOT}/terraform/bootstrap"
  terraform init
  terraform apply -auto-approve
  cd "${REPO_ROOT}"
fi

# Copy state if it doesn't exist
if [ "${STATE_EXISTS}" = false ]; then
  echo "State file does not exist in s3 bucket. Copying bootstrap state to bucket."
  aws s3 cp "${REPO_ROOT}/terraform/bootstrap/terraform.tfstate" "s3://${STATE_BUCKET}/${STATE_KEY}"
fi

echo "Bootstrap complete."
