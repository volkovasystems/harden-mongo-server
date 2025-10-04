#!/bin/bash
set -e

# ================================
# MongoDB Server Hardening Script
# ================================
# Comprehensive MongoDB security hardening and maintenance script
# 
# This script consolidates all MongoDB hardening functionality:
# - Installation and configuration
# - Security hardening (authentication, firewall, storage engine)
# - Monitoring and backup setup
# - Health checking and status reporting
# - Maintenance operations
# - mmapv1 to WiredTiger migration
# ================================

# Script metadata
SCRIPT_VERSION="2.0"
SCRIPT_NAME="MongoDB Server Hardening Script"
RUN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
LOG_FILE="/var/log/mongodb-hardening-$(date +%F).log"

# Configuration with defaults
ADMIN_USER="${MONGO_ADMIN_USER:-admin}"
ADMIN_PASS="${MONGO_ADMIN_PASS:-}"
APP_SERVER_IP="${MONGO_APP_IP:-127.0.0.1}"
BACKUP_RETENTION_DAYS="${MONGO_BACKUP_RETENTION:-30}"
MONGO_DOMAIN="${MONGO_DOMAIN:-}"
# SSL is MANDATORY for maximum security - no option to disable
USE_SSL="true"

# Paths
DB_PATH="/var/lib/mongodb"
LOG_PATH="/var/log/mongodb/mongod.log"
BACKUP_PATH="/var/backups/mongodb"
CA_DIR="/etc/mongoCA"
CLIENT_DIR="/etc/mongoCA/clients"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Counters for summary
ISSUES_FOUND=0
ISSUES_FIXED=0
WARNINGS=0

# ================================
# Help and usage information
# ================================
show_help() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION

A comprehensive MongoDB hardening and maintenance script that:
- Installs and configures MongoDB with maximum security
- Sets up MANDATORY SSL/TLS encryption for all connections
- Creates strong authentication and firewall rules
- Migrates from old to modern secure storage engine
- Configures automated monitoring and backups
- Performs health checks and maintenance

🔒 SECURITY NOTICE: This script implements the highest security standards.
    SSL/TLS encryption is MANDATORY and cannot be disabled.

USAGE:
    sudo $0 [COMMAND] [OPTIONS]

COMMANDS:
    harden          Full hardening setup (default if no command specified)
    status          Check MongoDB status and security
    maintenance     Perform maintenance operations
    backup          Create immediate backup
    restore <file>  Restore from backup file
    config          Interactive configuration setup
    ssl-setup       Setup SSL/TLS with Let's Encrypt certificates
    ssl-renew       Renew SSL certificates and client certificates
    help            Show this help message

MAINTENANCE SUB-COMMANDS:
    sudo $0 maintenance cleanup-logs     # Clean old log files
    sudo $0 maintenance cleanup-backups  # Clean old backup files
    sudo $0 maintenance restart         # Restart MongoDB service
    sudo $0 maintenance security-check  # Run security validation
    sudo $0 maintenance disk-cleanup    # Emergency disk cleanup

OPTIONS:
    --dry-run       Show what would be done without executing
    --force         Force operations without confirmation prompts
    --verbose       Enable verbose output
    --config-only   Only setup configuration, don't run hardening

ENVIRONMENT VARIABLES:
    MONGO_ADMIN_USER        MongoDB admin username (default: admin)
    MONGO_ADMIN_PASS        MongoDB admin password (prompted if not set)
    MONGO_APP_IP           Application server IP for firewall (default: 127.0.0.1)
    MONGO_BACKUP_RETENTION  Backup retention days (default: 30)
    MONGO_DOMAIN           Domain name for SSL certificates (REQUIRED - will be prompted)

EXAMPLES:
    # Full hardening (interactive - will prompt for domain)
    sudo $0

    # Full hardening with SSL domain specified
    sudo MONGO_DOMAIN="db.mycompany.com" MONGO_ADMIN_PASS="securepass" $0

    # Check security status
    sudo $0 status

    # Perform maintenance
    sudo $0 maintenance

    # Create secure backup
    sudo $0 backup

    # Preview what will be done (no changes made)
    sudo $0 --dry-run

REQUIREMENTS:
    - Ubuntu/Debian Linux system
    - Root privileges (sudo access)
    - Internet connection (for MongoDB and SSL certificates)
    - A domain name that points to this server (for SSL certificates)
    - Port 80 temporarily free (for SSL certificate verification)

EOF
}

# ================================
# Logging and output functions
# ================================
log_and_print() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Print to console with colors and user-friendly formatting
    case "$level" in
        "INFO") echo -e "${BLUE}ℹ${NC}  $message" ;;
        "OK") echo -e "${GREEN}✓${NC}  $message" ;;
        "WARN") echo -e "${YELLOW}⚠${NC}  WARNING: $message"; ((WARNINGS++)) ;;
        "ERROR") echo -e "${RED}✗${NC}  ERROR: $message"; ((ISSUES_FOUND++)) ;;
        "FIXED") echo -e "${CYAN}🔧${NC}  COMPLETED: $message"; ((ISSUES_FIXED++)) ;;
        "QUERY") echo -e "${MAGENTA}?${NC}  INPUT NEEDED: $message" ;;
        "SECURITY") echo -e "${GREEN}🔒${NC}  SECURITY: $message" ;;
        "EXPLAIN") echo -e "${CYAN}📋${NC}  EXPLANATION: $message" ;;
    esac
}

print_section() {
    echo
    echo -e "${BLUE}$1${NC}"
    echo "$(printf '=%.0s' $(seq 1 ${#1}))"
}

# ================================
# Privilege and dependency checks
# ================================
check_privileges() {
    if [ "$EUID" -ne 0 ]; then
        log_and_print "ERROR" "This script must be run as root for security operations"
        echo
        echo "Usage: sudo $0 [command]"
        echo "Run '$0 help' for more information"
        exit 1
    fi
}

