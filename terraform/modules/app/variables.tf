variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "gel-exifstrip"
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 180
}

variable "python_version" {
  description = "Python version for Lambda runtime (must be set via TF_VAR_python_version environment variable)"
  type        = string
}

variable "access_logs_bucket" {
  description = "Name of the S3 bucket for access logs"
  type        = string
}

variable "log_level" {
  description = "Log level for Lambda function"
  type        = string
  default     = "INFO"
}

variable "max_file_size" {
  description = "Maximum file size for uploads in bytes"
  type        = number
  default     = 10485760
}

