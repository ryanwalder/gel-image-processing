terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

output "ingest_bucket_name" {
  description = "Name of the ingest S3 bucket"
  value       = aws_s3_bucket.bucket_ingest.id
}

output "processed_bucket_name" {
  description = "Name of the processed S3 bucket"
  value       = aws_s3_bucket.bucket_processed.id
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.image_processor.arn
}

output "lambda_role_arn" {
  description = "ARN of the Lambda IAM role"
  value       = aws_iam_role.lambda_role.arn
}

output "user_a_access_key_id" {
  description = "Access Key ID for user_a"
  value       = aws_iam_access_key.user_a_key.id
}

output "user_a_secret_access_key" {
  description = "Secret Access Key for user_a"
  value       = aws_iam_access_key.user_a_key.secret
  sensitive   = true
}

output "user_b_access_key_id" {
  description = "Access Key ID for user_b"
  value       = aws_iam_access_key.user_b_key.id
}

output "user_b_secret_access_key" {
  description = "Secret Access Key for user_b"
  value       = aws_iam_access_key.user_b_key.secret
  sensitive   = true
}
