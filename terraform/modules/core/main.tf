terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Outputs
output "state_bucket_name" {
  description = "Name of the S3 bucket for Terraform state"
  value       = aws_s3_bucket.terraform_state.id
}

output "access_logs_bucket_name" {
  description = "Name of the S3 bucket for access logs"
  value       = aws_s3_bucket.access_logs.id
}

output "state_lock_table_name" {
  description = "Name of the DynamoDB table for state locking"
  value       = aws_dynamodb_table.terraform_state_lock.id
}

output "s3_kms_key_arn" {
  description = "ARN of the KMS key for S3 encryption"
  value       = aws_kms_key.s3_encryption.arn
}

output "dynamodb_kms_key_arn" {
  description = "ARN of the KMS key for DynamoDB encryption"
  value       = aws_kms_key.dynamodb_encryption.arn
}
