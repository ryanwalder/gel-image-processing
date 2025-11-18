# IAM Role for Lambda function execution
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# IAM Policy for lambda function
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Read and delete access to ingest bucket
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:CopyObject"
        ]
        Resource = "${aws_s3_bucket.bucket_ingest.arn}/*"
      },
      # Write access to processed bucket
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.bucket_processed.arn}/*"
      },
      # KMS permissions for ingest bucket decryption (read-only)
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.ingest_bucket_encryption.arn
      },
      # KMS permissions for processed bucket encryption/decryption (read-write)
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*"
        ]
        Resource = aws_kms_key.processed_bucket_encryption.arn
      },
      # HeadBucket and ListBucket access for bucket existence checks
      {
        Effect = "Allow"
        Action = [
          "s3:HeadBucket",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.bucket_ingest.arn,
          aws_s3_bucket.bucket_processed.arn
        ]
      },
      # CloudWatch access
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      # CloudWatch Logs access
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:log-group:/aws/lambda/gel-exifstrip-*"
      },
      # KMS access for deployment bucket
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.deployment_bucket_encryption.arn
      },
      # SSM Parameter Store access for configuration
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameters",
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/${var.project_name}/*"
      }
    ]
  })
}