check_dependencies() {
    local missing_deps=()
    
    # Check for required commands
    for cmd in curl wget openssl tar gzip; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_and_print "WARN" "Installing missing dependencies: ${missing_deps[*]}"
        apt-get update -qq
        apt-get install -y "${missing_deps[@]}"
        log_and_print "FIXED" "Installed missing dependencies"
    fi
}

# ================================
# Configuration management
# ================================
prompt_for_config() {
    if [ -z "$ADMIN_PASS" ]; then
        log_and_print "QUERY" "MongoDB admin password not set. Please provide configuration:"
        read -p "MongoDB admin username [$ADMIN_USER]: " input_user
        ADMIN_USER="${input_user:-$ADMIN_USER}"
        
        echo -n "MongoDB admin password: "
        read -s ADMIN_PASS
        echo
        
        if [ -z "$ADMIN_PASS" ]; then
            ADMIN_PASS=$(openssl rand -base64 32)
            log_and_print "INFO" "Generated secure random password"
        fi
    fi
    
    if [ "$APP_SERVER_IP" = "127.0.0.1" ]; then
        read -p "Allowed application server IP [$APP_SERVER_IP]: " input_ip
        if [[ $input_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            APP_SERVER_IP="$input_ip"
        elif [ -n "$input_ip" ]; then
            log_and_print "WARN" "Invalid IP format, using default: $APP_SERVER_IP"
        fi
    fi
    
    # Confirm retention policy
    read -p "Backup retention days [$BACKUP_RETENTION_DAYS]: " input_retention
    BACKUP_RETENTION_DAYS="${input_retention:-$BACKUP_RETENTION_DAYS}"
    
    # SSL domain is MANDATORY for maximum security
    if [ -z "$MONGO_DOMAIN" ]; then
        echo
        log_and_print "SECURITY" "SSL/TLS encryption is MANDATORY for maximum security"
        log_and_print "EXPLAIN" "You need a domain name that points to this server for SSL certificates"
        echo "Examples: db.mycompany.com, mongo.example.org, database.mydomain.net"
        echo
        while [ -z "$MONGO_DOMAIN" ]; do
            read -p "Enter your domain name for SSL certificate (REQUIRED): " MONGO_DOMAIN
            if [ -z "$MONGO_DOMAIN" ]; then
                log_and_print "ERROR" "Domain name is required for SSL setup. Cannot proceed without it."
                echo "This script enforces the highest security standards and requires SSL/TLS."
                echo "Please configure DNS to point your domain to this server's IP address."
                echo
            fi
        done
        log_and_print "OK" "Domain configured: $MONGO_DOMAIN"
        log_and_print "EXPLAIN" "The script will automatically obtain free SSL certificates from Let's Encrypt"
    else
        log_and_print "OK" "Using configured domain: $MONGO_DOMAIN"
    fi
}

save_config_to_env() {
    local env_file="/etc/environment.d/mongodb-hardening.conf"
    mkdir -p "$(dirname "$env_file")"
    
    cat > "$env_file" << EOF
# MongoDB Hardening Configuration
MONGO_ADMIN_USER="$ADMIN_USER"
MONGO_APP_IP="$APP_SERVER_IP"
MONGO_BACKUP_RETENTION="$BACKUP_RETENTION_DAYS"
EOF
    
    log_and_print "INFO" "Configuration saved to $env_file"
}

# ================================
# SSL Certificate Management
# ================================
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

setup_cert_renewal() {
    log_and_print "SECURITY" "Setting up automatic certificate renewal system..."
    log_and_print "EXPLAIN" "This ensures SSL certificates are automatically renewed before they expire"
    log_and_print "EXPLAIN" "Your MongoDB will stay secure without manual intervention"
    
    # Create renewal script
    local renew_script="/usr/local/bin/mongo-cert-renew.sh"
    cat > "$renew_script" << EOF
#!/bin/bash
set -e

MONGO_DOMAIN="$MONGO_DOMAIN"
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
            openssl x509 -req -in "\$CLIENT_DIR/\$client_name.csr" \
                -CA ca.pem -CAkey ca.key -CAcreateserial \
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

# ================================
# MongoDB installation and setup
# ================================
ensure_mongodb_installed() {
    log_and_print "INFO" "Checking MongoDB installation..."
    
    if ! command -v mongod &> /dev/null; then
        log_and_print "WARN" "MongoDB not installed. Installing MongoDB 3.4.24..."
        
        # Install dependencies
        apt-get update -qq
        apt-get install -y -qq gnupg curl lsb-release
        
        # Add MongoDB repository
        curl -fsSL https://www.mongodb.org/static/pgp/server-3.4.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/mongodb-archive-keyring.gpg] http://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/3.4 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-3.4.list
        
        # Install MongoDB
        apt-get update -qq
        apt-get install -y mongodb-org=3.4.24 mongodb-org-server=3.4.24 mongodb-org-shell=3.4.24 mongodb-org-mongos=3.4.24 mongodb-org-tools=3.4.24
        
        # Hold packages to prevent automatic updates
        apt-mark hold mongodb-org mongodb-org-server mongodb-org-shell mongodb-org-mongos mongodb-org-tools
        
        log_and_print "FIXED" "MongoDB 3.4.24 installed successfully"
    else
        MONGO_VERSION=$(mongod --version | head -n1 | awk '{print $3}')
        log_and_print "OK" "MongoDB installed: version $MONGO_VERSION"
    fi
}

ensure_directories_and_permissions() {
    log_and_print "INFO" "Setting up directories and permissions..."
    
    # Create required directories
    mkdir -p "$DB_PATH" "$(dirname "$LOG_PATH")" "$BACKUP_PATH"
    mkdir -p /var/run/mongodb
    
    # Ensure mongodb user exists
    if ! id -u mongodb &>/dev/null; then
        useradd --system --home /var/lib/mongodb --shell /bin/false mongodb
        log_and_print "FIXED" "Created mongodb system user"
    fi
    
    # Set correct ownership and permissions
    chown -R mongodb:mongodb "$DB_PATH" "$(dirname "$LOG_PATH")" "$BACKUP_PATH" /var/run/mongodb
    chmod 755 "$DB_PATH" "$(dirname "$LOG_PATH")"
    chmod 750 "$BACKUP_PATH"
    chmod 755 /var/run/mongodb
    
    log_and_print "OK" "Directory permissions configured correctly"
}

# ================================
# Service configuration
# ================================
ensure_systemd_service() {
    log_and_print "INFO" "Configuring systemd service..."
    
    local service_file="/etc/systemd/system/mongod.service"
    local service_content='[Unit]
Description=MongoDB Database Server
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/bin/mongod --config /etc/mongod.conf
PIDFile=/var/run/mongodb/mongod.pid
LimitNOFILE=64000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target'

    local service_updated=false
    
    if [ ! -f "$service_file" ]; then
        echo "$service_content" > "$service_file"
        service_updated=true
        log_and_print "FIXED" "Created systemd service file"
    else
        # Check if service file needs updating
        if ! grep -q "LimitNOFILE=64000" "$service_file" || ! grep -q "Restart=always" "$service_file"; then
            echo "$service_content" > "$service_file"
            service_updated=true
            log_and_print "FIXED" "Updated systemd service file"
        else
            log_and_print "OK" "Systemd service properly configured"
        fi
    fi
    
    if [ "$service_updated" = true ]; then
        systemctl daemon-reload
    fi
    
    # Enable service
    if ! systemctl is-enabled mongod &>/dev/null; then
        systemctl enable mongod
        log_and_print "FIXED" "Enabled MongoDB service"
    fi
}

# ================================
# Storage engine management
# ================================
check_and_migrate_storage_engine() {
    log_and_print "INFO" "Checking storage engine..."
    
    local current_engine="unknown"
    if systemctl is-active --quiet mongod; then
        current_engine=$(timeout 10 mongo --quiet --eval "db.serverStatus().storageEngine.name" 2>/dev/null || echo "unknown")
    fi
    
    if [[ "$current_engine" == "mmapv1" ]]; then
        log_and_print "WARN" "Detected mmapv1 storage engine. Starting migration to WiredTiger..."
        
        if [ "${DRY_RUN:-false}" = true ]; then
            log_and_print "INFO" "DRY RUN: Would migrate from mmapv1 to WiredTiger"
            return 0
        fi
        
        # Create migration backup
        local migration_backup="$BACKUP_PATH/migration-$(date +%F-%H%M%S)"
        mkdir -p "$migration_backup"
        log_and_print "INFO" "Creating migration backup at $migration_backup"
        
        if ! mongodump --out "$migration_backup" --quiet; then
            log_and_print "ERROR" "Failed to create migration backup"
            return 1
        fi
        
        # Stop MongoDB
        systemctl stop mongod
        
        # Backup existing data directory
        if [ -d "$DB_PATH" ] && [ "$(ls -A "$DB_PATH")" ]; then
            mv "$DB_PATH" "${DB_PATH}-mmapv1-backup-$(date +%F-%H%M%S)"
            log_and_print "INFO" "Backed up existing mmapv1 data directory"
        fi
        
        # Create fresh data directory
        mkdir -p "$DB_PATH"
        chown -R mongodb:mongodb "$DB_PATH"
        
        # Start MongoDB with WiredTiger (config will be updated later)
        systemctl start mongod
        
        # Wait for MongoDB to be ready
        local ready=false
        for i in {1..30}; do
            if mongo --eval "db.runCommand('ping')" &>/dev/null; then
                ready=true
                break
            fi
            sleep 2
        done
        
        if [ "$ready" = false ]; then
            log_and_print "ERROR" "MongoDB failed to start after migration"
            return 1
        fi
        
        # Restore data
        if mongorestore "$migration_backup" --quiet; then
            log_and_print "FIXED" "Successfully migrated from mmapv1 to WiredTiger"
        else
            log_and_print "ERROR" "Failed to restore data after migration"
            return 1
        fi
        
    elif [[ "$current_engine" == "wiredTiger" ]]; then
        log_and_print "OK" "Using WiredTiger storage engine"
    elif [[ "$current_engine" == "unknown" ]] && [ ! -f /etc/mongod.conf ]; then
        log_and_print "INFO" "New installation - will configure WiredTiger"
    else
        log_and_print "WARN" "Could not determine storage engine: $current_engine"
    fi
}

# ================================
# MongoDB configuration
# ================================
ensure_mongodb_config() {
    log_and_print "INFO" "Configuring MongoDB settings..."
    
    local config_file="/etc/mongod.conf"
    local config_changed=false
    
    # Build configuration content
    local config_content="storage:
  dbPath: $DB_PATH
  journal:
    enabled: true
  engine: wiredTiger

systemLog:
  destination: file
  path: $LOG_PATH
  logAppend: true

net:
  port: 27017
  bindIp: 127.0.0.1,$APP_SERVER_IP"

    # Add SSL configuration if enabled
    if [ "$USE_SSL" = "true" ] && [ -n "$MONGO_DOMAIN" ]; then
        local le_cert_path="/etc/letsencrypt/live/$MONGO_DOMAIN"
        local ca_cert_path="$CA_DIR/ca.pem"
        
        if [ -f "$le_cert_path/fullchain.pem" ] && [ -f "$le_cert_path/privkey.pem" ] && [ -f "$ca_cert_path" ]; then
            log_and_print "INFO" "Adding SSL configuration for domain: $MONGO_DOMAIN"
            config_content="$config_content
  ssl:
    mode: requireSSL
    PEMKeyFile: $le_cert_path/privkey.pem
    PEMKeyFilePassword: ''
    certificateSelector: subject="CN=$MONGO_DOMAIN"
    CAFile: $ca_cert_path
    allowConnectionsWithoutCertificates: false
    allowInvalidCertificates: false
    allowInvalidHostnames: false"
        else
            log_and_print "WARN" "SSL enabled but certificates not found, skipping SSL configuration"
        fi
    fi
    
    config_content="$config_content

security:
  authorization: enabled"
    
    # Add SSL x.509 authentication if SSL is enabled
    if [ "$USE_SSL" = "true" ] && [ -n "$MONGO_DOMAIN" ]; then
        config_content="$config_content
  clusterAuthMode: x509"
    fi
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would update MongoDB configuration"
        if [ "$USE_SSL" = "true" ]; then
            log_and_print "INFO" "DRY RUN: SSL mode would be enabled for $MONGO_DOMAIN"
        fi
        return 1
    fi
    
    # Check if config file exists and has correct content
    if [ ! -f "$config_file" ]; then
        echo "$config_content" > "$config_file"
        config_changed=true
        log_and_print "FIXED" "Created MongoDB configuration file"
    else
        # Check key security settings
        if ! grep -q "authorization: enabled" "$config_file"; then
            echo "$config_content" > "$config_file"
            config_changed=true
            log_and_print "FIXED" "Enabled authentication in MongoDB config"
        elif ! grep -q "engine: wiredTiger" "$config_file"; then
            echo "$config_content" > "$config_file"
            config_changed=true
            log_and_print "FIXED" "Updated storage engine to WiredTiger"
        elif ! grep -q "bindIp.*$APP_SERVER_IP" "$config_file"; then
            echo "$config_content" > "$config_file"
            config_changed=true
            log_and_print "FIXED" "Updated network binding configuration"
        else
            log_and_print "OK" "MongoDB configuration is secure"
        fi
    fi
    
    return $([ "$config_changed" = true ] && echo 0 || echo 1)
}

# ================================
# Firewall configuration
# ================================
ensure_firewall_rules() {
    log_and_print "INFO" "Configuring firewall rules..."
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would configure firewall rules for MongoDB"
        return 0
    fi
    
    # Remove existing MongoDB rules
    iptables -D INPUT -p tcp --dport 27017 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 27017 -j DROP 2>/dev/null || true
    
    # Add new rules (allow specific IP, drop others)
    iptables -I INPUT -p tcp -s "$APP_SERVER_IP" --dport 27017 -j ACCEPT
    iptables -I INPUT -p tcp --dport 27017 -j DROP
    
    # Save iptables rules
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save &>/dev/null
    elif command -v iptables-save &> /dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    log_and_print "FIXED" "Configured firewall rules (allow $APP_SERVER_IP, block others)"
}

# ================================
# Service management
# ================================
ensure_mongodb_running() {
    log_and_print "INFO" "Managing MongoDB service..."
    
    local restart_needed=false
    local config_changed=$1
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would ensure MongoDB service is running"
        return 0
    fi
    
    if ! systemctl is-active --quiet mongod; then
        systemctl start mongod
        restart_needed=true
        log_and_print "FIXED" "Started MongoDB service"
    elif [ "$config_changed" = true ]; then
        systemctl restart mongod
        restart_needed=true
        log_and_print "FIXED" "Restarted MongoDB service to apply configuration changes"
    else
        log_and_print "OK" "MongoDB service is running"
    fi
    
    if [ "$restart_needed" = true ]; then
        # Wait for MongoDB to be ready
        log_and_print "INFO" "Waiting for MongoDB to be ready..."
        local ready=false
        for i in {1..30}; do
            if mongo --eval "db.runCommand('ping')" &>/dev/null; then
                log_and_print "OK" "MongoDB is ready"
                ready=true
                break
            fi
            sleep 2
        done
        
        if [ "$ready" = false ]; then
            log_and_print "ERROR" "MongoDB failed to start within 60 seconds"
            return 1
        fi
    fi
}

# ================================
# Authentication setup
# ================================
ensure_authentication() {
    log_and_print "INFO" "Configuring MongoDB authentication..."
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would configure MongoDB authentication"
        return 0
    fi
    
    # First check if we can connect without auth (new installation)
    if mongo --eval "db.runCommand('ping')" &>/dev/null 2>&1; then
        # No auth required yet, create admin user
        log_and_print "INFO" "Creating admin user '$ADMIN_USER'..."
        
        local create_user_result=$(mongo admin --eval "
        try {
            db.createUser({
                user: '$ADMIN_USER',
                pwd: '$ADMIN_PASS',
                roles: [{ role: 'root', db: 'admin' }]
            });
            print('SUCCESS: Admin user created');
        } catch(e) {
            if (e.code === 11000) {
                print('INFO: Admin user already exists');
            } else {
                print('ERROR: ' + e.message);
                throw e;
            }
        }" 2>&1)
        
        if echo "$create_user_result" | grep -q "SUCCESS\|INFO"; then
            log_and_print "FIXED" "MongoDB authentication configured"
        else
            log_and_print "WARN" "User creation had issues: $create_user_result"
        fi
    else
        # Auth already required, test with credentials
        if mongo -u "$ADMIN_USER" -p "$ADMIN_PASS" --authenticationDatabase admin --eval "db.runCommand('ping')" &>/dev/null; then
            log_and_print "OK" "Authentication is working correctly"
        else
            log_and_print "ERROR" "Authentication test failed - credentials may be incorrect"
            return 1
        fi
    fi
}

# ================================
# Log rotation setup
# ================================
ensure_log_rotation() {
    log_and_print "INFO" "Setting up log rotation..."
    
    local logrotate_file="/etc/logrotate.d/mongodb"
    local logrotate_content="$LOG_PATH {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 640 mongodb mongodb
    sharedscripts
    postrotate
        systemctl reload mongod > /dev/null 2>&1 || true
    endscript
}"

    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would configure log rotation"
        return 0
    fi

    if [ ! -f "$logrotate_file" ] || ! grep -q "weekly" "$logrotate_file"; then
        echo "$logrotate_content" > "$logrotate_file"
        log_and_print "FIXED" "Configured log rotation for MongoDB"
    else
        log_and_print "OK" "Log rotation is properly configured"
    fi
}

# ================================
# Monitoring and backup scripts
# ================================
ensure_monitoring_scripts() {
    log_and_print "INFO" "Setting up monitoring and backup scripts..."
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would create monitoring and backup scripts"
        return 0
    fi
    
    # Disk space monitor
    local disk_script="/usr/local/bin/check_mongo_disk.sh"
    cat > "$disk_script" << 'EOF'
#!/bin/bash
THRESHOLD=85
USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
if [ "$USAGE" -gt "$THRESHOLD" ]; then
    echo "$(date): Disk usage critical: $USAGE%, cleaning logs..."
    journalctl --vacuum-size=200M
    find /var/log/mongodb/ -type f -name "*.log*" -size +50M -delete 2>/dev/null || true
    find /var/backups/mongodb/ -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true
fi
EOF
    chmod +x "$disk_script"
    
    # MongoDB watchdog
    local watchdog_script="/usr/local/bin/mongo_watchdog.sh"
    cat > "$watchdog_script" << 'EOF'
#!/bin/bash
if ! pgrep mongod > /dev/null; then
    echo "$(date): MongoDB down, restarting..."
    systemctl restart mongod
fi
EOF
    chmod +x "$watchdog_script"
    
    # Backup script
    local backup_script="/usr/local/bin/mongo_backup.sh"
    cat > "$backup_script" << EOF
#!/bin/bash
set -e

# Load configuration
ADMIN_USER="$ADMIN_USER"
ADMIN_PASS="$ADMIN_PASS"
BACKUP_PATH="$BACKUP_PATH"
BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_DAYS"

BACKUP_DIR="\$BACKUP_PATH/mongo-\$(date +%F)"
echo "\$(date): Starting MongoDB backup to \$BACKUP_DIR"

# Create backup
if mongodump --out "\$BACKUP_DIR" --username "\$ADMIN_USER" --password "\$ADMIN_PASS" --authenticationDatabase admin --quiet; then
    # Compress backup
    tar -czf "\${BACKUP_DIR}.tar.gz" -C "\$(dirname "\$BACKUP_DIR")" "\$(basename "\$BACKUP_DIR")"
    rm -rf "\$BACKUP_DIR"
    
    # Clean old backups
    find "\$BACKUP_PATH" -name "mongo-*.tar.gz" -mtime +\$BACKUP_RETENTION_DAYS -delete 2>/dev/null || true
    
    echo "\$(date): MongoDB backup completed successfully"
else
    echo "\$(date): MongoDB backup failed" >&2
    exit 1
fi
EOF
    chmod +x "$backup_script"
    
    log_and_print "FIXED" "Created monitoring and backup scripts"
}

# ================================
# Cron jobs setup
# ================================
ensure_cron_jobs() {
    log_and_print "INFO" "Setting up scheduled tasks..."
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would configure cron jobs"
        return 0
    fi
    
    local cron_content="# MongoDB monitoring and maintenance
*/15 * * * * /usr/local/bin/check_mongo_disk.sh >/dev/null 2>&1
*/5 * * * * /usr/local/bin/mongo_watchdog.sh >/dev/null 2>&1
0 2 * * 0 /usr/local/bin/mongo_backup.sh >> /var/log/mongodb/backup.log 2>&1"

    # Get current crontab, removing old MongoDB entries
    (crontab -l 2>/dev/null | grep -v "check_mongo_disk\|mongo_watchdog\|mongo_backup" || true) > /tmp/crontab_temp
    
    # Add MongoDB cron jobs
    echo "$cron_content" >> /tmp/crontab_temp
    
    # Install new crontab
    crontab /tmp/crontab_temp
    rm /tmp/crontab_temp
    
    log_and_print "FIXED" "Configured scheduled monitoring and backup tasks"
    
    # Ensure cron service is running
    if ! systemctl is-active --quiet cron; then
        systemctl start cron
        systemctl enable cron
        log_and_print "FIXED" "Started cron service"
    else
        log_and_print "OK" "Cron service is running"
    fi
}

# ================================
# Security validation
# ================================
perform_security_check() {
    print_section "Security Validation"
    
    local security_issues=0
    
    # Check authentication
    if mongo -u "$ADMIN_USER" -p "$ADMIN_PASS" --authenticationDatabase admin --eval "db.runCommand('ping')" &>/dev/null; then
        log_and_print "OK" "Authentication is working"
    else
        log_and_print "ERROR" "Authentication test failed"
        ((security_issues++))
    fi
    
    # Check firewall rules
    if iptables -L INPUT -n | grep -q "27017"; then
        log_and_print "OK" "Firewall rules are configured"
        
        # Verify specific rule exists
        if iptables -L INPUT -n | grep -q "$APP_SERVER_IP.*27017.*ACCEPT"; then
            log_and_print "OK" "Application server IP ($APP_SERVER_IP) is allowed"
        else
            log_and_print "WARN" "Application server IP rule may not be configured correctly"
        fi
    else
        log_and_print "ERROR" "No firewall rules found for MongoDB port"
        ((security_issues++))
    fi
    
    # Check if MongoDB is running as mongodb user
    if pgrep -u mongodb mongod &>/dev/null; then
        log_and_print "OK" "MongoDB is running as mongodb user"
    else
        log_and_print "ERROR" "MongoDB is not running as mongodb user"
        ((security_issues++))
    fi
    
    # Check storage engine
    if systemctl is-active --quiet mongod; then
        local engine=$(mongo -u "$ADMIN_USER" -p "$ADMIN_PASS" --authenticationDatabase admin --quiet --eval "print(db.serverStatus().storageEngine.name)" 2>/dev/null)
        if [ "$engine" = "wiredTiger" ]; then
            log_and_print "OK" "Using secure WiredTiger storage engine"
        else
            log_and_print "WARN" "Storage engine: $engine (WiredTiger recommended)"
        fi
    fi
    
    # Check configuration file
    if [ -f /etc/mongod.conf ]; then
        if grep -q "authorization: enabled" /etc/mongod.conf; then
            log_and_print "OK" "Authentication is enabled in configuration"
        else
            log_and_print "ERROR" "Authentication not enabled in configuration"
            ((security_issues++))
        fi
    else
        log_and_print "ERROR" "MongoDB configuration file missing"
        ((security_issues++))
    fi
    
    return $security_issues
}

# ================================
# Status reporting
# ================================
show_status() {
    print_section "MongoDB Status Report"
    
    # Service status
    if systemctl is-active --quiet mongod; then
        log_and_print "OK" "MongoDB service is running"
        local uptime=$(ps -o etime= -p $(pgrep mongod) | tr -d ' ')
        log_and_print "INFO" "Service uptime: $uptime"
    else
        log_and_print "ERROR" "MongoDB service is not running"
    fi
    
    # Version information
    if command -v mongod &> /dev/null; then
        local version=$(mongod --version | head -n1 | awk '{print $3}')
        log_and_print "INFO" "MongoDB version: $version"
    fi
    
    # Configuration status
    if [ -f /etc/mongod.conf ]; then
        log_and_print "OK" "Configuration file exists"
        
        # Check key settings
        if grep -q "authorization: enabled" /etc/mongod.conf; then
            log_and_print "OK" "Authentication enabled"
        else
            log_and_print "WARN" "Authentication not enabled"
        fi
        
        local engine=$(grep "engine:" /etc/mongod.conf | awk '{print $2}' || echo "unknown")
        log_and_print "INFO" "Configured storage engine: $engine"
        
        # Check SSL status
        if grep -q "mode: requireSSL" /etc/mongod.conf; then
            log_and_print "OK" "SSL/TLS mode enabled"
            local ssl_domain=$(grep "certificateSelector" /etc/mongod.conf | grep -o 'CN=[^"]*' | cut -d'=' -f2)
            if [ -n "$ssl_domain" ]; then
                log_and_print "INFO" "SSL domain: $ssl_domain"
                
                # Check certificate expiry
                local le_path="/etc/letsencrypt/live/$ssl_domain"
                if [ -f "$le_path/cert.pem" ]; then
                    local cert_expiry=$(openssl x509 -in "$le_path/cert.pem" -noout -enddate | cut -d= -f2)
                    log_and_print "INFO" "SSL certificate expires: $cert_expiry"
                fi
            fi
        else
            log_and_print "INFO" "SSL/TLS mode disabled"
        fi
    else
        log_and_print "WARN" "Configuration file missing"
    fi
    
    # Disk usage
    local disk_usage=$(df -h / | awk 'NR==2 {print $5}')
    local disk_percent=$(echo $disk_usage | sed 's/%//')
    
    if [ "$disk_percent" -lt 80 ]; then
        log_and_print "OK" "Disk usage: $disk_usage"
    elif [ "$disk_percent" -lt 90 ]; then
        log_and_print "WARN" "Disk usage: $disk_usage (getting high)"
    else
        log_and_print "ERROR" "Disk usage: $disk_usage (critical)"
    fi
    
    # Database and backup info
    if [ -d "$DB_PATH" ]; then
        local db_size=$(du -sh "$DB_PATH" 2>/dev/null | awk '{print $1}' || echo "unknown")
        log_and_print "INFO" "Database size: $db_size"
    fi
    
    if [ -d "$BACKUP_PATH" ]; then
        local backup_count=$(find "$BACKUP_PATH" -name "mongo-*.tar.gz" 2>/dev/null | wc -l)
        local backup_size=$(du -sh "$BACKUP_PATH" 2>/dev/null | awk '{print $1}' || echo "unknown")
        log_and_print "INFO" "Backups: $backup_count files, $backup_size total"
    fi
    
    # Monitoring scripts
    local scripts_ok=0
    local scripts_total=3
    
    [ -x "/usr/local/bin/check_mongo_disk.sh" ] && ((scripts_ok++))
    [ -x "/usr/local/bin/mongo_watchdog.sh" ] && ((scripts_ok++))
    [ -x "/usr/local/bin/mongo_backup.sh" ] && ((scripts_ok++))
    
    if [ $scripts_ok -eq $scripts_total ]; then
        log_and_print "OK" "All monitoring scripts are installed"
    else
        log_and_print "WARN" "Monitoring scripts: $scripts_ok/$scripts_total installed"
    fi
    
    # Cron jobs
    if crontab -l 2>/dev/null | grep -q "check_mongo_disk\|mongo_watchdog\|mongo_backup"; then
        local cron_count=$(crontab -l 2>/dev/null | grep -c "check_mongo_disk\|mongo_watchdog\|mongo_backup")
        log_and_print "OK" "Scheduled tasks configured ($cron_count active)"
    else
        log_and_print "WARN" "Scheduled tasks not configured"
    fi
}

# ================================
# Maintenance operations
# ================================
perform_maintenance() {
    print_section "Maintenance Operations"
    
    local operation="$1"
    
    case "$operation" in
        "cleanup-logs")
            log_and_print "INFO" "Cleaning old log files..."
            local log_dir="$(dirname "$LOG_PATH")"
            if [ -d "$log_dir" ]; then
                local cleaned=$(find "$log_dir" -name "*.log*" -mtime +7 -type f | wc -l)
                if [ "${DRY_RUN:-false}" = true ]; then
                    log_and_print "INFO" "DRY RUN: Would clean $cleaned old log files"
                else
                    find "$log_dir" -name "*.log*" -mtime +7 -type f -delete 2>/dev/null || true
                    log_and_print "FIXED" "Cleaned $cleaned old log files"
                fi
            fi
            ;;
            
        "cleanup-backups")
            log_and_print "INFO" "Cleaning old backup files..."
            if [ -d "$BACKUP_PATH" ]; then
                local cleaned=$(find "$BACKUP_PATH" -name "mongo-*.tar.gz" -mtime +$BACKUP_RETENTION_DAYS -type f | wc -l)
                if [ "${DRY_RUN:-false}" = true ]; then
                    log_and_print "INFO" "DRY RUN: Would clean $cleaned old backup files"
                else
                    find "$BACKUP_PATH" -name "mongo-*.tar.gz" -mtime +$BACKUP_RETENTION_DAYS -type f -delete 2>/dev/null || true
                    log_and_print "FIXED" "Cleaned $cleaned old backup files"
                fi
            fi
            ;;
            
        "restart")
            log_and_print "INFO" "Restarting MongoDB service..."
            if [ "${DRY_RUN:-false}" = true ]; then
                log_and_print "INFO" "DRY RUN: Would restart MongoDB service"
            else
                if [ "${FORCE:-false}" != true ]; then
                    echo -n "Are you sure you want to restart MongoDB? (y/N): "
                    read -r confirm
                    if [[ ! $confirm =~ ^[Yy]$ ]]; then
                        log_and_print "INFO" "Restart cancelled by user"
                        return 0
                    fi
                fi
                
                systemctl restart mongod
                sleep 3
                if systemctl is-active --quiet mongod; then
                    log_and_print "FIXED" "MongoDB restarted successfully"
                else
                    log_and_print "ERROR" "MongoDB failed to restart"
                    return 1
                fi
            fi
            ;;
            
        "security-check")
            perform_security_check
            ;;
            
        "disk-cleanup")
            log_and_print "INFO" "Performing emergency disk cleanup..."
            if [ "${DRY_RUN:-false}" = true ]; then
                log_and_print "INFO" "DRY RUN: Would perform emergency disk cleanup"
            else
                # Clean logs aggressively
                find /var/log -name "*.log*" -size +100M -mtime +1 -delete 2>/dev/null || true
                # Clean old backups (more aggressive - 14 days)
                find "$BACKUP_PATH" -name "mongo-*.tar.gz" -mtime +14 -delete 2>/dev/null || true
                # Vacuum journal
                journalctl --vacuum-size=100M &>/dev/null
                # Clean package cache
                apt-get clean &>/dev/null
                log_and_print "FIXED" "Emergency disk cleanup completed"
            fi
            ;;
            
        *)
            # Default maintenance
            perform_maintenance "cleanup-logs"
            perform_maintenance "cleanup-backups"
            
            # Vacuum systemd journal
            if [ "${DRY_RUN:-false}" = true ]; then
                log_and_print "INFO" "DRY RUN: Would clean system journal"
            else
                journalctl --vacuum-size=200M &>/dev/null
                log_and_print "OK" "Cleaned system journal"
            fi
            
            # Check disk usage
            local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
            if [ "$disk_usage" -gt 85 ]; then
                log_and_print "WARN" "High disk usage: ${disk_usage}% - consider running disk-cleanup"
            else
                log_and_print "OK" "Disk usage: ${disk_usage}%"
            fi
            ;;
    esac
}

