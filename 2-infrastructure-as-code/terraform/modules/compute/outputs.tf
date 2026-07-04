# modules/compute/outputs.tf

output "jenkins_master_public_ip" {
  value       = aws_instance.jenkins_master.public_ip
  description = "Public IP address to access the primary Jenkins interface (Port 8080)"
}

output "jenkins_slave_public_ip" {
  value       = aws_instance.jenkins_slave.public_ip
  description = "Public IP of the pipeline worker execution node"
}

output "sonarqube_public_ip" {
  value       = aws_instance.sonarqube.public_ip
  description = "Public IP address to access the SonarQube Code Analyzer (Port 9000)"
}