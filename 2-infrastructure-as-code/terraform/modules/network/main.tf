# ==============================================================================
# MODULE: NETWORKING LAYERS
# TARGET ARCHITECTURE: Multi-Stack DevSecOps Voting Application (hh.drawio.jpg)
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name                                       = "dev-vpc"
    "kubernetes.io/cluster/dev-votingapp-cluster" = "shared"
  }
}

# ------------------------------------------------------------------------------
# PUBLIC NETWORKING SPACE (ALB, Jenkins Master/Slave, SonarQube)
# ------------------------------------------------------------------------------
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  
  tags = {
    Name                                       = "dev-public-subnet-a"
    "kubernetes.io/cluster/dev-votingapp-cluster" = "shared"
    "kubernetes.io/role/elb"                   = "1" # Required for External ALBs
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24" # Clean sequential network design
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true
  
  tags = {
    Name                                       = "dev-public-subnet-b"
    "kubernetes.io/cluster/dev-votingapp-cluster" = "shared"
    "kubernetes.io/role/elb"                   = "1" # Required for External ALBs
  }
}

# ------------------------------------------------------------------------------
# PRIVATE NETWORKING SPACE (EKS Worker Nodes, Redis, RDS PostgreSQL)
# ------------------------------------------------------------------------------
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.11.0/24" # Match exact blueprint tracking (Worker Node 1)
  availability_zone = "${var.region}a"
  
  tags = {
    Name                                       = "dev-private-worker-a"
    "kubernetes.io/cluster/dev-votingapp-cluster" = "shared"
    "kubernetes.io/role/internal-elb"          = "1" # Required for Private K8s Services
  }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.12.0/24" # Match exact blueprint tracking (Worker Node 2)
  availability_zone = "${var.region}b"
  
  tags = {
    Name                                       = "dev-private-worker-b"
    "kubernetes.io/cluster/dev-votingapp-cluster" = "shared"
    "kubernetes.io/role/internal-elb"          = "1" # Required for Private K8s Services
  }
}

# ------------------------------------------------------------------------------
# INTERNET GATEWAY & NAT ROUTERS
# ------------------------------------------------------------------------------
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "dev-igw" }  
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "dev-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "dev-nat-gw" }
}

# ------------------------------------------------------------------------------
# ROUTING MANAGEMENT
# ------------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "dev-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "dev-private-rt" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

# ------------------------------------------------------------------------------
# ROUTE TABLE ASSOCIATIONS
# ------------------------------------------------------------------------------
resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}