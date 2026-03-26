#!/bin/bash

# Final Setup Script - Final configuration and information display

# Source common utilities
source /tmp/scripts/utils.sh

# Setup error handling
setup_error_handling

log "Starting final setup and information display..."

# Paths
BASE_TF_PATH="/root/devops-tf-deployment/tf-openstack-base"
HEAD_TF_PATH="/root/devops-tf-deployment/tf-head-services"

# Display deployment information
display_deployment_info() {
    log "Gathering deployment information..."

    # Get outputs from Terraform
    local head_host monitoring_password keycloak_password

    cd "$BASE_TF_PATH" || {
        log_error "Failed to change to base Terraform directory"
        return 1
    }

    if ! head_host=$(tofu output -raw cluster_ip 2>/dev/null); then
        log_warning "Could not retrieve head_host from Terraform output"
        head_host="<unavailable>"
    fi

    cd "$HEAD_TF_PATH" || {
        log_error "Failed to change to head services directory"
        return 1
    }

    if ! monitoring_password=$(tofu output -raw monitoring_admin_password 2>/dev/null); then
        log_warning "Could not retrieve monitoring password from Terraform output"
        monitoring_password="<unavailable>"
    fi

    if ! keycloak_password=$(tofu output -raw keycloak_password 2>/dev/null); then
        log_warning "Could not retrieve Keycloak password from Terraform output"
        keycloak_password="<unavailable>"
    fi

    log_success "Deployment information gathered"

    # Display the information
    echo ""
    echo "========================================"
    echo " DEPLOYMENT COMPLETED SUCCESSFULLY! "
    echo "========================================"
    echo ""
    echo " Web Interface:"
    echo "   URL: https://$head_host/"
    echo ""
    echo " Default Login Credentials:"
    echo "   Username: crczp-admin"
    echo "   Password: password"
    echo ""
    echo " Monitoring (Grafana):"
    echo "   Admin Password: $monitoring_password"
    echo ""
    echo " Keycloak Admin:"
    echo "   Admin Password: $keycloak_password"
    echo ""
    echo " Training Libraries to Import:"
    echo "   Repository URLs to add in the web interface:"
    echo ""
    echo "   • Demo Training:"
    echo "     https://github.com/cyberrangecz/library-demo-training.git"
    echo ""
    echo "   • Demo Training (Adaptive):"
    echo "     https://github.com/cyberrangecz/library-demo-training-adaptive.git"
    echo ""
    echo "   • Junior Hacker:"
    echo "     https://github.com/cyberrangecz/library-junior-hacker.git"
    echo ""
    echo "   • Junior Hacker (Adaptive):"
    echo "     https://github.com/cyberrangecz/library-junior-hacker-adaptive.git"
    echo ""
    echo "   • Locust 3302:"
    echo "     https://github.com/cyberrangecz/library-locust-3302.git"
    echo ""
    echo "   • Secret Laboratory:"
    echo "     https://github.com/cyberrangecz/library-secret-laboratory.git"
    echo ""
    echo "========================================"
    echo ""
}

# Verify services are running
verify_services() {
    log "Verifying deployed services..."

    # Check if OpenStack is responding
    if source /etc/kolla/admin-openrc.sh 2>/dev/null && openstack service list >/dev/null 2>&1; then
        log_success "OpenStack services are running"
    else
        log_warning "OpenStack services may not be fully ready"
    fi

    # Check if Kubernetes is responding
    if kubectl version --client >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
        log_success "Kubernetes cluster is accessible"
    else
        log_warning "Kubernetes cluster may not be fully ready"
    fi

    log_success "Service verification completed"
}

# Final cleanup and optimization
final_cleanup() {
    log "Performing final cleanup..."

    # Clean up package cache
    apt autoremove -y >/dev/null 2>&1 || true
    apt autoclean >/dev/null 2>&1 || true

    # Clean up temporary files
    rm -rf /tmp/scripts/ 2>/dev/null || true

    # Ensure proper permissions
    chmod 600 /root/.ssh/id_rsa 2>/dev/null || true
    chmod 600 /root/.kube/config 2>/dev/null || true

    log_success "Final cleanup completed"
}

# Main execution
main() {
    log "=== Starting Final Setup Phase ==="

    # Give services a moment to settle
    sleep 10

    verify_services
    display_deployment_info
    final_cleanup

    log_success "=== Final Setup Phase Completed ==="
    log_success "CyberRange deployment is ready for use!"
}

# Run main function
main "$@"
