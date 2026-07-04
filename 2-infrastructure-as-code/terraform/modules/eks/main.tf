# ==============================================================================
# MODULE: EKS COMPONENT PROVISIONER
# TARGET ARCHITECTURE: Multi-Stack DevSecOps Voting Application (hh.drawio.jpg)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. IAM ROLES FOR THE KUBERNETES CONTROL PLANE
# ------------------------------------------------------------------------------
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-control-plane-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy" # 🟢 FIXED: Valid ARN format matching partition schema
}

# ------------------------------------------------------------------------------
# 2. THE EKS MASTER CONTROL PLANE RESOURCE
# ------------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.31" # Supported EKS version in us-east-1

  vpc_config {
    subnet_ids              = var.private_subnet_ids # Keeps control communications private
    endpoint_private_access = true
    endpoint_public_access  = true # Allows you/Jenkins to interface via kubectl
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy]
}

# ------------------------------------------------------------------------------
# 3. IAM ROLES FOR THE PRIVATE KUBERNETES WORKER NODES
# ------------------------------------------------------------------------------
resource "aws_iam_role" "nodes" {
  name = "${var.cluster_name}-worker-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "nodes_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy" 
}

resource "aws_iam_role_policy_attachment" "nodes_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy" 
}

resource "aws_iam_role_policy_attachment" "nodes_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly" 
}

# ------------------------------------------------------------------------------
# 4. MANAGED WORKER NODE GROUP (The actual instances running your Pods)
# ------------------------------------------------------------------------------
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "votingapp-managed-nodes"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.private_subnet_ids # Confines worker hosts to private network zones

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = 2 # Worker Node 1 and Worker Node 2 from your blueprint
    max_size     = 4
    min_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.nodes_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.nodes_AmazonEC2ContainerRegistryReadOnly,
  ]

  tags = {
    Name        = "dev-eks-worker-node"
    Project     = "Multi-Stack-Voting-App"
    Environment = "dev"
  }
}