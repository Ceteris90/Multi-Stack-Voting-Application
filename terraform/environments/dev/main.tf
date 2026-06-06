# environments/dev/main.tf
# 1. Instantiate the network module correctly
module "network" {
  source = "../../modules/network"
  region = var.region # <-- Looks for var.region
}

# ==================== SECURITY GROUPS ====================

# Instance A Security Group (Public Frontend / Bastion)

resource "aws_security_group" "sg_a" {
  name        = "frontend-sg"
  description = "Allow HTTP  and SSH access"
  vpc_id      = module.network.vpc_id # <-- FIXED: Changed 'modules' to 'module'

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Results App Dashboard"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from anywhere (or change to your IP for production security)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Instance B Security Group (Redis & Worker)
resource "aws_security_group" "sg_b" {
  name        = "backend-sg"
  description = "Allow Redis from Frontend, SSH via Bastion proxy"
  vpc_id      = module.network.vpc_id

  ingress {
    description     = "Redis port from Frontend Instance"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_a.id] # <-- FIXED: Swapped 'cidr_blocks' out for 'security_groups'
  }

  ingress {
    description     = "SSH proxy via Frontend Instance"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_a.id] # <-- FIXED: Swapped 'cidr_blocks' out for 'security_groups'
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

# Instance C Security Group (PostgreSQL Database)

resource "aws_security_group" "sg_c" {
  name        = "database-sg"
  description = "Allow Postgres access from within the VPC network"
  vpc_id      = module.network.vpc_id

  # 💻 FIXED: Trust the entire internal VPC space for database port 5432
  ingress {
    description = "PostgreSQL traffic from within VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # 🟢 Secure internal VPC-wide tracking
  }

  ingress {
    description     = "SSH proxy via Frontend Instance"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_a.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==================== ALB + ASG BLUEPRINT ====================

resource "aws_security_group" "sg_alb" {
  name        = "alb-sg"
  description = "Allow HTTP/HTTPS from the internet to the ALB"
  vpc_id      = module.network.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "sg_app" {
  name        = "app-asg-sg"
  description = "Allow traffic from ALB to web instances"
  vpc_id      = module.network.vpc_id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_alb.id]
  }

  ingress {
    description = "SSH for administration"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "app" {
  name               = "dev-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sg_alb.id]
  subnets            = module.network.public_subnet_ids
}

resource "aws_lb_target_group" "app" {
  name     = "dev-app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.network.vpc_id

  health_check {
    enabled             = true
    path                = "/"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "dev-app-lt-"
  image_id      = var.ami_id
  instance_type = "t3.micro"
  key_name      = "myironhackerkey"

  vpc_security_group_ids = [aws_security_group.sg_app.id]

  user_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y nginx
              echo "ALB + ASG blueprint" > /var/www/html/index.html
              systemctl enable nginx
              systemctl start nginx
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "dev-app-asg-instance"
    }
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "dev-app-asg"
  min_size                  = 2
  max_size                  = 4
  desired_capacity          = 2
  vpc_zone_identifier       = module.network.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300
  wait_for_capacity_timeout = "10m"

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "dev-app-asg"
    propagate_at_launch = true
  }
}

# ==================== EC2 INSTANCES ====================

# Make sure you have a keypair created in AWS called "myironhackerkey" or change this name
resource "aws_instance" "instance_a" {
  ami                    = var.ami_id
  instance_type          = "t3.micro"
  subnet_id              = module.network.public_subnet_id
  vpc_security_group_ids = [aws_security_group.sg_a.id]
  key_name               = "myironhackerkey"

  tags = {
    Name = "Instance-A-Frontend"
  }
}

resource "aws_instance" "instance_b" {
  ami                    = var.ami_id
  instance_type          = "t3.micro"
  subnet_id              = module.network.private_subnet_b_id
  vpc_security_group_ids = [aws_security_group.sg_b.id]
  key_name               = "myironhackerkey"

  tags = {
    Name = "Instance-B-Backend"
  }
}

resource "aws_db_subnet_group" "postgres" {
  name       = "dev-postgres-subnet-group"
  subnet_ids = [module.network.private_subnet_c_id, module.network.private_subnet_c_b_id]

  tags = {
    Name = "dev-postgres-subnet-group"
  }
}

resource "aws_db_instance" "postgres" {
  identifier                   = "dev-postgres-multiaz"
  allocated_storage            = 20
  storage_type                 = "gp3"
  engine                       = "postgres"
  engine_version               = "15"
  instance_class               = "db.t3.micro"
  db_name                      = "postgres"
  username                     = "postgres"
  password                     = "your_secure_password"
  publicly_accessible          = false
  multi_az                     = true
  backup_retention_period      = 7
  backup_window                = "03:00-04:00"
  maintenance_window           = "Mon:04:30-Mon:05:30"
  storage_encrypted            = true
  deletion_protection          = false
  skip_final_snapshot          = true
  apply_immediately            = true
  vpc_security_group_ids       = [aws_security_group.sg_c.id]
  db_subnet_group_name         = aws_db_subnet_group.postgres.name
  performance_insights_enabled = false

  tags = {
    Name = "dev-postgres-multiaz"
  }
}