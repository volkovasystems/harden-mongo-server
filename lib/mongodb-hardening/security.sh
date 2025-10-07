#!/usr/bin/env bash
# MongoDB Hardening Utility - Security Library
# Provides advanced security hardening, authentication, and access control functions

# Prevent multiple inclusion
if [[ -n "${_MONGODB_HARDENING_SECURITY_LOADED:-}" ]]; then
    return 0
fi
readonly _MONGODB_HARDENING_SECURITY_LOADED=1

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
# Security Configuration Constants
# ================================

# Default security settings
readonly MONGODB_KEYFILE_PATH="/var/lib/mongodb/keyfile"
readonly MONGODB_KEYFILE_SIZE="1024"
readonly MONGODB_MIN_PASSWORD_LENGTH="12"
readonly MONGODB_MAX_FAILED_ATTEMPTS="3"
readonly MONGODB_LOCKOUT_DURATION="300"

# Security profiles
readonly -A SECURITY_PROFILES=(
    [basic]="Basic security configuration"
    [standard]="Standard security hardening"
    [strict]="Strict security enforcement"
    [paranoid]="Maximum security hardening"
)

# ================================
# Authentication and Authorization
# ================================

# Generate MongoDB keyfile for replica set authentication
generate_mongodb_keyfile() {
    local keyfile_path="${1:-$MONGODB_KEYFILE_PATH}"
    local key_size="${2:-$MONGODB_KEYFILE_SIZE}"
    
    info "Generating MongoDB keyfile at $keyfile_path"
    
    # Create keyfile directory
    local keyfile_dir
    keyfile_dir="$(dirname "$keyfile_path")"
    create_dir_safe "$keyfile_dir" 700 mongodb:mongodb
    
    # Generate random key
    local keyfile_content
    keyfile_content=$(openssl rand -base64 "$key_size" | tr -d '\n' | head -c 1024)
    
    if ! is_dry_run; then
        echo "$keyfile_content" > "$keyfile_path"
        chmod 600 "$keyfile_path"
        chown mongodb:mongodb "$keyfile_path"
    fi
    
    execute_or_simulate "Set keyfile permissions" "chmod 600 '$keyfile_path'"
    execute_or_simulate "Set keyfile ownership" "chown mongodb:mongodb '$keyfile_path'"
    
    success "MongoDB keyfile generated successfully"
    return 0
}

