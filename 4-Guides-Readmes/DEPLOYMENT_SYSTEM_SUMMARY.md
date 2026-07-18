# 🎯 Voting Application - Zero-Hardcoding Deployment System

Complete deployment solution for Multi-Stack Voting Application with zero hardcoded values.

---

## 📦 What's Been Created

### Core Deployment Files

| File | Purpose |
|------|---------|
| **`deploy.sh`** | Main orchestration script - handles build, deploy, cleanup |
| **`deployment.config`** | Central configuration file - ALL settings in one place |
| **`deploy.sh validate`** | Pre-deployment validation - checks tools, configs, AWS access |

### Documentation Files

| File | Purpose |
|------|---------|
| **`QUICK_START.md`** | 2-minute quick reference guide |
| **`README_DEPLOYMENT.md`** | Overview and deployment process |
| **`CI_CD_EXAMPLES.md`** | Ready-to-use GitHub Actions, GitLab CI, Jenkins configs |

---

## 🚀 Quick Start (30 seconds)

```bash
cd ~/Documents/Multi-Stack-Voting-Application

# 1. Edit configuration (customize for your environment)
nano deployment.config

# 2. Validate everything is set up
./deploy.sh validate

# 3. Preview what will be deployed
./deploy.sh deploy --dry-run

# 4. Deploy everything
./deploy.sh deploy

# 5. Access the application
# Voting:  http://localhost:8080
# Results: http://localhost:8081
```

---

## ⚙️ Configuration (deployment.config)

### Must-Configure Values

These MUST be customized before deployment:

```bash
AWS_REGION="us-east-1"                    # Change to your region
TF_VAR_key_name="your-ec2-key-pair"      # Create EC2 key pair first
TF_VAR_ami_id="ami-0c55b159cbfafe1f0"    # Must match your AWS region
DOCKER_REGISTRY="docker.io"               # Or your private registry
DOCKER_REGISTRY_USERNAME="your-username" # Docker Hub username
POSTGRES_PASSWORD="change-this!"         # Strong password for database
```

### Optional Settings

```bash
DEPLOY_METHOD="docker-compose"  # "kubernetes" or "argocd" for K8s
SKIP_BUILD="false"              # Set to "true" to reuse images
SKIP_TERRAFORM="false"          # Set to "true" to skip infrastructure
DRY_RUN="false"                 # Set to "true" for preview mode
```

See `deployment.config` for complete list of settings.

---

## 📋 Complete Command Reference

### Deploy Everything

```bash
# Full deployment (build → provision → deploy)
./deploy.sh deploy

# With custom configuration
./deploy.sh deploy --config deployment-prod.config

# Preview without making changes
./deploy.sh deploy --dry-run

# Skip building images (reuse existing)
./deploy.sh deploy --skip-build

# Skip infrastructure provisioning
./deploy.sh deploy --skip-tf

# Skip Kubernetes deployment
./deploy.sh deploy --skip-k8s
```

### Individual Commands

```bash
# Just build Docker images
./deploy.sh build

# Just provision AWS infrastructure
./deploy.sh infrastructure

# Just deploy to Kubernetes
./deploy.sh kubernetes

# Just deploy with Docker Compose
./deploy.sh compose
```

### Cleanup & Teardown

```bash
# Remove all deployed resources
./deploy.sh cleanup

# Preview cleanup
./deploy.sh cleanup --dry-run
```

### Validation

```bash
# Validate configuration and tools
./deploy.sh validate

# This checks:
# ✓ Required tools (Docker, Terraform, AWS CLI, kubectl)
# ✓ Configuration file and values
# ✓ AWS credentials
# ✓ Project structure
# ✓ File permissions
# ✓ Docker daemon status
```

---

## 🎯 Use Cases

### 1. Local Docker Compose Testing

```bash
# Fast local testing
nano deployment.config
# Set: DEPLOY_METHOD="docker-compose"

./deploy.sh compose

# Access at http://localhost:8080
```

### 2. Kubernetes Development

```bash
# Full infrastructure + K8s deployment
nano deployment.config
# Set: DEPLOY_METHOD="kubernetes"
# Set: SKIP_BUILD="false"

# First ensure kubeconfig configured
aws eks update-kubeconfig --name dev-votingapp-cluster

./deploy.sh deploy
```

### 3. Production with Private Registry

```bash
# Configure for production
cp deployment.config deployment-prod.config
nano deployment-prod.config

# Set values for production:
# AWS_REGION="us-east-1"
# DOCKER_REGISTRY="123456789.dkr.ecr.us-east-1.amazonaws.com"
# POSTGRES_PASSWORD="very-strong-password"

./deploy.sh deploy --config deployment-prod.config
```

### 4. CI/CD Pipeline Integration

```bash
# GitHub Actions, GitLab CI, or Jenkins can use:
./deploy.sh deploy

# With secrets from CI/CD environment variables
# All config sourced from deployment.config which CI/CD creates
```

### 5. Infrastructure Only (No Application)

```bash
./deploy.sh infrastructure
```

### 6. Application Only (Infrastructure Already Exists)

```bash
./deploy.sh deploy --skip-tf
```

---

## 📊 What Gets Deployed

### With `./deploy.sh deploy`

