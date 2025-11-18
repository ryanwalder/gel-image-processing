# IAM Users for application access

# IAM User A - Read/Write access to ingest bucket
resource "aws_iam_user" "user_a" {
  name = "user_a"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    Purpose     = "Ingest bucket upload access"
  }
}

resource "aws_iam_user_policy" "user_a_policy" {
  user = aws_iam_user.user_a.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.bucket_ingest.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.bucket_ingest.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = aws_kms_key.ingest_bucket_encryption.arn
      }
    ]
  })
}

resource "aws_iam_access_key" "user_a_key" {
  user = aws_iam_user.user_a.name
}

# IAM User B - Read access to processed bucket
resource "aws_iam_user" "user_b" {
  name = "user_b"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    Purpose     = "Processed bucket read access"
  }
}

resource "aws_iam_user_policy" "user_b_policy" {
  user = aws_iam_user.user_b.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.bucket_processed.arn}/*",
          aws_s3_bucket.bucket_processed.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.processed_bucket_encryption.arn
      }
    ]
  })
}

resource "aws_iam_access_key" "user_b_key" {
  user = aws_iam_user.user_b.name
}

