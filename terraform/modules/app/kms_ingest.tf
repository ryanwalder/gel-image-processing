data "aws_caller_identity" "current" {}

# KMS key for ingest bucket encryption
resource "aws_kms_key" "ingest_bucket_encryption" {
  description             = "KMS key for ingest bucket encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    Purpose     = "ingest-bucket-encryption"
  }
}

resource "aws_kms_alias" "ingest_bucket_encryption_alias" {
  name          = "alias/${var.project_name}-ingest-encryption"
  target_key_id = aws_kms_key.ingest_bucket_encryption.key_id
}

# KMS key policy for least-privilege access
resource "aws_kms_key_policy" "ingest_bucket_encryption_policy" {
  key_id = aws_kms_key.ingest_bucket_encryption.id
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
          "kms:CancelKeyDeletion"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow Lambda to use the key"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.lambda_role.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "Allow user_a to use the key"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_user.user_a.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      }
    ]
  })
}

