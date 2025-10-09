#!/bin/bash
# =============================================================================
# MongoDB Hardening - Monitoring and Maintenance Library Module
# =============================================================================
# This module provides monitoring, backup, and maintenance functions including:
# - Log rotation and management
# - Monitoring script generation
# - Backup and restore operations
# - Cron job scheduling
# - System status reporting
# =============================================================================

# Prevent multiple sourcing
if [[ "${_MONITORING_LIB_LOADED:-}" == "true" ]]; then
    return 0
fi
readonly _MONITORING_LIB_LOADED=true

# =============================================================================
# Log Management
# =============================================================================

# Set up log rotation for MongoDB
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

# =============================================================================
# Monitoring Scripts Generation
# =============================================================================

# Create monitoring and maintenance scripts
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

# =============================================================================
# Cron Job Management
# =============================================================================

# Set up cron jobs for automated maintenance
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

# =============================================================================
# Backup Operations
# =============================================================================

# Create MongoDB backup
create_backup() {
    print_section "MongoDB Backup"
    
    local backup_name="${1:-mongo-$(date +%F_%T)}"
    local backup_dir="$BACKUP_PATH/$backup_name"
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would create backup '$backup_name'"
        return 0
    fi
    
    log_and_print "INFO" "Creating MongoDB backup: $backup_name"
    
    # Ensure backup directory exists
    mkdir -p "$BACKUP_PATH"
    
    # Create the backup
    if mongodump --out "$backup_dir" --username "$ADMIN_USER" --password "$ADMIN_PASS" --authenticationDatabase admin --quiet; then
        # Compress the backup
        tar -czf "${backup_dir}.tar.gz" -C "$BACKUP_PATH" "$backup_name"
        rm -rf "$backup_dir"
        
        local backup_size=$(du -sh "${backup_dir}.tar.gz" | awk '{print $1}')
        log_and_print "FIXED" "Backup created: ${backup_name}.tar.gz (${backup_size})"
        
        # Clean old backups if retention is set
        if [ -n "$BACKUP_RETENTION_DAYS" ] && [ "$BACKUP_RETENTION_DAYS" -gt 0 ]; then
            local deleted_count=$(find "$BACKUP_PATH" -name "mongo-*.tar.gz" -mtime +$BACKUP_RETENTION_DAYS -delete -print 2>/dev/null | wc -l)
            if [ "$deleted_count" -gt 0 ]; then
                log_and_print "INFO" "Cleaned up $deleted_count old backups"
            fi
        fi
    else
        log_and_print "ERROR" "Backup failed"
        return 1
    fi
}

