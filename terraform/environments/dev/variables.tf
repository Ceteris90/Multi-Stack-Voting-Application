# environments/dev/variables.tf

variable "region" {
  type        = string
  description = "The target AWS Region used across the dev environment"
  default     = "us-east-1"
}

variable "ami_id" {
  type        = string
  description = "The Ubuntu AMI ID for your EC2 instances"
  default     = "ami-04b70fa74e45c3917"
}