# modules/eks/outputs.tf

output "cluster_endpoint" {
  value       = aws_eks_cluster.main.endpoint
  description = "The secure endpoint URL to reach your Kubernetes API Control Plane."
}

output "cluster_name" {
  value       = aws_eks_cluster.main.name
  description = "The verified operational name of the initialized cluster."
}

output "cluster_certificate_authority_data" {
  value       = aws_eks_cluster.main.certificate_authority[0].data
  description = "Base64 encoded certificate data required to authenticate connections."
}