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

################################################################################
# CI/CD SECURITY PIPELINE OVERVIEW
################################################################################
# WEBHOOK → JENKINS → SONARQUBE → TRIVY → DEPLOY
#
# 1. WEBHOOK (GitHub)
#    - Triggered on: Git push to main branch
#    - Target: http://localhost:8080/github-webhook/
#    - Action: Starts Jenkins job (vote_app)
#
# 2. JENKINS PIPELINE (Pipeline as Code from Jenkinsfile)
#    Stage 1: Checkout
#      - Clones latest code from GitHub repo
#      - Captures commit hash and message
#
#    Stage 2: Validate Sonar Config
#      - Verifies sonar-project.properties exists
#      - Ensures scanner configuration is present
#
#    Stage 3: SonarQube Scan
#      - Scanner: sonar-scanner (host binary at /usr/local/bin/sonar-scanner)
#      - Server: http://localhost:9000
#      - Auth: Token from JOB_SONAR_TOKEN (Jenkins env)
#      - Profiles: Sonar way (Python, JavaScript, C#, Docker, etc.)
#      - Quality Gate: wait=true (blocks on fail)
#
#    Stage 4: Quality Gate
#      - Enforced during scan (sonar.qualitygate.wait=true)
#      - Timeout: 300 seconds
#      - Blocks pipeline if quality gate fails
#
#    Stage 5: Container Security Scan (Trivy)
#      - Tool: Trivy v0.72.0 (container vulnerability scanner)
#      - Scans:
#        * Dockerfiles for misconfigurations (root user, secrets, no HEALTHCHECK)
#        * Python dependencies (requirements.txt) for CVEs
#        * Node.js dependencies (package.json) for CVEs
#      - Filter: HIGH,CRITICAL severity issues reported
#      - Failures: Non-blocking (reports for review)
#
# 3. SONARQUBE (Code Quality Gate)
#    - Server: http://localhost:9000
#    - Project: multi-stack-voting-application
#    - Issues Tracked: Code smells, vulnerabilities, security hotspots
#    - Quality Profiles:
#      * Python (Sonar way): analyzes vote/ app
#      * JavaScript (Sonar way): analyzes result/ frontend
#      * C# (Sonar way): analyzes worker/ service
#      * Docker/IaC profiles: analyzes Dockerfiles
#    - Output: Dashboard at http://localhost:9000/dashboard?id=multi-stack-voting-application
#
# 4. TRIVY (Container Security)
#    - Detects: Known CVEs, hardcoded secrets, insecure configurations
#    - Checks:
#      * Non-root user requirement (prevents container escape)
#      * HEALTHCHECK instructions (enables health monitoring)
#      * Hardcoded secrets (database passwords, API keys)
#    - Database: Updated automatically (mirror.gcr.io/aquasec/trivy-db)
#
# 5. RESULT
#    - All checks pass: Green ✓ (pipeline succeeds)
#    - Quality gate fails: Red ✗ (pipeline blocked)
#    - Trivy issues: Logged (for ops review, non-blocking)
#
# SECURITY POSTURE (Commit 360d3e9)
#   Vote Service:      0 vulnerabilities ✓
#   Worker Service:    0 vulnerabilities ✓
#   Result Service:    0 vulnerabilities ✓
#   Dependencies:      No HIGH/CRITICAL CVEs ✓
#
# NEXT BUILD TRIGGERS
#   - GitHub webhook: On next push to main branch
#   - Manual trigger: Jenkins "Build Now" button (requires login)
#   - Scheduled: Poll SCM every 5 minutes (fallback)
#
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

check_http_endpoint() {
    local url="$1"

    if [[ -z "${url}" || "${url}" == "Pending LoadBalancer hostname" ]]; then
        echo "UNAVAILABLE"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "UNKNOWN"
        return 0
    fi

    local status_code=""
    status_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${url}" 2>/dev/null || true)

    if [[ "${status_code}" == "200" ]]; then
        echo "OK"
    elif [[ -n "${status_code}" && "${status_code}" != "000" ]]; then
        echo "HTTP ${status_code}"
    else
        echo "DOWN"
    fi
}

