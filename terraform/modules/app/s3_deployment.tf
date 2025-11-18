# S3 bucket for Lambda deployment artifacts
# Separate from ingest bucket to prevent user tampering and recursive triggers

resource "aws_kms_key" "deployment_bucket_encryption" {
  description             = "KMS key for ${var.project_name} deployment bucket encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_kms_alias" "deployment_bucket_encryption" {
  name          = "alias/${var.project_name}-deployment-encryption"
  target_key_id = aws_kms_key.deployment_bucket_encryption.key_id
}

# KMS Key Policy for deployment bucket
resource "aws_kms_key_policy" "deployment_bucket_encryption" {
  key_id = aws_kms_key.deployment_bucket_encryption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Create*",
          "kms:Describe*",
          "kms:Enable*",
          "kms:List*",
          "kms:Put*",
          "kms:Update*",
          "kms:Revoke*",
          "kms:Disable*",
          "kms:Get*",
          "kms:Delete*",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow Lambda to use the key"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_s3_bucket" "bucket_deployment" {
  bucket = "${var.project_name}-deployment"

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_s3_bucket_versioning" "bucket_deployment_versioning" {
  bucket = aws_s3_bucket.bucket_deployment.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_deployment_encryption" {
  bucket = aws_s3_bucket.bucket_deployment.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.deployment_bucket_encryption.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "bucket_deployment_pab" {
  bucket = aws_s3_bucket.bucket_deployment.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "bucket_deployment_logging" {
  bucket = aws_s3_bucket.bucket_deployment.id

  target_bucket = var.access_logs_bucket
  target_prefix = "${var.project_name}-deployment/"
}

resource "aws_s3_bucket_policy" "bucket_deployment_policy" {
  bucket = aws_s3_bucket.bucket_deployment.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedObjectUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.bucket_deployment.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      {
        Sid       = "DenyIncorrectEncryptionHeader"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.bucket_deployment.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.deployment_bucket_encryption.arn
          }
        }
      }
    ]
  })
}
