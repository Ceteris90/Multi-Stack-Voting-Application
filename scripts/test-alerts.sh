#!/usr/bin/env bash
set -euo pipefail

# Small helper to test SNS, CloudWatch metric, and optional CloudWatch Logs path
# Usage: ./scripts/test-alerts.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."

echo "Discovering SNS topic ARN from Terraform outputs..."
pushd "${ROOT_DIR}/2-infrastructure-as-code/terraform/environments/dev" >/dev/null
SNS_ARN=$(terraform output -raw dev_alerts_sns_topic_arn 2>/dev/null || true)
popd >/dev/null

if [[ -z "${SNS_ARN:-}" ]]; then
  echo "SNS topic ARN not found. Ensure Terraform applied the dev environment and outputs are available."
  exit 1
fi

echo "SNS ARN: ${SNS_ARN}"

echo "Publishing test SNS message..."
aws sns publish --topic-arn "${SNS_ARN}" --subject "Test Notification" --message "This is a test notification from the deployment guide."

echo "Injecting metric datapoint to trigger alarm..."
aws cloudwatch put-metric-data --namespace MultiStackVotingApp --metric-name VotingAppErrorCount --value 2 --unit Count

echo "Metric injected. Check alarm state with:"
echo "  aws cloudwatch describe-alarms --alarm-names \"dev-voting-app-error-alarm\" --query 'MetricAlarms[0].StateValue' --output text"

echo "Optional: push an ERROR log to CloudWatch Logs. This requires IAM permissions for logs:CreateLogStream and logs:PutLogEvents."
echo "See DEPLOYMENT_GUIDE.md for full commands to create a log stream and push a test ERROR message."

echo "Done."
#!/usr/bin/env bash
set -euo pipefail

# Simple script to exercise SNS, CloudWatch metric and optional log push
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${PROJECT_ROOT}/2-infrastructure-as-code/terraform/environments/dev"

echo "Locating SNS topic ARN from Terraform outputs..."
cd "${TF_DIR}"
SNS_ARN=$(terraform output -raw dev_alerts_sns_topic_arn 2>/dev/null || true)

if [[ -z "${SNS_ARN}" ]]; then
  echo "SNS topic ARN not found in Terraform outputs. Ensure infrastructure applied." >&2
  exit 1
fi

echo "Publishing test message to SNS: ${SNS_ARN}"
aws sns publish --topic-arn "${SNS_ARN}" --subject "Test Notification" --message "This is a test notification from the deployment test script." || {
  echo "Failed to publish SNS test message" >&2
  exit 1
}

echo "Injecting metric datapoint to trigger the alarm (VotingAppErrorCount=2)..."
aws cloudwatch put-metric-data --namespace MultiStackVotingApp --metric-name VotingAppErrorCount --value 2 --unit Count || {
  echo "Failed to put metric data" >&2
  exit 1
}

echo "Done. Check CloudWatch alarm state (may take several minutes):"
echo "aws cloudwatch describe-alarms --alarm-names \"dev-voting-app-error-alarm\""

exit 0
