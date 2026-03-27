#!/bin/bash

# Infrastructure Deployment Script - Deploy Kubernetes and applications using Terraform

# Source common utilities
source /tmp/scripts/utils.sh

# Setup error handling
setup_error_handling

log "Starting infrastructure deployment..."

# Get environment variables
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-1.0.0.1}"

# Paths
REPO_PATH="/root/devops-tf-deployment"
BASE_TF_PATH="$REPO_PATH/tf-openstack-base"
HEAD_TF_PATH="$REPO_PATH/tf-head-services"
VENV_PATH="/root/kolla-ansible-venv"

# === CUSTOM: Docker images của bạn ===
CUSTOM_FRONTEND_IMAGE="sp26ojt/frontend-platform"
CUSTOM_FRONTEND_TAG="v6"

CUSTOM_TRAINING_IMAGE="nnm311/kypo-training-service"
CUSTOM_TRAINING_TAG="v26"

CUSTOM_ADAPTIVE_TRAINING_IMAGE="nnm311/kypo-adaptive-training-service"
CUSTOM_ADAPTIVE_TRAINING_TAG="v1"
# ======================================

# Setup application credentials
setup_application_credentials() {
    log "Setting up OpenStack application credentials..."

    source /etc/kolla/admin-openrc.sh
    source "$VENV_PATH/bin/activate"

    # Check if demo application credential already exists
    if openstack application credential show demo > /dev/null 2>&1; then
        log "Using existing application credential"
        export OS_APPLICATION_CREDENTIAL_ID=$(openstack application credential show demo -f json | jq -r '.id')
    else
        log "Creating new application credential"
        export OS_APPLICATION_CREDENTIAL_ID=$(openstack application credential create \
            --unrestricted \
            --role admin \
            --secret password \
            demo -f json | jq -r '.id')
    fi

    # Set up credential environment
    export OS_AUTH_TYPE=v3applicationcredential
    export OS_INTERFACE=public
    export OS_APPLICATION_CREDENTIAL_SECRET=password

    # Unset password-based auth variables
    unset OS_AUTH_PLUGIN OS_ENDPOINT_TYPE OS_PASSWORD OS_PROJECT_DOMAIN_NAME \
          OS_PROJECT_NAME OS_TENANT_NAME OS_USERNAME OS_USER_DOMAIN_NAME

    log_success "Application credentials configured"
}

# Setup Git repository
setup_git_repository() {
    log "Setting up Git repository..."

    # Clone repository only if it doesn't exist
    cd /root
    if [ ! -d "$REPO_PATH" ]; then
        log "Cloning repository..."
        retry git clone -b v1.4.0 https://github.com/cyberrangecz/devops-tf-deployment

        if [ ! -d "$REPO_PATH" ]; then
            log_error "Failed to clone repository"
            return 1
        fi
        log "Repository cloned successfully"
    else
        log "Repository already exists, updating..."
        cd "$REPO_PATH"

        # Fetch latest changes but don't reset local modifications
        if ! git fetch origin v1.4.0 2>/dev/null; then
            log_warning "Failed to fetch updates, continuing with existing repository"
        fi
    fi

    log_success "Git repository setup completed"
}

# Deploy base infrastructure
deploy_base_infrastructure() {
    log "Deploying base infrastructure with Terraform..."

    cd "$BASE_TF_PATH" || {
        log_error "Failed to change to base Terraform directory"
        return 1
    }

    # Check if Terraform is already initialized
    if [ ! -d ".terraform" ]; then
        log "Initializing Terraform..."
        retry tofu init
    else
        log "Terraform already initialized, checking for updates..."
        retry tofu init -upgrade
    fi

    # === CUSTOM FIX: Chỉ Curl file images.tf đã fix cứng IP về ===
    log "Downloading custom images.tf..."
    IMAGES_TF_PATH=".terraform/modules/images/images.tf"
    CUSTOM_FILE_URL="http://192.168.121.1:8080/images.tf" # <-- Điền link của bạn vào đây

    if [ -d ".terraform/modules/images" ]; then
        rm -f "$IMAGES_TF_PATH"
        curl -sSL "$CUSTOM_FILE_URL" -o "$IMAGES_TF_PATH"
        log "Successfully replaced images.tf"
    else
        log_warning "Directory .terraform/modules/images not found. Custom fix skipped."
    fi
    # ==============================================================

    # Set Terraform variables
    export TF_VAR_external_network_name=public1
    export TF_VAR_dns_nameservers="[\"$DNS1\",\"$DNS2\"]"
    export TF_VAR_standard_small_disk="10"
    export TF_VAR_standard_medium_disk="16"

    log "Terraform variables configured:"
    log "  - external_network_name: $TF_VAR_external_network_name"
    log "  - dns_nameservers: $TF_VAR_dns_nameservers"
    log "  - standard_small_disk: $TF_VAR_standard_small_disk"
    log "  - standard_medium_disk: $TF_VAR_standard_medium_disk"

    # Check current state
    log "Checking current infrastructure state..."
    if tofu plan -var-file tfvars/vars-all.tfvars -detailed-exitcode >/dev/null 2>&1; then
        exit_code=$?
        case $exit_code in
            0)
                log "Infrastructure is up to date, no changes needed"
                return 0
                ;;
            1)
                log_error "Terraform plan failed"
                return 1
                ;;
            2)
                log "Changes detected, applying infrastructure updates..."
                ;;
        esac
    fi

    # Apply Terraform configuration
    log "Applying base infrastructure (this may take 15-30 minutes)..."

    # === CUSTOM FIX 2: Ép chạy tuần tự để chống nghẽn I/O ===
    if ! retry tofu apply -auto-approve -var-file tfvars/vars-all.tfvars -parallelism=1; then
        log_error "Base infrastructure deployment failed"
        return 1
    fi

    log_success "Base infrastructure deployment completed"
}

