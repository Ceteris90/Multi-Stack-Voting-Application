#!/bin/bash

################################################################################
# DEPLOYMENT PREREQUISITE VALIDATOR
################################################################################
# Validates that all required tools and configurations are in place
# before attempting deployment
################################################################################

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/deployment.config"
if [[ ! -f "${CONFIG_FILE}" && -f "${SCRIPT_DIR}/deployment.config" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/deployment.config"
fi

checks_passed=0
checks_failed=0

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
check_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((checks_passed++))
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
    ((checks_failed++))
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================================================
# VALIDATION CHECKS (TEMPORARILY DISABLE STRICT EXIT)
# ============================================================================
set +e

section "CHECKING REQUIRED TOOLS"

# Docker
if command -v docker &> /dev/null; then
    docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    [ -z "$docker_version" ] && docker_version="Unknown"
    check_pass "Docker installed (v${docker_version})"
else
    check_fail "Docker not found - install from https://docs.docker.com/get-docker/"
fi

# Docker Compose (Handles modern 'docker compose' plugin as well)
if command -v docker-compose &> /dev/null; then
    compose_version=$(docker-compose version --short 2>/dev/null || docker-compose --version 2>/dev/null | awk '{print $4}')
    [ -z "$compose_version" ] && compose_version="Unknown"
    check_pass "Docker Compose installed (${compose_version})"
elif docker compose version &> /dev/null; then
    compose_version=$(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null | awk '{print $4}')
    check_pass "Docker Compose plugin installed (${compose_version})"
else
    check_warn "Docker Compose not found - some deployments may not work"
fi

# Terraform
if command -v terraform &> /dev/null; then
    tf_version=$(terraform -version 2>/dev/null | head -n1 | awk '{print $2}')
    [ -z "$tf_version" ] && tf_version="Unknown"
    check_pass "Terraform installed (${tf_version})"
else
    check_fail "Terraform not found - install from https://www.terraform.io/downloads"
fi

# AWS CLI
if command -v aws &> /dev/null; then
    aws_version=$(aws --version 2>&1 | awk '{print $1}' | cut -d'/' -f2)
    [ -z "$aws_version" ] && aws_version="Unknown"
    check_pass "AWS CLI installed (v${aws_version})"
else
    check_fail "AWS CLI not found - install from https://aws.amazon.com/cli/"
fi

# kubectl
if command -v kubectl &> /dev/null; then
    kubectl_version=$(kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    [ -z "$kubectl_version" ] && kubectl_version="Unknown"
    check_pass "kubectl installed (${kubectl_version})"
else
    check_warn "kubectl not found - Kubernetes deployments will not work"
fi

# Ansible
if command -v ansible-playbook &> /dev/null; then
    ansible_version=$(ansible-playbook --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    [ -z "$ansible_version" ] && ansible_version="Unknown"
    check_pass "Ansible installed (v${ansible_version})"
else
    check_warn "ansible-playbook not found - Ansible deployment will not work"
fi

# ============================================================================
section "CHECKING CONFIGURATION FILE"

if [[ -f "${CONFIG_FILE}" ]]; then
    check_pass "Configuration file found: ${CONFIG_FILE}"
    source "${CONFIG_FILE}" 2>/dev/null

    # Normalize Ansible paths for scripts/ execution context.
    default_ansible_inventory="${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/generated_inventory.ini"
    default_ansible_setup="${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/playbook-setup.yml"
    default_ansible_deploy="${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/playbook-deploy.yml"

    if [[ -z "${ANSIBLE_INVENTORY_FILE:-}" ]] || [[ ! -f "${ANSIBLE_INVENTORY_FILE}" ]]; then
        ANSIBLE_INVENTORY_FILE="${default_ansible_inventory}"
    fi

    if [[ -z "${ANSIBLE_SETUP_PLAYBOOK:-}" ]] || [[ ! -f "${ANSIBLE_SETUP_PLAYBOOK}" ]]; then
        ANSIBLE_SETUP_PLAYBOOK="${default_ansible_setup}"
    fi

    if [[ -z "${ANSIBLE_DEPLOY_PLAYBOOK:-}" ]] || [[ ! -f "${ANSIBLE_DEPLOY_PLAYBOOK}" ]]; then
        ANSIBLE_DEPLOY_PLAYBOOK="${default_ansible_deploy}"
    fi
else
    check_fail "Configuration file not found: ${CONFIG_FILE}"
    check_fail "Run deployment script to generate default config"
fi

# ============================================================================
section "VALIDATING CONFIGURATION VALUES"

if [[ -n "${AWS_REGION:-}" ]]; then
    check_pass "AWS_REGION configured: ${AWS_REGION}"
else
    check_fail "AWS_REGION not set in deployment.config"
fi

# Prompt the user for input
echo -ne "${YELLOW}Enter EC2 ssh key name: ${NC}"
read -r TF_VAR_key_name

if [[ -n "${TF_VAR_key_name:-}" ]] && [[ "${TF_VAR_key_name}" != "your-ec2-key-pair" ]]; then
    check_pass "EC2 key pair configured: ${TF_VAR_key_name}"
else
    check_fail "TF_VAR_key_name not properly configured (update in deployment.config)"
fi

# Prompt the user for input
echo -ne "${YELLOW}Enter Docker Registry Username: ${NC}"
read -r DOCKER_REGISTRY_USERNAME

echo -ne "${YELLOW}Enter Docker Registry Password/Token: ${NC}"
read -r DOCKER_PASSWORD

if [[ -n "${DOCKER_REGISTRY_USERNAME:-}" ]] && [[ "${DOCKER_REGISTRY_USERNAME}" != "your-docker-username" ]]; then
    check_pass "Docker registry username configured: ${DOCKER_REGISTRY_USERNAME}"
    if [[ -n "${DOCKER_PASSWORD:-}" ]] && [[ "${DOCKER_PASSWORD}" != "your-docker-password-or-access-token" ]]; then
        check_pass "Docker registry password/token configured"
    else
        check_warn "DOCKER_PASSWORD not set; will rely on existing docker login session if available"
    fi
else
    check_warn "DOCKER_REGISTRY_USERNAME not set (required for image push)"
fi

# Prompt the user for input
echo -ne "${YELLOW}Enter PostgreSQL Password: ${NC}"
read -r POSTGRES_PASSWORD

if [[ -n "${POSTGRES_PASSWORD:-}" ]] && [[ "${POSTGRES_PASSWORD}" != "postgres-password-123" ]]; then
    check_pass "Database password configured (hidden for security)"
else
    check_fail "POSTGRES_PASSWORD using default value - change in deployment.config"
fi

# ============================================================================
section "CHECKING AWS CONNECTIVITY"

if command -v aws &> /dev/null; then
    account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$account_id" ]; then
        check_pass "AWS credentials valid (Account: ${account_id})"
    else
        check_fail "AWS credentials not configured - run: aws configure"
    fi
else
    check_warn "AWS CLI not found - cannot verify AWS connectivity"
fi

# ============================================================================
section "CHECKING PROJECT STRUCTURE"

required_dirs=(
    "1-application-source"
    "2-infrastructure-as-code"
    "3-gitops-manifests"
)

for dir in "${required_dirs[@]}"; do
    if [[ -d "${PROJECT_ROOT}/${dir}" ]]; then
        check_pass "Directory found: ${dir}"
    else
        check_fail "Directory missing: ${dir}"
    fi
done

required_files=(
    "1-application-source/vote/Dockerfile"
    "1-application-source/result/Dockerfile"
    "1-application-source/worker/Dockerfile"
    "2-infrastructure-as-code/terraform/environments/dev/main.tf"
    "docker-compose.yml"
    "scripts/deploy.sh"
)

for file in "${required_files[@]}"; do
    if [[ -f "${PROJECT_ROOT}/${file}" ]]; then
        check_pass "File found: ${file}"
    else
        check_fail "File missing: ${file}"
    fi
done

if [[ -f "${PROJECT_ROOT}/deployment.config" ]]; then
    check_pass "File found: deployment.config"
elif [[ -f "${SCRIPT_DIR}/deployment.config" ]]; then
    check_pass "File found: scripts/deployment.config"
else
    check_fail "File missing: deployment.config (expected in repo root or scripts/)"
fi

# ============================================================================
section "CHECKING ANSIBLE CONFIGURATION"

if [[ "${ANSIBLE_ENABLED:-false}" == "true" ]]; then
    check_pass "Ansible deployment enabled"

    if [[ -f "${ANSIBLE_SETUP_PLAYBOOK:-}" ]]; then
        check_pass "Ansible setup playbook found: ${ANSIBLE_SETUP_PLAYBOOK}"
    else
        check_fail "Ansible setup playbook not found: ${ANSIBLE_SETUP_PLAYBOOK:-}"
    fi

    if [[ -f "${ANSIBLE_DEPLOY_PLAYBOOK:-}" ]]; then
        check_pass "Ansible deploy playbook found: ${ANSIBLE_DEPLOY_PLAYBOOK}"
    else
        check_fail "Ansible deploy playbook not found: ${ANSIBLE_DEPLOY_PLAYBOOK:-}"
    fi

    if [[ -f "${ANSIBLE_INVENTORY_FILE:-}" ]]; then
        check_pass "Ansible inventory file found: ${ANSIBLE_INVENTORY_FILE}"
    else
        check_warn "Ansible inventory file not found yet - deploy.sh will generate it"
    fi
else
    check_warn "Ansible deployment disabled in deployment.config"
fi

# ============================================================================
section "CHECKING DOCKER DAEMON"

if command -v docker &> /dev/null; then
    if docker ps &> /dev/null; then
        check_pass "Docker daemon is running"
    else
        check_fail "Docker daemon not running - start Docker service"
    fi
else
    check_warn "Docker not available - cannot check daemon status"
fi

# ============================================================================
section "CHECKING FILE PERMISSIONS"

if [[ -x "${PROJECT_ROOT}/scripts/deploy.sh" ]]; then
    check_pass "scripts/deploy.sh is executable"
else
    check_warn "scripts/deploy.sh not executable - run: chmod +x scripts/deploy.sh"
fi

if [[ -x "${PROJECT_ROOT}/scripts/validate.sh" ]]; then
    check_pass "scripts/validate.sh is executable"
else
    check_warn "scripts/validate.sh not executable - run: chmod +x scripts/validate.sh"
fi

if [[ -x "${PROJECT_ROOT}/scripts/test-alerts.sh" ]]; then
    check_pass "scripts/test-alerts.sh is executable"
else
    check_warn "scripts/test-alerts.sh not executable - run: chmod +x scripts/test-alerts.sh"
fi

# ============================================================================
section "CHECKING TERRAFORM CONFIGURATION"

tf_dir="${PROJECT_ROOT}/2-infrastructure-as-code/terraform"

if [[ -d "${tf_dir}" ]]; then
    check_pass "Terraform directory found"
    
    main_tf_count=$(find "${tf_dir}" -name "main.tf" -type f 2>/dev/null | wc -l)
    if [[ ${main_tf_count} -gt 0 ]]; then
        check_pass "Terraform modules found (${main_tf_count} main.tf files)"
    else
        check_fail "No Terraform modules found"
    fi
else
    check_fail "Terraform directory not found"
fi

# ============================================================================
section "CHECKING DOCKER IMAGES"

docker_images=("vote" "result" "worker")

for image in "${docker_images[@]}"; do
    if docker images 2>/dev/null | grep -q "$image"; then
        check_pass "Docker image found: ${image}"
    else
        check_warn "Docker image not built: ${image} (will be built during deployment)"
    fi
done

# ============================================================================
section "SUMMARY"

# Re-enable strict mode for final termination logic
set -e

total_checks=$((checks_passed + checks_failed))
echo ""
echo -e "Checks Passed: ${GREEN}${checks_passed}/${total_checks}${NC}"
if [[ ${checks_failed} -gt 0 ]]; then
    echo -e "Checks Failed: ${RED}${checks_failed}/${total_checks}${NC}"
fi
echo ""

if [[ ${checks_failed} -eq 0 ]]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ ALL CHECKS PASSED - Ready to deploy!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Review and customize: nano deployment.config"
    echo "  2. Preview deployment: ./scripts/deploy.sh deploy --dry-run"
    echo "  3. Deploy: ./scripts/deploy.sh deploy"
    echo ""
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}✗ SOME CHECKS FAILED - Fix issues before deploying${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Issues to fix:"
    echo "  - Install missing tools (see above)"
    echo "  - Update deployment.config with your values"
    echo "  - Verify AWS credentials (aws configure)"
    echo ""
    exit 1
fi