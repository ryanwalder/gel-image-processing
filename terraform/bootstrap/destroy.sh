#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Script to delete all the resources created by Terraform.
#
# Used here instead of `terraform destroy` as we set lifecycle:prevent_delete on
# a load of resources so terraform won't delete them wihtout editing the
# terraform code which seems a bit onerous for a test like this.
#
# Usage: ./destroy.sh [--force]
#   --force   Skip confirmation prompt and proceed with deletion

FORCE_DELETE=false
if [[ "${1:-}" == "--force" ]]; then
  FORCE_DELETE=true
fi

# Project name
PROJECT_NAME="gel-exifstrip"

# Set AWS region
export AWS_DEFAULT_REGION="eu-west-2"
# Disable the pager as it waits for user input
export AWS_PAGER=""

# Define variables
BUCKETS=(
  "${PROJECT_NAME}-ingest"
  "${PROJECT_NAME}-processed"
  "${PROJECT_NAME}-access-logs"
  "${PROJECT_NAME}-terraform-state"
  "${PROJECT_NAME}-deployment"
)
ALIASES=(
  "s3-encryption"
  "dynamodb-encryption"
  "access-logs-encryption"
  "ingest-encryption"
  "processed-encryption"
  "deployment-encryption"
)
ROLE_NAME="${PROJECT_NAME}-lambda-role"
LAMBDA_FUNCTION="${PROJECT_NAME}-image-processor"
LAMBDA_LAYER="${PROJECT_NAME}-lambda-layer"
LOG_GROUP="/aws/lambda/${PROJECT_NAME}-image-processor"

echo "Starting destruction of Terraform-deployed resources for ${PROJECT_NAME}..."

# Collect list of resources to delete
RESOURCES_TO_DELETE=()

# Check Lambda function
if aws lambda get-function --function-name "${LAMBDA_FUNCTION}" &>/dev/null; then
  RESOURCES_TO_DELETE+=("Lambda function: ${LAMBDA_FUNCTION}")
fi

# Check Lambda layer
if aws lambda list-layer-versions --layer-name "${LAMBDA_LAYER}" --query 'LayerVersions[0]' --output text 2>/dev/null | grep -q .; then
  RESOURCES_TO_DELETE+=("Lambda layer: ${LAMBDA_LAYER}")
fi

# Check S3 buckets
for bucket in "${BUCKETS[@]}"; do
  if aws s3 ls "s3://${bucket}" &>/dev/null; then
    RESOURCES_TO_DELETE+=("S3 bucket: ${bucket}")
  fi
done

# Check DynamoDB
if aws dynamodb describe-table --table-name "${PROJECT_NAME}-terraform-state-lock" &>/dev/null; then
  RESOURCES_TO_DELETE+=("DynamoDB table: ${PROJECT_NAME}-terraform-state-lock")
fi

# Check KMS aliases
for alias_suffix in "${ALIASES[@]}"; do
  alias_name="alias/${PROJECT_NAME}-${alias_suffix}"
  if aws kms describe-key --key-id "${alias_name}" &>/dev/null; then
    RESOURCES_TO_DELETE+=("KMS alias: ${alias_name}")
  fi
done

# Check IAM role
if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
  RESOURCES_TO_DELETE+=("IAM role: ${ROLE_NAME}")
fi

# Check IAM users
for user in "user_a" "user_b"; do
  if aws iam get-user --user-name "${user}" &>/dev/null; then
    RESOURCES_TO_DELETE+=("IAM user: ${user}")
  fi
done

# Check CloudWatch log group
if aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" --query 'logGroups[?logGroupName==`'"${LOG_GROUP}"'`].logGroupName' --output text | grep -q "${LOG_GROUP}"; then
  RESOURCES_TO_DELETE+=("CloudWatch log group: ${LOG_GROUP}")
fi

# Check SSM Parameters
SSM_PARAMS=("ingest-bucket" "processed-bucket" "processed-kms-key-arn" "max-file-size" "log-level")
for param in "${SSM_PARAMS[@]}"; do
  param_name="/${PROJECT_NAME}/${param}"
  if aws ssm get-parameter --name "${param_name}" &>/dev/null; then
    RESOURCES_TO_DELETE+=("SSM Parameter: ${param_name}")
  fi
done