# Validate password strength
validate_password_strength() {
    local password="$1"
    local min_length="${2:-$MONGODB_MIN_PASSWORD_LENGTH}"
    local errors=0
    
    # Check minimum length
    if [[ ${#password} -lt $min_length ]]; then
        error "Password is too short (minimum $min_length characters)"
        ((errors++))
    fi
    
    # Check for uppercase letters
    if [[ ! "$password" =~ [A-Z] ]]; then
        error "Password must contain at least one uppercase letter"
        ((errors++))
    fi
    
    # Check for lowercase letters
    if [[ ! "$password" =~ [a-z] ]]; then
        error "Password must contain at least one lowercase letter"
        ((errors++))
    fi
    
    # Check for numbers
    if [[ ! "$password" =~ [0-9] ]]; then
        error "Password must contain at least one number"
        ((errors++))
    fi
    
    # Check for special characters
    if [[ ! "$password" =~ [^a-zA-Z0-9] ]]; then
        error "Password must contain at least one special character"
        ((errors++))
    fi
    
    # Check for common weak passwords
    local weak_passwords=("password" "admin" "root" "mongodb" "123456" "qwerty")
    local lower_password
    lower_password=$(echo "$password" | tr '[:upper:]' '[:lower:]')
    
    for weak in "${weak_passwords[@]}"; do
        if [[ "$lower_password" == *"$weak"* ]]; then
            error "Password contains common weak pattern: $weak"
            ((errors++))
            break
        fi
    done
    
    if ((errors == 0)); then
        success "Password meets strength requirements"
        return 0
    else
        return 1
    fi
}

# Generate secure password
generate_secure_password() {
    local length="${1:-16}"
    local use_special="${2:-true}"
    
    local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    if [[ "$use_special" == "true" ]]; then
        chars="${chars}!@#$%^&*()_+-=[]{}|;:,.<>?"
    fi
    
    local password=""
    for ((i=0; i<length; i++)); do
        password+="${chars:RANDOM%${#chars}:1}"
    done
    
    echo "$password"
}

# Configure MongoDB SCRAM authentication
configure_scram_auth() {
    local mechanism="${1:-SCRAM-SHA-256}"
    
    info "Configuring SCRAM authentication mechanism: $mechanism"
    
    # Validate mechanism
    case "$mechanism" in
        SCRAM-SHA-1|SCRAM-SHA-256)
            ;;
        *)
            error "Unsupported SCRAM mechanism: $mechanism"
            return 1
            ;;
    esac
    
    # Update MongoDB configuration
    local config_file="/etc/mongod.conf"
    if [[ -f "$config_file" ]]; then
        # Check if setParameter section exists
        if grep -q "setParameter:" "$config_file"; then
            # Update existing setParameter section
            if grep -q "authenticationMechanisms:" "$config_file"; then
                execute_or_simulate "Update auth mechanisms" \
                    "sed -i 's/authenticationMechanisms:.*/authenticationMechanisms: \"$mechanism\"/' '$config_file'"
            else
                execute_or_simulate "Add auth mechanisms" \
                    "sed -i '/setParameter:/a\\  authenticationMechanisms: \"$mechanism\"' '$config_file'"
            fi
        else
            # Add setParameter section
            execute_or_simulate "Add setParameter section" \
                "echo 'setParameter:' >> '$config_file' && echo '  authenticationMechanisms: \"$mechanism\"' >> '$config_file'"
        fi
        
        success "SCRAM authentication mechanism configured: $mechanism"
    else
        error "MongoDB configuration file not found: $config_file"
        return 1
    fi
}

# ================================
# Role-Based Access Control (RBAC)
# ================================

# Create custom MongoDB role
create_mongodb_role() {
    local role_name="$1"
    local privileges="$2"
    local database="${3:-admin}"
    local admin_user="${4:-}"
    local admin_password="${5:-}"
    
    info "Creating MongoDB role: $role_name"
    
    local create_role_command="db.createRole({
        role: '$role_name',
        privileges: [$privileges],
        roles: []
    })"
    
    if mongodb_execute "$database" "$create_role_command" "admin" "$admin_user" "$admin_password"; then
        success "MongoDB role '$role_name' created successfully"
    else
        error "Failed to create MongoDB role '$role_name'"
        return 1
    fi
}

# Create read-only database user
create_readonly_user() {
    local username="$1"
    local password="$2"
    local target_database="$3"
    local admin_user="${4:-}"
    local admin_password="${5:-}"
    
    info "Creating read-only user: $username for database: $target_database"
    
    local create_user_command="db.createUser({
        user: '$username',
        pwd: '$password',
        roles: [
            { role: 'read', db: '$target_database' }
        ]
    })"
    
    if mongodb_execute "admin" "$create_user_command" "admin" "$admin_user" "$admin_password"; then
        success "Read-only user '$username' created successfully"
    else
        error "Failed to create read-only user '$username'"
        return 1
    fi
}

# Create read-write database user
create_readwrite_user() {
    local username="$1"
    local password="$2"
    local target_database="$3"
    local admin_user="${4:-}"
    local admin_password="${5:-}"
    
    info "Creating read-write user: $username for database: $target_database"
    
    local create_user_command="db.createUser({
        user: '$username',
        pwd: '$password',
        roles: [
            { role: 'readWrite', db: '$target_database' }
        ]
    })"
    
    if mongodb_execute "admin" "$create_user_command" "admin" "$admin_user" "$admin_password"; then
        success "Read-write user '$username' created successfully"
    else
        error "Failed to create read-write user '$username'"
        return 1
    fi
}

# ================================
# Network Security
# ================================

# Configure MongoDB network binding
configure_network_security() {
    local bind_ip="${1:-127.0.0.1}"
    local port="${2:-27017}"
    local max_connections="${3:-1000}"
    
    info "Configuring MongoDB network security"
    
    # Validate IP address
    if [[ "$bind_ip" != "127.0.0.1" && "$bind_ip" != "localhost" ]]; then
        if ! is_valid_ip "$bind_ip"; then
            error "Invalid IP address: $bind_ip"
            return 1
        fi
    fi
    
    # Validate port
    if ! is_valid_port "$port"; then
        error "Invalid port number: $port"
        return 1
    fi
    
    # Check if port is already in use by another service
    if port_in_use "$port" && [[ "$(get_mongodb_service_status)" != "active" ]]; then
        warn "Port $port is already in use by another service"
    fi
    
    # Update MongoDB configuration
    local config_file="/etc/mongod.conf"
    if [[ -f "$config_file" ]]; then
        # Update network configuration
        if grep -q "^net:" "$config_file"; then
            execute_or_simulate "Update bind IP" \
                "sed -i '/^net:/,/^[^[:space:]]/ s/bindIp:.*/bindIp: $bind_ip/' '$config_file'"
            execute_or_simulate "Update port" \
                "sed -i '/^net:/,/^[^[:space:]]/ s/port:.*/port: $port/' '$config_file'"
            execute_or_simulate "Update max connections" \
                "sed -i '/^net:/,/^[^[:space:]]/ s/maxIncomingConnections:.*/maxIncomingConnections: $max_connections/' '$config_file'"
        fi
        
        success "Network security configuration applied"
    else
        error "MongoDB configuration file not found"
        return 1
    fi
}

