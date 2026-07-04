terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
    region = "us-east-1"
}

variable "backend_name_prefix" {
  type        = string
  description = "Prefix used to derive unique Terraform backend resource names."
  default     = "votingapp"
}

variable "backend_bucket_name" {
  type        = string
  description = "Optional explicit S3 bucket name for Terraform state backend."
  default     = ""
}

variable "backend_lock_table_name" {
  type        = string
  description = "Optional explicit DynamoDB table name for Terraform state locking."
  default     = ""
}

data "aws_caller_identity" "current" {}

locals {
  derived_prefix   = "${data.aws_caller_identity.current.account_id}-${var.backend_name_prefix}"
  s3_bucket_name   = var.backend_bucket_name != "" ? var.backend_bucket_name : "${local.derived_prefix}-tfstate"
  lock_table_name  = var.backend_lock_table_name != "" ? var.backend_lock_table_name : "${local.derived_prefix}-tflock"
}

# 1. The S3 Bucket for Storing Terraform State Files
# ==================================================

resource "aws_s3_bucket" "terraform_state" {
  bucket        = local.s3_bucket_name # MUST be globally unique
  force_destroy = false # Prevents accidental deletion of your state history

  tags = {
    Name        = "Terraform State Backend"
    Environment = "Dev/Bootstrap"
    Project     = "Multi-Stack-Voting-App"
  }
}

# Enable versioning so you can roll back your infrastructure state if it gets corrupted
# =====================================================================================

resource "aws_s3_bucket_versioning" "state_versioning" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state file at rest since it contains sensitive infrastructure secrets/passwords
# =======================================================================================

resource "aws_s3_bucket_server_side_encryption_configuration" "state_encryption" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access to the state bucket to secure your infrastructure blueprints
# ====================================================================================

resource "aws_s3_bucket_public_access_block" "state_public_block" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 2. The DynamoDB Table for State Locking
# This prevents two developers (or Jenkins and you) from running "terraform apply" at the same time
# =================================================================================================

resource "aws_dynamodb_table" "terraform_locks" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID" # This exact case-sensitive key name is required by Terraform

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "Terraform State Lock Table"
    Environment = "Dev/Bootstrap"
    Project     = "Multi-Stack-Voting-App"
  }
}

# Outputs to verify the exact resource names created
output "s3_bucket_name" {
  value       = aws_s3_bucket.terraform_state.id
  description = "Use this string inside your environments/dev/backend.tf file"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.terraform_locks.id
  description = "Use this string inside your environments/dev/backend.tf file"
}