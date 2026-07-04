# ==============================================================================
# ENVIRONMENT: DEVELOPMENT (VARIABLES DECLARATION)
# TARGET ARCHITECTURE: Multi-Stack DevSecOps Voting Application (hh.drawio.jpg)
# ==============================================================================

variable "region" {
  type        = string
  description = "The target AWS Region used across the dev environment network infrastructure."
  default     = "us-east-1"
}

variable "ami_id" {
  type        = string
  description = "The baseline Ubuntu 22.04 LTS AMI ID used for Jenkins Master, Slave, and SonarQube instances."
  default     = "ami-04b70fa74e45c3917" # Canonical, Ubuntu, 22.04 LTS, amd64
}

variable "instance_type" {
  type       = string
  description = "The EC2 instance type used for Jenkins Master, Slave, and SonarQube instances."
  default     = "t3.medium" # Upgraded for microservice scheduling stability
}


variable "key_name" {
  type        = string
  description = "The name of the pre-configured AWS Key Pair used for administrative SSH connections."
  default     = "myironhackerkey"
}

variable "db_password" {
  type        = string
  description = "The master password for the Multi-AZ PostgreSQL relational database engine."
  sensitive   = true # 🔒 Prevents Terraform from exposing your plain-text password to stdout logs
}

variable "alert_email" {
  type        = string
  description = "Email address to receive SNS alert notifications. Leave empty to disable email alerts."
  default     = ""
}