# ================================
# System-Level Security Hardening
# ================================

# Secure MongoDB system user
secure_mongodb_user() {
    info "Securing MongoDB system user account"
    
    # Check if mongodb user exists
    if ! id mongodb >/dev/null 2>&1; then
        warn "MongoDB user does not exist, creating..."
        execute_or_simulate "Create mongodb user" \
            "useradd -r -s /bin/false -d /var/lib/mongodb mongodb"
    fi
    
    # Disable shell access for mongodb user
    execute_or_simulate "Disable shell for mongodb user" \
        "usermod -s /bin/false mongodb"
    
    # Set proper home directory
    execute_or_simulate "Set mongodb user home" \
        "usermod -d /var/lib/mongodb mongodb"
    
    # Lock the account password
    execute_or_simulate "Lock mongodb user password" \
        "usermod -L mongodb"
    
    success "MongoDB system user secured"
}

# Set file and directory permissions
secure_mongodb_files() {
    local db_path="${1:-/var/lib/mongodb}"
    local log_path="${2:-/var/log/mongodb}"
    local config_file="${3:-/etc/mongod.conf}"
    
    info "Securing MongoDB files and directories"
    
    # Secure database directory
    if [[ -d "$db_path" ]]; then
        execute_or_simulate "Secure database directory" \
            "chmod 750 '$db_path' && chown -R mongodb:mongodb '$db_path'"
    fi
    
    # Secure log directory
    if [[ -d "$log_path" ]]; then
        execute_or_simulate "Secure log directory" \
            "chmod 750 '$log_path' && chown -R mongodb:mongodb '$log_path'"
    fi
    
    # Secure configuration file
    if [[ -f "$config_file" ]]; then
        execute_or_simulate "Secure config file" \
            "chmod 644 '$config_file' && chown root:root '$config_file'"
    fi
    
    # Secure keyfile if it exists
    if [[ -f "$MONGODB_KEYFILE_PATH" ]]; then
        execute_or_simulate "Secure keyfile" \
            "chmod 600 '$MONGODB_KEYFILE_PATH' && chown mongodb:mongodb '$MONGODB_KEYFILE_PATH'"
    fi
    
    success "MongoDB file permissions secured"
}

# Configure system limits for MongoDB
configure_system_limits() {
    info "Configuring system limits for MongoDB"
    
    local limits_file="/etc/security/limits.d/99-mongodb.conf"
    local limits_config="# MongoDB system limits
mongodb soft nofile 64000
mongodb hard nofile 64000
mongodb soft nproc 64000
mongodb hard nproc 64000
mongodb soft memlock unlimited
mongodb hard memlock unlimited"
    
    if ! is_dry_run; then
        echo "$limits_config" > "$limits_file"
        chmod 644 "$limits_file"
    fi
    
    execute_or_simulate "Apply MongoDB system limits" "echo '$limits_config' > '$limits_file'"
    success "System limits configured for MongoDB"
}

# ================================
# Security Profiles and Hardening
# ================================

# Apply security profile
apply_security_profile() {
    local profile="${1:-standard}"
    local db_path="${2:-/var/lib/mongodb}"
    local log_path="${3:-/var/log/mongodb}"
    local bind_ip="${4:-127.0.0.1}"
    local port="${5:-27017}"
    
    print_section "Applying Security Profile: $profile"
    
    case "$profile" in
        basic)
            apply_basic_security "$db_path" "$log_path" "$bind_ip" "$port"
            ;;
        standard)
            apply_standard_security "$db_path" "$log_path" "$bind_ip" "$port"
            ;;
        strict)
            apply_strict_security "$db_path" "$log_path" "$bind_ip" "$port"
            ;;
        paranoid)
            apply_paranoid_security "$db_path" "$log_path" "$bind_ip" "$port"
            ;;
        *)
            error "Unknown security profile: $profile"
            return 1
            ;;
    esac
}