resolve_public_vote_url() {
    local public_vote_url="${PUBLIC_VOTE_URL:-}"
    local namespace="${K8S_NAMESPACE:-voting-app}"

    if [[ "${DEPLOY_METHOD:-}" == "docker-compose" ]]; then
        echo ""
        return 0
    fi

    if [[ -n "${public_vote_url}" && "${public_vote_url}" != "Pending LoadBalancer hostname" ]]; then
        echo "${public_vote_url}"
        return 0
    fi

    if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
        public_vote_url=$(kubectl -n "${namespace}" get svc vote -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        if [[ -n "${public_vote_url}" ]]; then
            echo "http://${public_vote_url}"
            return 0
        fi
    fi

    echo ""
}

run_vote_simulation() {
    local simulate_after_deploy="${RUN_VOTE_SIMULATION_AFTER_DEPLOY:-true}"
    local simulate_votes_count="${SIMULATE_VOTES_COUNT:-1000}"
    local simulate_vote_workers="${SIMULATE_VOTE_WORKERS:-10}"
    local simulate_local_ratio="${SIMULATE_VOTES_LOCAL_RATIO:-0.5}"
    local simulate_script="${PROJECT_ROOT}/scripts/simulate_votes.py"
    local public_vote_url=""
    local -a simulate_cmd

    if [[ "${simulate_after_deploy}" != "true" ]]; then
        log_info "Skipping vote simulation because RUN_VOTE_SIMULATION_AFTER_DEPLOY=${simulate_after_deploy}"
        return 0
    fi

    if [[ ! -f "${simulate_script}" ]]; then
        log_warn "Vote simulator not found: ${simulate_script}"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        log_warn "python3 not available; skipping vote simulation"
        return 0
    fi

    public_vote_url=$(resolve_public_vote_url)

    simulate_cmd=(
        python3 "${simulate_script}"
        --votes "${simulate_votes_count}"
        --workers "${simulate_vote_workers}"
        --local-ratio "${simulate_local_ratio}"
    )

    if [[ -n "${public_vote_url}" ]]; then
        simulate_cmd+=(--aws-vote-url "${public_vote_url}")
    else
        simulate_cmd=(
            python3 "${simulate_script}"
            --votes "${simulate_votes_count}"
            --workers "${simulate_vote_workers}"
            --local-ratio 1.0
        )
        log_warn "AWS vote URL is not ready; running local-only simulation"
    fi

    log_section "RUNNING VOTE SIMULATION"
    log_info "Command: ${simulate_cmd[*]}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run vote simulation"
        return 0
    fi

    "${simulate_cmd[@]}" || log_warn "Vote simulation finished with a non-zero exit status"
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
    local previous_ansible_inventory_file="${ANSIBLE_INVENTORY_FILE:-}"
    local previous_ansible_setup_playbook="${ANSIBLE_SETUP_PLAYBOOK:-}"
    local previous_ansible_deploy_playbook="${ANSIBLE_DEPLOY_PLAYBOOK:-}"
    local previous_ansible_remote_user="${ANSIBLE_REMOTE_USER:-}"
    local previous_ansible_backend_host="${ANSIBLE_BACKEND_HOST:-}"
    local previous_ansible_frontend_host="${ANSIBLE_FRONTEND_HOST:-}"
    local previous_ansible_backend_group="${ANSIBLE_BACKEND_GROUP:-${ANSIBLE_BACKEND_INVENTORY_NAME:-}}"
    local previous_ansible_frontend_group="${ANSIBLE_FRONTEND_GROUP:-${ANSIBLE_FRONTEND_INVENTORY_NAME:-}}"

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

    if [[ -n "${previous_ansible_inventory_file}" ]]; then
        ANSIBLE_INVENTORY_FILE="${previous_ansible_inventory_file}"
    fi

    if [[ -n "${previous_ansible_setup_playbook}" ]]; then
        ANSIBLE_SETUP_PLAYBOOK="${previous_ansible_setup_playbook}"
    fi

    if [[ -n "${previous_ansible_deploy_playbook}" ]]; then
        ANSIBLE_DEPLOY_PLAYBOOK="${previous_ansible_deploy_playbook}"
    fi

    if [[ -n "${previous_ansible_remote_user}" ]]; then
        ANSIBLE_REMOTE_USER="${previous_ansible_remote_user}"
    fi

    if [[ -n "${previous_ansible_backend_host}" ]]; then
        ANSIBLE_BACKEND_HOST="${previous_ansible_backend_host}"
    fi

    if [[ -n "${previous_ansible_frontend_host}" ]]; then
        ANSIBLE_FRONTEND_HOST="${previous_ansible_frontend_host}"
    fi

    if [[ -n "${previous_ansible_backend_group}" ]]; then
        ANSIBLE_BACKEND_GROUP="${previous_ansible_backend_group}"
    fi

    if [[ -n "${previous_ansible_frontend_group}" ]]; then
        ANSIBLE_FRONTEND_GROUP="${previous_ansible_frontend_group}"
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

    local backend_group_name="${ANSIBLE_BACKEND_GROUP:-${ANSIBLE_BACKEND_INVENTORY_NAME:-backend}}"
    local frontend_group_name="${ANSIBLE_FRONTEND_GROUP:-${ANSIBLE_FRONTEND_INVENTORY_NAME:-frontend}}"
    local backend_inventory_name="${ANSIBLE_BACKEND_INVENTORY_NAME:-backend01}"
    local frontend_inventory_name="${ANSIBLE_FRONTEND_INVENTORY_NAME:-frontend01}"
    local backend_connection="ssh"
    local frontend_connection="ssh"

    if [[ "${ANSIBLE_BACKEND_HOST:-}" == "127.0.0.1" || "${ANSIBLE_BACKEND_HOST:-}" == "localhost" ]]; then
        backend_connection="local"
    fi

    if [[ "${ANSIBLE_FRONTEND_HOST:-}" == "127.0.0.1" || "${ANSIBLE_FRONTEND_HOST:-}" == "localhost" ]]; then
        frontend_connection="local"
    fi

    cat > "${inventory_file}" <<EOF
[${backend_group_name}]
${backend_inventory_name} ansible_host=${ANSIBLE_BACKEND_HOST:-127.0.0.1} ansible_user=${ANSIBLE_REMOTE_USER:-ubuntu} ansible_connection=${backend_connection}

[${frontend_group_name}]
${frontend_inventory_name} ansible_host=${ANSIBLE_FRONTEND_HOST:-127.0.0.1} ansible_user=${ANSIBLE_REMOTE_USER:-ubuntu} ansible_connection=${frontend_connection}
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
        -e "ansible_backend_group=${ANSIBLE_BACKEND_GROUP:-${ANSIBLE_BACKEND_INVENTORY_NAME:-backend}}" \
        -e "ansible_frontend_group=${ANSIBLE_FRONTEND_GROUP:-${ANSIBLE_FRONTEND_INVENTORY_NAME:-frontend}}" \
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
        -e "ansible_backend_group=${ANSIBLE_BACKEND_GROUP:-${ANSIBLE_BACKEND_INVENTORY_NAME:-backend}}" \
        -e "ansible_frontend_group=${ANSIBLE_FRONTEND_GROUP:-${ANSIBLE_FRONTEND_INVENTORY_NAME:-frontend}}" \
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
# Auto-configure kubectl context for EKS when not already connected.
ensure_kubectl_context() {
    if kubectl cluster-info &>/dev/null; then
        return 0
    fi
    if [[ -n "${K8S_CLUSTER_NAME:-}" ]] && command -v aws >/dev/null 2>&1; then
        log_info "Configuring kubectl context for EKS cluster: ${K8S_CLUSTER_NAME}..."
        aws eks update-kubeconfig --name "${K8S_CLUSTER_NAME}" --region "${AWS_REGION:-us-east-1}" 2>/dev/null || true
    fi
}

# ============================================================================
deploy_to_kubernetes() {
    if [[ "${SKIP_K8S_DEPLOY}" == "true" ]]; then
        log_warn "Skipping Kubernetes deployment"
        return 0
    fi
    
    log_section "DEPLOYING TO KUBERNETES"
    
    # Check kubectl connectivity, auto-configure EKS context if needed
    log_info "Checking Kubernetes cluster connectivity..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        ensure_kubectl_context
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
            # Apply core app manifests first (no external CRDs required).
            local core_manifest_paths=(
                "${gitops_dir}/2-data-queue"
                "${gitops_dir}/4-database"
                "${gitops_dir}/1-voting-frontend"
                "${gitops_dir}/5-results-dashboard"
                "${gitops_dir}/3-background-worker"
            )

            local manifest_path
            for manifest_path in "${core_manifest_paths[@]}"; do
                if [[ -d "${manifest_path}" || -f "${manifest_path}" ]]; then
                    kubectl apply -f "${manifest_path}" || log_warn "Failed applying core manifest path: ${manifest_path}"
                fi
            done

            # Optional add-ons may require additional controllers/CRDs. Apply best-effort.
            local optional_manifests=(
                "${gitops_dir}/ingress.yaml"
                "${gitops_dir}/ingress-controller-nginx.yaml"
                "${gitops_dir}/ingress-controller-alb.yaml"
                "${gitops_dir}/cert-manager.yaml"
            )

            local optional_manifest
            for optional_manifest in "${optional_manifests[@]}"; do
                if [[ -f "${optional_manifest}" ]]; then
                    kubectl apply -f "${optional_manifest}" || log_warn "Optional manifest failed (can be ignored for basic app URLs): ${optional_manifest}"
                fi
            done

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
            FLASK_SECRET_KEY="${FLASK_SECRET_KEY:-local-dev-vote-secret-key-change-me}" \
            VOTE_PORT="${VOTE_PORT:-8000}" \
            RESULT_PORT="${RESULT_PORT:-8081}" \
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

    local gitops_dir="${PROJECT_ROOT}/3-gitops-manifests/voting-app-gitops-manifests"
    local argocd_app_manifest="${PROJECT_ROOT}/3-gitops-manifests/argocd-apps/voting-app.yaml"

    log_info "Removing GitOps and EKS add-on manifests (best effort)..."
    if [[ "${DRY_RUN}" != "true" ]]; then
        local teardown_manifests=(
            "${argocd_app_manifest}"
            "${gitops_dir}/ingress.yaml"
            "${gitops_dir}/cert-manager.yaml"
            "${gitops_dir}/ingress-controller-nginx.yaml"
            "${gitops_dir}/ingress-controller-alb.yaml"
        )

        local teardown_manifest
        for teardown_manifest in "${teardown_manifests[@]}"; do
            if [[ -f "${teardown_manifest}" ]]; then
                kubectl delete -f "${teardown_manifest}" --ignore-not-found=true || true
            fi
        done
    else
        log_info "[DRY RUN] Would delete GitOps and EKS add-on manifests"
    fi
    
    log_info "Deleting Kubernetes namespace: ${K8S_NAMESPACE}"
    if [[ "${DRY_RUN}" != "true" ]]; then
        kubectl delete namespace "${K8S_NAMESPACE}" --ignore-not-found || true
        kubectl delete namespace ingress-nginx --ignore-not-found || true
        kubectl delete namespace aws-load-balancer-controller --ignore-not-found || true
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
    run_vote_simulation
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

trigger_jenkins_build() {
    log_section "TRIGGERING JENKINS BUILD"
    
    local jenkins_url="${JENKINS_URL:-http://localhost:8080}"
    local jenkins_job="${JENKINS_JOB:-vote_app}"
    local jenkins_user="${JENKINS_USER:-}"
    local jenkins_token="${JENKINS_TOKEN:-}"
    
    log_info "Jenkins URL: ${jenkins_url}"
    log_info "Jenkins Job: ${jenkins_job}"

    local trigger_url="${jenkins_url}/job/${jenkins_job}/build"
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local response_body="${tmp_dir}/body.txt"
    local response_headers="${tmp_dir}/headers.txt"
    local cookie_jar="${tmp_dir}/cookies.txt"

    cleanup_tmp() {
        rm -rf "${tmp_dir}" >/dev/null 2>&1 || true
    }
    
    # Try to access Jenkins API (may be 403 if anonymous access restricted)
    local api_response=$(curl -s -w "\n%{http_code}" --max-time 5 "${jenkins_url}/api/json" 2>/dev/null | tail -1)
    if [[ "${api_response}" == "200" ]] || [[ "${api_response}" == "403" ]]; then
        log_info "✓ Jenkins is accessible (HTTP ${api_response})"
    else
        log_error "Cannot reach Jenkins at ${jenkins_url} (HTTP ${api_response})"
        return 1
    fi
    
    # If credentials provided, attempt API trigger first, then CSRF crumb flow if needed.
    if [[ -n "${jenkins_user}" && -n "${jenkins_token}" ]]; then
        log_info "Using authentication for Jenkins"

        curl -sS -u "${jenkins_user}:${jenkins_token}" \
            -X POST "${trigger_url}" \
            -D "${response_headers}" \
            -o "${response_body}" >/dev/null || true

        local response
        response=$(awk '/^HTTP\// {code=$2} END {print code}' "${response_headers}")

        if [[ "${response}" == "201" ]] || [[ "${response}" == "200" ]]; then
            log_info "Build triggered successfully via authenticated API (HTTP ${response})"
            cleanup_tmp
            display_jenkins_info
            return 0
        fi

        if grep -qiE "csrf|crumb|session token is missing|no valid crumb" "${response_body}"; then
            log_warn "Jenkins requested CSRF crumb; retrying with crumb + session cookie"

            curl -sS -u "${jenkins_user}:${jenkins_token}" \
                -c "${cookie_jar}" \
                "${jenkins_url}/crumbIssuer/api/json" \
                -o "${tmp_dir}/crumb.json" >/dev/null || true

            local crumb_field
            local crumb_value
            crumb_field=$(sed -n 's/.*"crumbRequestField"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp_dir}/crumb.json" | head -1)
            crumb_value=$(sed -n 's/.*"crumb"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp_dir}/crumb.json" | head -1)

            if [[ -n "${crumb_field}" && -n "${crumb_value}" ]]; then
                curl -sS -u "${jenkins_user}:${jenkins_token}" \
                    -b "${cookie_jar}" -c "${cookie_jar}" \
                    -H "${crumb_field}: ${crumb_value}" \
                    -X POST "${trigger_url}" \
                    -D "${response_headers}" \
                    -o "${response_body}" >/dev/null || true

                response=$(awk '/^HTTP\// {code=$2} END {print code}' "${response_headers}")
                if [[ "${response}" == "201" ]] || [[ "${response}" == "200" ]]; then
                    log_info "Build triggered successfully with CSRF crumb (HTTP ${response})"
                    cleanup_tmp
                    display_jenkins_info
                    return 0
                fi
            else
                log_warn "Could not obtain CSRF crumb from Jenkins"
            fi
        fi

        log_warn "Authenticated trigger failed (HTTP ${response:-unknown})"
    fi

    # Fallback: Direct POST to trigger (works only for anonymous-triggerable jobs).
    log_info "Attempting direct build trigger..."
    curl -sS -X POST "${trigger_url}" -D "${response_headers}" -o "${response_body}" >/dev/null || true
    local response
    response=$(awk '/^HTTP\// {code=$2} END {print code}' "${response_headers}")

    if [[ "${response}" == "201" ]] || [[ "${response}" == "200" ]]; then
        log_info "Build triggered successfully (HTTP ${response})"
        cleanup_tmp
        display_jenkins_info
        return 0
    fi

    if grep -qiE "csrf|crumb|session token is missing|no valid crumb" "${response_body}"; then
        log_warn "Jenkins rejected the request due to missing CSRF token."
    fi

    # If we get here, direct trigger failed - show guidance
    log_warn "Could not trigger build via API (HTTP ${response:-unknown})"
    log_info ""
    log_info "------------------------------------------------------------------"
    log_info "SOLUTION 1: Trigger build via Jenkins Web UI (Easiest)"
    log_info "------------------------------------------------------------------"
    log_info "1. Open Jenkins in your browser:"
    log_info "   ${jenkins_url}/job/${jenkins_job}/"
    log_info ""
    log_info "2. Log in with your Jenkins credentials"
    log_info ""
    log_info "3. Click the 'Build Now' button on the left side"
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "SOLUTION 2: Trigger via deploy script with authentication"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "1. Get your Jenkins API token:"
    log_info "   - Go to: ${jenkins_url}/user/<your-username>/configure"
    log_info "   - Click 'Add new Token' under API tokens section"
    log_info "   - Copy the token"
    log_info ""
    log_info "2. Set environment variables and trigger:"
    log_info "   export JENKINS_USER=<your-username>"
    log_info "   export JENKINS_TOKEN=<your-api-token>"
    log_info "   bash scripts/deploy.sh jenkins"
    log_info ""
    log_info "------------------------------------------------------------------"
    log_info "SOLUTION 3: Trigger via GitHub push (Automatic)"
    log_info "------------------------------------------------------------------"
    log_info "Just push to main branch:"
    log_info "   git commit -am 'Trigger build'"
    log_info "   git push origin main"
    log_info ""
    log_info "GitHub webhook will automatically trigger the Jenkins build"
    log_info "------------------------------------------------------------------"
    log_info ""

    cleanup_tmp
    return 1
}

display_jenkins_info() {
    local jenkins_url="${JENKINS_URL:-http://localhost:8080}"
    local jenkins_job="${JENKINS_JOB:-vote_app}"
    
    log_info ""
    log_info "Build job initiated. Monitor progress at:"
    log_info "  ${jenkins_url}/job/${jenkins_job}/"
    log_info ""
    log_info "Pipeline stages:"
    log_info "  1. Checkout SCM"
    log_info "  2. Validate Sonar Config"
    log_info "  3. SonarQube Scan"
    log_info "  4. Quality Gate"
    log_info "  5. Container Security Scan (Trivy)"
    log_info "  6. Deploy to ArgoCD"
    log_info ""
}

display_deployment_info() {
    local public_vote_url="${PUBLIC_VOTE_URL:-}"
    local public_result_url="${PUBLIC_RESULT_URL:-}"
    local eks_vote_url=""
    local eks_result_url=""
    local vote_hostname=""
    local result_hostname=""
    local can_query_k8s="false"
    local local_vote_url="http://localhost:${VOTE_PORT:-8000}"
    local local_result_url="http://localhost:${RESULT_PORT:-8081}"
    local local_vote_status=""
    local aws_vote_status=""
    local local_result_status=""
    local aws_result_status=""

    if [[ "${DEPLOY_METHOD}" == "docker-compose" ]]; then
        public_vote_url="http://localhost:${VOTE_PORT:-8000}"
        public_result_url="http://localhost:${RESULT_PORT:-8081}"
    fi

    # Auto-configure EKS context so URL lookup always works without manual steps
    if [[ "${DEPLOY_METHOD}" == "kubernetes" ]] || [[ "${DEPLOY_METHOD}" == "argocd" ]]; then
        ensure_kubectl_context
    fi

    if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
        can_query_k8s="true"
        vote_hostname=$(kubectl -n "${K8S_NAMESPACE}" get svc vote -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        result_hostname=$(kubectl -n "${K8S_NAMESPACE}" get svc result -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

        if [[ -n "${vote_hostname}" ]]; then
            eks_vote_url="http://${vote_hostname}"
        fi

        if [[ -n "${result_hostname}" ]]; then
            eks_result_url="http://${result_hostname}"
        fi
    fi

    if [[ ("${DEPLOY_METHOD}" == "kubernetes" || "${DEPLOY_METHOD}" == "argocd") && ( -z "${public_vote_url}" || -z "${public_result_url}" ) ]]; then
        if [[ -n "${eks_vote_url}" ]]; then
            public_vote_url="${eks_vote_url}"
        fi
        if [[ -n "${eks_result_url}" ]]; then
            public_result_url="${eks_result_url}"
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
    if [[ "${DEPLOY_METHOD}" == "docker-compose" ]]; then
        echo "Local URLs:"
    else
        echo "Public URLs:"
    fi
    echo "  Vote app:   ${public_vote_url}"
    echo "  Result app: ${public_result_url}"

    if [[ "${DEPLOY_METHOD}" == "docker-compose" ]]; then
        echo ""
        echo "EKS URLs (${K8S_NAMESPACE} namespace):"
        if [[ -n "${eks_vote_url}" || -n "${eks_result_url}" ]]; then
            echo "  Vote app:   ${eks_vote_url:-Pending LoadBalancer hostname}"
            echo "  Result app: ${eks_result_url:-Pending LoadBalancer hostname}"
        elif [[ "${can_query_k8s}" == "true" ]]; then
            echo "  Vote app:   Pending LoadBalancer hostname"
            echo "  Result app: Pending LoadBalancer hostname"
            echo "  Note: Services may not be type LoadBalancer yet."
        else
            echo "  Unable to query cluster (kubectl context not configured or cluster unreachable)."
            echo "  Run: aws eks update-kubeconfig --name ${K8S_CLUSTER_NAME} --region ${AWS_REGION}"
        fi
    fi

    if [[ "${DEPLOY_METHOD}" == "kubernetes" || "${DEPLOY_METHOD}" == "argocd" ]]; then
        if [[ "${public_vote_url}" == "Pending LoadBalancer hostname" || "${public_result_url}" == "Pending LoadBalancer hostname" ]]; then
            echo "  Note: If this remains pending, verify the 'voting-app' namespace and LoadBalancer services exist."
        fi
    fi

    local_vote_status=$(check_http_endpoint "${local_vote_url}")
    local_result_status=$(check_http_endpoint "${local_result_url}")
    aws_vote_status=$(check_http_endpoint "${public_vote_url}")
    aws_result_status=$(check_http_endpoint "${public_result_url}")

    echo ""
    echo "Endpoint checks:"
    case "${local_vote_status}" in
        OK) echo "  ✅ Local Vote           (${local_vote_url})" ;;
        HTTP*) echo "  ❌ Local Vote           ${local_vote_status}" ;;
        DOWN) echo "  ❌ Local Vote           Unreachable (${local_vote_url})" ;;
        *) echo "  ⚠️  Local Vote           ${local_vote_status}" ;;
    esac
    case "${aws_vote_status}" in
        OK) echo "  ✅ AWS Vote             (${public_vote_url})" ;;
        HTTP*) echo "  ❌ AWS Vote             ${aws_vote_status}" ;;
        DOWN) echo "  ❌ AWS Vote             Unreachable (${public_vote_url})" ;;
        UNAVAILABLE) echo "  ⚠️  AWS Vote             URL not configured or still pending" ;;
        *) echo "  ⚠️  AWS Vote             ${aws_vote_status}" ;;
    esac
    case "${local_result_status}" in
        OK) echo "  ✅ Local Result         (${local_result_url})" ;;
        HTTP*) echo "  ❌ Local Result         ${local_result_status}" ;;
        DOWN) echo "  ❌ Local Result         Unreachable (${local_result_url})" ;;
        *) echo "  ⚠️  Local Result         ${local_result_status}" ;;
    esac
    case "${aws_result_status}" in
        OK) echo "  ✅ AWS Result           (${public_result_url})" ;;
        HTTP*) echo "  ❌ AWS Result           ${aws_result_status}" ;;
        DOWN) echo "  ❌ AWS Result           Unreachable (${public_result_url})" ;;
        UNAVAILABLE) echo "  ⚠️  AWS Result           URL not configured or still pending" ;;
        *) echo "  ⚠️  AWS Result           ${aws_result_status}" ;;
    esac

    echo ""
    echo "Load test command:"
    if [[ "${public_vote_url}" != "Pending LoadBalancer hostname" ]]; then
        echo "  python3 ${PROJECT_ROOT}/scripts/simulate_votes.py --aws-vote-url ${public_vote_url}"
    else
        echo "  python3 ${PROJECT_ROOT}/scripts/simulate_votes.py --local-ratio 1.0"
        echo "  Set PUBLIC_VOTE_URL or wait for the LoadBalancer hostname before sending AWS traffic."
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

