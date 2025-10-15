#!/usr/bin/env bash
# MongoDB Server Hardening Tool - MongoDB Library
# Provides MongoDB-specific functions for service management, configuration, and database operations

# Prevent multiple inclusion
if [[ -n "${_HARDEN_MONGO_SERVER_MONGODB_LOADED:-}" ]]; then
    return 0
fi
readonly _HARDEN_MONGO_SERVER_MONGODB_LOADED=1

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
# MongoDB Configuration Constants
# ================================

# Default configuration paths
readonly MONGODB_CONFIG_FILE="/etc/mongod.conf"
readonly MONGODB_SERVICE_NAME="mongod"
readonly MONGODB_USER="mongodb"
readonly MONGODB_GROUP="mongodb"
readonly MONGODB_DEFAULT_PORT="27017"
readonly MONGODB_DEFAULT_BIND_IP="127.0.0.1"


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



# Apply given MongoDB configuration content
apply_mongodb_config_content() {
    local content="$1"
    local db_path="${2:-$DEFAULT_DB_PATH}"
    local log_path="${3:-$DEFAULT_LOG_PATH}"

    info "Applying MongoDB configuration..."

    # Backup existing configuration
    backup_mongodb_config

    # Write provided configuration content
    if ! is_dry_run; then
        echo "$content" > "$MONGODB_CONFIG_FILE"
        chmod 644 "$MONGODB_CONFIG_FILE"
        chown root:root "$MONGODB_CONFIG_FILE"
    fi

    success "MongoDB configuration applied to $MONGODB_CONFIG_FILE"

    # Ensure required paths exist
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
    
    # TLS/x509 auth if admin certs exist
    local admin_cert="/etc/mongoCA/clients/admin.pem"
    local ca_cert="/etc/mongoCA/ca.crt"
    local tls_options=""
    if [[ -f "$admin_cert" && -f "$ca_cert" ]]; then
        tls_options="--tls --tlsCertificateKeyFile '$admin_cert' --tlsCAFile '$ca_cert' --authenticationDatabase '\$external' --authenticationMechanism 'MONGODB-X509'"
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
    
    echo "$command" | eval "$mongo_cmd --host '$bind_ip' --port '$port' $tls_options $connect_options '$database'"
}


# ================================
# 1.0.0 MVP MongoDB Configuration
# ================================

# 1.0.0 MVP Constants
readonly MONGODB_HARDENED_CONFIG_TEMPLATE='# MongoDB Configuration File - Security Hardened (MVP)
# Storage engine (WiredTiger enforced)
storage:
  dbPath: %DB_PATH%
  engine: wiredTiger
  journal:
    enabled: true
  wiredTiger:
    engineConfig:
      cacheSizeGB: %CACHE_SIZE%
    collectionConfig:
      blockCompressor: snappy
    indexConfig:
      prefixCompression: true

# Network interfaces (VPN + localhost by default)
net:
  port: %PORT%
  bindIp: %BIND_IP%
  maxIncomingConnections: %MAX_CONNECTIONS%
  tls:
    mode: requireTLS
    certificateKeyFile: %TLS_CERT_KEY_FILE%
    CAFile: %TLS_CA_FILE%
    allowConnectionsWithoutCertificates: false
    allowInvalidCertificates: false
    allowInvalidHostnames: false
    disabledProtocols: TLS1_0,TLS1_1

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
    command:
      verbosity: 1

# Security (x509-only authentication)
security:
  authorization: enabled
  clusterAuthMode: x509
  javascriptEnabled: false

# Set parameters for 1.0.0 MVP
setParameter:
  authenticationMechanisms: "MONGODB-X509"
  tlsMode: "requireTLS"
  maxLogSizeKB: 10240
  failIndexKeyTooLong: false

# Operation profiling
operationProfiling:
  mode: slowOp
  slowOpThresholdMs: 100'