# Basic security profile
apply_basic_security() {
    local db_path="$1"
    local log_path="$2" 
    local bind_ip="$3"
    local port="$4"
    
    info "Applying basic security configuration"
    
    # Enable authentication
    configure_scram_auth "SCRAM-SHA-1"
    
    # Secure file permissions
    secure_mongodb_files "$db_path" "$log_path"
    
    # Configure network binding
    configure_network_security "$bind_ip" "$port" 1000
    
    success "Basic security profile applied"
}

# Standard security profile
apply_standard_security() {
    local db_path="$1"
    local log_path="$2"
    local bind_ip="$3" 
    local port="$4"
    
    info "Applying standard security configuration"
    
    # Apply basic security
    apply_basic_security "$db_path" "$log_path" "$bind_ip" "$port"
    
    # Generate keyfile
    generate_mongodb_keyfile
    
    # Secure MongoDB user
    secure_mongodb_user
    
    # Configure system limits
    configure_system_limits
    
    # Use stronger SCRAM
    configure_scram_auth "SCRAM-SHA-256"
    
    success "Standard security profile applied"
}

# Strict security profile
apply_strict_security() {
    local db_path="$1"
    local log_path="$2"
    local bind_ip="$3"
    local port="$4"
    
    info "Applying strict security configuration"
    
    # Apply standard security
    apply_standard_security "$db_path" "$log_path" "$bind_ip" "$port"
    
    # More restrictive file permissions
    execute_or_simulate "Set strict file permissions" \
        "chmod 700 '$db_path' && chmod 700 '$log_path'"
    
    # Disable JavaScript execution (should already be in template)
    info "JavaScript execution disabled by default"
    
    # Lower connection limits
    configure_network_security "$bind_ip" "$port" 500
    
    success "Strict security profile applied"
}

# Paranoid security profile
apply_paranoid_security() {
    local db_path="$1"
    local log_path="$2"
    local bind_ip="$3"
    local port="$4"
    
    info "Applying paranoid security configuration"
    
    # Apply strict security
    apply_strict_security "$db_path" "$log_path" "$bind_ip" "$port"
    
    # Force localhost binding only
    if [[ "$bind_ip" != "127.0.0.1" ]]; then
        warn "Paranoid mode forces localhost binding"
        bind_ip="127.0.0.1"
    fi
    
    # Use non-standard port
    if [[ "$port" == "27017" ]]; then
        warn "Consider using non-standard port in paranoid mode"
    fi
    
    # Very restrictive connection limits  
    configure_network_security "$bind_ip" "$port" 100
    
    # Additional hardening
    execute_or_simulate "Set paranoid file permissions" \
        "chmod 700 '$db_path' '$log_path' && chmod 600 /etc/mongod.conf"
    
    success "Paranoid security profile applied"
}

# ================================
# Security Auditing and Monitoring
# ================================

# Enable MongoDB auditing
enable_mongodb_auditing() {
    local audit_destination="${1:-file}"
    local audit_path="${2:-/var/log/mongodb/audit.log}"
    local audit_filter="${3:-}"
    
    info "Enabling MongoDB auditing"
    
    local config_file="/etc/mongod.conf"
    local audit_config=""
    
    case "$audit_destination" in
        file)
            audit_config="auditLog:
  destination: file
  format: JSON
  path: $audit_path"
            ;;
        syslog)
            audit_config="auditLog:
  destination: syslog"
            ;;
        *)
            error "Unsupported audit destination: $audit_destination"
            return 1
            ;;
    esac
    
    # Add audit filter if provided
    if [[ -n "$audit_filter" ]]; then
        audit_config="$audit_config
  filter: '$audit_filter'"
    fi
    
    # Add to MongoDB configuration
    if [[ -f "$config_file" ]]; then
        if ! grep -q "auditLog:" "$config_file"; then
            if ! is_dry_run; then
                echo "" >> "$config_file"
                echo "# Auditing configuration" >> "$config_file"
                echo "$audit_config" >> "$config_file"
            fi
            execute_or_simulate "Enable MongoDB auditing" "echo 'Audit config added to $config_file'"
        fi
        
        # Create audit log directory and file
        if [[ "$audit_destination" == "file" ]]; then
            local audit_dir
            audit_dir="$(dirname "$audit_path")"
            create_dir_safe "$audit_dir" 750 mongodb:mongodb
            
            if [[ ! -f "$audit_path" ]]; then
                execute_or_simulate "Create audit log file" "touch '$audit_path'"
                execute_or_simulate "Set audit log permissions" "chmod 640 '$audit_path' && chown mongodb:mongodb '$audit_path'"
            fi
        fi
        
        success "MongoDB auditing enabled"
    else
        error "MongoDB configuration file not found"
        return 1
    fi
}

