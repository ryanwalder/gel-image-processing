terraform {
  required_version = ">= 1.0"

  backend "s3" {
    bucket         = "gel-exifstrip-terraform-state"
    key            = "gel-exifstrip/terraform.tfstate"
    region         = "eu-west-2"
    dynamodb_table = "gel-exifstrip-terraform-state-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Core infrastructure module
module "core" {
  source = "./modules/core"

  providers = {
    aws = aws
  }
}

# Application module
module "app" {
  source = "./modules/app"

  providers = {
    aws = aws
  }

  environment        = var.environment
  project_name       = var.project_name
  python_version     = var.python_version
  log_level          = var.log_level
  access_logs_bucket = module.core.access_logs_bucket_name
}

# Outputs
output "ingest_bucket_name" {
  description = "Name of the ingest S3 bucket"
  value       = module.app.ingest_bucket_name
}

output "processed_bucket_name" {
  description = "Name of the processed S3 bucket"
  value       = module.app.processed_bucket_name
}

output "user_a_access_key_id" {
  description = "Access Key ID for user_a"
  value       = module.app.user_a_access_key_id
}

output "user_a_secret_access_key" {
  description = "Secret Access Key for user_a"
  value       = module.app.user_a_secret_access_key
  sensitive   = true
}

output "user_b_access_key_id" {
  description = "Access Key ID for user_b"
  value       = module.app.user_b_access_key_id
}

output "user_b_secret_access_key" {
  description = "Secret Access Key for user_b"
  value       = module.app.user_b_secret_access_key
  sensitive   = true
}
