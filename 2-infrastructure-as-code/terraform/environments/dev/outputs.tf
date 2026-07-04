# environments/dev/outputs.tf

output "dev_jenkins_master_ip" {
  value       = module.compute.jenkins_master_public_ip
  description = "The public IP entry point for Jenkins Master UI"
}

output "dev_jenkins_slave_ip" {
  value       = module.compute.jenkins_slave_public_ip
  description = "The public IP of your build execution workspace node"
}

output "dev_sonarqube_ip" {
  value       = module.compute.sonarqube_public_ip
  description = "The public IP entry point for your SonarQube Server Quality Gate"
}

output "dev_eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "The endpoint URL for your EKS control plane API"
}

output "dev_alerts_sns_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "SNS topic ARN for deployment alert notifications"
}