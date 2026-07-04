# 🚀 Voting Application - Complete Deployment System

**Zero hardcoding • One-file configuration • Complete automation**

This deployment system eliminates all hardcoded values and provides a single configuration file to control everything - building Docker images, provisioning AWS infrastructure, and deploying to Kubernetes or Docker Compose.

---

## ⚡ 30-Second Quick Start

```bash
cd ~/Documents/Multi-Stack-Voting-Application

# 1. Edit ONE configuration file
nano deployment.config

# 2. Validate setup
./validate.sh

# 3. Deploy everything
./deploy.sh deploy
```

That's it! Everything is configured through `deployment.config` - no hardcoding anywhere.

---

## 📁 What You Get

### Deployment Scripts (Executable)
- **`deploy.sh`** - Main orchestrator (19KB, fully documented)
- **`validate.sh`** - Pre-deployment validation (9KB)

### Configuration (Centralized)
- **`deployment.config`** - All settings in ONE place (never hardcoded)

### Documentation (Complete)
- **`QUICK_START.md`** - 2-minute reference guide
- **`README_DEPLOYMENT.md`** - Overview and deployment process
- **`DEPLOYMENT_SYSTEM_SUMMARY.md`** - Architecture and features overview
- **`CI_CD_EXAMPLES.md`** - Ready-to-use GitHub Actions, GitLab, Jenkins configs

---

## 🎯 What Gets Deployed

### All-in-One: `./deploy.sh deploy`

