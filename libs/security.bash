#!/bin/bash
# =============================================================================
# MongoDB Hardening - Security Library Module
# =============================================================================
# This module provides security hardening functions including:
# - Firewall configuration and management
# - Authentication setup and validation
# - Security checks and vulnerability assessment
# - Access control and permission management
# =============================================================================

# Prevent multiple sourcing
if [[ "${_SECURITY_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly _SECURITY_LIB_LOADED=true

# =============================================================================
# Firewall Configuration
# =============================================================================

# Configure firewall rules for MongoDB
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

# =============================================================================
# Authentication Management
# =============================================================================

# Configure MongoDB authentication
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

# =============================================================================
# Security Validation and Assessment
# =============================================================================

# Perform comprehensive security check
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
        
        # Check SSL configuration
        if grep -q "mode: requireSSL" /etc/mongod.conf; then
            log_and_print "OK" "SSL/TLS is required"
            
            # Check SSL certificate files
            local cert_file=$(grep "PEMKeyFile:" /etc/mongod.conf | awk '{print $2}')
            local ca_file=$(grep "CAFile:" /etc/mongod.conf | awk '{print $2}')
            
            if [ -f "$cert_file" ]; then
                log_and_print "OK" "SSL certificate file exists"
                
                # Check certificate expiry
                local cert_expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)
                if [ -n "$cert_expiry" ]; then
                    log_and_print "INFO" "SSL certificate expires: $cert_expiry"
                    
                    # Check if certificate expires within 30 days
                    local expiry_timestamp=$(date -d "$cert_expiry" +%s 2>/dev/null)
                    local current_timestamp=$(date +%s)
                    local days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))
                    
                    if [ "$days_until_expiry" -lt 30 ]; then
                        log_and_print "WARN" "SSL certificate expires in $days_until_expiry days"
                    fi
                fi
            else
                log_and_print "ERROR" "SSL certificate file not found: $cert_file"
                ((security_issues++))
            fi
            
            if [ -f "$ca_file" ]; then
                log_and_print "OK" "CA certificate file exists"
            else
                log_and_print "ERROR" "CA certificate file not found: $ca_file"
                ((security_issues++))
            fi
            
        else
            log_and_print "ERROR" "SSL/TLS is not required"
            ((security_issues++))
        fi
        
        # Check bind IP
        local bind_ip=$(grep "bindIp:" /etc/mongod.conf | awk '{print $2}')
        if [ "$bind_ip" = "127.0.0.1" ]; then
            log_and_print "OK" "MongoDB bound to localhost only"
        else
            log_and_print "WARN" "MongoDB bind IP: $bind_ip (consider restricting to localhost)"
        fi
        
    else
        log_and_print "ERROR" "MongoDB configuration file missing"
        ((security_issues++))
    fi
    
    # Check file permissions
    if [ -f /etc/mongod.conf ]; then
        local config_perms=$(stat -c "%a" /etc/mongod.conf)
        if [ "$config_perms" = "644" ]; then
            log_and_print "OK" "Configuration file permissions are secure"
        else
            log_and_print "WARN" "Configuration file permissions: $config_perms (should be 644)"
        fi
    fi
    
    if [ -d "$DB_PATH" ]; then
        local db_perms=$(stat -c "%a" "$DB_PATH")
        local db_owner=$(stat -c "%U:%G" "$DB_PATH")
        
        if [ "$db_owner" = "mongodb:mongodb" ]; then
            log_and_print "OK" "Database directory ownership is correct"
        else
            log_and_print "ERROR" "Database directory ownership: $db_owner (should be mongodb:mongodb)"
            ((security_issues++))
        fi
        
        if [ "$db_perms" = "755" ]; then
            log_and_print "OK" "Database directory permissions are secure"
        else
            log_and_print "WARN" "Database directory permissions: $db_perms (should be 755)"
        fi
    fi
    
    # Network connectivity test
    log_and_print "INFO" "Testing network connectivity..."
    if timeout 5 bash -c "</dev/tcp/127.0.0.1/27017" &>/dev/null; then
        log_and_print "OK" "MongoDB is accepting connections on localhost"
    else
        log_and_print "ERROR" "MongoDB is not accepting connections"
        ((security_issues++))
    fi
    
    # Summary
    if [ $security_issues -eq 0 ]; then
        log_and_print "OK" "All security checks passed"
        log_and_print "SECURITY" "MongoDB is properly secured with SSL/TLS encryption and authentication"
    else
        log_and_print "WARN" "$security_issues security issues found that require attention"
    fi
    
    return $security_issues
}

# =============================================================================
# Advanced Security Functions
# =============================================================================

# Check for common security vulnerabilities
check_security_vulnerabilities() {
    log_and_print "INFO" "Checking for security vulnerabilities..."
    
    local vulnerabilities=0
    
    # Check for default passwords
    if [ "$ADMIN_PASS" = "password" ] || [ "$ADMIN_PASS" = "admin" ] || [ "$ADMIN_PASS" = "123456" ]; then
        log_and_print "ERROR" "Using weak default password"
        ((vulnerabilities++))
    fi
    
    # Check for open ports
    local open_ports=$(ss -tuln | grep :27017 | wc -l)
    if [ "$open_ports" -gt 1 ]; then
        log_and_print "WARN" "MongoDB may be listening on multiple interfaces"
    fi
    
    # Check for unnecessary services
    local running_services=$(systemctl list-units --type=service --state=active | wc -l)
    log_and_print "INFO" "Active services count: $running_services"
    
    # Check system updates
    if command -v apt &> /dev/null; then
        local updates=$(apt list --upgradable 2>/dev/null | grep -v "WARNING" | wc -l)
        if [ "$updates" -gt 1 ]; then
            log_and_print "WARN" "$((updates-1)) system updates available"
        fi
    fi
    
    return $vulnerabilities
}

# Validate SSL/TLS configuration
validate_ssl_config() {
    log_and_print "INFO" "Validating SSL/TLS configuration..."
    
    local ssl_issues=0
    
    if [ -n "$MONGO_DOMAIN" ]; then
        # Test SSL connection
        if timeout 10 openssl s_client -connect "127.0.0.1:27017" -servername "$MONGO_DOMAIN" </dev/null &>/dev/null; then
            log_and_print "OK" "SSL connection test successful"
        else
            log_and_print "ERROR" "SSL connection test failed"
            ((ssl_issues++))
        fi
        
        # Check certificate chain
        local le_cert="/etc/letsencrypt/live/$MONGO_DOMAIN/cert.pem"
        if [ -f "$le_cert" ]; then
            if openssl x509 -in "$le_cert" -noout -text | grep -q "$MONGO_DOMAIN"; then
                log_and_print "OK" "SSL certificate matches domain"
            else
                log_and_print "ERROR" "SSL certificate does not match domain"
                ((ssl_issues++))
            fi
        fi
    fi
    
    return $ssl_issues
}

# =============================================================================
# Module Information
# =============================================================================

# Display security module information
security_module_info() {
    echo "Security Library Module - Security hardening functions"
    echo "Provides: firewall, authentication, validation, vulnerability checks"
}