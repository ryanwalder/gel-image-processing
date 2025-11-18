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
