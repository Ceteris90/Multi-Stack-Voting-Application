# ==============================================================================
# ENVIRONMENT: DEVELOPMENT (ORCHESTRATION LAYER)
# TARGET ARCHITECTURE: Multi-Stack DevSecOps Voting Application (hh.drawio.jpg)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. CORE NETWORKING MODULE (Instantiates Network Architecture)
# ------------------------------------------------------------------------------
module "network" {
  source = "../../modules/network"
  region = var.region
}

# ------------------------------------------------------------------------------
# 2. AUTOMATION & PIPELINE TOOLING (Public Subnets Layer)
# ------------------------------------------------------------------------------
# Provisions Jenkins Master, Jenkins Slave, and SonarQube Server as independent
# hosts within the public network boundaries.
module "compute" {
  source             = "../../modules/compute"
  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  ami_id             = var.ami_id
  instance_type     = var.instance_type
  key_name           = var.key_name
  jenkins_sg_id      = aws_security_group.sg_jenkins.id
}

# ------------------------------------------------------------------------------
# 3. KUBERNETES CLUSTER MANAGEMENT (Private Subnets Layer)
# ------------------------------------------------------------------------------
# Deploys EKS Control Plane and Managed Worker Node Groups securely into 
# Private Subnets 10.0.11.0/24 & 10.0.12.0/24.
module "eks" {
  source             = "../../modules/eks"
  cluster_name       = "dev-votingapp-cluster"
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  node_instance_type = "t3.medium" # Upgraded for microservice scheduling stability
}

# ==============================================================================
# SECURITY CLASSIFICATION LAYER (FIREWALL REGULATION RULES)
# ==============================================================================

# ------------------------------------------------------------------------------
# PIPELINE COMPONENT FIREWALL: Jenkins & SonarQube Tooling
# ------------------------------------------------------------------------------
resource "aws_security_group" "sg_jenkins" {
  name        = "dev-pipeline-tooling-sg"
  description = "Regulate inbound pipeline connections and verification requests"
  vpc_id      = module.network.vpc_id

  ingress {
    description = "Allow UI access to Jenkins Control Panel"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Can narrow this down to your personal gateway IP
  }

  ingress {
    description = "Allow incoming Webhook notifications from GitHub"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow secure configuration dashboard for SonarQube Server"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Secure SSH remote systems administration access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outward resolution dependencies, image registries and updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "dev-pipeline-tooling-sg"
    Project     = "Multi-Stack-Voting-App"
    Terraform   = "true"
  }
}

# ------------------------------------------------------------------------------
# MANAGED DATA STACK COMPONENT: PostgreSQL Database Infrastructure
# ------------------------------------------------------------------------------
resource "aws_security_group" "sg_database" {
  name        = "dev-isolated-database-sg"
  description = "Restrict access to database layer entirely inside internal VPC space"
  vpc_id      = module.network.vpc_id

  ingress {
    description = "Isolate SQL transaction requests exclusively to EKS Private Worker instances"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # Restricted boundary validation matching network module
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "dev-isolated-database-sg"
    Project     = "Multi-Stack-Voting-App"
    Terraform   = "true"
  }
}

# ==============================================================================
# PERSISTENT STORAGE LAYER DATA CONFIGURATION
# ==============================================================================

resource "aws_db_subnet_group" "postgres" {
  name        = "dev-postgres-subnet-group"
  description = "Bind structural data records cross-AZ to Private Subnets 1 and 2"
  subnet_ids  = module.network.private_subnet_ids

  tags = {
    Name        = "dev-postgres-subnet-group"
    Project     = "Multi-Stack-Voting-App"
    Terraform   = "true"
  }
}

resource "aws_db_instance" "postgres" {
  identifier                  = "dev-postgres-multiaz"
  allocated_storage           = 20
  max_allocated_storage       = 100
  storage_type                = "gp3"
  engine                      = "postgres"
  engine_version              = "15.18"
  instance_class              = "db.t3.micro"
  db_name                     = "postgres"
  username                    = "postgres"
  password                    = var.db_password # SECURE PRACTICE: Controlled via variables file
  publicly_accessible         = false           # Never expose to public internet routes
  multi_az                    = true            # High-Availability architecture replication enabled
  skip_final_snapshot         = true
  apply_immediately           = true
  vpc_security_group_ids      = [aws_security_group.sg_database.id]
  db_subnet_group_name        = aws_db_subnet_group.postgres.name
  deletion_protection         = false

  tags = {
    Name        = "dev-postgres-multiaz"
    Project     = "Multi-Stack-Voting-App"
    Terraform   = "true"
  }
}