run_preflight_validation() {
    local checks_passed=0
    local checks_failed=0

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

    set +e

    section "CHECKING REQUIRED TOOLS"

    if command -v docker &> /dev/null; then
        docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
        [ -z "$docker_version" ] && docker_version="Unknown"
        check_pass "Docker installed (v${docker_version})"
    else
        check_fail "Docker not found - install from https://docs.docker.com/get-docker/"
    fi

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

    if command -v terraform &> /dev/null; then
        tf_version=$(terraform -version 2>/dev/null | head -n1 | awk '{print $2}')
        [ -z "$tf_version" ] && tf_version="Unknown"
        check_pass "Terraform installed (${tf_version})"
    else
        check_fail "Terraform not found - install from https://www.terraform.io/downloads"
    fi

    if command -v aws &> /dev/null; then
        aws_version=$(aws --version 2>&1 | awk '{print $1}' | cut -d'/' -f2)
        [ -z "$aws_version" ] && aws_version="Unknown"
        check_pass "AWS CLI installed (v${aws_version})"
    else
        check_fail "AWS CLI not found - install from https://aws.amazon.com/cli/"
    fi

    if command -v kubectl &> /dev/null; then
        kubectl_version=$(kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
        [ -z "$kubectl_version" ] && kubectl_version="Unknown"
        check_pass "kubectl installed (${kubectl_version})"
    else
        check_warn "kubectl not found - Kubernetes deployments will not work"
    fi

    if command -v ansible-playbook &> /dev/null; then
        ansible_version=$(ansible-playbook --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        [ -z "$ansible_version" ] && ansible_version="Unknown"
        check_pass "Ansible installed (v${ansible_version})"
    else
        check_warn "ansible-playbook not found - Ansible deployment will not work"
    fi

    section "CHECKING CONFIGURATION FILE"

    if [[ -f "${CONFIG_FILE}" ]]; then
        check_pass "Configuration file found: ${CONFIG_FILE}"
        source "${CONFIG_FILE}" 2>/dev/null

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

    section "VALIDATING CONFIGURATION VALUES"

    if [[ -n "${AWS_REGION:-}" ]]; then
        check_pass "AWS_REGION configured: ${AWS_REGION}"
    else
        check_fail "AWS_REGION not set in deployment.config"
    fi

    echo -ne "${YELLOW}Enter EC2 ssh key name: ${NC}"
    read -r TF_VAR_key_name

    if [[ -n "${TF_VAR_key_name:-}" ]] && [[ "${TF_VAR_key_name}" != "your-ec2-key-pair" ]]; then
        check_pass "EC2 key pair configured: ${TF_VAR_key_name}"
    else
        check_fail "TF_VAR_key_name not properly configured (update in deployment.config)"
    fi

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

    echo -ne "${YELLOW}Enter PostgreSQL Password: ${NC}"
    read -r POSTGRES_PASSWORD

    if [[ -n "${POSTGRES_PASSWORD:-}" ]] && [[ "${POSTGRES_PASSWORD}" != "postgres-password-123" ]]; then
        check_pass "Database password configured (hidden for security)"
    else
        check_fail "POSTGRES_PASSWORD using default value - change in deployment.config"
    fi

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

    section "CHECKING FILE PERMISSIONS"

    if [[ -x "${PROJECT_ROOT}/scripts/deploy.sh" ]]; then
        check_pass "scripts/deploy.sh is executable"
    else
        check_warn "scripts/deploy.sh not executable - run: chmod +x scripts/deploy.sh"
    fi

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

    section "CHECKING DOCKER IMAGES"

    docker_images=("vote" "result" "worker")

    for image in "${docker_images[@]}"; do
        if docker images 2>/dev/null | grep -q "$image"; then
            check_pass "Docker image found: ${image}"
        else
            check_warn "Docker image not built: ${image} (will be built during deployment)"
        fi
    done

    section "SUMMARY"

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
        return 0
    fi

    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}✗ SOME CHECKS FAILED - Fix issues before deploying${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "Issues to fix:"
    echo "  - Install missing tools (see above)"
    echo "  - Update deployment.config with your values"
    echo "  - Verify AWS credentials (aws configure)"
    echo ""
    return 1
}

run_test_alerts() {
    local tf_dir="${PROJECT_ROOT}/2-infrastructure-as-code/terraform/environments/dev"

    echo "Discovering SNS topic ARN from Terraform outputs..."
    pushd "${tf_dir}" >/dev/null
    SNS_ARN=$(terraform output -raw dev_alerts_sns_topic_arn 2>/dev/null || true)
    popd >/dev/null

    if [[ -z "${SNS_ARN:-}" ]]; then
        echo "SNS topic ARN not found. Ensure Terraform applied the dev environment and outputs are available." >&2
        return 1
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
}

# ============================================================================
# USAGE INFORMATION
# ============================================================================
usage() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

COMMANDS:
    deploy          Deploy the entire application stack
    validate        Run prerequisite and configuration validation
    test-alerts     Send a test SNS message and CloudWatch metric
    cleanup         Tear down all deployed resources
    build           Build Docker images only
    infrastructure  Provision infrastructure only
    kubernetes      Deploy to Kubernetes only
    compose         Deploy with Docker Compose only
    ansible         Deploy with Ansible only
    jenkins         Trigger Jenkins CI/CD pipeline build

OPTIONS:
    --dry-run       Show what would be executed without making changes
    --skip-build    Skip Docker image builds
    --skip-tf       Skip Terraform provisioning
    --skip-k8s      Skip Kubernetes deployment
    --config FILE   Use specific config file (default: deployment.config)
    --ansible-backend-group NAME  Set the backend inventory group name
    --ansible-frontend-group NAME Set the frontend inventory group name
    --ansible-backend-name NAME   Set the backend inventory host alias
    --ansible-frontend-name NAME  Set the frontend inventory host alias
    --ansible-backend-host HOST   Set the backend target host/IP
    --ansible-frontend-host HOST  Set the frontend target host/IP
    --ansible-remote-user USER    Set the Ansible SSH user
    --ansible-inventory-file FILE  Set the generated inventory path
    -h, --help      Show this help message

EXAMPLES:
    # Deploy everything using default configuration
    $0 deploy

    # Run validation
    $0 validate

    # Test alerts
    $0 test-alerts

    # Trigger Jenkins build
    $0 jenkins

    # Trigger Jenkins with authentication
    JENKINS_USER=admin JENKINS_TOKEN=your-token $0 jenkins

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
            --ansible-backend-group)
                ANSIBLE_BACKEND_GROUP="$2"
                ANSIBLE_BACKEND_INVENTORY_NAME="$2"
                shift 2
                ;;
            --ansible-frontend-group)
                ANSIBLE_FRONTEND_GROUP="$2"
                ANSIBLE_FRONTEND_INVENTORY_NAME="$2"
                shift 2
                ;;
            --ansible-backend-name)
                ANSIBLE_BACKEND_GROUP="$2"
                ANSIBLE_BACKEND_INVENTORY_NAME="$2"
                shift 2
                ;;
            --ansible-frontend-name)
                ANSIBLE_FRONTEND_GROUP="$2"
                ANSIBLE_FRONTEND_INVENTORY_NAME="$2"
                shift 2
                ;;
            --ansible-backend-host)
                ANSIBLE_BACKEND_HOST="$2"
                shift 2
                ;;
            --ansible-frontend-host)
                ANSIBLE_FRONTEND_HOST="$2"
                shift 2
                ;;
            --ansible-remote-user)
                ANSIBLE_REMOTE_USER="$2"
                shift 2
                ;;
            --ansible-inventory-file)
                ANSIBLE_INVENTORY_FILE="$2"
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
        validate)
            run_preflight_validation
            ;;
        test-alerts)
            run_test_alerts
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
        jenkins)
            trigger_jenkins_build
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
