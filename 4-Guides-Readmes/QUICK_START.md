# Voting Application Deployment Quick Reference

## 🚀 One-Line Setup

```bash
# 1. Configure your settings
nano deployment.config

# 2. Deploy everything
./deploy.sh deploy

# 3. Access the app
# For local Docker Compose: Voting:  http://localhost:8080
# For AWS EKS/Kubernetes: use the external LoadBalancer/Ingress hostname from the cluster
```

## 📋 Essential Configuration (deployment.config)

```bash
AWS_REGION="us-east-1"                    # Your AWS region
TF_VAR_key_name="my-ec2-key"             # EC2 key pair name
TF_VAR_ami_id="ami-0c55b159cbfafe1f0"   # Ubuntu AMI (region-specific)
DOCKER_REGISTRY="docker.io"              # docker.io or your registry
DOCKER_REGISTRY_USERNAME="your-username" # Docker Hub username
DOCKER_PASSWORD="your-docker-password-or-access-token" # Docker Hub access token or password
POSTGRES_PASSWORD="strong-password"      # Database password
TF_VAR_alert_email=""                    # Optional SNS alert email
DEPLOY_METHOD="docker-compose"           # or "kubernetes"
```

> For AWS EKS deployments, local URLs only apply to Docker Compose. Query ingress/load balancer addresses with `kubectl get ingress -n voting-app` or `kubectl get svc -n ingress-nginx`.

## ⚡ Common Commands

```bash
# Preview deployment
./deploy.sh deploy --dry-run

# Deploy with Docker Compose (simplest)
./deploy.sh compose

# Build images only
./deploy.sh build

# Deploy to Kubernetes
./deploy.sh kubernetes

# Complete cleanup
./deploy.sh cleanup

# Selective options
./deploy.sh deploy --skip-build        # Reuse existing images
./deploy.sh deploy --skip-tf           # Skip infrastructure
./deploy.sh deploy --skip-k8s          # Skip Kubernetes
```

## 🔍 Verify Deployment

```bash
# Docker Compose
docker-compose ps
curl http://localhost:8080/

# Kubernetes
kubectl get pods -n voting-app
kubectl logs -f deployment/vote -n voting-app
```

## 📊 Service URLs

- **Voting App**: http://localhost:8080 (or your K8s service IP)
- **Results Dashboard**: http://localhost:8081 (or your K8s service IP)
- **Database**: postgres://postgres:password@db:5432/votes
- **Redis**: redis://redis:6379

## 🧹 Cleanup

```bash
# Tear down everything
./deploy.sh cleanup

# Or manually
docker-compose down -v
kubectl delete namespace voting-app
terraform destroy
```

## 📚 Full Documentation

See `README_DEPLOYMENT.md` for complete guide with:
- Prerequisites & installation
- Detailed configuration
- Monitoring & verification
- Troubleshooting
- Advanced topics

## 🆘 Troubleshooting

```bash
# Check logs
tail -f /tmp/voting-app-deployment.log

# Verify tools
docker --version
terraform --version
aws --version
kubectl --version

# Test AWS access
aws sts get-caller-identity

# Verify config
source deployment.config && echo $AWS_REGION
```

---

**For complete documentation, see README_DEPLOYMENT.md**
