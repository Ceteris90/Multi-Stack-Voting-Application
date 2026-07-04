# Deployment Guide

This guide provides the core steps for deploying the Multi-Stack Voting Application.

## 1. Overview

This repository contains:

- `deploy.sh` - orchestration script for build, infrastructure, and application deployment
- `validate.sh` - pre-deployment validator
- `deployment.config` - centralized configuration file
- `1-application-source/` - application service sources
- `2-infrastructure-as-code/terraform/` - AWS infrastructure code
- `3-gitops-manifests/` - Kubernetes manifests and GitOps deployment artifacts

## 2. Prerequisites

Ensure the following tools are installed and configured:

- Docker
- Terraform
- AWS CLI
- kubectl
- An AWS credentials profile with appropriate permissions

## 3. Configure `deployment.config`

Open `deployment.config` and set values for:

- `AWS_REGION`
- `TF_VAR_key_name`
- `TF_VAR_ami_id`
- `DOCKER_REGISTRY`
- `DOCKER_REGISTRY_USERNAME`
- `DOCKER_PASSWORD`
- `POSTGRES_PASSWORD`

Optional settings include:

- `DEPLOY_METHOD`
- `SKIP_BUILD`
- `SKIP_TERRAFORM`
- `DRY_RUN`
- `TF_VAR_alert_email`

## 4. Validate Setup

Run:

```bash
./validate.sh
```

This checks tool availability, AWS access, configuration, and project structure.

## 5. Deploy

For a full deployment:

```bash
./deploy.sh deploy
```

Useful variants:

```bash
./deploy.sh deploy --dry-run
./deploy.sh deploy --skip-build
./deploy.sh deploy --skip-tf
```

## 6. Terraform Infrastructure

The infrastructure code lives in `2-infrastructure-as-code/terraform/environments/dev`.

The deployment script now bootstraps backend state resources from `2-infrastructure-as-code/terraform/bootstrap` automatically before provisioning the dev environment. This creates the S3 bucket and DynamoDB lock table used by the remote state backend.

Typical Terraform workflow:

```bash
cd 2-infrastructure-as-code/terraform/environments/dev
terraform fmt -recursive
terraform init -backend=false
terraform validate
terraform plan -refresh=false -no-color
terraform apply -auto-approve
```

## 7. Monitoring and Alerting

The dev Terraform deployment now includes AWS monitoring resources:

- CloudWatch log groups for the vote app, results dashboard, and worker service
- A CloudWatch metric filter that counts `ERROR` log messages
- A CloudWatch metric alarm that fires when the error count is above threshold
- An SNS topic and email subscription for alert notifications

You can enable email alerts by setting the Terraform variable:

```bash
export TF_VAR_alert_email="you@example.com"
```

### Inspecting CloudWatch & SNS resources

Terraform (dev environment) creates the following monitoring resources:

- **SNS topic:** `dev-voting-app-alerts` (output variable: `dev_alerts_sns_topic_arn`)
- **CloudWatch log groups:** `/voting-app/vote`, `/voting-app/results`, `/voting-app/worker`
- **Metric:** `VotingAppErrorCount` (namespace: `MultiStackVotingApp`)
- **Alarm:** `dev-voting-app-error-alarm`

Quick commands to inspect them (replace <ARN> with the SNS topic ARN from Terraform output):

```bash
# Get the SNS topic ARN created by Terraform
cd 2-infrastructure-as-code/terraform/environments/dev
terraform output dev_alerts_sns_topic_arn

# List CloudWatch log groups for the app
aws logs describe-log-groups --log-group-name-prefix "/voting-app"

# Tail logs (AWS CLI v2)
aws logs tail "/voting-app/vote" --follow

# Describe the alarm
aws cloudwatch describe-alarms --alarm-names "dev-voting-app-error-alarm"

# Describe alarms for the metric
aws cloudwatch describe-alarms-for-metric --metric-name VotingAppErrorCount --namespace MultiStackVotingApp

# Get SNS topic attributes (shows subscriptions)
aws sns get-topic-attributes --topic-arn <ARN>

# List subscriptions for the topic
aws sns list-subscriptions-by-topic --topic-arn <ARN>
```

