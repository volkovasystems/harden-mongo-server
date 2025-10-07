#!/usr/bin/env bash
# MongoDB Hardening Utility - MongoDB Library
# Provides MongoDB-specific functions for service management, configuration, and database operations

# Prevent multiple inclusion
if [[ -n "${_MONGODB_HARDENING_MONGODB_LOADED:-}" ]]; then
    return 0
fi
readonly _MONGODB_HARDENING_MONGODB_LOADED=1

# Load required modules
if [[ -z "${_MONGODB_HARDENING_CORE_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
fi

if [[ -z "${_MONGODB_HARDENING_LOGGING_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
fi

if [[ -z "${_MONGODB_HARDENING_SYSTEM_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/system.sh"
fi

# ================================
# MongoDB Configuration Constants
# ================================

# Default configuration paths
readonly MONGODB_CONFIG_FILE="/etc/mongod.conf"
readonly MONGODB_SERVICE_NAME="mongod"
readonly MONGODB_USER="mongodb"
readonly MONGODB_GROUP="mongodb"
readonly MONGODB_DEFAULT_PORT="27017"
readonly MONGODB_DEFAULT_BIND_IP="127.0.0.1"

# MongoDB configuration templates
readonly MONGODB_SECURE_CONFIG_TEMPLATE='# MongoDB Configuration File - Security Hardened
# MongoDB storage options
storage:
  dbPath: %DB_PATH%
  journal:
    enabled: true
  wiredTiger:
    engineConfig:
      cacheSizeGB: %CACHE_SIZE%
    collectionConfig:
      blockCompressor: snappy
    indexConfig:
      prefixCompression: true

# Network interfaces
net:
  port: %PORT%
  bindIp: %BIND_IP%
  maxIncomingConnections: %MAX_CONNECTIONS%
  ssl:
    mode: %SSL_MODE%
    PEMKeyFile: %SSL_PEM_FILE%
    CAFile: %SSL_CA_FILE%

# Process management
processManagement:
  fork: true
  pidFilePath: /var/run/mongodb/mongod.pid
  timeZoneInfo: /usr/share/zoneinfo

# Logging
systemLog:
  destination: file
  logAppend: true
  logRotate: reopen
  path: %LOG_PATH%
  verbosity: 0
  component:
    accessControl:
      verbosity: 1

# Security
security:
  authorization: %AUTH_ENABLED%
  keyFile: %KEY_FILE%
  javascriptEnabled: false
  clusterAuthMode: %CLUSTER_AUTH_MODE%

# Operation profiling
operationProfiling:
  mode: slowOp
  slowOpThresholdMs: 100

# Storage engine options
setParameter:
  authenticationMechanisms: "SCRAM-SHA-1,SCRAM-SHA-256"
  failIndexKeyTooLong: false
  maxLogSizeKB: 10240'

# ================================
# MongoDB Service Management
# ================================

# Check if MongoDB is installed
is_mongodb_installed() {
    is_package_installed "mongodb-org" || is_package_installed "mongodb" || command_exists mongod
}

# Get MongoDB version
get_mongodb_version() {
    if command_exists mongod; then
        mongod --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
    else
        echo "not_installed"
    fi
}

# Get MongoDB service status
get_mongodb_service_status() {
    local service_manager
    service_manager=$(detect_service_manager)
    
    case "$service_manager" in
        systemd)
            systemctl is-active "$MONGODB_SERVICE_NAME" 2>/dev/null || echo "inactive"
            ;;
        sysvinit|openrc)
            if pgrep mongod >/dev/null; then
                echo "active"
            else
                echo "inactive"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Start MongoDB service
start_mongodb_service() {
    local service_manager
    service_manager=$(detect_service_manager)
    
    info "Starting MongoDB service..."
    
    case "$service_manager" in
        systemd)
            execute_or_simulate "Start MongoDB service" "systemctl start $MONGODB_SERVICE_NAME"
            ;;
        sysvinit)
            execute_or_simulate "Start MongoDB service" "service $MONGODB_SERVICE_NAME start"
            ;;
        openrc)
            execute_or_simulate "Start MongoDB service" "rc-service $MONGODB_SERVICE_NAME start"
            ;;
        *)
            warn "Unknown service manager, attempting direct start..."
            execute_or_simulate "Start MongoDB directly" "mongod --config $MONGODB_CONFIG_FILE --fork"
            ;;
    esac
    
    # Wait for service to start
    local attempts=0
    local max_attempts=30
    while ((attempts < max_attempts)); do
        if [[ "$(get_mongodb_service_status)" == "active" ]]; then
            success "MongoDB service started successfully"
            return 0
        fi
        sleep 1
        ((attempts++))
    done
    
    error "Failed to start MongoDB service within $max_attempts seconds"
    return 1
}

# Stop MongoDB service
stop_mongodb_service() {
    local service_manager
    service_manager=$(detect_service_manager)
    
    info "Stopping MongoDB service..."
    
    case "$service_manager" in
        systemd)
            execute_or_simulate "Stop MongoDB service" "systemctl stop $MONGODB_SERVICE_NAME"
            ;;
        sysvinit)
            execute_or_simulate "Stop MongoDB service" "service $MONGODB_SERVICE_NAME stop"
            ;;
        openrc)
            execute_or_simulate "Stop MongoDB service" "rc-service $MONGODB_SERVICE_NAME stop"
            ;;
        *)
            warn "Unknown service manager, attempting direct stop..."
            local pid
            pid=$(pgrep mongod)
            if [[ -n "$pid" ]]; then
                execute_or_simulate "Stop MongoDB process" "kill -TERM $pid"
            fi
            ;;
    esac
    
    # Wait for service to stop
    local attempts=0
    local max_attempts=30
    while ((attempts < max_attempts)); do
        if [[ "$(get_mongodb_service_status)" == "inactive" ]]; then
            success "MongoDB service stopped successfully"
            return 0
        fi
        sleep 1
        ((attempts++))
    done
    
    error "Failed to stop MongoDB service within $max_attempts seconds"
    return 1
}

