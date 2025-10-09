#!/bin/bash
# =============================================================================
# MongoDB Hardening - System Library Module
# =============================================================================
# This module provides core system functions including:
# - Logging and output formatting
# - Privilege and dependency checking
# - Directory and permission management
# - Configuration prompts and persistence
# =============================================================================

# Prevent multiple sourcing
if [[ "${_SYSTEM_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly _SYSTEM_LIB_LOADED=true

# =============================================================================
# Logging and Output Functions
# =============================================================================

# Main logging function with color-coded output
log_and_print() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file (only if writable)
    if [[ -w "$(dirname "$LOG_FILE" 2>/dev/null)" ]] || [[ -w "$LOG_FILE" ]] 2>/dev/null; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
    fi
    
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

# Print section headers
print_section() {
    echo
    echo -e "${BLUE}$1${NC}"
    echo "$(printf '=%.0s' $(seq 1 ${#1}))"
}

# =============================================================================
# Privilege and Dependency Management
# =============================================================================

# Check if script is running with root privileges
check_privileges() {
    if [ "$EUID" -ne 0 ]; then
        log_and_print "ERROR" "This script must be run as root for security operations"
        echo
        echo "Usage: sudo $0 [command]"
        echo "Run '$0 help' for more information"
        exit 1
    fi
}

# Check and install missing system dependencies
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

# =============================================================================
# Directory and Permission Management
# =============================================================================

# Set up directories and proper permissions
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

# =============================================================================
# Configuration Management
# =============================================================================

# Interactive configuration prompts
prompt_for_config() {
    if [ -z "$ADMIN_PASS" ]; then
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

# Save configuration to environment file
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

# =============================================================================
# Module Information
# =============================================================================

# Display system module information
system_module_info() {
    echo "System Library Module - Core system functions"
    echo "Provides: logging, dependencies, permissions, configuration"
}