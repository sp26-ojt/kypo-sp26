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

    # Priority chain: KYPO_PUBLIC_HOST → KYPO_PUBLIC_IP → cluster_ip (tofu output)
    if [[ -n "${KYPO_PUBLIC_HOST:-}" ]]; then
        head_host="${KYPO_PUBLIC_HOST}"
        log "Using KYPO_PUBLIC_HOST as display URL: ${head_host}"
    elif [[ -n "${KYPO_PUBLIC_IP:-}" ]]; then
        head_host="${KYPO_PUBLIC_IP}"
        log "Using KYPO_PUBLIC_IP as display URL: ${head_host}"
    else
        log "Using cluster_ip as display URL: ${head_host}"
    fi

    cd "$HEAD_TF_PATH" || {
        log_error "Failed to change to head services directory"
        return 1
    }

    local grafana_user prometheus_user
    grafana_user="admin"
    prometheus_user="admin"

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
    echo "   URL:      https://$head_host/grafana/"
    echo "   Username: $grafana_user"
    echo "   Password: $monitoring_password"
    echo ""
    echo " Monitoring (Prometheus):"
    echo "   URL:      https://$head_host/prometheus/"
    echo "   Username: $prometheus_user"
    echo "   Password: $monitoring_password"
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

# Configure OpenStack quotas
configure_openstack_quotas() {
    log "Configuring OpenStack quotas..."

    source /etc/kolla/admin-openrc.sh
    source /root/kolla-ansible-venv/bin/activate

    local total_ram_mb total_vcpu usable_ram_mb max_instances
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    total_vcpu=$(nproc)
    usable_ram_mb=$(( total_ram_mb - 20480 ))
    max_instances=100

    # Update Placement inventory via API (cpu_allocation_ratio=16, disk_allocation_ratio=3)
    local admin_pass token rp gen total_disk
    admin_pass=$(grep keystone_admin_password /etc/kolla/passwords.yml | awk '{print $2}')

    token=$(curl -s -X POST http://10.1.2.9:5000/v3/auth/tokens \
        -H 'Content-Type: application/json' \
        -d "{\"auth\":{\"identity\":{\"methods\":[\"password\"],\"password\":{\"user\":{\"name\":\"admin\",\"domain\":{\"name\":\"Default\"},\"password\":\"${admin_pass}\"}}},\"scope\":{\"project\":{\"name\":\"admin\",\"domain\":{\"name\":\"Default\"}}}}}" \
        -D - 2>/dev/null | grep -i x-subject-token | awk '{print $2}' | tr -d '\r ')

    if [[ -n "$token" ]]; then
        rp=$(curl -s http://10.1.2.9:8780/resource_providers \
            -H "X-Auth-Token: $token" \
            -H 'OpenStack-API-Version: placement 1.36' \
            | python3 -c 'import sys,json; print(json.load(sys.stdin)["resource_providers"][0]["uuid"])' 2>/dev/null)

        gen=$(curl -s "http://10.1.2.9:8780/resource_providers/$rp/inventories" \
            -H "X-Auth-Token: $token" \
            -H 'OpenStack-API-Version: placement 1.36' \
            | python3 -c 'import sys,json; print(json.load(sys.stdin)["resource_provider_generation"])' 2>/dev/null)

        total_disk=$(df -BG / | awk 'NR==2{print int($2)}')

        curl -s -X PUT "http://10.1.2.9:8780/resource_providers/$rp/inventories" \
            -H "X-Auth-Token: $token" \
            -H 'OpenStack-API-Version: placement 1.36' \
            -H 'Content-Type: application/json' \
            -d "{
                \"resource_provider_generation\": $gen,
                \"inventories\": {
                    \"VCPU\":      {\"total\": $total_vcpu, \"reserved\": 0, \"min_unit\": 1, \"max_unit\": $total_vcpu, \"step_size\": 1, \"allocation_ratio\": 16.0},
                    \"MEMORY_MB\": {\"total\": $total_ram_mb, \"reserved\": 512, \"min_unit\": 1, \"max_unit\": $total_ram_mb, \"step_size\": 1, \"allocation_ratio\": 1.0},
                    \"DISK_GB\":   {\"total\": $total_disk, \"reserved\": 0, \"min_unit\": 1, \"max_unit\": $total_disk, \"step_size\": 1, \"allocation_ratio\": 3.0}
                }
            }" >/dev/null
        log_success "Placement inventory updated (VCPU ratio=16, DISK ratio=3)"
    else
        log_warning "Could not get Keystone token, skipping Placement update"
    fi

    # Set Nova quota for each project
    for project in admin demo; do
        if openstack project show "$project" >/dev/null 2>&1; then
            openstack quota set \
                --cores $(( total_vcpu * 16 )) \
                --ram "$usable_ram_mb" \
                --instances "$max_instances" \
                --floating-ips 50 \
                --volumes 100 \
                --gigabytes 2000 \
                "$project"
            log_success "Quota updated for project: $project (vCPU=$(( total_vcpu * 16 )), RAM=${usable_ram_mb}MB, instances=$max_instances)"
        else
            log_warning "Project '$project' not found, skipping"
        fi
    done
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
    configure_openstack_quotas
    display_deployment_info
    final_cleanup

    log_success "=== Final Setup Phase Completed ==="
    log_success "CyberRange deployment is ready for use!"
}

# Run main function
main "$@"