# Generate hardened MongoDB configuration (MVP)
generate_mongodb_hardened_config() {
    local db_path="${1:-$DEFAULT_DB_PATH}"
    local log_path="${2:-$DEFAULT_LOG_PATH}"
    local port="${3:-$MONGODB_DEFAULT_PORT}"
    local bind_ips="${4:-127.0.0.1,10.8.0.1}"
    local max_connections="${5:-1024}"
    local cache_size="${6:-1}"
    local tls_cert_key="${7:-/etc/ssl/mongodb/mongodb-server.pem}"
    local tls_ca="${8:-/etc/mongoCA/ca.crt}"
    
    info "Generating MongoDB 1.0.0 MVP configuration..."
    
    # Add allowed IPs from configuration
    local allowed_ips
    allowed_ips=$(get_config_value "network.allowedIPs")
    if [[ -n "$allowed_ips" && "$allowed_ips" != "[]" && "$allowed_ips" != "null" ]]; then
        # Parse JSON array of IPs and add them
        local additional_ips
        additional_ips=$(echo "$allowed_ips" | jq -r '.[] | select(length > 0)' | paste -sd ',' -)
        if [[ -n "$additional_ips" ]]; then
            bind_ips="$bind_ips,$additional_ips"
        fi
    fi
    
    # Replace template variables
    local config_content="$MONGODB_HARDENED_CONFIG_TEMPLATE"
    config_content="${config_content//%DB_PATH%/$db_path}"
    config_content="${config_content//%LOG_PATH%/$log_path}"
    config_content="${config_content//%PORT%/$port}"
    config_content="${config_content//%BIND_IP%/$bind_ips}"
    config_content="${config_content//%MAX_CONNECTIONS%/$max_connections}"
    config_content="${config_content//%CACHE_SIZE%/$cache_size}"
    config_content="${config_content//%TLS_CERT_KEY_FILE%/$tls_cert_key}"
    config_content="${config_content//%TLS_CA_FILE%/$tls_ca}"
    
    echo "$config_content"
}

# Get certificate subject DN from a client certificate (RFC2253)
get_cert_subject_dn() {
    local role="$1"
    local cert_path="/etc/mongoCA/clients/${role}.crt"
    [[ -f "$cert_path" ]] || { echo ""; return 1; }
    local subj
    subj=$(openssl x509 -in "$cert_path" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=\s*//')
    echo "$subj"
}

# Create MongoDB x509 users
create_x509_users() {
    info "Creating MongoDB x509 users for 1.0.0 MVP..."
    
    # Wait for MongoDB to be available
    if ! wait_for_mongodb_ready; then
        error "MongoDB is not ready for user creation"
        return 1
    fi
    
    # Create custom roles first
    create_custom_roles
    
    # Create x509 users for each role
    local roles=("root" "admin" "app" "backup")
    for role in "${roles[@]}"; do
        create_x509_user "$role"
    done
    
    success "All x509 users created for 1.0.0 MVP"
}

# Create custom MongoDB roles
create_custom_roles() {
    info "Creating custom MongoDB roles for 1.0.0 MVP..."
    
    # Create hmsOpsAdmin role (cluster monitoring only)
    local ops_admin_role='
    db.createRole({
        role: "hmsOpsAdmin",
        privileges: [],
        roles: [ { role: "clusterMonitor", db: "admin" } ]
    })'
    
    mongodb_execute "admin" "$ops_admin_role" ""
    
    # Create hmsAppRW role (minimal DML, no DDL/index operations)
    local app_rw_role='
    db.createRole({
        role: "hmsAppRW",
        privileges: [
            {
                resource: { db: "", collection: "" },
                actions: [ "find", "insert", "update", "remove" ]
            }
        ],
        roles: []
    })'
    
    mongodb_execute "admin" "$app_rw_role" ""
    
    success "Custom roles created"
}

# Create x509 user for specific role
create_x509_user() {
    local role_name="$1"
    
    info "Creating x509 user for role: $role_name"
    
    # Map role names to MongoDB roles
    local mongodb_roles
    case "$role_name" in
        "root")
            mongodb_roles='[ { role: "root", db: "admin" } ]'
            ;;
        "admin")
            mongodb_roles='[ { role: "hmsOpsAdmin", db: "admin" } ]'
            ;;
        "app")
            mongodb_roles='[ { role: "hmsAppRW", db: "admin" } ]'
            ;;
        "backup")
            mongodb_roles='[ { role: "backup", db: "admin" } ]'
            ;;
        *)
            error "Unknown role: $role_name"
            return 1
            ;;
    esac
    
    # Determine x509 user DN from certificate
    local user_dn
    user_dn=$(get_cert_subject_dn "$role_name")
    if [[ -z "$user_dn" ]]; then
        warn "Could not determine subject DN for role '$role_name'"
        return 1
    fi

    # Build clientSource list based on role
    local client_sources=("127.0.0.1")
    case "$role_name" in
        root) client_sources+=("10.8.0.0/24") ;;
        admin) client_sources=("10.8.0.0/24") ;;
        app)
            client_sources+=("10.8.0.0/24")
            # Append allowed IPs from config
            local allowed_ips
            allowed_ips=$(get_config_value "network.allowedIPs")
            if [[ -n "$allowed_ips" && "$allowed_ips" != "[]" && "$allowed_ips" != "null" ]]; then
                while IFS= read -r ip; do
                    [[ -n "$ip" && "$ip" != "null" ]] && client_sources+=("$ip")
                done < <(echo "$allowed_ips" | jq -r '.[]')
            fi
            ;;
        backup) client_sources=("127.0.0.1") ;;
    esac

    # Convert client_sources array to JSON
    local cs_json
    cs_json=$(printf '%s\n' "${client_sources[@]}" | jq -R -s -c 'split("\n")[:-1]')

    # Create x509 user in $external with DN
    local create_user_script="
    db.getSiblingDB('$external').runCommand({
      createUser: '$user_dn',
      roles: $mongodb_roles,
      authenticationRestrictions: [ { clientSource: $cs_json } ]
    })"

    if mongodb_execute "\$external" "$create_user_script" ""; then
        success "x509 user created for $role_name"
    else
        warn "User $role_name may already exist or creation failed"
    fi
}