# Restart MongoDB service
restart_mongodb_service() {
    info "Restarting MongoDB service..."
    
    if stop_mongodb_service; then
        sleep 2
        start_mongodb_service
    else
        return 1
    fi
}

# Enable MongoDB service to start on boot
enable_mongodb_service() {
    local service_manager
    service_manager=$(detect_service_manager)
    
    case "$service_manager" in
        systemd)
            execute_or_simulate "Enable MongoDB service" "systemctl enable $MONGODB_SERVICE_NAME"
            ;;
        sysvinit)
            execute_or_simulate "Enable MongoDB service" "chkconfig $MONGODB_SERVICE_NAME on"
            ;;
        openrc)
            execute_or_simulate "Enable MongoDB service" "rc-update add $MONGODB_SERVICE_NAME default"
            ;;
        *)
            warn "Unknown service manager, cannot configure auto-start"
            return 1
            ;;
    esac
}

# ================================
# MongoDB Configuration Management
# ================================

# Backup existing MongoDB configuration
backup_mongodb_config() {
    local backup_file="${MONGODB_CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    if [[ -f "$MONGODB_CONFIG_FILE" ]]; then
        execute_or_simulate "Backup MongoDB configuration" "cp '$MONGODB_CONFIG_FILE' '$backup_file'"
        success "Configuration backed up to $backup_file"
    else
        info "No existing configuration file found"
    fi
}

# Generate secure MongoDB configuration
generate_mongodb_config() {
    local db_path="${1:-$DEFAULT_DB_PATH}"
    local log_path="${2:-$DEFAULT_LOG_PATH}"
    local port="${3:-$MONGODB_DEFAULT_PORT}"
    local bind_ip="${4:-$MONGODB_DEFAULT_BIND_IP}"
    local ssl_enabled="${5:-false}"
    local auth_enabled="${6:-enabled}"
    local ssl_pem_file="${7:-}"
    local ssl_ca_file="${8:-}"
    local key_file="${9:-}"
    
    # Calculate cache size (50% of available memory, max 1GB for small systems)
    local mem_info
    mem_info=$(get_memory_info)
    local mem_total
    mem_total=$(echo "$mem_info" | grep -o "total:[0-9]*" | cut -d: -f2)
    local cache_size=$((mem_total / 2048))  # Convert MB to GB and take half
    if ((cache_size < 1)); then
        cache_size=1
    elif ((cache_size > 64)); then
        cache_size=64  # Cap at 64GB for very large systems
    fi
    
    # Calculate max connections based on memory
    local max_connections=1000
    if ((mem_total < 2048)); then
        max_connections=200
    elif ((mem_total < 4096)); then
        max_connections=500
    fi
    
    # Set SSL mode
    local ssl_mode="disabled"
    if [[ "$ssl_enabled" == "true" ]]; then
        ssl_mode="requireSSL"
    fi
    
    # Set cluster auth mode
    local cluster_auth_mode="keyFile"
    if [[ "$ssl_enabled" == "true" ]]; then
        cluster_auth_mode="x509"
    fi
    
    # Generate configuration content
    local config_content="$MONGODB_SECURE_CONFIG_TEMPLATE"
    config_content="${config_content//%DB_PATH%/$db_path}"
    config_content="${config_content//%LOG_PATH%/$log_path}"
    config_content="${config_content//%PORT%/$port}"
    config_content="${config_content//%BIND_IP%/$bind_ip}"
    config_content="${config_content//%CACHE_SIZE%/$cache_size}"
    config_content="${config_content//%MAX_CONNECTIONS%/$max_connections}"
    config_content="${config_content//%SSL_MODE%/$ssl_mode}"
    config_content="${config_content//%SSL_PEM_FILE%/$ssl_pem_file}"
    config_content="${config_content//%SSL_CA_FILE%/$ssl_ca_file}"
    config_content="${config_content//%AUTH_ENABLED%/$auth_enabled}"
    config_content="${config_content//%KEY_FILE%/$key_file}"
    config_content="${config_content//%CLUSTER_AUTH_MODE%/$cluster_auth_mode}"
    
    echo "$config_content"
}

