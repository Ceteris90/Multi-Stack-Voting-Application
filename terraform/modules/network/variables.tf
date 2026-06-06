# modules/network/variables.tf
variable "region" {
  type        = string
  description = "The target AWS region passed from the environment layer"
}