1. **Builds Docker Images** from source code
   - Vote app (Flask/Python)
   - Result app (Node.js)
   - Worker service (C#)

2. **Provisions AWS Infrastructure** with Terraform
   - VPC with public/private subnets
   - EKS Kubernetes cluster
   - EC2 instances (Jenkins, SonarQube)
   - RDS PostgreSQL database
   - ElastiCache Redis cache
   - Security groups and policies

3. **Deploys Applications** to:
   - Kubernetes (if configured) or
   - Docker Compose (local testing)

---

## ⚙️ Configuration (deployment.config)

### Essential Settings (Must Customize)

```bash
AWS_REGION="us-east-1"                    # Your AWS region
TF_VAR_key_name="your-ec2-key-pair"      # EC2 key pair for SSH
TF_VAR_ami_id="ami-0c55b159cbfafe1f0"    # Ubuntu AMI (region-specific)
DOCKER_REGISTRY="docker.io"               # docker.io or your registry
DOCKER_REGISTRY_USERNAME="your-username" # Docker username
DOCKER_PASSWORD="your-docker-password-or-access-token" # Docker Hub access token or password
POSTGRES_PASSWORD="secure-password"      # Database password
```

### Optional Settings

```bash
DEPLOY_METHOD="docker-compose"  # kubernetes, argocd, or docker-compose
SKIP_BUILD="false"              # true to reuse existing images
SKIP_TERRAFORM="false"          # true to skip infrastructure
DRY_RUN="false"                 # true for preview mode
```

**All settings documented in `deployment.config`** - just open and customize!

---

## 📋 Command Reference

### Deploy

```bash
./deploy.sh deploy              # Deploy everything
./deploy.sh deploy --dry-run    # Preview changes
./deploy.sh deploy --skip-build # Reuse existing images
```

### Individual Steps

```bash
./deploy.sh build               # Build Docker images only
./deploy.sh infrastructure      # Provision AWS only
./deploy.sh kubernetes          # Deploy to Kubernetes only
./deploy.sh compose            # Deploy with Docker Compose only
```

### Cleanup

```bash
./deploy.sh cleanup             # Remove all resources
./deploy.sh cleanup --dry-run   # Preview cleanup
```

### Validate

```bash
./validate.sh                   # Check tools, config, AWS access
```

---

## 🎮 Usage Examples

### Example 1: Local Docker Compose Testing

```bash
# Edit config for Docker Compose
nano deployment.config
# Change: DEPLOY_METHOD="docker-compose"

# Deploy locally
./deploy.sh compose

# Access at http://localhost:8080 (voting) and http://localhost:8081 (results)
```

### Example 2: Full Kubernetes Deployment

```bash
# Configure for Kubernetes
nano deployment.config
# Set AWS region, EC2 key, Docker registry username

# Update kubeconfig
aws eks update-kubeconfig --name dev-votingapp-cluster

# Deploy everything
./deploy.sh deploy

# Monitor
kubectl logs -f deployment/vote -n voting-app
```

### Example 3: Reuse Infrastructure, Redeploy Apps

```bash
# Skip infrastructure, just redeploy apps with new images
./deploy.sh deploy --skip-tf

# Or skip build and use existing images
./deploy.sh deploy --skip-build
```

### Example 4: CI/CD Pipeline

```bash
# GitHub Actions/GitLab CI/Jenkins creates deployment.config from secrets
echo "AWS_REGION=$AWS_REGION" > deployment.config
echo "TF_VAR_key_name=$TF_KEY_NAME" >> deployment.config
echo "DOCKER_REGISTRY=$DOCKER_REGISTRY" >> deployment.config

# Then deploy
./deploy.sh deploy
```

---

## 📊 File Structure

```
deployment-system/
├── deploy.sh                      # Main orchestrator (executable)
├── validate.sh                    # Validator (executable)
├── deployment.config              # Configuration (edit this!)
├── README_DEPLOYMENT.md          # This file
├── QUICK_START.md                # 2-minute reference
├── DEPLOYMENT_SYSTEM_SUMMARY.md  # Architecture overview
└── CI_CD_EXAMPLES.md             # CI/CD integration examples

1-application-source/
├── vote/                          # Flask voting app
├── result/                        # Node.js results app
└── worker/                        # C# background worker

2-infrastructure-as-code/
└── terraform/
    └── environments/dev/          # Infrastructure code

3-gitops-manifests/
└── voting-app-gitops-manifests/  # Kubernetes manifests

docker-compose.yml                # Docker Compose configuration
```

---

## ✅ Quick Validation

Before deploying, run the validator:

```bash
./validate.sh
```

This checks:
- ✓ Required tools installed (Docker, Terraform, AWS CLI, kubectl)
- ✓ Configuration file exists and values are set
- ✓ AWS credentials configured
- ✓ Project structure intact
- ✓ File permissions correct
- ✓ Docker daemon running

---

## 🔍 Monitoring Deployment

### Real-Time Logs

```bash
tail -f /tmp/voting-app-deployment.log
```

### AWS Monitoring (Terraform)

The dev Terraform environment now creates:

- CloudWatch log groups for the vote, results, and worker services
- A CloudWatch metric filter for application error logs
- A CloudWatch alarm that triggers an SNS topic when errors occur
- An SNS subscription to send alerts by email when `TF_VAR_alert_email` is set

Set the alert email before provisioning:

```bash
export TF_VAR_alert_email="you@example.com"
```

### Docker Compose Status

```bash
docker-compose ps
docker-compose logs -f vote
```

### Kubernetes Status

```bash
kubectl get deployments -n voting-app
kubectl get pods -n voting-app
kubectl logs -f deployment/vote -n voting-app
```

### Access Applications

- **Local Docker Compose**:
  - Voting App: http://localhost:8080
  - Results Dashboard: http://localhost:8081

- **AWS EKS / Ingress**:
  - Use the external LoadBalancer hostname produced by EKS, not localhost.
  - Find it with:
    ```bash
    kubectl get svc -n ingress-nginx
    kubectl get ingress -n voting-app
    ```
  - The current manifests use an NGINX ingress controller and expect external DNS/ALB routing.

---

## 🧹 Cleanup

```bash
# Remove everything
./deploy.sh cleanup

# Or if cleanup fails, manual cleanup:
docker-compose down -v
kubectl delete namespace voting-app
cd 2-infrastructure-as-code/terraform/environments/dev && terraform destroy
```

---

## 📚 Documentation

| Document | Purpose | Read Time |
|----------|---------|-----------|
| **QUICK_START.md** | Essential commands and config | 2 min |
| **DEPLOYMENT_SYSTEM_SUMMARY.md** | Architecture and features | 10 min |
| **CI_CD_EXAMPLES.md** | GitHub Actions, GitLab, Jenkins | 15 min |
| **This file** | Overview and getting started | 5 min |

**Start with QUICK_START.md, then refer to README_DEPLOYMENT.md for details.**

---

## 🤔 Key Features

### ✅ Zero Hardcoding
- Everything configurable through `deployment.config`
- No values embedded in scripts
- Easy environment-specific deployments (dev/staging/prod)

### ✅ Modular
- Deploy everything: `./deploy.sh deploy`
- Or individual steps: `./deploy.sh build`, `./deploy.sh infrastructure`, etc.
- Skip parts you don't need: `--skip-build`, `--skip-tf`, `--skip-k8s`

### ✅ Safe
- Preview mode: `--dry-run` shows what would happen
- Pre-flight validation: `./validate.sh`
- Proper error handling and logging
- Automatic rollback on failure

### ✅ Flexible
- Docker Compose for local testing
- Kubernetes for production
- AWS infrastructure with Terraform
- Support for private registries
- Custom environment configs

### ✅ CI/CD Ready
- Ready-to-use GitHub Actions workflow
- GitLab CI/CD pipeline examples
- Jenkins pipeline configuration
- Works with GitHub Secrets, GitLab Variables, Jenkins Credentials

---

## 🐛 Troubleshooting

### Validation Fails

```bash
./validate.sh
# Shows what needs to be fixed
```

### Docker Build Fails

```bash
# Check logs
tail -f /tmp/voting-app-deployment.log

# Rebuild with verbose output
./deploy.sh build
```

### Terraform Fails

```bash
# Check AWS credentials
aws sts get-caller-identity

# Check Terraform state
cd 2-infrastructure-as-code/terraform/environments/dev
terraform state list
```

### Kubernetes Won't Connect

```bash
# Update kubeconfig
aws eks update-kubeconfig --name dev-votingapp-cluster --region us-east-1

# Verify connection
kubectl cluster-info
```

See **README_DEPLOYMENT.md** for more troubleshooting.

---

## 🔐 Security Notes

1. **Never commit secrets**: Add `deployment.config` to `.gitignore` if it contains real passwords
2. **Use AWS Secrets Manager**: Store sensitive values there
3. **Use IAM roles**: Prefer roles over access keys
4. **Rotate credentials**: Change database and registry passwords regularly
5. **Secure kubeconfig**: Restrict access to kubectl config files

---

## 📞 Getting Help

1. **Quick answer**: Read QUICK_START.md
2. **Complete reference**: See README_DEPLOYMENT.md
3. **Pre-deployment check**: Run `./validate.sh`
4. **Preview changes**: Use `./deploy.sh deploy --dry-run`
5. **Check logs**: `tail -f /tmp/voting-app-deployment.log`
6. **View config**: `cat deployment.config`

---

## 🎓 How It Works

```
User runs: ./deploy.sh deploy
    ↓
Script reads deployment.config (all settings in one place)
    ↓
Runs validate.sh (pre-flight checks)
    ↓
Builds Docker images (from 1-application-source/)
    ↓
Pushes to registry (Docker Hub, ECR, etc.)
    ↓
Provisions infrastructure (Terraform in 2-infrastructure-as-code/)
    ↓
Deploys applications (Kubernetes or Docker Compose)
    ↓
Success! Applications running
```

---

## 📝 Common Configuration Scenarios

### Development (Docker Compose Local)

```bash
cp deployment.config deployment-dev.config

# Edit deployment-dev.config:
DEPLOY_METHOD="docker-compose"
AWS_REGION="us-east-1"
SKIP_TERRAFORM="true"  # No AWS infrastructure needed
```

### Staging (AWS Kubernetes)

```bash
cp deployment.config deployment-staging.config

# Edit deployment-staging.config:
DEPLOY_METHOD="kubernetes"
AWS_REGION="us-east-1"
TF_VAR_instance_type="t3.medium"  # Medium instances
```

### Production (AWS Kubernetes High Availability)

```bash
cp deployment.config deployment-prod.config

# Edit deployment-prod.config:
DEPLOY_METHOD="kubernetes"
AWS_REGION="us-east-1"
TF_VAR_instance_type="t3.large"    # Larger instances
POSTGRES_PASSWORD="very-secure-password"
```

---

## ✨ Next Steps

1. **Read QUICK_START.md** (2 minutes)
2. **Edit deployment.config** (5 minutes)
3. **Run validate.sh** (2 minutes)
4. **Preview with --dry-run** (2 minutes)
5. **Deploy!** `./deploy.sh deploy`

---

## 📄 License

See LICENSE file in the project root.

---

**Everything you need is in ONE configuration file. No hardcoding. Complete automation. Deploy with confidence!**

Questions? Check `README_DEPLOYMENT.md` or run `./validate.sh` for diagnostics.
