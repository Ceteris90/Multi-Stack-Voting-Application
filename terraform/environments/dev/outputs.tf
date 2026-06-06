# environments/dev/outputs.tf

output "instance_a_public_ip" {
  description = "Public IP of Frontend / Bastion Host"
  value       = aws_instance.instance_a.public_ip # <-- FIXED: Pulls actual Public IP
}

output "instance_b_private_ip" {
  description = "Private IP of Backend Services (Redis/Worker)"
  value       = aws_instance.instance_b.private_ip # <-- FIXED: Pulls actual Private IP
}

output "db_endpoint" {
  description = "RDS PostgreSQL endpoint for the Multi-AZ database"
  value       = aws_db_instance.postgres.address
}

output "db_port" {
  description = "RDS PostgreSQL port"
  value       = aws_db_instance.postgres.port
}

output "alb_dns_name" {
  description = "DNS name of the application load balancer"
  value       = aws_lb.app.dns_name
}

output "asg_name" {
  description = "Autoscaling group created for the web tier"
  value       = aws_autoscaling_group.app.name
}