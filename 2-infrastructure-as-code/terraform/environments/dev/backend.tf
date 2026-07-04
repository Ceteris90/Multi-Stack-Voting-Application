terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "ceteris90-votingapp-tfstate-bucket"
    key            = "dev/multi-stack-voting-app.tfstate" # Path inside the bucket
    region         = "us-east-1"
    use_lockfile   = true
    encrypt        = true
  }
}

provider "aws" {
  region = var.region # <-- Looks for var.region
}