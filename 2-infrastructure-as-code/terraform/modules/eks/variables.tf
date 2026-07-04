# modules/eks/variables.tf

variable "cluster_name" {
  type        = string
  description = "The target identifying name of your EKS deployment cluster"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the cluster is orchestrated"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Secure private subnet IDs list mapping instances across AZs"
}

variable "node_instance_type" {
  type        = string
  description = "The compute size footprint tier for running your cluster workloads"
  default     = "t3.medium"
}