# Processed bucket
resource "aws_s3_bucket" "bucket_processed" {
  bucket = "${var.project_name}-processed"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    Purpose     = "destination-bucket"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "bucket_processed_versioning" {
  bucket = aws_s3_bucket.bucket_processed.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_processed_encryption" {
  bucket = aws_s3_bucket.bucket_processed.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.processed_bucket_encryption.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bucket_processed_pab" {
  bucket = aws_s3_bucket.bucket_processed.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "bucket_processed_logging" {
  bucket = aws_s3_bucket.bucket_processed.id

  target_bucket = var.access_logs_bucket
  target_prefix = "processed/"
}

resource "aws_s3_bucket_policy" "bucket_processed_policy" {
  bucket = aws_s3_bucket.bucket_processed.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedObjectUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.bucket_processed.arn}/*"
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
        Resource  = "${aws_s3_bucket.bucket_processed.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.processed_bucket_encryption.arn
          }
        }
      }
    ]
  })
}