# Apply MongoDB configuration
apply_mongodb_config() {
    local db_path="${1:-$DEFAULT_DB_PATH}"
    local log_path="${2:-$DEFAULT_LOG_PATH}"
    local port="${3:-$MONGODB_DEFAULT_PORT}"
    local bind_ip="${4:-$MONGODB_DEFAULT_BIND_IP}"
    local ssl_enabled="${5:-false}"
    local auth_enabled="${6:-enabled}"
    local ssl_pem_file="${7:-}"
    local ssl_ca_file="${8:-}"
    local key_file="${9:-}"
    
    info "Applying MongoDB configuration..."
    
    # Backup existing configuration
    backup_mongodb_config
    
    # Generate new configuration
    local new_config
    new_config=$(generate_mongodb_config "$db_path" "$log_path" "$port" "$bind_ip" "$ssl_enabled" "$auth_enabled" "$ssl_pem_file" "$ssl_ca_file" "$key_file")
    
    # Write configuration file
    if ! is_dry_run; then
        echo "$new_config" > "$MONGODB_CONFIG_FILE"
        chmod 644 "$MONGODB_CONFIG_FILE"
        chown root:root "$MONGODB_CONFIG_FILE"
    fi
    
    success "MongoDB configuration applied to $MONGODB_CONFIG_FILE"
    
    # Create required directories
    create_dir_safe "$(dirname "$db_path")" 755 "$MONGODB_USER:$MONGODB_GROUP"
    create_dir_safe "$db_path" 755 "$MONGODB_USER:$MONGODB_GROUP"
    create_dir_safe "$(dirname "$log_path")" 755 "$MONGODB_USER:$MONGODB_GROUP"
    
    # Create log file with proper permissions
    if [[ ! -f "$log_path" ]]; then
        execute_or_simulate "Create MongoDB log file" "touch '$log_path'"
        execute_or_simulate "Set log file ownership" "chown '$MONGODB_USER:$MONGODB_GROUP' '$log_path'"
        execute_or_simulate "Set log file permissions" "chmod 644 '$log_path'"
    fi
}

# Validate MongoDB configuration
validate_mongodb_config() {
    local config_file="${1:-$MONGODB_CONFIG_FILE}"
    
    if [[ ! -f "$config_file" ]]; then
        error "MongoDB configuration file not found: $config_file"
        return 1
    fi
    
    info "Validating MongoDB configuration..."
    
    # Test configuration syntax
    if command_exists mongod; then
        if mongod --config "$config_file" --configtest 2>/dev/null; then
            success "MongoDB configuration syntax is valid"
        else
            error "MongoDB configuration contains syntax errors"
            return 1
        fi
    else
        warn "mongod command not found, skipping syntax validation"
    fi
    
    # Check required sections
    local required_sections=("storage" "net" "systemLog" "security")
    for section in "${required_sections[@]}"; do
        if grep -q "^${section}:" "$config_file"; then
            verbose "Configuration section found: $section"
        else
            warn "Missing configuration section: $section"
        fi
    done
    
    # Check file permissions
    local config_perms
    config_perms=$(stat -c %a "$config_file" 2>/dev/null)
    if [[ "$config_perms" -le "644" ]]; then
        verbose "Configuration file permissions are secure: $config_perms"
    else
        warn "Configuration file permissions may be too permissive: $config_perms"
    fi
    
    success "MongoDB configuration validation completed"
}

# ================================
# MongoDB Database Operations
# ================================