# ================================
# Backup operations
# ================================
create_backup() {
    print_section "Creating Backup"
    
    if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
        log_and_print "ERROR" "Admin credentials not configured for backup"
        return 1
    fi
    
    local backup_dir="$BACKUP_PATH/mongo-$(date +%F-%H%M%S)"
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would create backup at $backup_dir"
        return 0
    fi
    
    log_and_print "INFO" "Creating backup at $backup_dir"
    
    mkdir -p "$backup_dir"
    
    if mongodump --out "$backup_dir" --username "$ADMIN_USER" --password "$ADMIN_PASS" --authenticationDatabase admin; then
        # Compress backup
        tar -czf "${backup_dir}.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"
        rm -rf "$backup_dir"
        
        local backup_size=$(du -sh "${backup_dir}.tar.gz" | awk '{print $1}')
        log_and_print "FIXED" "Backup created: ${backup_dir}.tar.gz ($backup_size)"
    else
        log_and_print "ERROR" "Backup creation failed"
        return 1
    fi
}

restore_backup() {
    print_section "Restoring Backup"
    
    local backup_file="$1"
    
    if [ ! -f "$backup_file" ]; then
        log_and_print "ERROR" "Backup file not found: $backup_file"
        return 1
    fi
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would restore from $backup_file"
        return 0
    fi
    
    log_and_print "INFO" "Restoring from backup: $backup_file"
    
    # Extract backup to temporary directory
    local temp_dir="/tmp/mongo-restore-$$"
    mkdir -p "$temp_dir"
    
    if ! tar -xzf "$backup_file" -C "$temp_dir"; then
        log_and_print "ERROR" "Failed to extract backup file"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Find the backup directory inside the extracted archive
    local restore_dir=$(find "$temp_dir" -type d -name "mongo-*" | head -n1)
    if [ -z "$restore_dir" ]; then
        restore_dir="$temp_dir"
    fi
    
    if [ "${FORCE:-false}" != true ]; then
        log_and_print "WARN" "This will overwrite existing database data!"
        echo -n "Are you sure you want to continue? (y/N): "
        read -r confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            log_and_print "INFO" "Restore cancelled by user"
            rm -rf "$temp_dir"
            return 0
        fi
    fi
    
    if mongorestore "$restore_dir"; then
        log_and_print "FIXED" "Database restore completed successfully"
    else
        log_and_print "ERROR" "Database restore failed"
        rm -rf "$temp_dir"
        return 1
    fi
    
    rm -rf "$temp_dir"
}

