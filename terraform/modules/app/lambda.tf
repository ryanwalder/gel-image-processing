# SSM Parameters for Lambda configuration
resource "aws_ssm_parameter" "ingest_bucket" {
  name  = "/${var.project_name}/ingest-bucket"
  type  = "String"
  value = aws_s3_bucket.bucket_ingest.id

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_ssm_parameter" "processed_bucket" {
  name  = "/${var.project_name}/processed-bucket"
  type  = "String"
  value = aws_s3_bucket.bucket_processed.id

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_ssm_parameter" "processed_kms_key_arn" {
  name  = "/${var.project_name}/processed-kms-key-arn"
  type  = "String"
  value = aws_kms_key.processed_bucket_encryption.arn

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_ssm_parameter" "max_file_size" {
  name  = "/${var.project_name}/max-file-size"
  type  = "String"
  value = tostring(var.max_file_size)

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_ssm_parameter" "log_level" {
  name  = "/${var.project_name}/log-level"
  type  = "String"
  value = var.log_level

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# CloudWatch Log Group for Lambda with retention
resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${var.project_name}-image-processor"
  retention_in_days = 30

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_lambda_function" "image_processor" {
  function_name = "${var.project_name}-image-processor"
  runtime       = "python${var.python_version}"
  handler       = "lambda_function.lambda_handler"
  memory_size   = 512
  timeout       = var.lambda_timeout

  s3_bucket         = aws_s3_bucket.bucket_deployment.id
  s3_key            = aws_s3_object.lambda_zip.key
  s3_object_version = aws_s3_object.lambda_zip.version_id
  # Redeploy if the lambda updates
  source_code_hash = base64sha256(jsonencode({
    code  = aws_s3_object.lambda_zip.source_hash
    layer = aws_lambda_layer_version.lambda_layer.arn
  }))

  layers = [aws_lambda_layer_version.lambda_layer.arn]

  role = aws_iam_role.lambda_role.arn

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.lambda_log_group]

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_s3_object" "lambda_zip" {
  bucket      = aws_s3_bucket.bucket_deployment.id
  key         = "lambda_function.zip"
  source      = "${path.root}/../.dist/lambda_function.zip"
  source_hash = filemd5("${path.root}/../.dist/lambda_function.zip")

  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.deployment_bucket_encryption.arn
}


resource "aws_lambda_layer_version" "lambda_layer" {
  layer_name          = "${var.project_name}-lambda-layer"
  compatible_runtimes = ["python${var.python_version}"]
  s3_bucket           = aws_s3_bucket.bucket_deployment.id
  s3_key              = aws_s3_object.lambda_layer_zip.key
  source_code_hash    = aws_s3_object.lambda_layer_zip.source_hash
}

resource "aws_s3_object" "lambda_layer_zip" {
  bucket      = aws_s3_bucket.bucket_deployment.id
  key         = "lambda_layer.zip"
  source      = "${path.root}/../.dist/lambda_layer.zip"
  source_hash = filemd5("${path.root}/../.dist/lambda_layer.zip")

  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.deployment_bucket_encryption.arn
}

# Allow S3 bucket to invoke Lambda function
resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.image_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.bucket_ingest.arn

  lifecycle {
    replace_triggered_by = [aws_lambda_function.image_processor]
  }
}

