# modules/compute/outputs.tf
output "public_ip_a" {
  value = aws_instance.instance_a.public_ip
}

output "private_ip_b" {
  value = aws_instance.instance_b.private_ip
}

output "private_ip_c" {
  value = aws_instance.instance_c.private_ip
}