#!/bin/bash
# =============================================================================
# MongoDB Hardening - SSL/TLS Certificate Library Module
# =============================================================================
# This module provides SSL/TLS certificate management functions including:
# - Let's Encrypt certificate setup
# - Local Certificate Authority management
# - Client certificate generation
# - Certificate renewal automation
# =============================================================================

# Prevent multiple sourcing
if [[ "${_SSL_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly _SSL_LIB_LOADED=true

# =============================================================================
# Main SSL Certificate Setup
# =============================================================================

# Main SSL certificate setup orchestration
setup_ssl_certificates() {
    print_section "SSL Certificate Setup"
    
    if [ -z "$MONGO_DOMAIN" ]; then
        log_and_print "ERROR" "MONGO_DOMAIN is required for SSL setup"
        return 1
    fi
    
    log_and_print "SECURITY" "Setting up maximum security SSL/TLS encryption for domain: $MONGO_DOMAIN"
    log_and_print "EXPLAIN" "This creates certificates to encrypt all data between MongoDB and applications"
    log_and_print "EXPLAIN" "All connections will be secured - no unencrypted data will ever be transmitted"
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would setup SSL certificates with Let's Encrypt"
        return 0
    fi
    
    # Install certbot if not present
    if ! command -v certbot &> /dev/null; then
        log_and_print "INFO" "Installing certbot (Let's Encrypt certificate tool)..."
        log_and_print "EXPLAIN" "Certbot obtains free, trusted SSL certificates that browsers and applications recognize"
        apt-get update -qq
        apt-get install -y certbot
        log_and_print "FIXED" "Installed certbot - ready to obtain SSL certificates"
    fi
    
    # Generate Let's Encrypt certificate
    local le_path="/etc/letsencrypt/live/$MONGO_DOMAIN"
    if [ ! -d "$le_path" ]; then
        log_and_print "INFO" "Obtaining Let's Encrypt certificate for $MONGO_DOMAIN"
        
        # Stop MongoDB temporarily if running to free port 80
        local mongo_was_running=false
        if systemctl is-active --quiet mongod; then
            mongo_was_running=true
            systemctl stop mongod
        fi
        
        # Get certificate
        if certbot certonly --standalone -d "$MONGO_DOMAIN" --non-interactive --agree-tos --email "admin@$MONGO_DOMAIN"; then
            log_and_print "FIXED" "Obtained Let's Encrypt certificate"
        else
            log_and_print "ERROR" "Failed to obtain Let's Encrypt certificate"
            # Restart MongoDB if it was running
            if [ "$mongo_was_running" = true ]; then
                systemctl start mongod
            fi
            return 1
        fi
        
        # Restart MongoDB if it was running
        if [ "$mongo_was_running" = true ]; then
            systemctl start mongod
        fi
    else
        log_and_print "OK" "Let's Encrypt certificate already exists"
    fi
    
    # Create local CA for client certificates
    setup_client_ca
    
    # Generate default client certificate
    generate_client_certificate "app1"
    
    # Setup certificate renewal
    setup_cert_renewal
}

# =============================================================================
# Local Certificate Authority Management
# =============================================================================

# Setup local CA for client certificates
setup_client_ca() {
    log_and_print "SECURITY" "Setting up local Certificate Authority for client certificates..."
    log_and_print "EXPLAIN" "This creates a private certificate authority to issue certificates for applications"
    log_and_print "EXPLAIN" "Applications will use these certificates to prove their identity to MongoDB"
    
    mkdir -p "$CA_DIR" "$CLIENT_DIR"
    cd "$CA_DIR"
    
    if [ ! -f ca.key ]; then
        # Generate CA private key
        openssl genrsa -out ca.key 4096
        
        # Generate CA certificate
        openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
            -subj "/C=US/ST=State/L=City/O=MyOrg/OU=Database/CN=MongoCA" \
            -out ca.pem
        
        # Set proper permissions
        chmod 600 ca.key
        chmod 644 ca.pem
        chown -R mongodb:mongodb "$CA_DIR"
        
        log_and_print "FIXED" "Created local CA for client certificates (10-year validity)"
        log_and_print "EXPLAIN" "Client applications will use certificates from this CA to authenticate securely"
    else
        log_and_print "OK" "Local CA already exists"
    fi
}

# =============================================================================
# Client Certificate Generation
# =============================================================================

# Generate client certificate for applications
generate_client_certificate() {
    local client_name="$1"
    
    if [ -z "$client_name" ]; then
        log_and_print "ERROR" "Client name required for certificate generation"
        return 1
    fi
    
    log_and_print "SECURITY" "Generating client certificate for: $client_name"
    log_and_print "EXPLAIN" "This certificate allows the application '$client_name' to connect securely to MongoDB"
    log_and_print "EXPLAIN" "The certificate expires in 90 days for enhanced security (automatically renewed)"
    
    cd "$CA_DIR"
    
    # Generate client private key
    openssl genrsa -out "$CLIENT_DIR/$client_name.key" 2048
    
    # Generate certificate signing request
    openssl req -new -key "$CLIENT_DIR/$client_name.key" \
        -subj "/C=US/ST=State/L=City/O=MyOrg/OU=Client/CN=$client_name" \
        -out "$CLIENT_DIR/$client_name.csr"
    
    # Generate client certificate (90-day expiry)
    openssl x509 -req -in "$CLIENT_DIR/$client_name.csr" \
        -CA ca.pem -CAkey ca.key -CAcreateserial \
        -out "$CLIENT_DIR/$client_name.pem" -days 90 -sha256
    
    # Set proper permissions
    chmod 600 "$CLIENT_DIR/$client_name.key"
    chmod 644 "$CLIENT_DIR/$client_name.pem"
    chown -R mongodb:mongodb "$CLIENT_DIR"
    
    log_and_print "FIXED" "Generated client certificate: $client_name (90-day expiry)"
}

# =============================================================================
# Certificate Renewal System
# =============================================================================

# Setup automated certificate renewal
setup_cert_renewal() {
    log_and_print "SECURITY" "Setting up automatic certificate renewal system..."
    log_and_print "EXPLAIN" "This creates a monthly renewal system to keep all certificates current"
    log_and_print "EXPLAIN" "Let's Encrypt certificates are renewed every 60 days, client certificates every 90 days"
    
    local renew_script="/usr/local/bin/mongo-cert-renew.sh"
    
    # Create renewal script
    cat > "$renew_script" << EOF
#!/bin/bash
# MongoDB Certificate Renewal Script
# This script renews both Let's Encrypt and client certificates

# Configuration
CA_DIR="$CA_DIR"
CLIENT_DIR="$CLIENT_DIR"

echo "\$(date): Starting MongoDB certificate renewal"

# Renew Let's Encrypt certificates
echo "[*] Renewing Let's Encrypt certificates..."
certbot renew --quiet

# Regenerate all client certificates
echo "[*] Regenerating client certificates..."
if [ -d "\$CLIENT_DIR" ]; then
    cd "\$CA_DIR"
    for csr in "\$CLIENT_DIR"/*.csr; do
        if [ -f "\$csr" ]; then
            client_name=\$(basename "\$csr" .csr)
            echo "  - Renewing client certificate: \$client_name"
            openssl x509 -req -in "\$CLIENT_DIR/\$client_name.csr" \\
                -CA ca.pem -CAkey ca.key -CAcreateserial \\
                -out "\$CLIENT_DIR/\$client_name.pem" -days 90 -sha256
        fi
    done
    chown -R mongodb:mongodb "\$CLIENT_DIR"
fi

# Restart MongoDB to reload certificates
echo "[*] Restarting MongoDB to reload certificates..."
systemctl restart mongod

echo "\$(date): Certificate renewal completed"
EOF
    chmod +x "$renew_script"
    
    # Create systemd service for renewal
    cat > /etc/systemd/system/mongo-cert-renew.service << EOF
[Unit]
Description=Renew MongoDB SSL certificates
After=network.target

[Service]
Type=oneshot
ExecStart=$renew_script
User=root
EOF
    
    # Create systemd timer for monthly renewal
    cat > /etc/systemd/system/mongo-cert-renew.timer << EOF
[Unit]
Description=Run MongoDB certificate renewal monthly

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # Enable and start timer
    systemctl daemon-reload
    systemctl enable mongo-cert-renew.timer
    systemctl start mongo-cert-renew.timer
    
    log_and_print "FIXED" "Certificate renewal system configured (monthly)"
}

# =============================================================================
# Manual Certificate Renewal
# =============================================================================

# Manually renew certificates
renew_certificates() {
    print_section "Certificate Renewal"
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would renew SSL and client certificates"
        return 0
    fi
    
    if [ -x "/usr/local/bin/mongo-cert-renew.sh" ]; then
        log_and_print "INFO" "Running certificate renewal..."
        /usr/local/bin/mongo-cert-renew.sh
        log_and_print "FIXED" "Certificate renewal completed"
    else
        log_and_print "ERROR" "Certificate renewal script not found. Run ssl-setup first."
        return 1
    fi
}

# =============================================================================
# Module Information
# =============================================================================

# Display SSL module information
ssl_module_info() {
    echo "SSL Library Module - Certificate management functions"
    echo "Provides: Let's Encrypt, local CA, client certificates, renewal"
}