If you enabled email alerts by setting `TF_VAR_alert_email`, confirm the subscription by checking the configured email inbox and approving the SNS confirmation message; then re-run `aws sns list-subscriptions-by-topic --topic-arn <ARN>` to verify the subscription status.

### Testing alarms and notifications

You can verify the notification pipeline and alarm behavior using the AWS CLI. Two quick methods are shown below:

- **A — Verify SNS delivery (quick):** publish a test message to the topic to confirm SNS delivery and subscription configuration.

```bash
# Get the SNS topic ARN
cd 2-infrastructure-as-code/terraform/environments/dev
SNS_ARN=$(terraform output -raw dev_alerts_sns_topic_arn)

# Publish a test message
aws sns publish --topic-arn "$SNS_ARN" --subject "Test Notification" --message "This is a test notification from the deployment guide."
```

- **B — Trigger the CloudWatch alarm (simulate metric):** the alarm watches the `VotingAppErrorCount` metric in namespace `MultiStackVotingApp`. You can inject a metric datapoint to force the alarm state change.

```bash
# Publish a test metric datapoint (value >= threshold to trigger)
aws cloudwatch put-metric-data --namespace MultiStackVotingApp --metric-name VotingAppErrorCount --value 2 --unit Count

# Inspect the alarm state (may take a minute for evaluation)
aws cloudwatch describe-alarms --alarm-names "dev-voting-app-error-alarm" --query 'MetricAlarms[0].StateValue' --output text
```

- **C — (Optional) Push an ERROR log to CloudWatch logs:** if you prefer to exercise the metric filter end-to-end, push an `ERROR` log event into `/voting-app/vote`. This requires creating a log stream and handling sequence tokens.

```bash
# Create a test log stream
aws logs create-log-stream --log-group-name "/voting-app/vote" --log-stream-name "test-stream-$(date +%s)"

# Get the upload sequence token (may be empty on first stream)
TOKEN=$(aws logs describe-log-streams --log-group-name "/voting-app/vote" --log-stream-name-prefix "test-stream" --query 'logStreams[0].uploadSequenceToken' --output text)

# Put a log event — include the token only if it is not 'None'
if [[ "$TOKEN" == "None" || "$TOKEN" == "" ]]; then
	aws logs put-log-events --log-group-name "/voting-app/vote" --log-stream-name "test-stream-$(date +%s)" --log-events timestamp=$(date +%s%3N),message="ERROR: test error to trigger metric filter"
else
	aws logs put-log-events --log-group-name "/voting-app/vote" --log-stream-name "test-stream-$(date +%s)" --log-events timestamp=$(date +%s%3N),message="ERROR: test error to trigger metric filter" --sequence-token "$TOKEN"
fi

# Wait a minute, then check the alarm state as above
```

Notes:
- The alarm evaluation period is 300 seconds (5 minutes); it can take ~1–6 minutes for CloudWatch to evaluate and change the alarm state after you inject metrics or logs.
- Use `aws cloudwatch describe-alarms --alarm-names "dev-voting-app-error-alarm"` to view alarm details and `aws sns list-subscriptions-by-topic --topic-arn "$SNS_ARN"` to confirm subscriptions.


## 8. AWS App Access

The local URLs below only apply to local Docker Compose or local test deployments.

For AWS EKS deployments, use the external LoadBalancer or Ingress hostname provided by the cluster.

Find the AWS service/ingress endpoint with:

```bash
kubectl get svc -n ingress-nginx
kubectl get ingress -n voting-app
```

Use the hostname in the Ingress output to access the application from the internet. If you use custom DNS, update the hosts in `3-gitops-manifests/voting-app-gitops-manifests/ingress.yaml` accordingly.

## 9. Troubleshooting

### Terraform issues

Check AWS credentials:

```bash
aws sts get-caller-identity
```

Check state:

```bash
cd 2-infrastructure-as-code/terraform/environments/dev
terraform state list
```

### Kubernetes issues

Update kubeconfig and verify access:

```bash
aws eks update-kubeconfig --name dev-votingapp-cluster --region us-east-1
kubectl cluster-info
```

### Docker issues

Inspect logs:

```bash
tail -f /tmp/voting-app-deployment.log
```

## 8. Notes

This file is intentionally provided as a deployment guide placeholder to resolve documentation references.
