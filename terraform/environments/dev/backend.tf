terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket = "ironhack-voter-result-112233-us-east-1"
    key = "dev/terraform.tfstate"
    region = "us-east-1"
    encrypt = true

    use_lockfile   = true
  }
}

provider "aws" {
  region = var.region # <-- Looks for var.region
}