# Setup Kubernetes configuration
setup_kubernetes_config() {
    log "Setting up Kubernetes configuration..."

    cd "$BASE_TF_PATH" || {
        log_error "Failed to change to base Terraform directory"
        return 1
    }

    # Create .kube directory and copy config
    safe_mkdir /root/.kube

    if [ -f config ]; then
        safe_copy config /root/.kube/config
        chmod 600 /root/.kube/config
    else
        log_error "Kubernetes config file not found"
        return 1
    fi

    log_success "Kubernetes configuration setup completed"
}

# Wait for Kubernetes cluster
wait_for_kubernetes() {
    log "Waiting for Kubernetes cluster to be ready..."

    # Wait for kubectl to be functional
    wait_for_service "kubectl" "kubectl version --client"

    # Wait for Traefik CRD to be available (indicates k3s is fully ready)
    wait_for_service "Traefik CRD" "kubectl get crd middlewares.traefik.io" 9999 1

    log_success "Kubernetes cluster is ready"
}

# Setup head services variables
setup_head_services_variables() {
    log "Setting up head services variables..."

    cd "$BASE_TF_PATH" || {
        log_error "Failed to change to base Terraform directory"
        return 1
    }

    # Extract outputs from base infrastructure
    local cluster_ip head_host proxy_host proxy_key
    local kubernetes_client_certificate kubernetes_client_key

    cluster_ip=$(tofu output -raw cluster_ip) || {
        log_error "Failed to get cluster_ip output"
        return 1
    }

    head_host=$(tofu output -raw cluster_ip) || {
        log_error "Failed to get head_host output"
        return 1
    }

    proxy_host=$(tofu output -raw proxy_host) || {
        log_error "Failed to get proxy_host output"
        return 1
    }

    proxy_key=$(tofu output -raw proxy_key) || {
        log_error "Failed to get proxy_key output"
        return 1
    }

    kubernetes_client_certificate=$(tofu output -raw kubernetes_client_certificate) || {
        log_error "Failed to get kubernetes_client_certificate output"
        return 1
    }

    kubernetes_client_key=$(tofu output -raw kubernetes_client_key) || {
        log_error "Failed to get kubernetes_client_key output"
        return 1
    }

    # Set environment variables for head services
    export TF_VAR_acme_contact="demo@example.com"
    export TF_VAR_application_credential_id="$OS_APPLICATION_CREDENTIAL_ID"
    export TF_VAR_application_credential_secret="$OS_APPLICATION_CREDENTIAL_SECRET"
    export TF_VAR_enable_monitoring=true
    export TF_VAR_gen_user_count=10
    export TF_VAR_head_host="$head_host"
    export TF_VAR_kubernetes_api_url="https://$cluster_ip:6443/"
    export TF_VAR_kubernetes_client_certificate="$kubernetes_client_certificate"
    export TF_VAR_kubernetes_client_key="$kubernetes_client_key"
    export TF_VAR_man_flavor="standard.medium"
    export TF_VAR_openid_configuration_insecure=true
    export TF_VAR_os_auth_url="$OS_AUTH_URL"
    export TF_VAR_os_region="RegionOne"
    export TF_VAR_proxy_host="$proxy_host"
    export TF_VAR_proxy_key="$proxy_key"

    # Configure users
    export TF_VAR_users="{\"crczp-admin\"={iss=\"https://$head_host/keycloak/realms/CRCZP\",keycloakUsername=\"crczp-admin\",keycloakPassword=\"password\",email=\"crczp-admin@example.com\",fullName=\"Demo Admin\",givenName=\"Demo\",familyName=\"Admin\",admin=true}}"

    log "Head services variables configured for host: $head_host"
    log_success "Head services variables setup completed"
}

