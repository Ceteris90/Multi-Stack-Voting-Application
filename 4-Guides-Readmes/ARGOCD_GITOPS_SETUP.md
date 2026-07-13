# ArgoCD GitOps Deployment Guide

## Overview

This guide explains how to deploy the **Multi-Stack Voting Application** using **ArgoCD** for GitOps-based continuous deployment.

### What is GitOps?

GitOps is an operational framework that takes DevOps best practices used for application development (like code review, version control, CI) and applies them to infrastructure automation and deployment. Git becomes the single source of truth for your infrastructure and applications.

### Architecture

```
GitHub (source code & manifests)
    ↓
Jenkins (CI: build, test, scan)
    ↓ (on success)
Update manifests in git with new image tags
    ↓ (git commit/push)
ArgoCD (CD: watches git, applies manifests to K8s)
    ↓
Kubernetes Cluster
    ↓
Voting App Deployed & Running
```

---

## Prerequisites

### Local Development
- Kubernetes cluster (minikube, kind, or managed EKS/AKS/GKE)
- `kubectl` configured to access your cluster
- `argocd` CLI (optional but recommended)
- Git access configured on your cluster (SSH key or token)

### Required Resources
- Docker registry (Docker Hub, ECR, GCR, or private registry)
- GitHub repository with write access to push updated manifests
- Kubernetes cluster with at least 2GB free memory

---

## Installation Steps

### Step 1: Create ArgoCD Namespace and Install ArgoCD

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD from official manifests
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

### Step 2: Access ArgoCD UI

#### Option A: Port Forwarding with Insecure Mode (Development - Recommended)

This is the easiest for local development. Configure ArgoCD to run in insecure HTTP mode:

```bash
# Enable insecure server (disable HTTPS and TLS redirects)
kubectl patch configmap argocd-cmd-params-cm -n argocd -p '{"data":{"server.insecure":"true"}}'

# Restart the server pod
kubectl rollout restart deployment argocd-server -n argocd

# Wait for pod to restart
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=60s

# Port forward (now HTTP, no SSL issues)
kubectl port-forward svc/argocd-server -n argocd 8080:80
# Access at: http://localhost:8080
```

#### Option A-Alt: Port Forwarding with HTTPS (if insecure mode not available)

If you prefer HTTPS with a self-signed certificate:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Access at: https://localhost:8080
# Accept the self-signed certificate warning in your browser
```

**To bypass SSL certificate warnings:**
- **Chrome**: Click "Advanced" → "Proceed to localhost (unsafe)"
- **Firefox**: Click "Advanced" → "Accept the Risk and Continue"
- **Safari**: Click "Show Details" → "Visit this website"

#### Option B: LoadBalancer (Production)
```bash
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
kubectl get svc argocd-server -n argocd
```

#### Option C: Ingress (Production)
```bash
# Apply the ingress manifest from the gitops directory
kubectl apply -f 3-gitops-manifests/voting-app-gitops-manifests/ingress.yaml
```

### Step 3: Get ArgoCD Admin Password

```bash
# Initial password is stored in a secret
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

**Change the password immediately after first login!**

---

## Configuration

### Create Namespace for Voting App

```bash
kubectl create namespace voting-app
```

### Configure Git Repository Access (if private)

If your repository is private, create a Git credential secret:

```bash
kubectl create secret generic github-credentials \
  -n argocd \
  --from-literal=url=https://github.com/Ceteris90/Multi-Stack-Voting-Application.git \
  --from-literal=username=<your-github-username> \
  --from-literal=password=<your-github-token>
```

---

## Deploy the Voting Application

### Option 1: Using ArgoCD UI

1. Login to ArgoCD UI
2. Click **+ New App**
3. Fill in the following:
   - **Application Name**: `voting-app`
   - **Project Name**: `default`
   - **Repository URL**: `https://github.com/Ceteris90/Multi-Stack-Voting-Application.git`
   - **Revision**: `main`
   - **Path**: `3-gitops-manifests/voting-app-gitops-manifests`
   - **Destination Cluster**: `https://kubernetes.default.svc`
   - **Destination Namespace**: `voting-app`
   - **Sync Policy**: `Automatic` (check "Prune resources" and "Self heal")
