#!/bin/bash

# Nginx Reverse Proxy Setup - Forward traffic to KYPO head services
# Strategy: bind nginx on both public IP and 10.1.2.161 (via IP alias)
# so Keycloak redirects (which use 10.1.2.161) are also caught by nginx.

source /tmp/scripts/utils.sh
setup_error_handling

log "Starting Nginx reverse proxy setup..."

HEAD_HOST="${HEAD_HOST:-10.1.2.161}"
PUBLIC_IP="${PUBLIC_IP:-42.115.38.85}"
VM_IFACE="${VM_IFACE:-eth1}"

install_nginx() {
    log "Installing Nginx..."
    apt-get update -qq
    apt-get install -y nginx
    log_success "Nginx installed"
}

add_ip_alias() {
    log "Adding IP alias $HEAD_HOST on $VM_IFACE..."

    if ip addr show "$VM_IFACE" | grep -q "$HEAD_HOST"; then
        log "IP alias $HEAD_HOST already exists, skipping"
    else
        ip addr add "$HEAD_HOST/24" dev "$VM_IFACE"
        log_success "IP alias $HEAD_HOST added"
    fi

    local netplan_file="/etc/netplan/99-kypo-alias.yaml"
    if [ ! -f "$netplan_file" ]; then
        cat > "$netplan_file" << EOF
network:
  version: 2
  ethernets:
    $VM_IFACE:
      addresses:
        - $HEAD_HOST/24
EOF
        log_success "Netplan alias config written"
    fi
}

generate_self_signed_cert() {
    log "Generating self-signed SSL certificate (SAN: $PUBLIC_IP + $HEAD_HOST)..."

    safe_mkdir /etc/nginx/ssl

    cat > /tmp/kypo-openssl.cnf << EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C=VN
ST=HCM
L=HoChiMinh
O=SP26
CN=$PUBLIC_IP

[v3_req]
subjectAltName = IP:$PUBLIC_IP,IP:$HEAD_HOST
EOF

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/kypo.key \
        -out    /etc/nginx/ssl/kypo.crt \
        -config /tmp/kypo-openssl.cnf

    chmod 600 /etc/nginx/ssl/kypo.key
    log_success "Certificate generated with SAN: $PUBLIC_IP, $HEAD_HOST"
}

configure_nginx() {
    log "Configuring Nginx..."

    rm -f /etc/nginx/sites-enabled/default

    cat > /etc/nginx/sites-available/kypo-proxy << EOF
server {
    listen $PUBLIC_IP:80;
    server_name $PUBLIC_IP;
    return 301 https://\$host\$request_uri;
}

server {
    listen $HEAD_HOST:80;
    server_name $HEAD_HOST;
    return 301 https://\$host\$request_uri;
}

server {
    listen $PUBLIC_IP:443 ssl;
    server_name $PUBLIC_IP;

    ssl_certificate     /etc/nginx/ssl/kypo.crt;
    ssl_certificate_key /etc/nginx/ssl/kypo.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass          https://$HEAD_HOST;
        proxy_ssl_verify    off;

        proxy_set_header    Host              $HEAD_HOST;
        proxy_set_header    X-Real-IP         \$remote_addr;
        proxy_set_header    X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;

        proxy_http_version  1.1;
        proxy_set_header    Upgrade           \$http_upgrade;
        proxy_set_header    Connection        "upgrade";

        proxy_read_timeout  300s;
        proxy_connect_timeout 10s;
    }
}

server {
    listen $HEAD_HOST:443 ssl;
    server_name $HEAD_HOST;

    ssl_certificate     /etc/nginx/ssl/kypo.crt;
    ssl_certificate_key /etc/nginx/ssl/kypo.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass          https://$HEAD_HOST;
        proxy_ssl_verify    off;

        proxy_set_header    Host              $HEAD_HOST;
        proxy_set_header    X-Real-IP         \$remote_addr;
        proxy_set_header    X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;

        proxy_http_version  1.1;
        proxy_set_header    Upgrade           \$http_upgrade;
        proxy_set_header    Connection        "upgrade";

        proxy_read_timeout  300s;
        proxy_connect_timeout 10s;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/kypo-proxy /etc/nginx/sites-enabled/kypo-proxy
    log_success "Nginx config written"
}

start_nginx() {
    log "Testing Nginx configuration..."
    nginx -t

    systemctl enable nginx
    systemctl restart nginx
    log_success "Nginx started"
}

rollback() {
    log "Rolling back nginx proxy setup..."

    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    apt-get remove -y nginx nginx-common 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true

    rm -f /etc/nginx/sites-available/kypo-proxy
    rm -rf /etc/nginx/ssl

    # Remove IP alias
    if ip addr show "$VM_IFACE" | grep -q "$HEAD_HOST"; then
        ip addr del "$HEAD_HOST/24" dev "$VM_IFACE"
        log_success "IP alias $HEAD_HOST removed"
    fi

    rm -f /etc/netplan/99-kypo-alias.yaml

    log_success "Rollback completed - back to Traefik direct access"
}

print_info() {
    echo ""
    echo "========================================"
    echo " NGINX REVERSE PROXY READY"
    echo "========================================"
    echo ""
    echo "  Access KYPO from internet:"
    echo "    https://$PUBLIC_IP/"
    echo ""
    echo "  To rollback: sudo bash /vagrant/scripts/05-nginx-proxy.sh rollback"
    echo "========================================"
    echo ""
}

main() {
    # Support rollback mode: bash 05-nginx-proxy.sh rollback
    if [ "${1:-}" = "rollback" ]; then
        rollback
        exit 0
    fi

    log "=== Starting Nginx Proxy Setup ==="

    install_nginx
    add_ip_alias
    generate_self_signed_cert
    configure_nginx
    start_nginx
    print_info

    log_success "=== Nginx Proxy Setup Completed ==="
}

main "$@"