# Deploy head services
deploy_head_services() {
    log "Deploying head services..."

    cd "$HEAD_TF_PATH" || {
        log_error "Failed to change to head services directory"
        return 1
    }

    # Copy provider and cloud configuration files if they don't exist
    if [ ! -f provider.tf ] && [ -f provider.tf-os ]; then
        cp provider.tf-os provider.tf
        log "Copied provider configuration"
    elif [ -f provider.tf ]; then
        log "Provider configuration already exists"
    else
        log_error "provider.tf-os not found"
        return 1
    fi

    if [ ! -f cloud.tf ] && [ -f cloud.tf-os ]; then
        cp cloud.tf-os cloud.tf
        log "Copied cloud configuration"
    elif [ -f cloud.tf ]; then
        log "Cloud configuration already exists"
    else
        log_error "cloud.tf-os not found"
        return 1
    fi

    # Update DNS settings in values.yaml if not already updated
    if [ -f values.yaml ]; then
        if ! grep -q "$DNS1" values.yaml; then
            log "Updating DNS settings in values.yaml..."
            sed -i -e "s/1.1.1.1/$DNS1/" -e "s/1.0.0.1/$DNS2/" values.yaml
            log "Updated DNS settings in values.yaml"
        else
            log "DNS settings already configured in values.yaml"
        fi
    else
        log_warning "values.yaml not found, continuing without DNS updates"
    fi

    # === CUSTOM FIX: Override frontend, training, adaptive-training images ===
    if [ -f values.yaml ]; then
        if ! grep -q "CUSTOM_IMAGE_OVERRIDE" values.yaml; then
            log "Appending custom image overrides to values.yaml..."
            cat >> values.yaml << EOF

# CUSTOM_IMAGE_OVERRIDE
frontend:
  image:
    url: ${CUSTOM_FRONTEND_IMAGE}
    tag: ${CUSTOM_FRONTEND_TAG}

training:
  image:
    url: ${CUSTOM_TRAINING_IMAGE}
    tag: ${CUSTOM_TRAINING_TAG}

adaptive-training:
  image:
    url: ${CUSTOM_ADAPTIVE_TRAINING_IMAGE}
    tag: ${CUSTOM_ADAPTIVE_TRAINING_TAG}
EOF
            log "Image overrides applied:"
            log "  - frontend: ${CUSTOM_FRONTEND_IMAGE}:${CUSTOM_FRONTEND_TAG}"
            log "  - training: ${CUSTOM_TRAINING_IMAGE}:${CUSTOM_TRAINING_TAG}"
            log "  - adaptive-training: ${CUSTOM_ADAPTIVE_TRAINING_IMAGE}:${CUSTOM_ADAPTIVE_TRAINING_TAG}"
        else
            log "Custom image overrides already applied in values.yaml"
        fi
    fi
    # =========================================================================

    # Check if Terraform is already initialized
    if [ ! -d ".terraform" ]; then
        log "Initializing head services Terraform..."
        retry tofu init
    else
        log "Terraform already initialized, checking for updates..."
        retry tofu init -upgrade
    fi

    # Check current state before applying
    log "Checking current head services state..."
    if tofu plan -detailed-exitcode >/dev/null 2>&1; then
        exit_code=$?
        case $exit_code in
            0)
                log "Head services are up to date, no changes needed"
                return 0
                ;;
            1)
                log_error "Terraform plan failed"
                return 1
                ;;
            2)
                log "Changes detected, applying head services updates..."
                ;;
        esac
    fi

    # Apply head services configuration
    log "Applying head services configuration (this may take 20-40 minutes)..."
    if ! retry tofu apply -auto-approve; then
        log_error "Head services deployment failed"
        return 1
    fi

    log_success "Head services deployment completed"
}

# Main execution
main() {
    log "=== Starting Infrastructure Deployment Phase ==="

    if ! source /etc/kolla/admin-openrc.sh 2>/dev/null; then
        log_error "Failed to source OpenStack credentials"
        exit 1
    fi

    # Execute deployment steps
    setup_application_credentials
    setup_git_repository
    deploy_base_infrastructure
    setup_kubernetes_config
    wait_for_kubernetes
    setup_head_services_variables
    deploy_head_services

    log_success "=== Infrastructure Deployment Phase Completed ==="
}

# Run main function
main "$@"