4. Click **Create**

### Option 2: Using kubectl and Pre-built Manifest

```bash
# Update the repo URL in the application manifest
sed -i 's|https://github.com/your-org|https://github.com/Ceteris90|g' \
  3-gitops-manifests/argocd-apps/voting-app.yaml

# Apply the ArgoCD Application resource
kubectl apply -f 3-gitops-manifests/argocd-apps/voting-app.yaml
```

### Option 3: Using ArgoCD CLI

```bash
# Login to ArgoCD
argocd login localhost:8080 --insecure --username admin --password <your-password>

# Create the application
argocd app create voting-app \
  --repo https://github.com/Ceteris90/Multi-Stack-Voting-Application.git \
  --path 3-gitops-manifests/voting-app-gitops-manifests \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace voting-app \
  --sync-policy auto \
  --auto-prune \
  --self-heal

# Trigger initial sync
argocd app sync voting-app
```

---

## Manifest Structure

### Directory Layout

```
3-gitops-manifests/
├── argocd-apps/
│   └── voting-app.yaml              # ArgoCD Application resource
├── voting-app-gitops-manifests/
│   ├── namespace.yaml               # Namespace definition
│   ├── kustomization.yaml           # Kustomize configuration
│   ├── ingress.yaml                 # Ingress for external access
│   ├── ingress-controller-nginx.yaml
│   ├── cert-manager.yaml
│   ├── 1-voting-frontend/           # Vote app (Python Flask)
│   ├── 2-data-queue/                # Redis data store
│   ├── 3-background-worker/         # Worker service (.NET)
│   ├── 4-database/                  # PostgreSQL database
│   └── 5-results-dashboard/         # Results app (Node.js)
└── gitops-values.env                # Environment variables
```

### Key Manifests

- **namespace.yaml**: Creates `voting-app` namespace
- **kustomization.yaml**: Orchestrates all components with Kustomize overlays
- **Deployment manifests**: Each service has its own deployment, service, and configuration
- **Ingress**: Exposes services externally
- **ConfigMaps/Secrets**: Application configuration

---

## GitOps Workflow

### Step 1: Update Image Tags

When Jenkins completes a successful build:

```bash
# Update deployment manifests with new image tags
# Example:
# OLD: image: voting-app/vote:latest
# NEW: image: voting-app/vote:a8e8d1a-35

# Update Kustomization with new image
kustomize set image voting-app/vote:a8e8d1a-35 \
  -n 1-voting-frontend \
  3-gitops-manifests/voting-app-gitops-manifests/

# Commit and push
git add 3-gitops-manifests/
git commit -m "Update image tags: a8e8d1a-35"
git push origin main
```

### Step 2: ArgoCD Detects Change

ArgoCD monitors the repository on a configurable interval (default: 3 minutes) and detects:
- New manifest files
- Updated image tags
- Configuration changes

### Step 3: Automatic Sync

With `syncPolicy: automated` enabled:
- ArgoCD compares Git state vs. Cluster state
- Automatically applies any differences
- Creates/Updates/Deletes resources as needed
- Notifies on sync success/failure

### Step 4: Monitor Deployment

```bash
# Watch ArgoCD app status
argocd app get voting-app

# Or use kubectl
kubectl get deployments -n voting-app -w
kubectl get pods -n voting-app -w

# Check logs
kubectl logs -n voting-app -l app=vote --tail=50 -f
```

---

## Manual Operations

### Trigger Manual Sync

```bash
# Sync immediately (don't wait for auto-sync interval)
argocd app sync voting-app

# Force full resync (ignore cache)
argocd app sync voting-app --force

# Sync specific resources only
argocd app sync voting-app --resource apps:Deployment/vote
```

