#!/bin/bash

# OpenStack Deployment Script - Deploy OpenStack using Kolla-Ansible

# Source common utilities
source /tmp/scripts/utils.sh

# Setup error handling
setup_error_handling

log "Starting OpenStack deployment..."

# Python virtual environment path
VENV_PATH="/root/kolla-ansible-venv"
KOLLA_CONFIG_DIR="/etc/kolla"
ANSIBLE_CONFIG_DIR="/etc/ansible"

# Setup Python virtual environment
setup_python_environment() {
    log "Setting up Python virtual environment for Kolla-Ansible..."

    if [ -d "$VENV_PATH" ]; then
        log_warning "Virtual environment already exists, removing..."
        rm -rf "$VENV_PATH"
    fi

    python3 -m venv "$VENV_PATH" --system-site-packages
    source "$VENV_PATH/bin/activate"

    # Upgrade pip
    retry pip install --upgrade pip

    log_success "Python virtual environment created"
}

# Install Ansible and Kolla-Ansible
install_kolla_ansible() {
    log "Installing Ansible and Kolla-Ansible..."

    # Ensure we're in the virtual environment
    source "$VENV_PATH/bin/activate"

    # Install specific versions for compatibility
    retry pip3 install 'ansible-core>=2.17,<2.18.99'
    retry pip3 install git+https://opendev.org/openstack/kolla-ansible@stable/2025.1

    log_success "Kolla-Ansible installation completed"
}

