#!/bin/bash

################################################################################
# VOTING APPLICATION DEPLOYMENT ORCHESTRATOR
################################################################################
# All-in-one deployment script for the Multi-Stack Voting Application
# Features:
#   - Zero hardcoding (all config from deployment.config)
#   - Build Docker images
#   - Provision AWS infrastructure with Terraform
#   - Deploy to Kubernetes or Docker Compose
#   - Complete teardown/cleanup
################################################################################

set -euo pipefail

# ============================================================================
# SCRIPT CONFIGURATION
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/deployment.config"
if [[ ! -f "${CONFIG_FILE}" && -f "${SCRIPT_DIR}/deployment.config" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/deployment.config"
fi
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${LOG_FILE:-/tmp/voting-app-deployment.log}"
    echo -e "${BLUE}[${timestamp}]${NC} ${level}: ${message}" | tee -a "${log_file}"
}

log_info() {
    log "${GREEN}INFO${NC}" "$@"
}

log_warn() {
    log "${YELLOW}WARN${NC}" "$@"
}

log_error() {
    log "${RED}ERROR${NC}" "$@"
    exit 1
}

log_section() {
    echo ""
    echo -e "${BLUE}=================================================================================${NC}"
    echo -e "${BLUE}$@${NC}"
    echo -e "${BLUE}=================================================================================${NC}"
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================
validate_config() {
    log_section "VALIDATING CONFIGURATION"
    
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "Configuration file not found: ${CONFIG_FILE}"
        exit 1
    fi
    
    local previous_dry_run="${DRY_RUN:-}"
    local previous_deploy_method="${DEPLOY_METHOD:-}"
    local previous_skip_build="${SKIP_BUILD:-}"
    local previous_skip_terraform="${SKIP_TERRAFORM:-}"
    local previous_skip_k8s="${SKIP_K8S_DEPLOY:-}"

    log_info "Loading configuration from: ${CONFIG_FILE}"
    source "${CONFIG_FILE}"

    # Normalize Ansible paths for scripts/ execution context.
    local default_ansible_inventory="${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/generated_inventory.ini"
    local default_ansible_setup="${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/playbook-setup.yml"
    local default_ansible_deploy="${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/playbook-deploy.yml"

    if [[ -n "${ANSIBLE_INVENTORY_FILE:-}" ]] && [[ ! -f "${ANSIBLE_INVENTORY_FILE}" ]] && [[ -f "${default_ansible_inventory}" ]]; then
        ANSIBLE_INVENTORY_FILE="${default_ansible_inventory}"
    elif [[ -z "${ANSIBLE_INVENTORY_FILE:-}" ]]; then
        ANSIBLE_INVENTORY_FILE="${default_ansible_inventory}"
    fi

    if [[ -n "${ANSIBLE_SETUP_PLAYBOOK:-}" ]] && [[ ! -f "${ANSIBLE_SETUP_PLAYBOOK}" ]] && [[ -f "${default_ansible_setup}" ]]; then
        ANSIBLE_SETUP_PLAYBOOK="${default_ansible_setup}"
    elif [[ -z "${ANSIBLE_SETUP_PLAYBOOK:-}" ]]; then
        ANSIBLE_SETUP_PLAYBOOK="${default_ansible_setup}"
    fi

    if [[ -n "${ANSIBLE_DEPLOY_PLAYBOOK:-}" ]] && [[ ! -f "${ANSIBLE_DEPLOY_PLAYBOOK}" ]] && [[ -f "${default_ansible_deploy}" ]]; then
        ANSIBLE_DEPLOY_PLAYBOOK="${default_ansible_deploy}"
    elif [[ -z "${ANSIBLE_DEPLOY_PLAYBOOK:-}" ]]; then
        ANSIBLE_DEPLOY_PLAYBOOK="${default_ansible_deploy}"
    fi

    if [[ -n "${previous_dry_run}" ]]; then
        DRY_RUN="${previous_dry_run}"
    fi

    if [[ -n "${previous_deploy_method}" ]]; then
        DEPLOY_METHOD="${previous_deploy_method}"
    fi

    if [[ -n "${previous_skip_build}" ]]; then
        SKIP_BUILD="${previous_skip_build}"
    fi

    if [[ -n "${previous_skip_terraform}" ]]; then
        SKIP_TERRAFORM="${previous_skip_terraform}"
    fi

    if [[ -n "${previous_skip_k8s}" ]]; then
        SKIP_K8S_DEPLOY="${previous_skip_k8s}"
    fi

    # Auto-detect Docker Hub username from local docker login session when unset.
    if [[ "${DOCKER_REGISTRY:-}" == "docker.io" ]] && [[ -z "${DOCKER_REGISTRY_USERNAME:-}" ]]; then
        local detected_docker_username
        detected_docker_username=$(docker info --format '{{.Username}}' 2>/dev/null || true)
        if [[ -n "${detected_docker_username}" ]] && [[ "${detected_docker_username}" != "<no value>" ]]; then
            DOCKER_REGISTRY_USERNAME="${detected_docker_username}"
            log_info "Detected Docker Hub username from local login session: ${DOCKER_REGISTRY_USERNAME}"
        fi
    fi

    # Normalize Docker image names when placeholder namespace is still configured.
    # Docker Hub pushes fail with insufficient scope if images point to a namespace
    # you do not own (for example: docker.io/your-org/*).
    if [[ "${DOCKER_REGISTRY:-}" == "docker.io" ]]; then
        if [[ "${VOTE_IMAGE:-}" == *"/your-org/"* ]] || [[ "${RESULT_IMAGE:-}" == *"/your-org/"* ]] || [[ "${WORKER_IMAGE:-}" == *"/your-org/"* ]]; then
            if [[ -z "${DOCKER_REGISTRY_USERNAME:-}" ]]; then
                if [[ "${DRY_RUN:-false}" == "true" ]]; then
                    log_warn "Docker images still use 'your-org' namespace. Set DOCKER_REGISTRY_USERNAME before real deploy/push."
                else
                    log_error "Docker images still use 'your-org' namespace. Set DOCKER_REGISTRY_USERNAME and update image names in scripts/deployment.config."
                fi
            else
                VOTE_IMAGE="${DOCKER_REGISTRY}/${DOCKER_REGISTRY_USERNAME}/voting-app-vote:${DOCKER_BUILD_TAGS}"
                RESULT_IMAGE="${DOCKER_REGISTRY}/${DOCKER_REGISTRY_USERNAME}/voting-app-result:${DOCKER_BUILD_TAGS}"
                WORKER_IMAGE="${DOCKER_REGISTRY}/${DOCKER_REGISTRY_USERNAME}/voting-app-worker:${DOCKER_BUILD_TAGS}"
                log_info "Using Docker Hub namespace '${DOCKER_REGISTRY_USERNAME}' for image tags"
            fi
        fi
    fi
    
    # Export variables for use in terraform
    export TF_VAR_ami_id
    export TF_VAR_instance_type
    export TF_VAR_key_name
    export TF_VAR_region
    if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
        export TF_VAR_db_password="${POSTGRES_PASSWORD}"
    fi
    if [[ -n "${ALERT_EMAIL:-}" ]]; then
        export TF_VAR_alert_email="${ALERT_EMAIL}"
        log_info "SNS email subscription enabled: ${ALERT_EMAIL}"
    else
        export TF_VAR_alert_email=""
        log_info "SNS email subscription disabled (ALERT_EMAIL not set)"
    fi
    export AWS_REGION
    export AWS_PROFILE

    if [[ -z "${TF_VAR_db_password:-}" ]]; then
        log_error "Database password is not configured. Set POSTGRES_PASSWORD in scripts/deployment.config."
    fi

    # Optional Terraform backend naming overrides.
    if [[ -n "${TF_BACKEND_NAME_PREFIX:-}" ]]; then
        export TF_VAR_backend_name_prefix="${TF_BACKEND_NAME_PREFIX}"
    fi
    if [[ -n "${TF_BACKEND_BUCKET_NAME:-}" ]]; then
        export TF_VAR_backend_bucket_name="${TF_BACKEND_BUCKET_NAME}"
    fi
    if [[ -n "${TF_BACKEND_LOCK_TABLE_NAME:-}" ]]; then
        export TF_VAR_backend_lock_table_name="${TF_BACKEND_LOCK_TABLE_NAME}"
    fi
    
    # Validate required tools
    local required_tools=("terraform" "docker" "aws" "kubectl" "ansible-playbook")
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &> /dev/null; then
            log_warn "${tool} not found. Install it to enable related features."
        fi
    done
    
    # Initialize log file
    mkdir -p "$(dirname "${LOG_FILE}")"
    log_info "Logging to: ${LOG_FILE}"
    
    # Display loaded configuration (hide sensitive values)
    log_info "AWS Region: ${AWS_REGION}"
    log_info "K8s Cluster: ${K8S_CLUSTER_NAME}"
    log_info "Docker Registry: ${DOCKER_REGISTRY}"
    log_info "Vote Image: ${VOTE_IMAGE}"
    log_info "Deploy Method: ${DEPLOY_METHOD}"
}

# ============================================================================
# DOCKER BUILD FUNCTIONS
# ============================================================================
build_docker_images() {
    if [[ "${SKIP_BUILD}" == "true" ]]; then
        log_warn "Skipping Docker image builds"
        return 0
    fi
    
    log_section "BUILDING DOCKER IMAGES"
    
    local app_source_dir="${PROJECT_ROOT}/1-application-source"
    
    # Build Vote application
    if [[ -f "${app_source_dir}/vote/Dockerfile" ]]; then
        log_info "Building Vote application image: ${VOTE_IMAGE}"
        if [[ "${DRY_RUN}" != "true" ]]; then
            docker build -t "${VOTE_IMAGE}" \
                -f "${app_source_dir}/vote/Dockerfile" \
                "${app_source_dir}/vote" || log_error "Failed to build Vote image"
            log_info "✓ Vote image built successfully"
        else
            log_info "[DRY RUN] Would build: ${VOTE_IMAGE}"
        fi
    fi
    
    # Build Result application
    if [[ -f "${app_source_dir}/result/Dockerfile" ]]; then
        log_info "Building Result application image: ${RESULT_IMAGE}"
        if [[ "${DRY_RUN}" != "true" ]]; then
            docker build -t "${RESULT_IMAGE}" \
                -f "${app_source_dir}/result/Dockerfile" \
                "${app_source_dir}/result" || log_error "Failed to build Result image"
            log_info "✓ Result image built successfully"
        else
            log_info "[DRY RUN] Would build: ${RESULT_IMAGE}"
        fi
    fi
    
    # Build Worker application
    if [[ -f "${app_source_dir}/worker/Dockerfile" ]]; then
        log_info "Building Worker application image: ${WORKER_IMAGE}"
        if [[ "${DRY_RUN}" != "true" ]]; then
            docker build -t "${WORKER_IMAGE}" \
                -f "${app_source_dir}/worker/Dockerfile" \
                "${app_source_dir}/worker" || log_error "Failed to build Worker image"
            log_info "✓ Worker image built successfully"
        else
            log_info "[DRY RUN] Would build: ${WORKER_IMAGE}"
        fi
    fi
}

push_docker_images() {
    if [[ "${DEPLOY_METHOD:-}" == "docker-compose" ]]; then
        log_info "Skipping image push for docker-compose deployment"
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would push Docker images to registry"
        return 0
    fi
    
    log_section "PUSHING DOCKER IMAGES TO REGISTRY"
    
    # Log in only when a non-interactive password/token is supplied.
    # If password is not set, rely on an existing local docker login session.
    if [[ -n "${DOCKER_REGISTRY_USERNAME:-}" ]] && [[ -n "${DOCKER_PASSWORD:-}" ]]; then
        log_info "Logging in to Docker registry: ${DOCKER_REGISTRY}"
        echo "${DOCKER_PASSWORD}" | docker login "${DOCKER_REGISTRY}" --username "${DOCKER_REGISTRY_USERNAME}" --password-stdin || log_error "Docker login failed"
    elif [[ -n "${DOCKER_REGISTRY_USERNAME:-}" ]]; then
        log_info "DOCKER_PASSWORD not set. Using existing Docker login session for ${DOCKER_REGISTRY_USERNAME}."
    else
        log_info "No Docker registry credentials configured. Assuming existing login session."
    fi
    
    log_info "Pushing ${VOTE_IMAGE}..."
    docker push "${VOTE_IMAGE}" || log_error "Failed to push Vote image"
    
    log_info "Pushing ${RESULT_IMAGE}..."
    docker push "${RESULT_IMAGE}" || log_error "Failed to push Result image"
    
    log_info "Pushing ${WORKER_IMAGE}..."
    docker push "${WORKER_IMAGE}" || log_error "Failed to push Worker image"
    
    log_info "✓ All images pushed successfully"
}

# ============================================================================
# GITOPS MANIFEST RENDERING
# ============================================================================
render_gitops_manifests() {
    local gitops_dir="${PROJECT_ROOT}/3-gitops-manifests/voting-app-gitops-manifests"
    local gitops_values_file="${gitops_dir}/gitops-values.env"

    if [[ ! -f "${gitops_values_file}" ]]; then
        log_warn "GitOps values file not found: ${gitops_values_file}. Using defaults."
        return 0
    fi

    set -a
    source "${gitops_values_file}"
    set +a

    local registry_prefix="${REGISTRY_PREFIX:-your-registry.example.com}"
    local image_tag="${IMAGE_TAG:-latest}"
    local ingress_class="${INGRESS_CLASS:-nginx}"
    local vote_host="${VOTE_HOST:-vote.example.com}"
    local result_host="${RESULT_HOST:-result.example.com}"
    local namespace="${NAMESPACE:-voting-app}"
    local tls_enabled="${TLS_ENABLED:-true}"
    local tls_email="${TLS_EMAIL:-admin@example.com}"
    local tls_secret_name="${TLS_SECRET_NAME:-voting-app-tls}"
    local cert_manager_issuer="${CERT_MANAGER_ISSUER:-letsencrypt-prod}"

    cat > "${gitops_dir}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${namespace}
resources:
  - namespace.yaml
  - 1-voting-frontend
  - 2-data-queue
  - 3-background-worker
  - 4-database
  - 5-results-dashboard
  - ingress.yaml
images:
  - name: voting-app-vote
    newName: ${registry_prefix}/voting-app-vote
    newTag: ${image_tag}
  - name: voting-app-result
    newName: ${registry_prefix}/voting-app-result
    newTag: ${image_tag}
  - name: voting-app-worker
    newName: ${registry_prefix}/voting-app-worker
    newTag: ${image_tag}
EOF

    cat > "${gitops_dir}/cert-manager.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${cert_manager_issuer}
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${tls_email}
    privateKeySecretRef:
      name: ${cert_manager_issuer}
    solvers:
      - http01:
          ingress:
            class: ${ingress_class}
EOF

    cat > "${gitops_dir}/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: voting-app
  namespace: ${namespace}
  annotations:
    kubernetes.io/ingress.class: ${ingress_class}
    cert-manager.io/cluster-issuer: ${cert_manager_issuer}
spec:
$(if [[ "${tls_enabled}" == "true" ]]; then
  echo "  tls:"
  echo "    - hosts:"
  echo "        - ${vote_host}"
  echo "        - ${result_host}"
  echo "      secretName: ${tls_secret_name}"
fi)
  rules:
    - host: ${vote_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vote
                port:
                  number: 80
    - host: ${result_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: result
                port:
                  number: 4000
EOF

    log_info "Rendered GitOps kustomization, ingress, and cert-manager config using ${gitops_values_file}"
}

# ============================================================================
# ANSIBLE DEPLOYMENT FUNCTIONS
# ============================================================================
render_ansible_inventory() {
    local inventory_file="${ANSIBLE_INVENTORY_FILE:-${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/generated_inventory.ini}"
    mkdir -p "$(dirname "${inventory_file}")"

    local backend_connection="ssh"
    local frontend_connection="ssh"

    if [[ "${ANSIBLE_BACKEND_HOST:-}" == "127.0.0.1" || "${ANSIBLE_BACKEND_HOST:-}" == "localhost" ]]; then
        backend_connection="local"
    fi

    if [[ "${ANSIBLE_FRONTEND_HOST:-}" == "127.0.0.1" || "${ANSIBLE_FRONTEND_HOST:-}" == "localhost" ]]; then
        frontend_connection="local"
    fi

    cat > "${inventory_file}" <<EOF
[backend]
backend01 ansible_host=${ANSIBLE_BACKEND_HOST:-127.0.0.1} ansible_user=${ANSIBLE_REMOTE_USER:-ubuntu} ansible_connection=${backend_connection}

[frontend]
frontend01 ansible_host=${ANSIBLE_FRONTEND_HOST:-127.0.0.1} ansible_user=${ANSIBLE_REMOTE_USER:-ubuntu} ansible_connection=${frontend_connection}
EOF

    log_info "Rendered Ansible inventory at ${inventory_file}"
}

deploy_with_ansible() {
    if [[ "${ANSIBLE_ENABLED:-false}" != "true" ]]; then
        log_warn "Ansible deployment is disabled in deployment.config"
        return 0
    fi

    log_section "DEPLOYING WITH ANSIBLE"

    local inventory_file="${ANSIBLE_INVENTORY_FILE:-${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/generated_inventory.ini}"
    local setup_playbook="${ANSIBLE_SETUP_PLAYBOOK:-${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/playbook-setup.yml}"
    local deploy_playbook="${ANSIBLE_DEPLOY_PLAYBOOK:-${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/playbook-deploy.yml}"

    if [[ ! -f "${setup_playbook}" ]]; then
        log_error "Ansible setup playbook not found: ${setup_playbook}"
        return 1
    fi

    if [[ ! -f "${deploy_playbook}" ]]; then
        log_error "Ansible deploy playbook not found: ${deploy_playbook}"
        return 1
    fi

    render_ansible_inventory

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run Ansible setup playbook: ${setup_playbook}"
        log_info "[DRY RUN] Would run Ansible deploy playbook: ${deploy_playbook}"
        return 0
    fi

    if ! command -v ansible-playbook &> /dev/null; then
        log_error "ansible-playbook is required for Ansible deployment"
        return 1
    fi

    log_info "Running Ansible setup playbook..."
    ansible-playbook -i "${inventory_file}" "${setup_playbook}" \
        -e "ansible_docker_user=${ANSIBLE_REMOTE_USER:-ubuntu}" \
        -e "ansible_become=${ANSIBLE_BECOME:-false}" \
        -e "db_host=${DB_HOST:-localhost}" \
        -e "db_port=${DB_PORT:-5432}" \
        -e "db_username=${POSTGRES_USER:-postgres}" \
        -e "db_password=${POSTGRES_PASSWORD:-postgres}" \
        -e "db_name=${POSTGRES_DB:-votes}" \
        -e "redis_host=${REDIS_HOST:-redis}" \
        -e "pg_host=${DB_HOST:-localhost}" \
        -e "pg_port=${DB_PORT:-5432}" \
        -e "pg_user=${POSTGRES_USER:-postgres}" \
        -e "pg_password=${POSTGRES_PASSWORD:-postgres}" \
        -e "pg_database=${POSTGRES_DB:-votes}" || log_error "Ansible setup playbook failed"

    log_info "Running Ansible deployment playbook..."
    ansible-playbook -i "${inventory_file}" "${deploy_playbook}" \
        -e "ansible_docker_user=${ANSIBLE_REMOTE_USER:-ubuntu}" \
        -e "ansible_become=${ANSIBLE_BECOME:-false}" \
        -e "db_host=${DB_HOST:-localhost}" \
        -e "db_port=${DB_PORT:-5432}" \
        -e "db_username=${POSTGRES_USER:-postgres}" \
        -e "db_password=${POSTGRES_PASSWORD:-postgres}" \
        -e "db_name=${POSTGRES_DB:-votes}" \
        -e "redis_host=${REDIS_HOST:-redis}" \
        -e "pg_host=${DB_HOST:-localhost}" \
        -e "pg_port=${DB_PORT:-5432}" \
        -e "pg_user=${POSTGRES_USER:-postgres}" \
        -e "pg_password=${POSTGRES_PASSWORD:-postgres}" \
        -e "pg_database=${POSTGRES_DB:-votes}" || log_error "Ansible deployment playbook failed"

    log_info "✓ Ansible deployment completed"
}

# ============================================================================
# TERRAFORM INFRASTRUCTURE FUNCTIONS
# ============================================================================
ensure_terraform_backend() {
    if [[ "${SKIP_TERRAFORM}" == "true" ]]; then
        log_warn "Skipping Terraform backend bootstrap because SKIP_TERRAFORM=true"
        return 0
    fi

    local bootstrap_dir="${PROJECT_ROOT}/2-infrastructure-as-code/terraform/bootstrap"
    if [[ ! -d "${bootstrap_dir}" ]]; then
        log_warn "Terraform bootstrap directory not found: ${bootstrap_dir}"
        return 0
    fi

    log_section "ENSURING TERRAFORM BACKEND RESOURCES"
    cd "${bootstrap_dir}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would initialize and apply Terraform bootstrap resources"
        cd "${PROJECT_ROOT}"
        return 0
    fi

    log_info "Initializing Terraform bootstrap workspace..."
    terraform init -upgrade || log_error "Terraform bootstrap init failed"

    log_info "Validating Terraform bootstrap configuration..."
    terraform validate || log_error "Terraform bootstrap validate failed"

    log_info "Applying Terraform backend bootstrap resources..."
    terraform apply -auto-approve || log_error "Terraform backend bootstrap apply failed"

    TF_BACKEND_BUCKET=$(terraform output -raw s3_bucket_name 2>/dev/null || true)
    TF_BACKEND_LOCK_TABLE=$(terraform output -raw dynamodb_table_name 2>/dev/null || true)
    if [[ -z "${TF_BACKEND_BUCKET}" ]]; then
        log_error "Failed to read Terraform backend bootstrap output (s3 bucket)."
    fi

    log_info "Terraform backend bucket: ${TF_BACKEND_BUCKET}"
    if [[ -n "${TF_BACKEND_LOCK_TABLE}" ]]; then
        log_info "Terraform lock table (legacy/optional): ${TF_BACKEND_LOCK_TABLE}"
    fi
    log_info "✓ Terraform backend resources created or already present"

    cd "${PROJECT_ROOT}"
}

provision_infrastructure() {
    if [[ "${SKIP_TERRAFORM}" == "true" ]]; then
        log_warn "Skipping Terraform infrastructure provisioning"
        return 0
    fi
    
    log_section "PROVISIONING AWS INFRASTRUCTURE WITH TERRAFORM"
    
    local tf_dir="${PROJECT_ROOT}/2-infrastructure-as-code/terraform/environments/dev"
    
    if [[ ! -d "${tf_dir}" ]]; then
        log_error "Terraform directory not found: ${tf_dir}"
        return 1
    fi

    ensure_terraform_backend
    cd "${tf_dir}"
    
    # Initialize Terraform
    log_info "Initializing Terraform..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        if [[ -z "${TF_BACKEND_BUCKET:-}" ]]; then
            log_error "Terraform backend details are missing. Bootstrap step did not return bucket name."
        fi

        terraform init \
            -backend-config="bucket=${TF_BACKEND_BUCKET}" \
            -backend-config="use_lockfile=true" \
            -backend-config="region=${AWS_REGION}" \
            -backend-config="key=dev/terraform.tfstate" \
            -upgrade || log_error "Terraform init failed"
    else
        log_info "[DRY RUN] Would initialize Terraform"
    fi
    
    # Validate Terraform
    log_info "Validating Terraform configuration..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        terraform validate || log_error "Terraform validation failed"
    else
        log_info "[DRY RUN] Would validate Terraform"
    fi
    
    # Plan Terraform
    log_info "Planning Terraform deployment..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        if ! terraform plan -out=tfplan; then
            # If another terraform process is active, surface a clearer message.
            if pgrep -af "terraform (plan|apply)" | grep -qv "$$"; then
                log_error "Terraform plan failed because another Terraform process appears to be running. Wait for it to finish, then retry deploy."
            fi
            log_error "Terraform plan failed"
        fi
    else
        log_info "[DRY RUN] Would create Terraform plan"
    fi
    
    # Apply Terraform
    log_info "Applying Terraform configuration..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        terraform apply tfplan || log_error "Terraform apply failed"
        
        # Extract outputs
        log_info "Extracting Terraform outputs..."
        TF_OUTPUTS=$(terraform output -json)
        log_info "Infrastructure provisioning complete"
    else
        log_info "[DRY RUN] Would apply Terraform configuration"
    fi
    
    cd "${PROJECT_ROOT}"
}

# ============================================================================
# KUBERNETES DEPLOYMENT FUNCTIONS
# ============================================================================
deploy_to_kubernetes() {
    if [[ "${SKIP_K8S_DEPLOY}" == "true" ]]; then
        log_warn "Skipping Kubernetes deployment"
        return 0
    fi
    
    log_section "DEPLOYING TO KUBERNETES"
    
    # Check kubectl connectivity
    log_info "Checking Kubernetes cluster connectivity..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        if ! kubectl cluster-info &> /dev/null; then
            log_warn "Unable to connect to Kubernetes cluster. Skipping K8s deployment."
            log_warn "To deploy to K8s, configure kubectl context for: ${K8S_CLUSTER_NAME}"
            return 0
        fi
    fi
    
    # Create namespace
    log_info "Creating Kubernetes namespace: ${K8S_NAMESPACE}"
    if [[ "${DRY_RUN}" != "true" ]]; then
        kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    else
        log_info "[DRY RUN] Would create namespace: ${K8S_NAMESPACE}"
    fi
    
    # Create image pull secret if using private registry
    if [[ "${DOCKER_REGISTRY}" != "docker.io" ]]; then
        log_info "Creating Docker registry secret..."
        if [[ "${DRY_RUN}" != "true" ]]; then
            kubectl create secret docker-registry regcred \
                --docker-server="${DOCKER_REGISTRY}" \
                --docker-username="${DOCKER_REGISTRY_USERNAME}" \
                --docker-password="${DOCKER_PASSWORD}" \
                -n "${K8S_NAMESPACE}" \
                --dry-run=client -o yaml | kubectl apply -f -
        fi
    fi
    
    # Deploy using GitOps manifests
    local gitops_dir="${PROJECT_ROOT}/3-gitops-manifests/voting-app-gitops-manifests"
    if [[ -d "${gitops_dir}" ]]; then
        log_info "Applying Kubernetes manifests from: ${gitops_dir}"
        if [[ "${DRY_RUN}" != "true" ]]; then
            kubectl apply -f "${gitops_dir}" -n "${K8S_NAMESPACE}" || \
                log_warn "Some manifests may have failed to apply"
            log_info "✓ Kubernetes manifests applied"
        else
            log_info "[DRY RUN] Would apply manifests from: ${gitops_dir}"
        fi
    else
        log_warn "GitOps manifests directory not found: ${gitops_dir}"
    fi
    
    # Wait for deployments
    log_info "Waiting for deployments to be ready..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        kubectl wait --for=condition=available --timeout=300s \
            deployment --all -n "${K8S_NAMESPACE}" || true
    fi
}

deploy_with_docker_compose() {
    log_section "DEPLOYING WITH DOCKER COMPOSE"
    
    local compose_file="${PROJECT_ROOT}/docker-compose.yml"
    
    if [[ ! -f "${compose_file}" ]]; then
        log_error "docker-compose.yml not found: ${compose_file}"
        return 1
    fi
    
    log_info "Starting services with Docker Compose..."
    
    if [[ "${DRY_RUN}" != "true" ]]; then
        log_info "Cleaning stale containers and orphans before startup..."
        # docker-compose v1 can fail to recreate services when stale image metadata is missing.
        # Remove stale service containers first; keep named volumes intact by avoiding -v for db.
        docker-compose -f "${compose_file}" rm -fs db vote result worker >/dev/null 2>&1 || true

        env \
            VOTE_IMAGE="${VOTE_IMAGE}" \
            RESULT_IMAGE="${RESULT_IMAGE}" \
            WORKER_IMAGE="${WORKER_IMAGE}" \
            POSTGRES_USER="${POSTGRES_USER:-postgres}" \
            POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}" \
            POSTGRES_DB="${POSTGRES_DB:-votes}" \
            docker-compose -f "${compose_file}" up -d --remove-orphans || log_error "Docker Compose startup failed"
        log_info "✓ All services started"
        
        log_info "Waiting for services to be healthy..."
        sleep 5
        docker-compose -f "${compose_file}" ps
    else
        log_info "[DRY RUN] Would start Docker Compose services"
    fi
}

# ============================================================================
# CLEANUP FUNCTIONS
# ============================================================================
cleanup_docker() {
    if [[ "${CLEANUP_DOCKER}" != "true" ]]; then
        return 0
    fi
    
    log_section "CLEANING UP DOCKER IMAGES"
    
    log_info "Removing Docker images..."
    docker rmi "${VOTE_IMAGE}" || true
    docker rmi "${RESULT_IMAGE}" || true
    docker rmi "${WORKER_IMAGE}" || true
    
    log_info "✓ Docker images removed"
}

destroy_infrastructure() {
    if [[ "${CLEANUP_TF_STATE}" != "true" ]]; then
        log_warn "Skipping Terraform state destruction. Set CLEANUP_TF_STATE=true to destroy."
        return 0
    fi
    
    log_section "DESTROYING INFRASTRUCTURE"
    
    local tf_dir="${PROJECT_ROOT}/2-infrastructure-as-code/terraform/environments/dev"
    
    cd "${tf_dir}"
    
    log_warn "Destroying all Terraform-managed infrastructure..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        terraform destroy -auto-approve || log_error "Terraform destroy failed"
        log_info "✓ Infrastructure destroyed"
    else
        log_info "[DRY RUN] Would destroy infrastructure"
    fi
    
    cd "${PROJECT_ROOT}"
}

teardown_kubernetes() {
    log_section "TEARING DOWN KUBERNETES DEPLOYMENT"
    
    log_info "Deleting Kubernetes namespace: ${K8S_NAMESPACE}"
    if [[ "${DRY_RUN}" != "true" ]]; then
        kubectl delete namespace "${K8S_NAMESPACE}" --ignore-not-found || true
        log_info "✓ Namespace deleted"
    else
        log_info "[DRY RUN] Would delete namespace: ${K8S_NAMESPACE}"
    fi
}

teardown_docker_compose() {
    log_section "TEARING DOWN DOCKER COMPOSE"
    
    local compose_file="${PROJECT_ROOT}/docker-compose.yml"
    
    log_info "Stopping Docker Compose services..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        docker-compose -f "${compose_file}" down -v || true
        log_info "✓ Docker Compose services stopped and volumes removed"
    else
        log_info "[DRY RUN] Would stop Docker Compose services"
    fi
}

# ============================================================================
# MAIN ORCHESTRATION FUNCTIONS
# ============================================================================
deploy() {
    log_section "STARTING DEPLOYMENT PROCESS"
    
    validate_config
    
    # Build phase
    build_docker_images
    push_docker_images
    
    # Infrastructure phase
    provision_infrastructure
    
    # Application deployment phase
    if [[ "${DEPLOY_METHOD}" == "kubernetes" ]] || [[ "${DEPLOY_METHOD}" == "argocd" ]]; then
        render_gitops_manifests
        deploy_to_kubernetes
    elif [[ "${DEPLOY_METHOD}" == "docker-compose" ]]; then
        deploy_with_docker_compose
    elif [[ "${DEPLOY_METHOD}" == "ansible" ]]; then
        deploy_with_ansible
    fi
    
    log_section "✓ DEPLOYMENT COMPLETE"
    display_deployment_info
}

cleanup() {
    log_section "STARTING CLEANUP PROCESS"
    
    validate_config
    
    if [[ "${DEPLOY_METHOD}" == "kubernetes" ]] || [[ "${DEPLOY_METHOD}" == "argocd" ]]; then
        teardown_kubernetes
    elif [[ "${DEPLOY_METHOD}" == "docker-compose" ]]; then
        teardown_docker_compose
    elif [[ "${DEPLOY_METHOD}" == "ansible" ]]; then
        log_warn "Ansible cleanup is not implemented yet; stopping here"
    fi
    
    cleanup_docker
    destroy_infrastructure
    
    log_section "✓ CLEANUP COMPLETE"
}

display_deployment_info() {
    local public_vote_url="${PUBLIC_VOTE_URL:-}"
    local public_result_url="${PUBLIC_RESULT_URL:-}"

    if [[ "${DEPLOY_METHOD}" == "docker-compose" ]]; then
        public_vote_url="http://localhost:8080"
        public_result_url="http://localhost:8081"
    elif [[ -z "${public_vote_url}" || -z "${public_result_url}" ]] && command -v kubectl >/dev/null 2>&1 && [[ "${DEPLOY_METHOD}" == "kubernetes" || "${DEPLOY_METHOD}" == "argocd" ]]; then
        local vote_hostname=""
        local result_hostname=""

        vote_hostname=$(kubectl -n "${K8S_NAMESPACE}" get svc vote -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        result_hostname=$(kubectl -n "${K8S_NAMESPACE}" get svc result -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

        if [[ -n "${vote_hostname}" ]]; then
            public_vote_url="http://${vote_hostname}"
        fi

        if [[ -n "${result_hostname}" ]]; then
            public_result_url="http://${result_hostname}"
        fi
    fi

    if [[ -z "${public_vote_url}" ]]; then
        public_vote_url="Pending LoadBalancer hostname"
    fi

    if [[ -z "${public_result_url}" ]]; then
        public_result_url="Pending LoadBalancer hostname"
    fi

    echo ""
    echo -e "${GREEN}=================================================================================${NC}"
    echo -e "${GREEN}DEPLOYMENT SUMMARY${NC}"
    echo -e "${GREEN}=================================================================================${NC}"
    echo ""
    echo "Project Root:        ${PROJECT_ROOT}"
    echo "Configuration File:  ${CONFIG_FILE}"
    echo "AWS Region:          ${AWS_REGION}"
    echo "Kubernetes Cluster:  ${K8S_CLUSTER_NAME}"
    echo "Namespace:           ${K8S_NAMESPACE}"
    echo "Deploy Method:       ${DEPLOY_METHOD}"
    if [[ "${DEPLOY_METHOD}" == "ansible" ]]; then
        echo "Ansible Inventory:   ${ANSIBLE_INVENTORY_FILE:-${PROJECT_ROOT}/2-infrastructure-as-code/Ansible/generated_inventory.ini}"
    fi
    echo ""
    
    if [[ "${DEPLOY_METHOD}" == "docker-compose" ]]; then
        echo "Docker Compose Services:"
        docker-compose -f "${PROJECT_ROOT}/docker-compose.yml" ps 2>/dev/null || true
    elif [[ "${DEPLOY_METHOD}" == "kubernetes" ]] || [[ "${DEPLOY_METHOD}" == "argocd" ]]; then
        echo "Kubernetes Deployments:"
        kubectl get deployments -n "${K8S_NAMESPACE}" 2>/dev/null || echo "  (Cluster not available)"
    fi

    echo ""
    echo "Public AWS URLs:"
    echo "  Vote app:   ${public_vote_url}"
    echo "  Result app: ${public_result_url}"
    if [[ "${DEPLOY_METHOD}" == "kubernetes" || "${DEPLOY_METHOD}" == "argocd" ]]; then
        if [[ "${public_vote_url}" == "Pending LoadBalancer hostname" || "${public_result_url}" == "Pending LoadBalancer hostname" ]]; then
            echo "  Note: If this remains pending, verify the 'voting-app' namespace and LoadBalancer services exist."
        fi
    fi

    if [[ "${DRY_RUN}" != "true" ]] && command -v aws >/dev/null 2>&1 && [[ "${SKIP_TERRAFORM:-false}" != "true" ]]; then
        local sns_topic_arn=""
        local sns_subscription_status=""
        local sns_subscription_endpoint=""

        if [[ -n "${TF_OUTPUTS:-}" ]] && command -v jq >/dev/null 2>&1; then
            sns_topic_arn=$(echo "${TF_OUTPUTS}" | jq -r '.dev_alerts_sns_topic_arn.value // empty' 2>/dev/null || true)
        fi

        if [[ -n "${sns_topic_arn}" ]]; then
            echo ""
            echo "SNS Email Subscription Status:"
            sns_subscription_status=$(aws sns list-subscriptions-by-topic \
                --topic-arn "${sns_topic_arn}" \
                --region "${AWS_REGION}" \
                --query "Subscriptions[?Protocol=='email']|[0].SubscriptionArn" \
                --output text 2>/dev/null || true)

            sns_subscription_endpoint=$(aws sns list-subscriptions-by-topic \
                --topic-arn "${sns_topic_arn}" \
                --region "${AWS_REGION}" \
                --query "Subscriptions[?Protocol=='email']|[0].Endpoint" \
                --output text 2>/dev/null || true)

            if [[ -z "${sns_subscription_status}" ]] || [[ "${sns_subscription_status}" == "None" ]]; then
                echo "  Email subscription: Not configured"
            elif [[ "${sns_subscription_status}" == "PendingConfirmation" ]]; then
                echo "  Email subscription: PendingConfirmation (${sns_subscription_endpoint:-unknown endpoint})"
            else
                echo "  Email subscription: Confirmed (${sns_subscription_endpoint:-unknown endpoint})"
            fi
        fi
    fi
    
    echo ""
    echo -e "${GREEN}Log file: ${LOG_FILE}${NC}"
    echo ""
}

# ============================================================================
# USAGE INFORMATION
# ============================================================================
usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

COMMANDS:
    deploy          Deploy the entire application stack
    cleanup         Tear down all deployed resources
    build           Build Docker images only
    infrastructure  Provision infrastructure only
    kubernetes      Deploy to Kubernetes only
    compose         Deploy with Docker Compose only
    ansible         Deploy with Ansible only

OPTIONS:
    --dry-run       Show what would be executed without making changes
    --skip-build    Skip Docker image builds
    --skip-tf       Skip Terraform provisioning
    --skip-k8s      Skip Kubernetes deployment
    --config FILE   Use specific config file (default: deployment.config)
    -h, --help      Show this help message

EXAMPLES:
    # Deploy everything using default configuration
    $0 deploy

    # Preview what would be deployed
    $0 deploy --dry-run

    # Just build Docker images
    $0 build

    # Clean up everything
    $0 cleanup

    # Deploy with custom config file
    $0 deploy --config /path/to/custom.config

    # Deploy with Ansible
    $0 ansible

CONFIGURATION:
    All configuration is managed in: ${CONFIG_FILE}
    Edit that file to customize deployment parameters.

EOF
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================
main() {
    local command="${1:-deploy}"

    if [[ "${command}" == "ansible" ]]; then
        DEPLOY_METHOD="ansible"
    fi
    
    # Parse optional arguments
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --skip-build)
                SKIP_BUILD="true"
                shift
                ;;
            --skip-tf)
                SKIP_TERRAFORM="true"
                shift
                ;;
            --skip-k8s)
                SKIP_K8S_DEPLOY="true"
                shift
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Execute command
    case "${command}" in
        deploy)
            deploy
            ;;
        cleanup)
            cleanup
            ;;
        build)
            validate_config
            build_docker_images
            push_docker_images
            ;;
        infrastructure)
            validate_config
            provision_infrastructure
            ;;
        kubernetes)
            validate_config
            deploy_to_kubernetes
            ;;
        compose)
            validate_config
            deploy_with_docker_compose
            ;;
        ansible)
            validate_config
            deploy_with_ansible
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown command: ${command}"
            usage
            exit 1
            ;;
    esac
}

# Execute main function
main "$@"
