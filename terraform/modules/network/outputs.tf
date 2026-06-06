# modules/network/outputs.tf

output "vpc_id" { 
  value = aws_vpc.main.id 
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public.id, aws_subnet.public_b.id]
}

output "private_subnet_b_id" {
  value = aws_subnet.private_b.id
}

output "private_subnet_ids" {
  value = [aws_subnet.private_b.id, aws_subnet.private_b_b.id]
}

output "private_subnet_c_id" {
  value = aws_subnet.private_c.id
}

output "private_subnet_c_b_id" {
  value = aws_subnet.private_c_b.id
}

output "database_subnet_ids" {
  value = [aws_subnet.private_c.id, aws_subnet.private_c_b.id]
}