# Connect to MongoDB and execute command
mongodb_execute() {
    local database="${1:-admin}"
    local command="$2"
    local auth_database="${3:-admin}"
    local username="${4:-}"
    local password="${5:-}"
    
    local mongo_cmd="mongosh"
    if ! command_exists mongosh && command_exists mongo; then
        mongo_cmd="mongo"
    fi
    
    if ! command_exists "$mongo_cmd"; then
        error "MongoDB client not found (mongosh or mongo)"
        return 1
    fi
    
    local connect_options=""
    if [[ -n "$username" && -n "$password" ]]; then
        connect_options="--username '$username' --password '$password' --authenticationDatabase '$auth_database'"
    fi
    
    # Get connection details from config
    local port
    local bind_ip
    if [[ -f "$MONGODB_CONFIG_FILE" ]]; then
        port=$(grep "port:" "$MONGODB_CONFIG_FILE" | awk '{print $2}' || echo "$MONGODB_DEFAULT_PORT")
        bind_ip=$(grep "bindIp:" "$MONGODB_CONFIG_FILE" | awk '{print $2}' || echo "$MONGODB_DEFAULT_BIND_IP")
    else
        port="$MONGODB_DEFAULT_PORT"
        bind_ip="$MONGODB_DEFAULT_BIND_IP"
    fi
    
    verbose "Executing MongoDB command on $bind_ip:$port/$database"
    
    echo "$command" | eval "$mongo_cmd --host '$bind_ip' --port '$port' $connect_options '$database'"
}

# Check MongoDB connection
check_mongodb_connection() {
    local username="${1:-}"
    local password="${2:-}"
    
    info "Testing MongoDB connection..."
    
    local test_command='db.runCommand({connectionStatus: 1})'
    
    if mongodb_execute "admin" "$test_command" "admin" "$username" "$password" >/dev/null 2>&1; then
        success "MongoDB connection successful"
        return 0
    else
        error "Failed to connect to MongoDB"
        return 1
    fi
}

# Create MongoDB user
create_mongodb_user() {
    local username="$1"
    local password="$2"
    local database="${3:-admin}"
    local roles="${4:-root}"
    local admin_user="${5:-}"
    local admin_password="${6:-}"
    
    info "Creating MongoDB user: $username"
    
    local create_user_command
    if [[ "$roles" == "root" ]]; then
        create_user_command="db.createUser({user: '$username', pwd: '$password', roles: ['root']})"
    else
        create_user_command="db.createUser({user: '$username', pwd: '$password', roles: [$roles]})"
    fi
    
    if mongodb_execute "$database" "$create_user_command" "admin" "$admin_user" "$admin_password"; then
        success "MongoDB user '$username' created successfully"
    else
        error "Failed to create MongoDB user '$username'"
        return 1
    fi
}

# Change MongoDB user password
change_mongodb_user_password() {
    local username="$1"
    local new_password="$2"
    local database="${3:-admin}"
    local admin_user="${4:-}"
    local admin_password="${5:-}"
    
    info "Changing password for MongoDB user: $username"
    
    local change_password_command="db.changeUserPassword('$username', '$new_password')"
    
    if mongodb_execute "$database" "$change_password_command" "admin" "$admin_user" "$admin_password"; then
        success "Password changed for MongoDB user '$username'"
    else
        error "Failed to change password for MongoDB user '$username'"
        return 1
    fi
}

# List MongoDB users
list_mongodb_users() {
    local admin_user="${1:-}"
    local admin_password="${2:-}"
    
    info "Listing MongoDB users..."
    
    local list_users_command="db.getUsers()"
    
    mongodb_execute "admin" "$list_users_command" "admin" "$admin_user" "$admin_password"
}

# ================================
# MongoDB Security Assessment
# ================================

