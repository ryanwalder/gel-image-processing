# Ingest bucket
resource "aws_s3_bucket" "bucket_ingest" {
  bucket = "${var.project_name}-ingest"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    Purpose     = "ingest-bucket"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "bucket_ingest_versioning" {
  bucket = aws_s3_bucket.bucket_ingest.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_ingest_encryption" {
  bucket = aws_s3_bucket.bucket_ingest.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.ingest_bucket_encryption.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bucket_ingest_pab" {
  bucket = aws_s3_bucket.bucket_ingest.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "bucket_ingest_logging" {
  bucket = aws_s3_bucket.bucket_ingest.id

  target_bucket = var.access_logs_bucket
  target_prefix = "ingest/"
}

resource "aws_s3_bucket_policy" "bucket_ingest_policy" {
  bucket = aws_s3_bucket.bucket_ingest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedObjectUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.bucket_ingest.arn}/*"
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
        Resource  = "${aws_s3_bucket.bucket_ingest.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.ingest_bucket_encryption.arn
          }
        }
      }
    ]
  })
}


# Lifecycle rules - expire uploaded images after 1 day
# Fallback in case the processing fails for some reason and doesn't remove the
# source file
resource "aws_s3_bucket_lifecycle_configuration" "bucket_ingest_lifecycle" {
  bucket = aws_s3_bucket.bucket_ingest.id

  rule {
    id     = "expire_ingest_objects"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

resource "aws_s3_bucket_notification" "bucket_ingest_notification" {
  bucket = aws_s3_bucket.bucket_ingest.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

