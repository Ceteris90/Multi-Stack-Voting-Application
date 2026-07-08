<img width="2207" height="1311" alt="AWS drawio (1)" src="https://github.com/user-attachments/assets/2d10f66c-d40e-432a-a615-e4cab2e10f63" />

# Multi-Stack Voting Application

Production-ready reference for deploying and operating a distributed voting system across local Docker Compose and AWS infrastructure Specifically EKS.

## Overview
This project contains a multi-service voting application and infrastructure automation stack:

- Vote frontend: Python/Flask
- Queue: Redis
- Worker: .NET (consumes votes from Redis and writes to PostgreSQL)
- Results dashboard: Node.js/Express/Socket.IO
- Database: PostgreSQL (local container or AWS-managed target)
- Automation: Terraform, Kubernetes manifests, Ansible, deployment scripts

## Architecture
Request and processing flow:

1. User submits vote in the Vote service.
2. Vote is pushed to Redis queue.
3. Worker consumes vote and persists it in PostgreSQL.
4. Result service reads persisted totals and exposes live results.

## Repository Layout

- `scripts/`: operational entrypoints (`deploy.sh`, `validate.sh`, `test-alerts.sh`)
- `1-application-source/`: application source and Dockerfiles (vote, worker, result)
- `2-infrastructure-as-code/`: Terraform and Ansible
- `3-gitops-manifests/`: Kubernetes manifests and GitOps assets
- `4-Guides-Readmes/`: supplemental guides
- `docker-compose.yml`: local runtime stack

## Prerequisites
Install and configure:

- Docker + Docker Compose
- Terraform >= 1.5
- AWS CLI (authenticated for target account)
- kubectl (for Kubernetes mode)
- Ansible (if using Ansible mode)

Optional but recommended:

- jq
- GNU make utilities

## Configuration
Primary runtime configuration:

- `scripts/deployment.config`

Important notes:

- Secrets and local config artifacts are intentionally ignored in root `.gitignore`.
- Do not commit credentials or environment-specific tokens.

## Standard Deployment Commands
Use the centralized deploy script:

```bash
# Validate workstation and configuration
./scripts/validate.sh

# Full deployment using configured defaults
./scripts/deploy.sh deploy

# Deploy application layer only (skip Terraform)
./scripts/deploy.sh deploy --skip-tf

# Dry run
./scripts/deploy.sh deploy --dry-run

# Infrastructure only
./scripts/deploy.sh infrastructure

# Kubernetes only
./scripts/deploy.sh kubernetes --skip-tf

# Cleanup
./scripts/deploy.sh cleanup
```

## Deployment Modes
Configured via `DEPLOY_METHOD` in `scripts/deployment.config`.

Supported values:

- `docker-compose`
- `kubernetes`
- `argocd`
- `ansible`

### Local Docker Compose
When `DEPLOY_METHOD=docker-compose`, service URLs are:

- Vote: `http://localhost:8080`
- Result: `http://localhost:8081`

### AWS / Kubernetes
When deploying Kubernetes manifests with LoadBalancer services:

- Public URLs are assigned dynamically by AWS ELB.
- `scripts/deploy.sh` prints resolved URLs in deployment summary when services are present.
- If services are not yet provisioned, summary may show `Pending LoadBalancer hostname`.

## AWS Operations
### Ensure kube context is current
```bash
aws eks update-kubeconfig --name dev-votingapp-cluster --region us-east-1
kubectl cluster-info
```

### Check public service hostnames
```bash
kubectl -n voting-app get svc vote result \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}'
```

### Check rollout status
```bash
kubectl -n voting-app rollout status deployment/redis --timeout=240s
kubectl -n voting-app rollout status deployment/db --timeout=240s
kubectl -n voting-app rollout status deployment/vote --timeout=240s
kubectl -n voting-app rollout status deployment/worker --timeout=240s
kubectl -n voting-app rollout status deployment/result --timeout=240s
```

## Monitoring and Alerts
Terraform provisions CloudWatch/SNS monitoring resources for the dev environment.

- SNS email subscription is controlled by `ALERT_EMAIL` in `scripts/deployment.config`.
- Subscription confirmation is required before notifications are delivered.
- Deployment summary includes SNS email subscription state when Terraform outputs are available.

## Security and Secret Management
Baseline controls in this repository:

- Centralized `.gitignore` for Terraform state/locks, tfvars, deployment config, Docker secret-style files, and env files
- No hardcoded production credentials in README
- Explicit separation of local config versus committed source

Recommended production hardening:

- Move secrets to AWS Secrets Manager or SSM Parameter Store
- Use IAM roles for service access
- Restrict Security Group ingress to minimum required CIDRs/ports
- Enable image scanning in CI

## Troubleshooting
### Terraform lock errors
If you hit a lock conflict, verify no other Terraform process is running before attempting unlock.

```bash
pgrep -af "terraform (plan|apply|destroy)"
```

### Kubernetes URL shows pending
Common causes:

- `voting-app` namespace not deployed
- `vote`/`result` services not type LoadBalancer
- ELB provisioning delay
- stale or wrong kube context

### Result not matching votes
Verify worker/result DB alignment and processing logs:

```bash
kubectl -n voting-app logs deployment/worker --tail=100
kubectl -n voting-app logs deployment/result --tail=100
```

## CI/CD and GitOps
- Terraform defines core AWS resources.
- Kubernetes manifests are stored under `3-gitops-manifests/`.
- Jenkinsfile and Sonar properties are included under `1-application-source/` for pipeline integration.

## License
See `LICENSE`.