### View Sync Status

```bash
# Live status
argocd app get voting-app

# JSON output for scripting
argocd app get voting-app -o json | jq '.status'

# Health status
kubectl get application voting-app -n argocd -o yaml | grep -A 20 "status:"
```

### Rollback to Previous State

```bash
# List sync history
argocd app history voting-app

# Rollback to specific sync
argocd app rollback voting-app <REVISION>

# Example: rollback to 3 syncs ago
argocd app rollback voting-app 3
```

### Restart Deployments

```bash
# Restart all deployments
kubectl rollout restart deployment -n voting-app

# Restart specific deployment
kubectl rollout restart deployment/vote -n voting-app

# Watch rollout progress
kubectl rollout status deployment/vote -n voting-app -w
```

---

## Advanced Configuration

### Self-Healing and Auto-Pruning

The application manifest is configured with:

```yaml
syncPolicy:
  automated:
    prune: true      # Delete resources that are removed from git
    selfHeal: true   # Correct drift from desired state
  syncOptions:
    - CreateNamespace=true  # Create namespace if missing
```

This ensures the cluster stays in sync with Git at all times.

### Notifications (Optional)

Integrate ArgoCD with Slack, Teams, or email for deployment notifications:

```bash
# Example: Slack webhook notification
kubectl create secret generic argocd-notifications-secret \
  -n argocd \
  --from-literal=slack-token=<your-slack-webhook-url>
```

### Custom Health Checks

Add custom health assessments in your deployments:

```yaml
# Deployment spec
spec:
  template:
    metadata:
      annotations:
        argocd.argoproj.io/custom-health: "true"
```

---

## Troubleshooting

### SSL Connection Errors (localhost:8080)

**Error**: `SSL received a record that exceeded the maximum permissible length`

**Solution**: Enable insecure (HTTP) mode in ArgoCD:

```bash
# Set ArgoCD to run in insecure mode (no HTTPS)
kubectl patch configmap argocd-cmd-params-cm -n argocd -p '{"data":{"server.insecure":"true"}}'

# Restart server
kubectl rollout restart deployment argocd-server -n argocd

# Wait for restart
sleep 10

# Now port-forward to HTTP
kubectl port-forward svc/argocd-server -n argocd 8080:80

# Access at: http://localhost:8080 (NOT https)
```

Alternatively, if HTTPS is required, browsers require you to accept the self-signed certificate warning before proceeding.

### Application Not Syncing

```bash
# Check application status
argocd app get voting-app

# View sync logs
argocd app logs voting-app

# Check resource errors
kubectl describe application voting-app -n argocd
```

### Pod Not Running

```bash
# Describe pod for events
kubectl describe pod -n voting-app <pod-name>

# View pod logs
kubectl logs -n voting-app <pod-name>

# Check resource limits
kubectl top pod -n voting-app
```

### Image Pull Errors

```bash
# Verify image exists in registry
docker pull <registry>/<image>:<tag>

# Check image pull secrets
kubectl get secrets -n voting-app

# Update secret if needed
kubectl create secret docker-registry regcred \
  --docker-server=<registry> \
  --docker-username=<user> \
  --docker-password=<password> \
  -n voting-app
```

### Repository Connection Issues

```bash
# Test git connectivity
kubectl exec -it argocd-repo-server-0 -n argocd -- sh

# Inside pod:
git ls-remote https://github.com/Ceteris90/Multi-Stack-Voting-Application.git
```

---

## Monitoring & Alerts

### Key Metrics to Monitor

- **Application Health**: Synced, Progressing, Healthy
- **Pod Status**: Running, Pending, CrashLoopBackOff
- **Resource Usage**: CPU, Memory, Disk
- **Deployment Status**: Replica count, Ready replicas

### ArgoCD Dashboards

- **ArgoCD UI**: Real-time application status
- **Grafana Integration**: Metrics and alerts
- **Kubernetes Dashboard**: Cluster-wide view

