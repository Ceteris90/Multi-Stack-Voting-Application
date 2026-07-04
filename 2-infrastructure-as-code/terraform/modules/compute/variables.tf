# modules/compute/variables.tf

variable "vpc_id" {
  type        = string
  description = "The target VPC ID coming from the network execution block"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "The list of distributed public subnets available within the VPC"
}

variable "ami_id" {
  type        = string
  description = "Ubuntu LTS operating system image selector ID"
}

variable "instance_type" {
  type        = string
  description = "The instance type for the automation tooling"
}

variable "key_name" {
  type        = string
  description = "Pre-registered AWS SSH key descriptor"
}

variable "jenkins_sg_id" {
  type        = string
  description = "The ID of the security group managing firewall entry points"
}