# Implement just-in-time database grants for App role
setup_just_in_time_grants() {
    info "Setting up just-in-time database grants..."
    
    # Create monitoring script for new database access
    create_jit_grants_monitor
    
    # Create systemd service for JIT grants
    create_jit_grants_service
    
    # Enable the service
    systemctl enable harden-mongo-server-jit-grants.service
    systemctl start harden-mongo-server-jit-grants.service
    
    success "Just-in-time grants configured"
}

# Create JIT grants monitoring script
create_jit_grants_monitor() {
    local jit_script="/usr/local/bin/harden-mongo-server-jit-grants.sh"
    
    # Resolve App user DN from certificate
    local app_dn
    app_dn=$(get_cert_subject_dn "app")
    
    cat > "$jit_script" << EOF
#!/bin/bash
# Just-in-Time Database Grants Monitor
# Automatically grants App role access to new business databases

LOG_FILE="/var/log/harden-mongo-server/jit-grants.log"
MONGO_CONFIG="/etc/mongod.conf"
ADMIN_CERT="/etc/mongoCA/clients/admin.pem"
CA_FILE="/etc/mongoCA/ca.crt"
APP_USER_DN="${app_dn}"
EXCLUDE_DBS="admin local config"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Get list of current databases
get_databases() {
mongo --tls --tlsCertificateKeyFile="$ADMIN_CERT" --tlsCAFile="$CA_FILE" \
          --authenticationDatabase="\$external" --authenticationMechanism="MONGODB-X509" \
          --eval "db.adminCommand('listDatabases').databases.forEach(function(db) { print(db.name) })" \
          2>/dev/null | grep -v "MongoDB shell" | grep -v "connecting to"
}

# Check if database should be excluded
is_excluded_database() {
    local db_name="$1"
    echo " $EXCLUDE_DBS " | grep -q " $db_name "
}

# Grant App role access to database
grant_app_access() {
    local db_name="$1"
    
    log_message "Granting App role access to database: $db_name"
    
    local grant_command="
    use $db_name;
    db.grantRolesToUser("$APP_USER_DN", [{ role: 'hmsAppRW', db: '$db_name' }]);
    "
    
if mongo --tls --tlsCertificateKeyFile="$ADMIN_CERT" --tlsCAFile="$CA_FILE" \
             --authenticationDatabase="\$external" --authenticationMechanism="MONGODB-X509" \
             --eval "$grant_command" 2>/dev/null; then
        log_message "Successfully granted App access to $db_name"
    else
        log_message "Failed to grant App access to $db_name"
    fi
}

# Monitor for new databases
monitor_databases() {
    local known_dbs_file="/var/lib/harden-mongo-server/known-databases"
    mkdir -p "$(dirname "$known_dbs_file")"
    
    # Initialize known databases file if it doesn't exist
    if [[ ! -f "$known_dbs_file" ]]; then
        get_databases > "$known_dbs_file"
        log_message "Initialized known databases list"
    fi
    
    while true; do
        local current_dbs
        current_dbs=$(get_databases)
        
        # Check for new databases
        echo "$current_dbs" | while read -r db_name; do
            [[ -z "$db_name" ]] && continue
            
            # Skip excluded databases
            if is_excluded_database "$db_name"; then
                continue
            fi
            
            # Check if this is a new database
            if ! grep -q "^$db_name\$" "$known_dbs_file"; then
                log_message "New database detected: $db_name"
                grant_app_access "$db_name"
                echo "$db_name" >> "$known_dbs_file"
            fi
        done
        
        # Update known databases list
        echo "$current_dbs" > "$known_dbs_file"
        
        # Sleep for 30 seconds before next check
        sleep 30
    done
}

# Main function
main() {
    log_message "Starting JIT grants monitor"
    monitor_databases
}

main "$@"
EOF
    
    chmod 755 "$jit_script"
    chown root:root "$jit_script"
}