# Configure Kolla-Ansible
configure_kolla_ansible() {
    log "Configuring Kolla-Ansible..."

    # Create necessary directories
    safe_mkdir "$KOLLA_CONFIG_DIR"
    safe_mkdir "$ANSIBLE_CONFIG_DIR"

    # Copy configuration files
    if [ -f /tmp/ansible.cfg ]; then
        safe_copy /tmp/ansible.cfg "$ANSIBLE_CONFIG_DIR/ansible.cfg"
    else
        log_warning "ansible.cfg not found, using defaults"
    fi

    # Copy Kolla configuration
    if [ -d "$VENV_PATH/share/kolla-ansible/etc_examples/kolla" ]; then
        cp -r "$VENV_PATH/share/kolla-ansible/etc_examples/kolla"/* "$KOLLA_CONFIG_DIR/"
        log "Copied Kolla configuration files"
    else
        log_error "Kolla configuration examples not found"
        return 1
    fi

    # Copy inventory files
    if [ -d "$VENV_PATH/share/kolla-ansible/ansible/inventory" ]; then
        cp "$VENV_PATH/share/kolla-ansible/ansible/inventory"/* /root/
        log "Copied inventory files"
    else
        log_error "Inventory files not found"
        return 1
    fi

    log_success "Kolla-Ansible configuration completed"
}

# Configure globals.yml
configure_globals() {
    log "Configuring Kolla globals..."

    local globals_file="$KOLLA_CONFIG_DIR/globals.yml"

    if [ ! -f "$globals_file" ]; then
        log_error "globals.yml not found at $globals_file"
        return 1
    fi

    declare -a settings=(
        "network_interface: \"eth1\""
        "kolla_base_distro: \"ubuntu\""
        "kolla_install_type: \"source\""
        "enable_heat: \"no\""
        "kolla_internal_vip_address: \"10.1.2.9\""
        "neutron_external_interface: \"eth2\""
    )

    # Loop through each setting
    for setting in "${settings[@]}"; do
        # Separate the key and the value
        key=$(echo "$setting" | cut -d: -f1)
        value=$(echo "$setting" | cut -d: -f2-)

        # Check if the key exists in the file (commented or uncommented)
        if grep -qE "^\s*#?\s*${key}:" "$globals_file"; then
            # If it exists, use sed to uncomment it and set the correct value
            echo "Updating setting: ${key}"
            sed -i -E "s|^\s*#?\s*${key}:.*|${key}:${value}|" "$globals_file"
        else
            # If it does not exist, add it to the end of the file
            echo "Adding setting: ${key}"
            echo "${key}:${value}" >> "$globals_file"
        fi
    done

    log_success "Globals configuration completed"
}

# Deploy OpenStack
deploy_openstack() {
    log "Starting OpenStack deployment with Kolla-Ansible..."

    # Ensure we're in the virtual environment
    source "$VENV_PATH/bin/activate"

    # Install dependencies
    log "Installing Kolla dependencies..."
    retry kolla-ansible install-deps

    # Generate passwords
    log "Generating Kolla passwords..."
    kolla-genpwd

    # Bootstrap servers
    log "Bootstrapping servers..."
    retry kolla-ansible bootstrap-servers -i /root/all-in-one

    # Run prechecks
    log "Running deployment prechecks..."
    if ! kolla-ansible prechecks -i /root/all-in-one; then
        log_error "Prechecks failed, continuing anyway..."
    fi

    # Deploy OpenStack
    log "Deploying OpenStack (this may take 30-60 minutes)..."
    if ! kolla-ansible deploy -i /root/all-in-one; then
        log_warning "First deployment attempt failed, retrying..."
        retry kolla-ansible deploy -i /root/all-in-one
    fi

    # Post-deployment configuration
    log "Running post-deployment configuration..."
    kolla-ansible post-deploy -i /root/all-in-one

    log_success "OpenStack deployment completed"
}

# Setup OpenStack client
setup_openstack_client() {
    log "Setting up OpenStack client..."

    # Ensure we're in the virtual environment
    source "$VENV_PATH/bin/activate"

    # Add admin-openrc to bashrc for convenience
    echo "source /etc/kolla/admin-openrc.sh" >> /root/.bashrc

    # Install OpenStack client
    retry pip3 install python-openstackclient -c https://releases.openstack.org/constraints/upper/2025.1

    log_success "OpenStack client setup completed"
}

# Initialize OpenStack
initialize_openstack() {
    log "Initializing OpenStack..."

    # Ensure we're in the virtual environment
    source "$VENV_PATH/bin/activate"

    source /etc/kolla/admin-openrc.sh

    # Update init-runonce script for correct network
    local init_script="$VENV_PATH/share/kolla-ansible/init-runonce"
    if [ -f "$init_script" ]; then
        sed -i 's/10.0/10.1/g' "$init_script"

        # Run initialization
        log "Running OpenStack initialization script..."
        bash "$init_script"
    else
        log_error "init-runonce script not found"
        return 1
    fi

    log_success "OpenStack initialization completed"
}

# Configure additional networking
configure_networking() {
    log "Configuring additional networking..."

    # Add eth2 interface configuration
    if ! grep -q "eth2:" /etc/netplan/50-vagrant.yaml; then
        echo "    eth2: {}" >> /etc/netplan/50-vagrant.yaml
        netplan apply
    fi

    # Bring up eth2 interface
    ip link set eth2 up

    log_success "Network configuration completed"
}

# Verify OpenStack deployment
verify_deployment() {
    log "Verifying OpenStack deployment..."

    # Ensure we're in the virtual environment
    source "$VENV_PATH/bin/activate"

    source /etc/kolla/admin-openrc.sh

    # Check if OpenStack services are responding
    if ! wait_for_service "OpenStack API" "openstack endpoint list"; then
        log_error "OpenStack API is not responding"
        return 1
    fi

    # List services to verify deployment
    log "OpenStack services status:"
    openstack service list || true

    log_success "OpenStack deployment verification completed"
}

# Main execution
main() {
    log "=== Starting OpenStack Deployment Phase ==="

    # Execute deployment steps
    setup_python_environment
    install_kolla_ansible
    configure_kolla_ansible
    configure_globals
    deploy_openstack

    # Deactivate virtual environment before client setup
    deactivate 2>/dev/null || true

    setup_openstack_client
    initialize_openstack
    configure_networking
    verify_deployment

    log_success "=== OpenStack Deployment Phase Completed ==="
    log "OpenStack is now available. You can access Horizon at http://10.1.2.10/"
}

# Run main function
main "$@"