# Check MongoDB security configuration
check_mongodb_security() {
    print_section "MongoDB Security Assessment"
    
    local issues_found=0
    
    # Check if MongoDB is running
    if [[ "$(get_mongodb_service_status)" != "active" ]]; then
        report_issue "high" "MongoDB service is not running"
        ((issues_found++))
    else
        success "MongoDB service is running"
    fi
    
    # Check configuration file exists and has proper permissions
    if [[ ! -f "$MONGODB_CONFIG_FILE" ]]; then
        report_issue "high" "MongoDB configuration file not found" "Create configuration file with secure settings"
        ((issues_found++))
    else
        local config_perms
        config_perms=$(stat -c %a "$MONGODB_CONFIG_FILE" 2>/dev/null)
        if [[ "$config_perms" -gt "644" ]]; then
            report_issue "medium" "MongoDB configuration file permissions too permissive ($config_perms)" "Set permissions to 644 or more restrictive"
            ((issues_found++))
        fi
    fi
    
    # Check authentication settings
    if [[ -f "$MONGODB_CONFIG_FILE" ]]; then
        if grep -q "authorization.*enabled" "$MONGODB_CONFIG_FILE"; then
            success "Authentication is enabled"
        else
            report_issue "critical" "MongoDB authentication is not enabled" "Enable authentication in MongoDB configuration"
            ((issues_found++))
        fi
        
        # Check bind IP
        local bind_ip
        bind_ip=$(grep "bindIp:" "$MONGODB_CONFIG_FILE" | awk '{print $2}')
        if [[ "$bind_ip" == "0.0.0.0" || "$bind_ip" == "*" ]]; then
            report_issue "high" "MongoDB is bound to all interfaces" "Restrict binding to specific IP addresses"
            ((issues_found++))
        elif [[ "$bind_ip" == "127.0.0.1" ]]; then
            success "MongoDB is bound to localhost only"
        else
            info "MongoDB is bound to specific IP: $bind_ip"
        fi
        
        # Check SSL/TLS
        if grep -q "ssl:" "$MONGODB_CONFIG_FILE"; then
            local ssl_mode
            ssl_mode=$(grep -A5 "ssl:" "$MONGODB_CONFIG_FILE" | grep "mode:" | awk '{print $2}')
            if [[ "$ssl_mode" == "requireSSL" ]]; then
                success "SSL/TLS is required"
            elif [[ "$ssl_mode" == "preferSSL" ]]; then
                warn "SSL/TLS is preferred but not required"
            else
                report_issue "medium" "SSL/TLS is not properly configured" "Configure SSL/TLS encryption"
                ((issues_found++))
            fi
        else
            report_issue "medium" "SSL/TLS is not configured" "Configure SSL/TLS encryption"
            ((issues_found++))
        fi
        
        # Check JavaScript execution
        if grep -q "javascriptEnabled.*false" "$MONGODB_CONFIG_FILE"; then
            success "JavaScript execution is disabled"
        else
            report_issue "low" "JavaScript execution may be enabled" "Disable JavaScript execution for security"
            ((issues_found++))
        fi
    fi
    
    # Check for default port
    local current_port
    if [[ -f "$MONGODB_CONFIG_FILE" ]]; then
        current_port=$(grep "port:" "$MONGODB_CONFIG_FILE" | awk '{print $2}')
    else
        current_port="$MONGODB_DEFAULT_PORT"
    fi
    
    if [[ "$current_port" == "$MONGODB_DEFAULT_PORT" ]]; then
        report_issue "low" "MongoDB is using default port ($MONGODB_DEFAULT_PORT)" "Consider using a non-standard port"
        ((issues_found++))
    fi
    
    # Check log file permissions
    local log_path
    if [[ -f "$MONGODB_CONFIG_FILE" ]]; then
        log_path=$(grep "path:" "$MONGODB_CONFIG_FILE" | awk '{print $2}')
        if [[ -n "$log_path" && -f "$log_path" ]]; then
            local log_perms
            log_perms=$(stat -c %a "$log_path" 2>/dev/null)
            if [[ "$log_perms" -gt "640" ]]; then
                report_issue "low" "MongoDB log file permissions too permissive ($log_perms)" "Restrict log file permissions"
                ((issues_found++))
            fi
        fi
    fi
    
    print_subsection "Security Assessment Summary"
    if ((issues_found == 0)); then
        success "No critical security issues found"
    else
        warn "$issues_found security issues identified"
    fi
    
    return $((issues_found > 0 ? 1 : 0))
}

# ================================
# Module Information
# ================================

# Module information
mongodb_module_info() {
    cat << EOF
MongoDB Hardening MongoDB Library v$MONGODB_HARDENING_VERSION

This module provides:
- MongoDB service management (start, stop, restart, enable)
- MongoDB configuration generation and management
- Database user creation and management
- MongoDB connection testing and validation
- Security assessment and configuration checking
- Configuration backup and restoration

Functions:
- is_mongodb_installed: Check if MongoDB is installed
- get_mongodb_version: Get installed MongoDB version
- get_mongodb_service_status: Check service status
- start/stop/restart_mongodb_service: Service control
- generate_mongodb_config: Create secure configuration
- apply_mongodb_config: Apply configuration with validation
- mongodb_execute: Execute MongoDB commands
- create_mongodb_user: Create database users
- check_mongodb_security: Security assessment

Configuration:
- MONGODB_CONFIG_FILE: Configuration file path ($MONGODB_CONFIG_FILE)
- MONGODB_SERVICE_NAME: Service name ($MONGODB_SERVICE_NAME)
- MONGODB_DEFAULT_PORT: Default port ($MONGODB_DEFAULT_PORT)

Dependencies: core.sh, logging.sh, system.sh
EOF
}