✅ **Docker Containers:**
- Vote application (Flask)
- Result application (Node.js)
- Worker service (C#)
- Redis cache
- PostgreSQL database

✅ **AWS Infrastructure** (via Terraform):
- VPC with public/private subnets
- EKS Kubernetes cluster
- EC2 instances (Jenkins, SonarQube)
- Security groups and network policies
- RDS PostgreSQL database
- ElastiCache Redis

✅ **Kubernetes Deployments** (if DEPLOY_METHOD="kubernetes"):
- Voting app deployment
- Result app deployment
- Worker deployment
- Database deployment
- Cache deployment

---

## 📝 Logs and Monitoring

### Deployment Logs

```bash
# Real-time logs
tail -f /tmp/voting-app-deployment.log

# Or after deployment
cat /tmp/voting-app-deployment.log | grep ERROR
```

### Docker Compose Monitoring

```bash
# Service status
docker-compose ps

# View logs
docker-compose logs -f vote
docker-compose logs -f result
docker-compose logs -f worker

# Access services
curl http://localhost:8080/  # Voting
curl http://localhost:8081/  # Results
```

### Kubernetes Monitoring

```bash
# Deployment status
kubectl get deployments -n voting-app

# Pod status
kubectl get pods -n voting-app -o wide

# Service endpoints
kubectl get svc -n voting-app

# View logs
kubectl logs -f deployment/vote -n voting-app

# Port forward
kubectl port-forward svc/vote 8080:80 -n voting-app
```

### AWS Monitoring

```bash
# EKS Cluster
aws eks describe-cluster --name dev-votingapp-cluster

# EC2 Instances
aws ec2 describe-instances --region us-east-1 --query 'Reservations[].Instances[].[InstanceId,State.Name,PrivateIpAddress]' --output table

# RDS Database
aws rds describe-db-instances --region us-east-1

# Terraform State
cd 2-infrastructure-as-code/terraform/environments/dev
terraform state list
```

---

## 🔧 Troubleshooting

### Validate Setup

```bash
./deploy.sh validate
# Checks all prerequisites before attempting deployment
```

### Common Issues

| Issue | Solution |
|-------|----------|
| "Docker not found" | Install Docker: https://docs.docker.com/get-docker/ |
| "AWS credentials not found" | Run: `aws configure` |
| "Terraform init failed" | Check AWS credentials and region |
| "kubectl not connecting" | Update kubeconfig: `aws eks update-kubeconfig --name dev-votingapp-cluster` |
| "Port 8080 already in use" | Change port in docker-compose.yml |
| "Database password rejected" | Update POSTGRES_PASSWORD in deployment.config |

### Debug Mode

```bash
# Verbose logging
export TF_LOG=DEBUG
./deploy.sh deploy

# Or check logs
tail -f /tmp/voting-app-deployment.log | grep -i error
```

### Manual Cleanup

If `./deploy.sh cleanup` fails:

```bash
# Docker
docker-compose down -v

# Kubernetes
kubectl delete namespace voting-app

# AWS (careful!)
cd 2-infrastructure-as-code/terraform/environments/dev
terraform destroy
```

---

## 🔐 Security Best Practices

### Never Commit Secrets

```bash
# Create local secret file (add to .gitignore)
cat > .deployment-secrets.sh << EOF
export POSTGRES_PASSWORD="actual-password"
export DOCKER_REGISTRY_PASSWORD="actual-token"
export AWS_ACCESS_KEY_ID="actual-key"
EOF

# Use before deploying
source .deployment-secrets.sh
./deploy.sh deploy
```

### AWS Secrets Manager

```bash
# Store secrets in AWS
aws secretsmanager create-secret --name voting-app/db-password \
  --secret-string "your-password"

# Reference in deployment (update deploy.sh)
POSTGRES_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id voting-app/db-password --query SecretString --output text)
```

### IAM Roles (Preferred over Access Keys)

```bash
# Create IAM role for EC2/EKS
aws iam create-role --role-name voting-app-deployer \
  --assume-role-policy-document file://trust-policy.json

# Assign policies instead of using access keys
aws iam attach-role-policy --role-name voting-app-deployer \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSFullAccess
```

---

## 📚 Complete Documentation

| File | Contents |
|------|----------|
| `QUICK_START.md` | 2-minute quick reference |
| `README_DEPLOYMENT.md` | Complete deployment reference |
| `CI_CD_EXAMPLES.md` | GitHub Actions, GitLab CI, Jenkins examples |
| `deploy.sh` | Main deployment script (self-documented) |
| `deployment.config` | Configuration file with descriptions |
| `deploy.sh validate` | Validation script with detailed checks |

---

## ✅ Next Steps

1. **Review Configuration**
   ```bash
   nano deployment.config
   ```

2. **Validate Setup**
   ```bash
   ./deploy.sh validate
   ```

3. **Preview Deployment**
   ```bash
   ./deploy.sh deploy --dry-run
   ```

4. **Deploy**
   ```bash
   ./deploy.sh deploy
   ```

5. **Monitor**
   ```bash
   # Docker Compose
   docker-compose logs -f
   
   # Or Kubernetes
   kubectl logs -f deployment/vote -n voting-app
   ```

6. **Access Application**
   - Voting: http://localhost:8080
   - Results: http://localhost:8081

---

## 📞 Support

- **Logs**: `/tmp/voting-app-deployment.log`
- **Validation**: `./deploy.sh validate`
- **Dry-run**: `./deploy.sh deploy --dry-run`
- **Config help**: `nano deployment.config` (all settings documented)
- **Full guide**: `README_DEPLOYMENT.md`

---

## 🎓 Architecture

```
User Request
    ↓
deployment.config (All configuration)
    ↓
deploy.sh (Orchestration)
   ├── validate command (Pre-flight checks)
    ├── Docker Build (1-application-source/)
    ├── Docker Push (Docker registry)
    ├── Terraform Apply (2-infrastructure-as-code/)
    ├── Kubernetes Deploy (3-gitops-manifests/)
    └── Docker Compose (docker-compose.yml)
```

---

**Everything is configurable, nothing is hardcoded. You control everything through `deployment.config`.**