# Restore MongoDB backup
restore_backup() {
    local backup_file="$1"
    local target_db="${2:-}"
    
    print_section "MongoDB Restore"
    
    if [ -z "$backup_file" ]; then
        log_and_print "ERROR" "Backup file path required"
        return 1
    fi
    
    if [ ! -f "$backup_file" ]; then
        log_and_print "ERROR" "Backup file not found: $backup_file"
        return 1
    fi
    
    if [ "${DRY_RUN:-false}" = true ]; then
        log_and_print "INFO" "DRY RUN: Would restore from '$backup_file'"
        return 0
    fi
    
    log_and_print "INFO" "Restoring MongoDB from backup: $backup_file"
    
    # Extract backup if it's compressed
    local restore_dir="/tmp/mongodb-restore-$$"
    mkdir -p "$restore_dir"
    
    if [[ "$backup_file" == *.tar.gz ]]; then
        tar -xzf "$backup_file" -C "$restore_dir"
    else
        cp -r "$backup_file" "$restore_dir/"
    fi
    
    # Perform the restore
    local restore_cmd="mongorestore"
    if [ -n "$target_db" ]; then
        restore_cmd="$restore_cmd --db $target_db"
    fi
    
    if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
        restore_cmd="$restore_cmd --username $ADMIN_USER --password $ADMIN_PASS --authenticationDatabase admin"
    fi
    
    if $restore_cmd "$restore_dir"/*; then
        log_and_print "FIXED" "MongoDB restore completed successfully"
    else
        log_and_print "ERROR" "MongoDB restore failed"
        rm -rf "$restore_dir"
        return 1
    fi
    
    # Cleanup
    rm -rf "$restore_dir"
}

# List available backups
list_backups() {
    log_and_print "INFO" "Available MongoDB backups:"
    
    if [ -d "$BACKUP_PATH" ]; then
        local backup_count=0
        for backup in "$BACKUP_PATH"/mongo-*.tar.gz; do
            if [ -f "$backup" ]; then
                local backup_name=$(basename "$backup")
                local backup_size=$(du -sh "$backup" | awk '{print $1}')
                local backup_date=$(stat -c %y "$backup" | cut -d' ' -f1,2 | cut -d':' -f1,2)
                echo "  - $backup_name ($backup_size, $backup_date)"
                ((backup_count++))
            fi
        done
        
        if [ $backup_count -eq 0 ]; then
            log_and_print "INFO" "No backups found in $BACKUP_PATH"
        else
            log_and_print "OK" "Found $backup_count backup(s)"
        fi
    else
        log_and_print "WARN" "Backup directory does not exist: $BACKUP_PATH"
    fi
}

# =============================================================================
# Status Reporting
# =============================================================================

# Show comprehensive MongoDB status
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
        if [ $backup_count -gt 0 ]; then
            local latest_backup=$(find "$BACKUP_PATH" -name "mongo-*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
            if [ -n "$latest_backup" ]; then
                local backup_date=$(stat -c %y "$latest_backup" | cut -d' ' -f1)
                log_and_print "INFO" "Latest backup: $(basename "$latest_backup") ($backup_date)"
            fi
        else
            log_and_print "WARN" "No backups found"
        fi
    fi
    
    # Connection test
    if systemctl is-active --quiet mongod; then
        if mongo -u "$ADMIN_USER" -p "$ADMIN_PASS" --authenticationDatabase admin --eval "db.runCommand('ping')" &>/dev/null; then
            log_and_print "OK" "Database connection successful"
        else
            log_and_print "ERROR" "Database connection failed"
        fi
    fi
}

# =============================================================================
# Maintenance Operations
# =============================================================================

# Perform maintenance tasks
perform_maintenance() {
    local maintenance_task="${1:-all}"
    
    print_section "Maintenance Operations"
    
    case "$maintenance_task" in
        "cleanup-logs")
            log_and_print "INFO" "Cleaning up old log files..."
            if [ "${DRY_RUN:-false}" = true ]; then
                log_and_print "INFO" "DRY RUN: Would clean up old log files"
            else
                find /var/log/mongodb/ -type f -name "*.log*" -mtime +7 -delete 2>/dev/null || true
                journalctl --vacuum-time=7d
                log_and_print "FIXED" "Cleaned up old log files"
            fi
            ;;
        "cleanup-backups")
            log_and_print "INFO" "Cleaning up old backup files..."
            if [ "${DRY_RUN:-false}" = true ]; then
                log_and_print "INFO" "DRY RUN: Would clean up old backups"
            else
                local deleted_count=$(find "$BACKUP_PATH" -name "mongo-*.tar.gz" -mtime +$BACKUP_RETENTION_DAYS -delete -print 2>/dev/null | wc -l)
                log_and_print "FIXED" "Cleaned up $deleted_count old backup files"
            fi
            ;;
        "restart")
            log_and_print "INFO" "Restarting MongoDB service..."
            if [ "${DRY_RUN:-false}" = true ]; then
                log_and_print "INFO" "DRY RUN: Would restart MongoDB service"
            else
                systemctl restart mongod
                log_and_print "FIXED" "MongoDB service restarted"
            fi
            ;;
        "security-check")
            perform_security_check
            ;;
        "disk-cleanup")
            log_and_print "INFO" "Performing emergency disk cleanup..."
            if [ "${DRY_RUN:-false}" = true ]; then
                log_and_print "INFO" "DRY RUN: Would perform disk cleanup"
            else
                # Emergency cleanup script
                /usr/local/bin/check_mongo_disk.sh
                apt-get autoremove -y
                apt-get autoclean
                log_and_print "FIXED" "Emergency disk cleanup completed"
            fi
            ;;
        "all")
            perform_maintenance "cleanup-logs"
            perform_maintenance "cleanup-backups"
            perform_maintenance "security-check"
            ;;
        *)
            log_and_print "ERROR" "Unknown maintenance task: $maintenance_task"
            log_and_print "INFO" "Available tasks: cleanup-logs, cleanup-backups, restart, security-check, disk-cleanup, all"
            return 1
            ;;
    esac
}

# Generate execution summary
generate_summary() {
    print_section "Execution Summary"
    
    log_and_print "INFO" "MongoDB Hardening Script v$SCRIPT_VERSION completed"
    log_and_print "INFO" "Execution time: $(date)"
    log_and_print "INFO" "Issues found: $ISSUES_FOUND"
    log_and_print "INFO" "Issues fixed: $ISSUES_FIXED"
    log_and_print "INFO" "Warnings: $WARNINGS"
    
    if [ $ISSUES_FOUND -eq 0 ]; then
        log_and_print "OK" "No issues detected - MongoDB is properly secured"
    elif [ $ISSUES_FIXED -eq $ISSUES_FOUND ]; then
        log_and_print "OK" "All issues have been resolved"
    else
        log_and_print "WARN" "$((ISSUES_FOUND - ISSUES_FIXED)) issues require manual attention"
    fi
    
    # Connection information
    if [ -n "$MONGO_DOMAIN" ] && [ -n "$ADMIN_USER" ]; then
        echo
        log_and_print "SECURITY" "MongoDB is now secured with SSL/TLS encryption"
        log_and_print "EXPLAIN" "Use these connection examples for your applications:"
        echo
        echo "  # With username/password authentication"
        echo "  mongo --ssl \\"
        echo "        --sslPEMKeyFile /etc/mongoCA/clients/app1.pem \\"
        echo "        --sslCAFile /etc/mongoCA/ca.pem \\"
        echo "        --host $MONGO_DOMAIN:27017 \\"
        echo "        -u $ADMIN_USER -p 'your-password' \\"
        echo "        --authenticationDatabase admin"
        echo
        echo "  # Connection string format:"
        echo "  mongodb://$ADMIN_USER:password@$MONGO_DOMAIN:27017/database?ssl=true&authSource=admin"
        echo
    fi
}

# =============================================================================
# Module Information
# =============================================================================

# Display monitoring module information
monitoring_module_info() {
    echo "Monitoring Library Module - Monitoring and maintenance functions"
    echo "Provides: log rotation, monitoring scripts, backups, cron jobs, status reporting"
}