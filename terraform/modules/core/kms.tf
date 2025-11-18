# KMS key for S3 bucket encryption
resource "aws_kms_key" "s3_encryption" {
  description             = "KMS key for S3 bucket encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_kms_alias" "s3_encryption_alias" {
  name          = "alias/${var.project_name}-s3-encryption"
  target_key_id = aws_kms_key.s3_encryption.key_id
}

# KMS key for DynamoDB encryption
resource "aws_kms_key" "dynamodb_encryption" {
  description             = "KMS key for DynamoDB table encryption"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_kms_alias" "dynamodb_encryption_alias" {
  name          = "alias/${var.project_name}-dynamodb-encryption"
  target_key_id = aws_kms_key.dynamodb_encryption.key_id
}

# KMS key for access logs bucket encryption
resource "aws_kms_key" "access_logs_encryption" {
  description             = "KMS key for access logs bucket encryption"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    Purpose     = "access-logs-encryption"
  }
}

resource "aws_kms_alias" "access_logs_encryption_alias" {
  name          = "alias/${var.project_name}-access-logs-encryption"
  target_key_id = aws_kms_key.access_logs_encryption.key_id
}

