#!/bin/bash

# System Setup Script - Initial system configuration and package installation

# Source common utilities
source /tmp/scripts/utils.sh

# Setup error handling
setup_error_handling

log "Starting system setup..."

# Get environment variables with defaults
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-1.0.0.1}"
RAM="${RAM:-45056}"

log "Configuration: DNS1=$DNS1, DNS2=$DNS2, RAM=${RAM}MB"

# Disk expansion
expand_disk() {
    log "Expanding disk space..."

    if ! growpart /dev/vda 3; then
        log_warning "growpart failed or partition already at maximum size"
    fi

    if ! lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv; then
        log_warning "lvextend failed or LV already at maximum size"
    fi

    if ! resize2fs /dev/ubuntu-vg/ubuntu-lv; then
        log_error "Failed to resize filesystem"
        return 1
    fi

    log_success "Disk expansion completed"
}

# Configure DNS settings
configure_dns() {
    log "Configuring DNS settings..."

    # Update netplan configuration
    if [ -f /etc/netplan/01-netcfg.yaml ]; then
        sed -i "s/4.2.2.1/$DNS1/g" /etc/netplan/01-netcfg.yaml || true
        sed -i "s/4.2.2.2/$DNS2/g" /etc/netplan/01-netcfg.yaml || true
        log "Updated netplan configuration"
    fi

    # Update systemd-resolved configuration
    if [ -f /etc/systemd/resolved.conf ]; then
        sed -i "s/4.2.2.1/$DNS1/g" /etc/systemd/resolved.conf || true
        sed -i "s/4.2.2.2/$DNS2/g" /etc/systemd/resolved.conf || true
        log "Updated systemd-resolved configuration"
    fi

    # Restart services
    systemctl restart systemd-resolved
    netplan apply

    log_success "DNS configuration completed"
}

# Install snap packages
install_snap_packages() {
    log "Installing snap packages..."

    # Ensure snapd is properly installed
    retry snap install core snapd

    # Install required snap packages
    local packages=("opentofu --classic" "kubectl --classic" "helm --classic")

    for package in "${packages[@]}"; do
        log "Installing snap package: $package"
        retry snap install $package
    done

    log_success "Snap packages installation completed"
}

# Update system and install APT packages
install_apt_packages() {
    log "Updating package lists..."
    retry apt update

    log "Installing APT packages..."
    local packages=(
        "python3-dev"
        "libffi-dev"
        "gcc"
        "libssl-dev"
        "python3-venv"
        "python3-docker"
        "pipenv"
        "jq"
    )

    retry apt install -y "${packages[@]}"

    # Reinstall certificates to fix potential SSL issues
    retry apt install --reinstall ca-certificates

    log_success "APT packages installation completed"
}

# Configure SSH directory and permissions
setup_ssh() {
    log "Setting up SSH configuration..."

    safe_mkdir /root/.ssh

    # Create SSH config with secure settings
    cat > /root/.ssh/config << 'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF

    chmod 600 /root/.ssh/config
    chmod 700 /root/.ssh

    log_success "SSH configuration completed"
}

# Clean up hosts file
cleanup_hosts() {
    log "Cleaning up hosts file..."
    sed -i -e '/127.0.2.1/d' /etc/hosts
    log_success "Hosts file cleanup completed"
}

# Main execution
main() {
    log "=== Starting System Setup Phase ==="

    # Execute setup steps
    expand_disk
    configure_dns

    # Wait for network connectivity
    wait_for_network

    install_snap_packages
    install_apt_packages
    setup_ssh
    cleanup_hosts

    log_success "=== System Setup Phase Completed ==="
}

# Run main function
main "$@"