### Example Monitoring Query

```bash
# Get application sync status
kubectl get application voting-app -n argocd \
  -o jsonpath='{.status.operationState.phase}'

# Expected values: Unknown, Succeeded, Failed, Error
```

---

## Security Best Practices

### 1. GitHub Access
- Use SSH keys instead of tokens when possible
- Rotate tokens regularly
- Use deploy keys for read-only access from ArgoCD

### 2. ArgoCD Admin Password
```bash
# Change password immediately after installation
argocd account update-password --account admin
```

### 3. RBAC (Role-Based Access Control)
```bash
# Configure ArgoCD RBAC policies in configmap
kubectl edit configmap argocd-rbac-cm -n argocd
```

### 4. Network Policies
```bash
# Restrict ArgoCD network access
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: argocd-network-policy
  namespace: argocd
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: voting-app
EOF
```

### 5. Secrets Management
- Use Sealed Secrets or External Secrets Operator
- Never commit secrets to Git
- Rotate credentials regularly

---

## Teardown

### Remove Application

```bash
# Delete the ArgoCD application (keeps K8s resources)
argocd app delete voting-app

# Or delete with cascade (removes all K8s resources)
argocd app delete voting-app --cascade
```

### Remove ArgoCD

```bash
# Delete namespace (removes all ArgoCD components)
kubectl delete namespace argocd
```

### Cleanup Git

```bash
# The gitops-manifests remain in Git for future deployments
# Optionally clean up old image tags from manifests
git log --oneline 3-gitops-manifests/ | head -20
```

---

## CI/CD Integration

### Jenkins → ArgoCD Flow

1. **Jenkins Builds Application**
   - Checkout code
   - Run tests & security scans
   - Build container image
   - Push image to registry

2. **Update GitOps Manifests**
   ```bash
   # In Jenkinsfile Deploy stage:
   # Update image tag in kustomization.yaml
   # Commit: git push origin main
   ```

3. **ArgoCD Detects Change**
   - Polls Git repository (default: every 3 minutes)
   - Detects updated image tag
   - Calculates diff vs. current cluster state

4. **ArgoCD Syncs Application**
   - With `syncPolicy: automated`, applies changes automatically
   - Rolls out new pods with updated image
   - Updates service endpoints
   - Records sync history and audit trail

### Example Jenkins Stage

```groovy
stage('Deploy to ArgoCD') {
    steps {
        script {
            sh '''
                GIT_COMMIT_SHORT=$(git rev-parse --short HEAD)
                BUILD_TAG="${GIT_COMMIT_SHORT}-${BUILD_NUMBER}"
                
                # Update kustomization with new image tag
                kustomize edit set image \
                    voting-app/vote:${BUILD_TAG} \
                    -n 1-voting-frontend \
                    3-gitops-manifests/voting-app-gitops-manifests/
                
                # Commit and push
                git config user.name "Jenkins"
                git config user.email "jenkins@example.com"
                git add 3-gitops-manifests/
                git commit -m "Update image tags: ${BUILD_TAG}"
                git push origin main
                
                # Optional: Sync ArgoCD immediately
                argocd app sync voting-app --insecure
            '''
        }
    }
}
```

---

## Next Steps

1. **Install ArgoCD** on your Kubernetes cluster
2. **Create the voting-app application** using one of the methods above
3. **Configure image update automation** (Kustomize, Helm, or Flux)
4. **Set up notifications** for deployment events
5. **Establish monitoring** and alerting
6. **Document your environment** with access credentials and runbooks

---

## References

- **ArgoCD Documentation**: https://argo-cd.readthedocs.io/
- **Kustomize**: https://kustomize.io/
- **GitOps Best Practices**: https://www.gitops.tech/
- **Kubernetes Ingress**: https://kubernetes.io/docs/concepts/services-networking/ingress/

---

**Last Updated**: July 13, 2026
**Repository**: https://github.com/Ceteris90/Multi-Stack-Voting-Application