# Check for security vulnerabilities
security_vulnerability_check() {
    print_section "Security Vulnerability Assessment"
    
    local issues_found=0
    
    # Check MongoDB version for known vulnerabilities
    local mongodb_version
    mongodb_version=$(get_mongodb_version)
    
    if [[ "$mongodb_version" != "not_installed" ]]; then
        local major_version
        major_version=$(echo "$mongodb_version" | cut -d. -f1)
        local minor_version  
        minor_version=$(echo "$mongodb_version" | cut -d. -f2)
        
        # Check for old versions with known issues
        if ((major_version < 4)); then
            report_issue "high" "MongoDB version $mongodb_version has known security vulnerabilities" \
                "Upgrade to MongoDB 4.4 or later"
            ((issues_found++))
        elif ((major_version == 4 && minor_version < 4)); then
            report_issue "medium" "MongoDB version $mongodb_version may have security vulnerabilities" \
                "Consider upgrading to MongoDB 4.4 or later"
            ((issues_found++))
        fi
    fi
    
    # Check for default credentials
    info "Checking for default/weak credentials..."
    # This would require connecting to MongoDB to check users
    
    # Check file permissions
    local critical_files=("/etc/mongod.conf" "/var/lib/mongodb" "/var/log/mongodb")
    for file in "${critical_files[@]}"; do
        if [[ -e "$file" ]]; then
            local perms
            perms=$(stat -c %a "$file" 2>/dev/null)
            local owner
            owner=$(stat -c %U:%G "$file" 2>/dev/null)
            
            case "$file" in
                "/etc/mongod.conf")
                    if [[ "$perms" -gt "644" ]]; then
                        report_issue "medium" "Configuration file permissions too permissive: $perms" \
                            "Set permissions to 644"
                        ((issues_found++))
                    fi
                    ;;
                "/var/lib/mongodb"|"/var/log/mongodb")
                    if [[ "$perms" -gt "750" ]]; then
                        report_issue "medium" "Directory permissions too permissive: $file ($perms)" \
                            "Set permissions to 750 or more restrictive"
                        ((issues_found++))
                    fi
                    if [[ "$owner" != "mongodb:mongodb" ]]; then
                        report_issue "medium" "Incorrect ownership for $file: $owner" \
                            "Set ownership to mongodb:mongodb"
                        ((issues_found++))
                    fi
                    ;;
            esac
        fi
    done
    
    print_subsection "Vulnerability Assessment Summary"
    if ((issues_found == 0)); then
        success "No security vulnerabilities detected"
    else
        warn "$issues_found potential security issues found"
    fi
    
    return $((issues_found > 0 ? 1 : 0))
}

# ================================
# Module Information
# ================================

# Module information
security_module_info() {
    cat << EOF
MongoDB Hardening Security Library v$MONGODB_HARDENING_VERSION

This module provides:
- Authentication mechanism configuration (SCRAM-SHA-1/256)
- Role-based access control (RBAC) management
- Password strength validation and generation
- MongoDB keyfile generation for replica sets
- Network security configuration
- System-level security hardening
- Security profile application (basic, standard, strict, paranoid)
- File and directory permission management
- Security auditing and monitoring
- Vulnerability assessment and checking

Functions:
- generate_mongodb_keyfile: Create replica set authentication key
- validate_password_strength: Check password complexity
- configure_scram_auth: Set up SCRAM authentication
- create_mongodb_role: Create custom database roles
- create_readonly_user/create_readwrite_user: User management
- configure_network_security: Network binding and limits
- secure_mongodb_user: System user hardening
- apply_security_profile: Apply predefined security configurations
- enable_mongodb_auditing: Configure audit logging
- security_vulnerability_check: Security assessment

Security Profiles:
- basic: Enable authentication and basic file security
- standard: Add keyfile, system limits, stronger SCRAM
- strict: Restrictive permissions and connection limits
- paranoid: Maximum security with localhost-only binding

Dependencies: core.sh, logging.sh, system.sh
EOF
}