# Display resources
if [ ${#RESOURCES_TO_DELETE[@]} -eq 0 ]; then
  echo "No resources found to delete."
  exit 0
fi

echo "The following resources will be deleted:"
for resource in "${RESOURCES_TO_DELETE[@]}"; do
  echo "  - ${resource}"
done

# Interactive confirmation (unless --force is used)
if [[ "${FORCE_DELETE}" == "false" ]]; then
  read -p "Do you want to proceed with deletion? (y/N): " -r
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Delete Lambda function
if aws lambda get-function --function-name "${LAMBDA_FUNCTION}" &>/dev/null; then
  echo "Deleting Lambda function..."
  aws lambda delete-function --function-name "${LAMBDA_FUNCTION}"
else
  echo "Lambda function already deleted or does not exist."
fi

# Delete Lambda layer (all versions)
if aws lambda list-layer-versions --layer-name "${LAMBDA_LAYER}" --query 'LayerVersions[0]' --output text 2>/dev/null | grep -q .; then
  echo "Deleting Lambda layer versions..."
  for version in $(aws lambda list-layer-versions --layer-name "${LAMBDA_LAYER}" --query 'LayerVersions[].Version' --output text); do
    aws lambda delete-layer-version --layer-name "${LAMBDA_LAYER}" --version-number "${version}"
  done
else
  echo "Lambda layer already deleted or does not exist."
fi

# Empty and delete S3 buckets
for bucket in "${BUCKETS[@]}"; do
  if aws s3 ls "s3://${bucket}" &>/dev/null; then
    echo "Emptying bucket ${bucket}..."
    aws s3 rm "s3://${bucket}" --recursive
    echo "Deleting versions and delete markers for ${bucket}..."
    version_objects=$(aws s3api list-object-versions --bucket "${bucket}" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null)
    if [ "$version_objects" != "null" ] && [ "$version_objects" != "[]" ]; then
      aws s3api delete-objects --bucket "${bucket}" --delete "{\"Objects\": $version_objects}" || true
    fi
    marker_objects=$(aws s3api list-object-versions --bucket "${bucket}" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null)
    if [ "$marker_objects" != "null" ] && [ "$marker_objects" != "[]" ]; then
      aws s3api delete-objects --bucket "${bucket}" --delete "{\"Objects\": $marker_objects}" || true
    fi
    echo "Deleting bucket ${bucket}..."
    aws s3 rb "s3://${bucket}"
  else
    echo "Bucket ${bucket} already deleted or does not exist."
  fi
done

# Delete DynamoDB table
if aws dynamodb describe-table --table-name "${PROJECT_NAME}-terraform-state-lock" &>/dev/null; then
  echo "Deleting DynamoDB table..."
  aws dynamodb delete-table --table-name "${PROJECT_NAME}-terraform-state-lock"
else
  echo "DynamoDB table already deleted or does not exist."
fi

# Delete KMS aliases and schedule key deletions
for alias_suffix in "${ALIASES[@]}"; do
  alias_name="alias/${PROJECT_NAME}-${alias_suffix}"
  if aws kms describe-key --key-id "${alias_name}" &>/dev/null; then
    echo "Deleting KMS alias ${alias_name}..."
    key_id=$(aws kms describe-key --key-id "${alias_name}" --query 'KeyMetadata.KeyId' --output text)
    aws kms delete-alias --alias-name "${alias_name}"
    if [ -n "${key_id}" ]; then
      echo "Scheduling deletion for KMS key ${key_id}..."
      aws kms schedule-key-deletion --key-id "${key_id}" --pending-window-in-days 7
    fi
  else
    echo "KMS alias ${alias_name} already deleted or does not exist."
  fi
done

# Delete IAM role
if aws iam get-role --role-name "${ROLE_NAME}" &>/dev/null; then
  echo "Deleting IAM role policies..."
  for policy in $(aws iam list-role-policies --role-name "${ROLE_NAME}" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${policy}"
  done
  echo "Deleting IAM role..."
  aws iam delete-role --role-name "${ROLE_NAME}"
else
  echo "IAM role already deleted or does not exist."
fi

# Delete IAM users
for user in "user_a" "user_b"; do
  if aws iam get-user --user-name "${user}" &>/dev/null; then
    echo "Deleting access keys for user ${user}..."
    for key_id in $(aws iam list-access-keys --user-name "${user}" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
      aws iam delete-access-key --user-name "${user}" --access-key-id "${key_id}"
    done
    echo "Deleting inline policies for user ${user}..."
    for policy in $(aws iam list-user-policies --user-name "${user}" --query 'PolicyNames[]' --output text); do
      aws iam delete-user-policy --user-name "${user}" --policy-name "${policy}"
    done
    echo "Deleting user ${user}..."
    aws iam delete-user --user-name "${user}"
  else
    echo "User ${user} already deleted or does not exist."
  fi
done

# Delete CloudWatch log group
if aws logs describe-log-groups --log-group-name-prefix "${LOG_GROUP}" --query 'logGroups[?logGroupName==`'"${LOG_GROUP}"'`].logGroupName' --output text | grep -q "${LOG_GROUP}"; then
  echo "Deleting CloudWatch log group..."
  aws logs delete-log-group --log-group-name "${LOG_GROUP}"
else
  echo "CloudWatch log group already deleted or does not exist."
fi

# Delete SSM Parameters
SSM_PARAMS=("ingest-bucket" "processed-bucket" "processed-kms-key-arn" "max-file-size" "log-level")
for param in "${SSM_PARAMS[@]}"; do
  param_name="/${PROJECT_NAME}/${param}"
  if aws ssm get-parameter --name "${param_name}" &>/dev/null; then
    echo "Deleting SSM Parameter ${param_name}..."
    aws ssm delete-parameter --name "${param_name}"
  else
    echo "SSM Parameter ${param_name} already deleted or does not exist."
  fi
done

echo "Destruction complete."