# Create JIT grants systemd service
create_jit_grants_service() {
    cat > "/etc/systemd/system/harden-mongo-server-jit-grants.service" << EOF
[Unit]
Description=MongoDB Just-in-Time Grants Monitor
After=mongod.service
Requires=mongod.service

[Service]
Type=simple
ExecStart=/usr/local/bin/harden-mongo-server-jit-grants.sh
Restart=on-failure
RestartSec=10
User=root
Group=root

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/log/harden-mongo-server /var/lib/harden-mongo-server

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
}

# Ensure WiredTiger migration is safe
ensure_safe_wiredtiger_migration() {
    info "Ensuring safe WiredTiger migration..."
    
    # Check current storage engine
    local current_engine
    current_engine=$(get_mongodb_storage_engine)
    
    if [[ "$current_engine" == "wiredTiger" ]]; then
        success "WiredTiger already in use"
        return 0
    fi
    
    # Encrypted backup before migration (MVP)
    info "Creating encrypted backup before WiredTiger migration..."
    if ! create_encrypted_backup "all"; then
        error "Failed to create encrypted backup before WiredTiger migration"
        return 1
    fi
    
    # Migration will be handled by configuration change
    warn "WiredTiger migration will occur on next MongoDB restart"
    success "Pre-migration encrypted backup created"
}

# Get MongoDB storage engine
get_mongodb_storage_engine() {
    if command_exists mongo; then
        mongo --eval "print(db.serverStatus().storageEngine.name)" --quiet 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Wait for MongoDB to be ready
wait_for_mongodb_ready() {
    local max_attempts=30
    local attempt=0
    
    while (( attempt < max_attempts )); do
        if mongo --eval "db.adminCommand('ping')" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        (( attempt++ ))
    done
    
    return 1
}

# Execute MongoDB configuration phase for 1.0.0 MVP
execute_mongodb_config_phase() {
    info "Starting MongoDB configuration phase..."
    
    # Ensure safe WiredTiger migration
    if ! ensure_safe_wiredtiger_migration; then
        error "Failed to prepare for WiredTiger migration"
        return 1
    fi
    
    # Generate hardened configuration
    local config_content
    config_content=$(generate_mongodb_hardened_config)

    # Save LKG of current config, then write atomically
    set_last_known_good "$MONGODB_CONFIG_FILE"
    write_config_atomic "$MONGODB_CONFIG_FILE" "$config_content"

    # Apply with graceful reload; validate via configtest; fallback to restart; rollback on failure
    if ! apply_with_graceful_reload \
        "mongod" \
        "systemctl reload mongod" \
        "mongod --config '$MONGODB_CONFIG_FILE' --configtest" \
        "systemctl restart mongod"; then
        warn "Reload/restart failed, rolling back to last-known-good"
        rollback_to_last_known_good "$MONGODB_CONFIG_FILE" || true
        systemctl restart mongod || true
        return 1
    fi
    
    success "MongoDB configuration phase completed"
}

# Set Feature Compatibility Version to installed major.minor
set_feature_compatibility_version() {
    local ver
    ver=$(get_mongodb_version)
    [[ -z "$ver" || "$ver" == "not_installed" ]] && return 1
    local major minor
    IFS='.' read -r major minor _ <<< "$ver"
    local fcv="${major}.${minor}"
    local cmd="db.adminCommand({setFeatureCompatibilityVersion: '$fcv'})"
    mongodb_execute "admin" "$cmd" "" "" "" >/dev/null 2>&1
}

# Validate minimal MongoDB requirements (TLS 1.2+ assumed)
validate_mongodb_requirements() {
    if ! command_exists mongod; then
        error "mongod not found"
        return 1
    fi
    return 0
}

# Execute MongoDB provisioning phase
execute_provision_phase() {
    info "Starting MongoDB provisioning phase..."
    
    # Wait for MongoDB to start with new configuration
    if ! wait_for_mongodb_ready; then
        error "MongoDB is not ready for provisioning"
        return 1
    fi
    
    # Create x509 users
    if ! create_x509_users; then
        error "Failed to create x509 users"
        return 1
    fi

    # Set FCV to current major.minor
    set_feature_compatibility_version || warn "Failed to set FCV"
    
    # Set up just-in-time grants
    if ! setup_just_in_time_grants; then
        error "Failed to setup just-in-time grants"
        return 1
    fi
    
    success "MongoDB provisioning phase completed"
}

# ================================
# Module Information
# ================================

# Module information
mongodb_module_info() {
    cat << EOF
MongoDB Server Hardening MongoDB Library v$HARDEN_MONGO_SERVER_VERSION

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

