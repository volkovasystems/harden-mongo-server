#!/usr/bin/env bash
# MongoDB Server Hardening Tool - SSL/TLS Library
# Provides SSL/TLS certificate generation, management, and configuration functions

# Prevent multiple inclusion
if [[ -n "${_HARDEN_MONGO_SERVER_SSL_LOADED:-}" ]]; then
    return 0
fi
readonly _HARDEN_MONGO_SERVER_SSL_LOADED=1

# Load required modules
if [[ -z "${_HARDEN_MONGO_SERVER_CORE_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
fi

if [[ -z "${_HARDEN_MONGO_SERVER_LOGGING_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
fi

if [[ -z "${_HARDEN_MONGO_SERVER_SYSTEM_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/system.sh"
fi

# ================================
# SSL/TLS Configuration Constants
# ================================

# Default SSL paths and settings
readonly MONGODB_SSL_DIR="/etc/ssl/mongodb"
readonly MONGODB_CA_DIR="/etc/mongoCA"
readonly MONGODB_CLIENT_DIR="/etc/mongoCA/clients"
readonly DEFAULT_KEY_SIZE="2048"
readonly DEFAULT_VALIDITY_DAYS="365"
readonly DEFAULT_COUNTRY="US"
readonly DEFAULT_STATE="California"
readonly DEFAULT_CITY="San Francisco"
readonly DEFAULT_ORG="MongoDB"

# SSL certificate file extensions
readonly CA_KEY_EXT=".key"
readonly CA_CERT_EXT=".crt" 
readonly SERVER_KEY_EXT=".key"
readonly SERVER_CERT_EXT=".crt"
readonly PEM_EXT=".pem"
readonly CSR_EXT=".csr"

# OpenSSL configuration templates
readonly OPENSSL_CA_CONFIG_TEMPLATE='# OpenSSL CA Configuration
[ ca ]
default_ca = CA_default

[ CA_default ]
dir = %CA_DIR%
certs = $dir/certs
crl_dir = $dir/crl
database = $dir/index.txt
new_certs_dir = $dir/newcerts
certificate = $dir/ca%CA_CERT_EXT%
serial = $dir/serial
crlnumber = $dir/crlnumber
crl = $dir/crl%CA_CERT_EXT%
private_key = $dir/ca%CA_KEY_EXT%
RANDFILE = $dir/private/.rand
default_days = %VALIDITY_DAYS%
default_crl_days = 30
default_md = sha256
preserve = no
policy = policy_match

[ policy_match ]
countryName = match
stateOrProvinceName = match
organizationName = match
organizationalUnitName = optional
commonName = supplied
emailAddress = optional

[ req ]
default_bits = %KEY_SIZE%
default_keyfile = privkey%PEM_EXT%
distinguished_name = req_distinguished_name
attributes = req_attributes
x509_extensions = v3_ca

[ req_distinguished_name ]
countryName = Country Name (2 letter code)
countryName_default = %COUNTRY%
countryName_min = 2
countryName_max = 2
stateOrProvinceName = State or Province Name (full name)
stateOrProvinceName_default = %STATE%
localityName = Locality Name (eg, city)
localityName_default = %CITY%
0.organizationName = Organization Name (eg, company)
0.organizationName_default = %ORG%
organizationalUnitName = Organizational Unit Name (eg, section)
commonName = Common Name (e.g. server FQDN or YOUR name)
commonName_max = 64
emailAddress = Email Address
emailAddress_max = 64

[ req_attributes ]

[ usr_cert ]
basicConstraints = CA:FALSE
nsComment = "OpenSSL Generated Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:true
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

[ v3_server ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
extendedKeyUsage = serverAuth

[ alt_names ]
%ALT_NAMES%'

# ================================
# Certificate Authority (CA) Management
# ================================

# Initialize Certificate Authority
initialize_ca() {
    local ca_dir="${1:-$MONGODB_CA_DIR}"
    local country="${2:-$DEFAULT_COUNTRY}"
    local state="${3:-$DEFAULT_STATE}"
    local city="${4:-$DEFAULT_CITY}"
    local org="${5:-$DEFAULT_ORG}"
    local email="${6:-admin@localhost}"
    local key_size="${7:-$DEFAULT_KEY_SIZE}"
    local validity_days="${8:-$((DEFAULT_VALIDITY_DAYS * 10))}"  # CA valid for 10x longer
    
    info "Initializing Certificate Authority at $ca_dir"
    
    # Create CA directory structure
    create_dir_safe "$ca_dir" 755 root:root
    create_dir_safe "$ca_dir/private" 700 root:root
    create_dir_safe "$ca_dir/certs" 755 root:root
    create_dir_safe "$ca_dir/newcerts" 755 root:root
    create_dir_safe "$ca_dir/crl" 755 root:root
    
    # Initialize CA database files
    if ! is_dry_run; then
        touch "$ca_dir/index.txt"
        echo 1000 > "$ca_dir/serial"
        echo 1000 > "$ca_dir/crlnumber"
    fi
    
    # Generate CA configuration
    local ca_config_file="$ca_dir/openssl.cnf"
    local ca_config_content="$OPENSSL_CA_CONFIG_TEMPLATE"
    ca_config_content="${ca_config_content//%CA_DIR%/$ca_dir}"
    ca_config_content="${ca_config_content//%CA_KEY_EXT%/$CA_KEY_EXT}"
    ca_config_content="${ca_config_content//%CA_CERT_EXT%/$CA_CERT_EXT}"
    ca_config_content="${ca_config_content//%PEM_EXT%/$PEM_EXT}"
    ca_config_content="${ca_config_content//%KEY_SIZE%/$key_size}"
    ca_config_content="${ca_config_content//%VALIDITY_DAYS%/$validity_days}"
    ca_config_content="${ca_config_content//%COUNTRY%/$country}"
    ca_config_content="${ca_config_content//%STATE%/$state}"
    ca_config_content="${ca_config_content//%CITY%/$city}"
    ca_config_content="${ca_config_content//%ORG%/$org}"
    ca_config_content="${ca_config_content//%ALT_NAMES%/DNS.1 = localhost\nDNS.2 = *.local\nIP.1 = 127.0.0.1}"
    
    if ! is_dry_run; then
        echo "$ca_config_content" > "$ca_config_file"
        chmod 644 "$ca_config_file"
    fi
    
    # Generate CA private key
    local ca_key_file="$ca_dir/ca$CA_KEY_EXT"
    execute_or_simulate "Generate CA private key" \
        "openssl genrsa -out '$ca_key_file' '$key_size'"
    
    if ! is_dry_run; then
        chmod 600 "$ca_key_file"
        chown root:root "$ca_key_file"
    fi
    
    # Generate CA certificate
    local ca_cert_file="$ca_dir/ca$CA_CERT_EXT"
    local ca_subject="/C=$country/ST=$state/L=$city/O=$org/CN=MongoDB CA/emailAddress=$email"
    
    execute_or_simulate "Generate CA certificate" \
        "openssl req -new -x509 -key '$ca_key_file' -out '$ca_cert_file' -days '$validity_days' -config '$ca_config_file' -extensions v3_ca -subj '$ca_subject'"
    
    if ! is_dry_run; then
        chmod 644 "$ca_cert_file"
        chown root:root "$ca_cert_file"
    fi
    
    success "Certificate Authority initialized successfully"
    
    # Display CA certificate information
    if [[ -f "$ca_cert_file" ]]; then
        info "CA Certificate Details:"
        openssl x509 -in "$ca_cert_file" -noout -text | grep -E "(Subject:|Not Before|Not After |Signature Algorithm)"
    fi
}

# Verify CA exists and is valid
verify_ca() {
    local ca_dir="${1:-$MONGODB_CA_DIR}"
    local ca_key_file="$ca_dir/ca$CA_KEY_EXT"
    local ca_cert_file="$ca_dir/ca$CA_CERT_EXT"
    
    info "Verifying Certificate Authority"
    
    # Check CA directory exists
    if [[ ! -d "$ca_dir" ]]; then
        error "CA directory not found: $ca_dir"
        return 1
    fi
    
    # Check CA private key
    if [[ ! -f "$ca_key_file" ]]; then
        error "CA private key not found: $ca_key_file"
        return 1
    fi
    
    # Check CA certificate
    if [[ ! -f "$ca_cert_file" ]]; then
        error "CA certificate not found: $ca_cert_file"
        return 1
    fi
    
    # Verify CA certificate is valid
    if ! openssl x509 -in "$ca_cert_file" -noout -checkend 86400 2>/dev/null; then
        warn "CA certificate expires within 24 hours"
    fi
    
    # Verify CA private key matches certificate
    local ca_key_hash
    local ca_cert_hash
    ca_key_hash=$(openssl rsa -in "$ca_key_file" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 | cut -d' ' -f2)
    ca_cert_hash=$(openssl x509 -in "$ca_cert_file" -pubkey -noout -outform DER 2>/dev/null | openssl dgst -sha256 | cut -d' ' -f2)
    
    if [[ "$ca_key_hash" != "$ca_cert_hash" ]]; then
        error "CA private key does not match certificate"
        return 1
    fi
    
    success "Certificate Authority verification passed"
}

# ================================
# Server Certificate Generation
# ================================

# Generate server certificate for MongoDB
generate_server_certificate() {
    local hostname="${1:-$(hostname -f)}"
    local ca_dir="${2:-$MONGODB_CA_DIR}"
    local cert_dir="${3:-$MONGODB_SSL_DIR}"
    local key_size="${4:-$DEFAULT_KEY_SIZE}"
    local validity_days="${5:-$DEFAULT_VALIDITY_DAYS}"
    local alt_names="${6:-}"
    
    info "Generating server certificate for $hostname"
    
    # Verify CA exists
    if ! verify_ca "$ca_dir"; then
        error "CA verification failed, cannot generate server certificate"
        return 1
    fi
    
    # Create certificate directory
    create_dir_safe "$cert_dir" 755 root:root
    
    local server_key_file="$cert_dir/mongodb-server$SERVER_KEY_EXT"
    local server_csr_file="$cert_dir/mongodb-server$CSR_EXT"
    local server_cert_file="$cert_dir/mongodb-server$SERVER_CERT_EXT"
    local server_pem_file="$cert_dir/mongodb-server$PEM_EXT"
    
    # Generate server private key
    execute_or_simulate "Generate server private key" \
        "openssl genrsa -out '$server_key_file' '$key_size'"
    
    if ! is_dry_run; then
        chmod 600 "$server_key_file"
        chown mongodb:mongodb "$server_key_file"
    fi
    
    # Create server certificate signing request
    local server_subject="/C=$DEFAULT_COUNTRY/ST=$DEFAULT_STATE/L=$DEFAULT_CITY/O=$DEFAULT_ORG/CN=$hostname"
    
    execute_or_simulate "Generate certificate signing request" \
        "openssl req -new -key '$server_key_file' -out '$server_csr_file' -subj '$server_subject'"
    
    # Create server certificate configuration with SAN
    local server_config_file="$cert_dir/server.cnf"
    local server_config="[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C=$DEFAULT_COUNTRY
ST=$DEFAULT_STATE
L=$DEFAULT_CITY
O=$DEFAULT_ORG
CN=$hostname

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = $hostname
DNS.2 = localhost
DNS.3 = $(hostname -s)
IP.1 = 127.0.0.1"

    # Add custom SAN entries if provided
    if [[ -n "$alt_names" ]]; then
        local counter=4
        IFS=',' read -ra SANS <<< "$alt_names"
        for san in "${SANS[@]}"; do
            san=$(echo "$san" | xargs)  # trim whitespace
            if is_valid_ip "$san"; then
                server_config="$server_config
IP.$counter = $san"
            else
                server_config="$server_config
DNS.$counter = $san"
            fi
            ((counter++))
        done
    fi
    
    if ! is_dry_run; then
        echo "$server_config" > "$server_config_file"
        chmod 644 "$server_config_file"
    fi
    
    # Sign server certificate with CA
    local ca_key_file="$ca_dir/ca$CA_KEY_EXT"
    local ca_cert_file="$ca_dir/ca$CA_CERT_EXT"
    
    execute_or_simulate "Sign server certificate" \
        "openssl x509 -req -in '$server_csr_file' -CA '$ca_cert_file' -CAkey '$ca_key_file' -CAcreateserial -out '$server_cert_file' -days '$validity_days' -extensions v3_req -extfile '$server_config_file'"
    
    if ! is_dry_run; then
        chmod 644 "$server_cert_file"
        chown mongodb:mongodb "$server_cert_file"
    fi
    
    # Create PEM file combining certificate and key
    execute_or_simulate "Create server PEM file" \
        "cat '$server_cert_file' '$server_key_file' > '$server_pem_file'"
    
    if ! is_dry_run; then
        chmod 600 "$server_pem_file"
        chown mongodb:mongodb "$server_pem_file"
    fi
    
    # Clean up CSR and config files
    execute_or_simulate "Clean up temporary files" \
        "rm -f '$server_csr_file' '$server_config_file'"
    
    success "Server certificate generated successfully"
    
    # Display certificate information
    if [[ -f "$server_cert_file" ]]; then
        info "Server Certificate Details:"
        openssl x509 -in "$server_cert_file" -noout -text | grep -E "(Subject:|Subject Alternative Name|Not Before|Not After |Signature Algorithm)" | head -10
    fi
}

# ================================
# Client Certificate Generation
# ================================

# Generate client certificate for MongoDB authentication
generate_client_certificate() {
    local client_name="$1"
    local ca_dir="${2:-$MONGODB_CA_DIR}"
    local client_dir="${3:-$MONGODB_CLIENT_DIR}"
    local key_size="${4:-$DEFAULT_KEY_SIZE}"
    local validity_days="${5:-$DEFAULT_VALIDITY_DAYS}"
    
    info "Generating client certificate for $client_name"
    
    # Verify CA exists
    if ! verify_ca "$ca_dir"; then
        error "CA verification failed, cannot generate client certificate"
        return 1
    fi
    
    # Create client directory
    create_dir_safe "$client_dir" 755 root:root
    create_dir_safe "$client_dir/$client_name" 750 mongodb:mongodb
    
    local client_key_file="$client_dir/$client_name/$client_name$SERVER_KEY_EXT"
    local client_csr_file="$client_dir/$client_name/$client_name$CSR_EXT"
    local client_cert_file="$client_dir/$client_name/$client_name$SERVER_CERT_EXT"
    local client_pem_file="$client_dir/$client_name/$client_name$PEM_EXT"
    
    # Generate client private key
    execute_or_simulate "Generate client private key" \
        "openssl genrsa -out '$client_key_file' '$key_size'"
    
    if ! is_dry_run; then
        chmod 600 "$client_key_file"
        chown mongodb:mongodb "$client_key_file"
    fi
    
    # Create client certificate signing request
    local client_subject="/C=$DEFAULT_COUNTRY/ST=$DEFAULT_STATE/L=$DEFAULT_CITY/O=$DEFAULT_ORG/CN=$client_name"
    
    execute_or_simulate "Generate client CSR" \
        "openssl req -new -key '$client_key_file' -out '$client_csr_file' -subj '$client_subject'"
    
    # Sign client certificate with CA
    local ca_key_file="$ca_dir/ca$CA_KEY_EXT"
    local ca_cert_file="$ca_dir/ca$CA_CERT_EXT"
    
    execute_or_simulate "Sign client certificate" \
        "openssl x509 -req -in '$client_csr_file' -CA '$ca_cert_file' -CAkey '$ca_key_file' -CAcreateserial -out '$client_cert_file' -days '$validity_days'"
    
    if ! is_dry_run; then
        chmod 644 "$client_cert_file"
        chown mongodb:mongodb "$client_cert_file"
    fi
    
    # Create client PEM file
    execute_or_simulate "Create client PEM file" \
        "cat '$client_cert_file' '$client_key_file' > '$client_pem_file'"
    
    if ! is_dry_run; then
        chmod 600 "$client_pem_file"
        chown mongodb:mongodb "$client_pem_file"
    fi
    
    # Clean up CSR file
    execute_or_simulate "Clean up CSR file" \
        "rm -f '$client_csr_file'"
    
    success "Client certificate for '$client_name' generated successfully"
}

# ================================
# SSL Configuration for MongoDB
# ================================

# Configure MongoDB to use SSL/TLS
configure_mongodb_ssl() {
    local server_pem_file="${1:-$MONGODB_SSL_DIR/mongodb-server$PEM_EXT}"
    local ca_cert_file="${2:-$MONGODB_CA_DIR/ca$CA_CERT_EXT}"
    local ssl_mode="${3:-requireSSL}"
    local client_cert_auth="${4:-true}"
    
    info "Configuring MongoDB SSL/TLS"
    
    # Verify certificate files exist
    if [[ ! -f "$server_pem_file" ]]; then
        error "Server PEM file not found: $server_pem_file"
        return 1
    fi
    
    if [[ ! -f "$ca_cert_file" ]]; then
        error "CA certificate file not found: $ca_cert_file"
        return 1
    fi
    
    # Validate SSL mode
    case "$ssl_mode" in
        disabled|allowSSL|preferSSL|requireSSL)
            ;;
        *)
            error "Invalid SSL mode: $ssl_mode"
            return 1
            ;;
    esac
    
    # Update MongoDB configuration file
    local config_file="/etc/mongod.conf"
    if [[ ! -f "$config_file" ]]; then
        error "MongoDB configuration file not found: $config_file"
        return 1
    fi
    
    # Backup current configuration
    execute_or_simulate "Backup MongoDB configuration" \
        "cp '$config_file' '$config_file.ssl-backup.$(date +%Y%m%d_%H%M%S)'"
    
    # Update SSL configuration in net section
    if grep -q "^net:" "$config_file"; then
        # Update existing net section
        if grep -q "ssl:" "$config_file"; then
            # Update existing SSL configuration
            execute_or_simulate "Update SSL mode" \
                "sed -i '/ssl:/,/^[^[:space:]]/ s/mode:.*/mode: $ssl_mode/' '$config_file'"
            execute_or_simulate "Update PEM key file" \
                "sed -i '/ssl:/,/^[^[:space:]]/ s|PEMKeyFile:.*|PEMKeyFile: $server_pem_file|' '$config_file'"
            execute_or_simulate "Update CA file" \
                "sed -i '/ssl:/,/^[^[:space:]]/ s|CAFile:.*|CAFile: $ca_cert_file|' '$config_file'"
        else
            # Add SSL configuration to net section
            local ssl_config="  ssl:
    mode: $ssl_mode
    PEMKeyFile: $server_pem_file
    CAFile: $ca_cert_file"
            
            if [[ "$client_cert_auth" == "true" ]]; then
                ssl_config="$ssl_config
    allowConnectionsWithoutCertificates: false"
            fi
            
            execute_or_simulate "Add SSL configuration" \
                "sed -i '/^net:/a\\$ssl_config' '$config_file'"
        fi
    else
        error "MongoDB configuration file missing 'net:' section"
        return 1
    fi
    
    # Update security section for x509 authentication if using client certificates
    if [[ "$client_cert_auth" == "true" ]]; then
        if grep -q "^security:" "$config_file"; then
            if ! grep -q "clusterAuthMode:" "$config_file"; then
                execute_or_simulate "Add x509 cluster auth" \
                    "sed -i '/^security:/a\\  clusterAuthMode: x509' '$config_file'"
            else
                execute_or_simulate "Update cluster auth mode" \
                    "sed -i 's/clusterAuthMode:.*/clusterAuthMode: x509/' '$config_file'"
            fi
        fi
    fi
    
    success "MongoDB SSL/TLS configuration updated"
    
    # Validate configuration syntax
    if command_exists mongod; then
        if mongod --config "$config_file" --configtest 2>/dev/null; then
            success "MongoDB configuration syntax validation passed"
        else
            error "MongoDB configuration contains syntax errors"
            return 1
        fi
    fi
}

# ================================
# Certificate Management Operations
# ================================

# List all certificates
list_certificates() {
    local ca_dir="${1:-$MONGODB_CA_DIR}"
    local ssl_dir="${2:-$MONGODB_SSL_DIR}"
    local client_dir="${3:-$MONGODB_CLIENT_DIR}"
    
    print_section "Certificate Inventory"
    
    # CA Certificate
    local ca_cert_file="$ca_dir/ca$CA_CERT_EXT"
    if [[ -f "$ca_cert_file" ]]; then
        print_subsection "Certificate Authority"
        local ca_subject
        local ca_expires
        ca_subject=$(openssl x509 -in "$ca_cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')
        ca_expires=$(openssl x509 -in "$ca_cert_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        
        print_kv "Subject" "$ca_subject"
        print_kv "Expires" "$ca_expires"
        print_kv "File" "$ca_cert_file"
    else
        warn "CA certificate not found"
    fi
    
    # Server Certificate
    local server_cert_file="$ssl_dir/mongodb-server$SERVER_CERT_EXT"
    if [[ -f "$server_cert_file" ]]; then
        print_subsection "Server Certificate"
        local server_subject
        local server_expires
        local server_san
        server_subject=$(openssl x509 -in "$server_cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')
        server_expires=$(openssl x509 -in "$server_cert_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        server_san=$(openssl x509 -in "$server_cert_file" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/^[[:space:]]*//')
        
        print_kv "Subject" "$server_subject"
        print_kv "Expires" "$server_expires"
        print_kv "SAN" "${server_san:-None}"
        print_kv "File" "$server_cert_file"
    else
        warn "Server certificate not found"
    fi
    
    # Client Certificates
    if [[ -d "$client_dir" ]]; then
        local client_count=0
        for client_path in "$client_dir"/*; do
            if [[ -d "$client_path" ]]; then
                local client_name
                client_name=$(basename "$client_path")
                local client_cert_file="$client_path/$client_name$SERVER_CERT_EXT"
                
                if [[ -f "$client_cert_file" ]]; then
                    if ((client_count == 0)); then
                        print_subsection "Client Certificates"
                    fi
                    
                    local client_subject
                    local client_expires
                    client_subject=$(openssl x509 -in "$client_cert_file" -noout -subject 2>/dev/null | sed 's/subject=//')
                    client_expires=$(openssl x509 -in "$client_cert_file" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
                    
                    echo "  Client: $client_name"
                    print_kv "    Subject" "$client_subject" 22
                    print_kv "    Expires" "$client_expires" 22
                    print_kv "    File" "$client_cert_file" 22
                    echo
                    
                    ((client_count++))
                fi
            fi
        done
        
        if ((client_count == 0)); then
            info "No client certificates found"
        fi
    fi
}

# Check certificate expiration
check_certificate_expiration() {
    local warning_days="${1:-30}"
    local ca_dir="${2:-$MONGODB_CA_DIR}"
    local ssl_dir="${3:-$MONGODB_SSL_DIR}"
    local client_dir="${4:-$MONGODB_CLIENT_DIR}"
    
    print_section "Certificate Expiration Check"
    
    local issues_found=0
    local warning_seconds=$((warning_days * 86400))
    
    # Check CA certificate
    local ca_cert_file="$ca_dir/ca$CA_CERT_EXT"
    if [[ -f "$ca_cert_file" ]]; then
        if ! openssl x509 -in "$ca_cert_file" -noout -checkend "$warning_seconds" 2>/dev/null; then
            if ! openssl x509 -in "$ca_cert_file" -noout -checkend 0 2>/dev/null; then
                report_issue "critical" "CA certificate has expired" "Regenerate CA and all certificates"
            else
                report_issue "high" "CA certificate expires within $warning_days days" "Plan CA certificate renewal"
            fi
            ((issues_found++))
        else
            success "CA certificate expiration check passed"
        fi
    fi
    
    # Check server certificate
    local server_cert_file="$ssl_dir/mongodb-server$SERVER_CERT_EXT"
    if [[ -f "$server_cert_file" ]]; then
        if ! openssl x509 -in "$server_cert_file" -noout -checkend "$warning_seconds" 2>/dev/null; then
            if ! openssl x509 -in "$server_cert_file" -noout -checkend 0 2>/dev/null; then
                report_issue "critical" "Server certificate has expired" "Regenerate server certificate"
            else
                report_issue "high" "Server certificate expires within $warning_days days" "Renew server certificate"
            fi
            ((issues_found++))
        else
            success "Server certificate expiration check passed"
        fi
    fi
    
    # Check client certificates
    if [[ -d "$client_dir" ]]; then
        for client_path in "$client_dir"/*; do
            if [[ -d "$client_path" ]]; then
                local client_name
                client_name=$(basename "$client_path")
                local client_cert_file="$client_path/$client_name$SERVER_CERT_EXT"
                
                if [[ -f "$client_cert_file" ]]; then
                    if ! openssl x509 -in "$client_cert_file" -noout -checkend "$warning_seconds" 2>/dev/null; then
                        if ! openssl x509 -in "$client_cert_file" -noout -checkend 0 2>/dev/null; then
                            report_issue "high" "Client certificate '$client_name' has expired" "Regenerate client certificate"
                        else
                            report_issue "medium" "Client certificate '$client_name' expires within $warning_days days" "Renew client certificate"
                        fi
                        ((issues_found++))
                    fi
                fi
            fi
        done
    fi
    
    if ((issues_found == 0)); then
        success "All certificates are valid and not expiring soon"
    fi
    
    return $((issues_found > 0 ? 1 : 0))
}

# Revoke certificate
revoke_certificate() {
    local cert_file="$1"
    local ca_dir="${2:-$MONGODB_CA_DIR}"
    
    info "Revoking certificate: $cert_file"
    
    if [[ ! -f "$cert_file" ]]; then
        error "Certificate file not found: $cert_file"
        return 1
    fi
    
    local ca_config_file="$ca_dir/openssl.cnf"
    local ca_key_file="$ca_dir/ca$CA_KEY_EXT"
    
    if [[ ! -f "$ca_config_file" ]]; then
        error "CA configuration not found: $ca_config_file"
        return 1
    fi
    
    # Revoke the certificate
    execute_or_simulate "Revoke certificate" \
        "openssl ca -config '$ca_config_file' -revoke '$cert_file'"
    
    # Generate updated CRL
    local crl_file="$ca_dir/crl/ca.crl"
    execute_or_simulate "Generate Certificate Revocation List" \
        "openssl ca -config '$ca_config_file' -gencrl -out '$crl_file'"
    
    success "Certificate revoked successfully"
}

# ================================
# Module Information
# ================================

# Module information
ssl_module_info() {
    cat << EOF
MongoDB Server Hardening SSL/TLS Library v$HARDEN_MONGO_SERVER_VERSION

This module provides:
- Certificate Authority (CA) initialization and management
- Server certificate generation with Subject Alternative Names
- Client certificate generation for x.509 authentication
- MongoDB SSL/TLS configuration and integration
- Certificate inventory and expiration monitoring
- Certificate revocation and CRL management
- OpenSSL configuration template generation

Functions:
- initialize_ca: Create and configure Certificate Authority
- verify_ca: Validate CA certificate and key integrity
- generate_server_certificate: Create server certificates with SAN
- generate_client_certificate: Create client certificates for authentication
- configure_mongodb_ssl: Enable SSL/TLS in MongoDB configuration
- list_certificates: Display certificate inventory
- check_certificate_expiration: Monitor certificate validity
- revoke_certificate: Revoke certificates and update CRL

Certificate Types:
- CA Certificate: Root certificate authority for signing
- Server Certificate: MongoDB server SSL/TLS certificate
- Client Certificate: x.509 client authentication certificates

Default Paths:
- CA Directory: $MONGODB_CA_DIR
- SSL Directory: $MONGODB_SSL_DIR
- Client Directory: $MONGODB_CLIENT_DIR

Dependencies: core.sh, logging.sh, system.sh, openssl
EOF
}