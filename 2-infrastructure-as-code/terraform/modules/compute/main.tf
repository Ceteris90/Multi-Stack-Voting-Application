# modules/compute/main.tf

# ------------------------------------------------------------------------------
# JENKINS MASTER HOST (Orchestration Dashboard)
# ------------------------------------------------------------------------------
resource "aws_instance" "jenkins_master" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = element(var.public_subnet_ids, 0) # Deploys in Public Subnet A
  vpc_security_group_ids = [var.jenkins_sg_id]
  key_name               = var.key_name

  root_block_device {
    volume_size           = 30 # Slightly larger for build history storage
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "dev-jenkins-master"
    Project     = "Multi-Stack-Voting-App"
    Role        = "CI-CD-Orchestration"
    Terraform   = "true"
  }
}

# ------------------------------------------------------------------------------
# JENKINS SLAVE HOST (The Build, Trivy & Docker Executor)
# ------------------------------------------------------------------------------
resource "aws_instance" "jenkins_slave" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = element(var.public_subnet_ids, 1) # Deploys in Public Subnet B for distribution
  vpc_security_group_ids = [var.jenkins_sg_id]
  key_name               = var.key_name

  root_block_device {
    volume_size           = 40 # Upgraded space to store Docker build layers and cache
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "dev-jenkins-slave"
    Project     = "Multi-Stack-Voting-App"
    Role        = "Pipeline-Execution-Worker"
    Terraform   = "true"
  }
}

# ------------------------------------------------------------------------------
# SONARQUBE SERVER HOST (Static Application Security Testing Dashboard)
# ------------------------------------------------------------------------------
resource "aws_instance" "sonarqube" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = element(var.public_subnet_ids, 0) # Deploys in Public Subnet A
  vpc_security_group_ids = [var.jenkins_sg_id]
  key_name               = var.key_name

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "dev-sonarqube-server"
    Project     = "Multi-Stack-Voting-App"
    Role        = "SAST-Quality-Gate"
    Terraform   = "true"
  }
}