# ================================
# Summary report
# ================================
generate_summary() {
    echo
    echo "======================================="
    echo "$SCRIPT_NAME v$SCRIPT_VERSION - Summary"
    echo "======================================="
    echo "Execution completed: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Log file: $LOG_FILE"
    echo
    
    echo "Results:"
    echo "  Issues Found: $ISSUES_FOUND"
    echo "  Issues Fixed: $ISSUES_FIXED"
    echo "  Warnings: $WARNINGS"
    echo
    
    if [ $ISSUES_FOUND -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}✓ MongoDB is fully hardened and secure${NC}"
    elif [ $ISSUES_FOUND -eq 0 ] && [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠ MongoDB is secure but has $WARNINGS warnings${NC}"
    else
        echo -e "${RED}✗ Found $ISSUES_FOUND security issues that require attention${NC}"
    fi
    
    echo
    echo "Configuration:"
    echo "  Admin User: $ADMIN_USER"
    echo "  Application IP: $APP_SERVER_IP"
    echo "  Backup Retention: $BACKUP_RETENTION_DAYS days"
    echo "  Database Path: $DB_PATH"
    echo "  Log Path: $LOG_PATH"
    echo "  Backup Path: $BACKUP_PATH"
    
    if systemctl is-active --quiet mongod; then
        echo
        echo "Connect to MongoDB:"
        if [ "$USE_SSL" = "true" ] && [ -n "$MONGO_DOMAIN" ]; then
            echo "  # With SSL (using client certificate):"
            echo "  mongo --ssl --sslPEMKeyFile $CLIENT_DIR/app1.pem --sslCAFile $CA_DIR/ca.pem --host $MONGO_DOMAIN:27017 -u \"$ADMIN_USER\" -p \"<password>\" --authenticationDatabase admin"
            echo "  # Or using x.509 authentication:"
            echo "  mongo --ssl --sslPEMKeyFile $CLIENT_DIR/app1.pem --sslCAFile $CA_DIR/ca.pem --host $MONGO_DOMAIN:27017 --authenticationMechanism MONGODB-X509"
        else
            echo "  mongo -u \"$ADMIN_USER\" -p \"<password>\" --authenticationDatabase admin"
        fi
    fi
    
    echo "======================================="
}

# ================================
# Main execution logic
# ================================
main() {
    # Initialize log file
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$RUN_DATE] $SCRIPT_NAME v$SCRIPT_VERSION started" > "$LOG_FILE"
    
    # Parse command line arguments
    local command="harden"
    local subcommand=""
    local backup_file=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            help|--help|-h)
                show_help
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --config-only)
                CONFIG_ONLY=true
                shift
                ;;
            harden|status|maintenance|backup|restore|config|ssl-setup|ssl-renew)
                command=$1
                shift
                ;;
            cleanup-logs|cleanup-backups|restart|security-check|disk-cleanup)
                if [ "$command" = "maintenance" ]; then
                    subcommand=$1
                fi
                shift
                ;;
            *)
                if [ "$command" = "restore" ] && [ -z "$backup_file" ]; then
                    backup_file=$1
                fi
                shift
                ;;
        esac
    done
    
    # Show header
    echo "======================================="
    echo "$SCRIPT_NAME v$SCRIPT_VERSION"
    echo "Started: $RUN_DATE"
    if [ "${DRY_RUN:-false}" = true ]; then
        echo "Mode: DRY RUN (no changes will be made)"
    fi
    echo "======================================="
    echo
    
    # Check privileges for operations that need root
    if [ "$command" != "help" ]; then
        check_privileges
    fi
    
    # Execute command
    case $command in
        "config")
            prompt_for_config
            save_config_to_env
            log_and_print "OK" "Configuration completed"
            ;;
            
        "status")
            show_status
            perform_security_check
            ;;
            
        "maintenance")
            check_dependencies
            prompt_for_config
            perform_maintenance "$subcommand"
            ;;
            
        "backup")
            check_dependencies
            prompt_for_config
            create_backup
            ;;
            
        "restore")
            if [ -z "$backup_file" ]; then
                log_and_print "ERROR" "Backup file required for restore command"
                echo "Usage: sudo $0 restore <backup_file>"
                exit 1
            fi
            check_dependencies
            prompt_for_config
            restore_backup "$backup_file"
            ;;
            
        "ssl-setup")
            check_dependencies
            prompt_for_config
            if [ -z "$MONGO_DOMAIN" ]; then
                log_and_print "ERROR" "MONGO_DOMAIN is required for SSL setup"
                echo "Set MONGO_DOMAIN environment variable or use interactive config"
                exit 1
            fi
            USE_SSL=true
            setup_ssl_certificates
            # Update MongoDB config with SSL
            ensure_mongodb_config
            ensure_mongodb_running true
            log_and_print "OK" "SSL setup completed"
            ;;
            
        "ssl-renew")
            check_dependencies
            renew_certificates
            ;;
            
        "harden"|*)
            # Full hardening process
            check_dependencies
            prompt_for_config
            
            if [ "${CONFIG_ONLY:-false}" = true ]; then
                save_config_to_env
                log_and_print "OK" "Configuration saved, skipping hardening"
            else
                print_section "MongoDB Installation"
                ensure_mongodb_installed
                ensure_directories_and_permissions
                ensure_systemd_service
                
                print_section "Storage Engine Management"
                check_and_migrate_storage_engine
                
                print_section "Security Configuration"
                
                # Setup SSL if enabled
                if [ "$USE_SSL" = "true" ] && [ -n "$MONGO_DOMAIN" ]; then
                    setup_ssl_certificates
                fi
                
                config_changed=$(ensure_mongodb_config && echo true || echo false)
                ensure_firewall_rules
                ensure_mongodb_running $config_changed
                ensure_authentication
                
                print_section "Monitoring Setup"
                ensure_log_rotation
                ensure_monitoring_scripts
                ensure_cron_jobs
                
                # Validate security
                perform_security_check
                
                # Show final status
                show_status
                
                # Save configuration for future runs
                save_config_to_env
            fi
            ;;
    esac
    
    # Generate summary
    generate_summary
    
    # Log completion
    echo "[$RUN_DATE] $SCRIPT_NAME v$SCRIPT_VERSION completed" >> "$LOG_FILE"
}

# Execute main function with all arguments
main "$@"