#!/bin/bash

# Fail-safe and Auto-restart Library Module
# Provides comprehensive recovery, monitoring, and auto-restart capabilities

# Prevent multiple sourcing
[[ "${BASH_SOURCE[0]}" != "${0}" ]] || { echo "This script should be sourced, not executed directly."; exit 1; }
[[ -n "${FAILSAFE_LIB_LOADED:-}" ]] && return 0
readonly FAILSAFE_LIB_LOADED=1

# Module information
failsafe_lib_info() {
    echo "Fail-safe and Auto-restart Library - Comprehensive recovery and monitoring system"
}

# Configuration
readonly FAILSAFE_DIR="/var/lib/mongodb-hardening"
readonly STATE_FILE="${FAILSAFE_DIR}/hardening-state.json"
readonly LOCKFILE="${FAILSAFE_DIR}/hardening.lock"
readonly RECOVERY_LOG="${FAILSAFE_DIR}/recovery.log"
readonly WATCHDOG_SCRIPT="${FAILSAFE_DIR}/mongodb-watchdog.sh"
readonly HEALTH_CHECK_SCRIPT="${FAILSAFE_DIR}/health-check.sh"
readonly RECOVERY_SCRIPT="${FAILSAFE_DIR}/auto-recovery.sh"

# Process states
declare -A PROCESS_STATES=(
    ["NOT_STARTED"]="0"
    ["IN_PROGRESS"]="1"
    ["COMPLETED"]="2"
    ["FAILED"]="3"
    ["INTERRUPTED"]="4"
)

# Initialize fail-safe system
init_failsafe_system() {
    log_info "Initializing fail-safe system..."
    
    # Create directories
    mkdir -p "$FAILSAFE_DIR"
    mkdir -p "$(dirname "$RECOVERY_LOG")"
    
    # Set proper permissions
    chmod 755 "$FAILSAFE_DIR"
    touch "$RECOVERY_LOG"
    chmod 644 "$RECOVERY_LOG"
    
    # Initialize state file if it doesn't exist
    if [[ ! -f "$STATE_FILE" ]]; then
        create_initial_state
    fi
    
    # Set up signal handlers
    setup_signal_handlers
    
    # Create watchdog, health check, recovery, and rollback scripts
    create_watchdog_script
    create_health_check_script
    create_recovery_script
    create_rollback_script
    
    log_info "Fail-safe system initialized"
}

# Create initial state file
create_initial_state() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat > "$STATE_FILE" << EOF
{
    "version": "1.0",
    "created": "$timestamp",
    "last_updated": "$timestamp",
    "current_step": "initialization",
    "total_steps": 0,
    "completed_steps": [],
    "failed_steps": [],
    "interrupted_steps": [],
    "process_id": null,
    "session_id": "$(uuidgen 2>/dev/null || date +%s)",
    "recovery_enabled": true,
    "services": {
        "mongodb": {
            "status": "unknown",
            "last_check": null,
            "restart_count": 0,
            "max_restarts": 5
        },
        "monitoring": {
            "status": "unknown",
            "last_check": null,
            "processes": []
        },
        "cron_jobs": {
            "status": "unknown",
            "last_check": null,
            "jobs": []
        }
    },
    "rollback_points": []
}
EOF
}

# Set up signal handlers for graceful shutdown
setup_signal_handlers() {
    trap 'handle_interruption SIGINT' INT
    trap 'handle_interruption SIGTERM' TERM
    trap 'handle_interruption SIGHUP' HUP
    trap 'cleanup_on_exit' EXIT
}

# Handle interruption signals
handle_interruption() {
    local signal="$1"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    log_warning "Received $signal signal, saving state for recovery..."
    
    # Update state with interruption
    update_state "interrupted" "$signal interruption at $timestamp"
    
    # Save current progress
    save_recovery_point "interrupted_by_$signal"
    
    # Log interruption
    echo "[$(date)] INTERRUPTED: Signal $signal received, state saved" >> "$RECOVERY_LOG"
    
    # Clean shutdown
    log_info "State saved. Run the script again to resume from where it left off."
    exit 130
}

# Cleanup on exit
cleanup_on_exit() {
    if [[ -f "$LOCKFILE" ]]; then
        rm -f "$LOCKFILE"
    fi
}

# Check if recovery is needed
check_for_recovery() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 1
    fi
    
    local current_step=$(jq -r '.current_step' "$STATE_FILE" 2>/dev/null)
    local interrupted_steps=$(jq -r '.interrupted_steps | length' "$STATE_FILE" 2>/dev/null)
    local failed_steps=$(jq -r '.failed_steps | length' "$STATE_FILE" 2>/dev/null)
    
    # Check if there are incomplete steps
    if [[ "$interrupted_steps" != "0" ]] || [[ "$failed_steps" != "0" ]] || [[ "$current_step" != "completed" ]]; then
        return 0  # Recovery needed
    fi
    
    return 1  # No recovery needed
}

# Attempt automatic recovery
attempt_recovery() {
    log_info "Attempting automatic recovery..."
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$(date)] RECOVERY: Starting automatic recovery process" >> "$RECOVERY_LOG"
    
    # Check what needs recovery
    recover_mongodb_service
    recover_monitoring_processes
    recover_cron_jobs
    recover_hardening_process
    
    log_info "Recovery attempt completed"
}

# Recover MongoDB service
recover_mongodb_service() {
    log_info "Checking MongoDB service status..."
    
    local mongodb_status="unknown"
    
    if systemctl is-active --quiet mongod; then
        mongodb_status="active"
        log_info "MongoDB service is running"
    elif systemctl is-enabled --quiet mongod; then
        log_warning "MongoDB service is enabled but not running, attempting restart..."
        if systemctl start mongod; then
            mongodb_status="recovered"
            log_info "MongoDB service successfully restarted"
        else
            mongodb_status="failed"
            log_error "Failed to restart MongoDB service"
        fi
    else
        mongodb_status="not_configured"
        log_warning "MongoDB service is not properly configured"
    fi
    
    # Update state
    update_service_state "mongodb" "$mongodb_status"
}

# Recover monitoring processes
recover_monitoring_processes() {
    log_info "Checking monitoring processes..."
    
    local monitoring_processes=()
    local recovered_count=0
    
    # Check for existing monitoring processes
    if pgrep -f "mongodb-watchdog" >/dev/null; then
        monitoring_processes+=("watchdog:running")
    else
        log_warning "MongoDB watchdog not running, starting..."
        if start_watchdog_service; then
            monitoring_processes+=("watchdog:recovered")
            ((recovered_count++))
        else
            monitoring_processes+=("watchdog:failed")
        fi
    fi
    
    # Check health check process
    if pgrep -f "health-check" >/dev/null; then
        monitoring_processes+=("health-check:running")
    else
        log_warning "Health check not running, starting..."
        if start_health_check_service; then
            monitoring_processes+=("health-check:recovered")
            ((recovered_count++))
        else
            monitoring_processes+=("health-check:failed")
        fi
    fi
    
    # Update monitoring state
    local status="active"
    if [[ $recovered_count -gt 0 ]]; then
        status="recovered"
    fi
    
    update_service_state "monitoring" "$status" "${monitoring_processes[@]}"
}

# Recover cron jobs
recover_cron_jobs() {
    log_info "Checking cron jobs..."
    
    local cron_jobs=()
    local missing_jobs=()
    
    # Define expected cron jobs
    local expected_jobs=(
        "mongodb-backup"
        "mongodb-maintenance"
        "ssl-certificate-renewal"
        "security-audit"
        "log-rotation"
    )
    
    # Check each expected job
    for job in "${expected_jobs[@]}"; do
        if crontab -l 2>/dev/null | grep -q "$job"; then
            cron_jobs+=("$job:present")
        else
            cron_jobs+=("$job:missing")
            missing_jobs+=("$job")
        fi
    done
    
    # Restore missing cron jobs
    if [[ ${#missing_jobs[@]} -gt 0 ]]; then
        log_warning "Found ${#missing_jobs[@]} missing cron jobs, attempting restoration..."
        restore_cron_jobs "${missing_jobs[@]}"
    fi
    
    update_service_state "cron_jobs" "checked" "${cron_jobs[@]}"
}

# Recover hardening process
recover_hardening_process() {
    if [[ ! -f "$STATE_FILE" ]]; then
        return 0
    fi
    
    local interrupted_steps=$(jq -r '.interrupted_steps[]' "$STATE_FILE" 2>/dev/null)
    local failed_steps=$(jq -r '.failed_steps[]' "$STATE_FILE" 2>/dev/null)
    
    if [[ -n "$interrupted_steps" ]] || [[ -n "$failed_steps" ]]; then
        log_info "Found incomplete hardening steps, manual intervention may be required"
        echo "[$(date)] RECOVERY: Incomplete hardening steps detected" >> "$RECOVERY_LOG"
        
        # Log details for manual review
        if [[ -n "$interrupted_steps" ]]; then
            log_warning "Interrupted steps: $interrupted_steps"
        fi
        if [[ -n "$failed_steps" ]]; then
            log_error "Failed steps: $failed_steps"
        fi
    fi
}

# Update service state in state file
update_service_state() {
    local service="$1"
    local status="$2"
    shift 2
    local additional_info=("$@")
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Create temporary file for jq update
    local temp_file=$(mktemp)
    
    # Update service state
    jq ".services[\"$service\"].status = \"$status\" | 
        .services[\"$service\"].last_check = \"$timestamp\"" "$STATE_FILE" > "$temp_file"
    
    # Add additional info if provided
    if [[ ${#additional_info[@]} -gt 0 ]]; then
        local info_json=$(printf '%s\n' "${additional_info[@]}" | jq -R -s -c 'split("\n")[:-1]')
        jq ".services[\"$service\"].processes = $info_json" "$temp_file" > "${temp_file}.tmp"
        mv "${temp_file}.tmp" "$temp_file"
    fi
    
    mv "$temp_file" "$STATE_FILE"
}

# Create watchdog script
create_watchdog_script() {
    cat > "$WATCHDOG_SCRIPT" << 'EOF'
#!/bin/bash

# MongoDB Watchdog - Monitors and restarts MongoDB if needed
LOCKFILE="/var/lib/mongodb-hardening/watchdog.lock"
LOGFILE="/var/lib/mongodb-hardening/watchdog.log"
MAX_RESTARTS=5
RESTART_COUNT=0

log_message() {
    echo "[$(date)] $*" >> "$LOGFILE"
}

check_mongodb() {
    if systemctl is-active --quiet mongod; then
        return 0
    else
        return 1
    fi
}

restart_mongodb() {
    if [[ $RESTART_COUNT -ge $MAX_RESTARTS ]]; then
        log_message "ERROR: Maximum restart attempts ($MAX_RESTARTS) reached"
        return 1
    fi
    
    log_message "Attempting to restart MongoDB (attempt $((RESTART_COUNT + 1))/$MAX_RESTARTS)"
    
    if systemctl restart mongod; then
        log_message "MongoDB successfully restarted"
        ((RESTART_COUNT++))
        return 0
    else
        log_message "Failed to restart MongoDB"
        ((RESTART_COUNT++))
        return 1
    fi
}

# Main watchdog loop
while true; do
    if [[ -f "$LOCKFILE" ]]; then
        other_pid=$(cat "$LOCKFILE")
        if kill -0 "$other_pid" 2>/dev/null; then
            log_message "Another watchdog instance is running (PID: $other_pid)"
            exit 1
        fi
    fi
    
    echo $$ > "$LOCKFILE"
    
    if ! check_mongodb; then
        log_message "MongoDB is not running, attempting restart..."
        restart_mongodb
    fi
    
    sleep 60  # Check every minute
done
EOF
    
    chmod +x "$WATCHDOG_SCRIPT"
}

# Create health check script
create_health_check_script() {
    cat > "$HEALTH_CHECK_SCRIPT" << 'EOF'
#!/bin/bash

# MongoDB Health Check Script
LOGFILE="/var/lib/mongodb-hardening/health-check.log"
STATE_FILE="/var/lib/mongodb-hardening/hardening-state.json"

log_message() {
    echo "[$(date)] $*" >> "$LOGFILE"
}

check_mongodb_health() {
    local status="healthy"
    
    # Check if service is running
    if ! systemctl is-active --quiet mongod; then
        status="service_down"
        log_message "HEALTH: MongoDB service is not running"
        return 1
    fi
    
    # Check if MongoDB is responding
    if ! timeout 10 mongo --quiet --eval "db.runCommand('ping')" >/dev/null 2>&1; then
        status="not_responding"
        log_message "HEALTH: MongoDB is not responding to ping"
        return 1
    fi
    
    # Check disk space
    local disk_usage=$(df /var/lib/mongodb | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        status="disk_full"
        log_message "HEALTH: Disk usage is at ${disk_usage}%"
        return 1
    fi
    
    # Check memory usage
    local memory_usage=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}')
    if [[ $memory_usage -gt 95 ]]; then
        status="memory_high"
        log_message "HEALTH: Memory usage is at ${memory_usage}%"
        return 1
    fi
    
    log_message "HEALTH: All checks passed"
    return 0
}

# Update health status in state file
update_health_status() {
    local status="$1"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    if [[ -f "$STATE_FILE" ]]; then
        jq ".services.mongodb.health_status = \"$status\" | 
            .services.mongodb.health_check = \"$timestamp\"" "$STATE_FILE" > "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
}

# Main health check
if check_mongodb_health; then
    update_health_status "healthy"
    exit 0
else
    update_health_status "unhealthy"
    exit 1
fi
EOF
    
    chmod +x "$HEALTH_CHECK_SCRIPT"
}

# Create auto-recovery script
create_recovery_script() {
    cat > "$RECOVERY_SCRIPT" << 'EOF'
#!/bin/bash

# Auto-recovery script for MongoDB hardening system
RECOVERY_LOG="/var/lib/mongodb-hardening/recovery.log"
WATCHDOG_SCRIPT="/var/lib/mongodb-hardening/mongodb-watchdog.sh"
HEALTH_CHECK_SCRIPT="/var/lib/mongodb-hardening/health-check.sh"

log_recovery() {
    echo "[$(date)] RECOVERY: $*" >> "$RECOVERY_LOG"
}

# Check and restart MongoDB if needed
recover_mongodb() {
    if ! systemctl is-active --quiet mongod; then
        log_recovery "MongoDB is down, attempting restart"
        if systemctl restart mongod; then
            log_recovery "MongoDB successfully restarted"
            return 0
        else
            log_recovery "Failed to restart MongoDB"
            return 1
        fi
    fi
    return 0
}

# Ensure watchdog is running
ensure_watchdog() {
    if ! pgrep -f "mongodb-watchdog" >/dev/null; then
        log_recovery "Starting MongoDB watchdog"
        nohup "$WATCHDOG_SCRIPT" >/dev/null 2>&1 &
    fi
}

# Ensure health checks are scheduled
ensure_health_checks() {
    if ! crontab -l 2>/dev/null | grep -q "health-check"; then
        log_recovery "Adding health check to crontab"
        (crontab -l 2>/dev/null; echo "*/5 * * * * $HEALTH_CHECK_SCRIPT") | crontab -
    fi
}

# Main recovery process
main() {
    log_recovery "Starting auto-recovery process"
    
    recover_mongodb
    ensure_watchdog
    ensure_health_checks
    
    log_recovery "Auto-recovery process completed"
}

main "$@"
EOF
    
    chmod +x "$RECOVERY_SCRIPT"
}

# Start watchdog service
start_watchdog_service() {
    if pgrep -f "mongodb-watchdog" >/dev/null; then
        log_info "MongoDB watchdog is already running"
        return 0
    fi
    
    log_info "Starting MongoDB watchdog..."
    nohup "$WATCHDOG_SCRIPT" >/dev/null 2>&1 &
    
    sleep 2
    if pgrep -f "mongodb-watchdog" >/dev/null; then
        log_info "MongoDB watchdog started successfully"
        return 0
    else
        log_error "Failed to start MongoDB watchdog"
        return 1
    fi
}

# Start health check service
start_health_check_service() {
    # Add health check to crontab if not already present
    if ! crontab -l 2>/dev/null | grep -q "health-check"; then
        log_info "Adding health check to crontab"
        (crontab -l 2>/dev/null; echo "*/5 * * * * $HEALTH_CHECK_SCRIPT") | crontab -
        return 0
    else
        log_info "Health check already scheduled in crontab"
        return 0
    fi
}

# Restore missing cron jobs
restore_cron_jobs() {
    local missing_jobs=("$@")
    local temp_cron=$(mktemp)
    
    # Get current crontab
    crontab -l 2>/dev/null > "$temp_cron" || touch "$temp_cron"
    
    for job in "${missing_jobs[@]}"; do
        case "$job" in
            "mongodb-backup")
                echo "0 2 * * * /var/lib/mongodb-hardening/backup-mongodb.sh" >> "$temp_cron"
                ;;
            "mongodb-maintenance")
                echo "0 3 * * 0 /var/lib/mongodb-hardening/maintenance.sh" >> "$temp_cron"
                ;;
            "ssl-certificate-renewal")
                echo "0 4 1 * * /var/lib/mongodb-hardening/renew-certificates.sh" >> "$temp_cron"
                ;;
            "security-audit")
                echo "0 5 * * 1 /var/lib/mongodb-hardening/security-audit.sh" >> "$temp_cron"
                ;;
            "log-rotation")
                echo "0 1 * * * /var/lib/mongodb-hardening/rotate-logs.sh" >> "$temp_cron"
                ;;
        esac
    done
    
    # Install new crontab
    crontab "$temp_cron"
    rm "$temp_cron"
    
    log_info "Restored ${#missing_jobs[@]} missing cron jobs"
}

# Update state with current step
update_state() {
    local step="$1"
    local message="${2:-}"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    if [[ ! -f "$STATE_FILE" ]]; then
        create_initial_state
    fi
    
    local temp_file=$(mktemp)
    jq ".current_step = \"$step\" | 
        .last_updated = \"$timestamp\" | 
        .process_id = $$ |
        .message = \"$message\"" "$STATE_FILE" > "$temp_file"
    mv "$temp_file" "$STATE_FILE"
}

# Mark step as completed
mark_step_completed() {
    local step="$1"
    local temp_file=$(mktemp)
    
    jq ".completed_steps += [\"$step\"]" "$STATE_FILE" > "$temp_file"
    mv "$temp_file" "$STATE_FILE"
}

# Mark step as failed
mark_step_failed() {
    local step="$1"
    local error="${2:-Unknown error}"
    local temp_file=$(mktemp)
    
    jq ".failed_steps += [{\"step\": \"$step\", \"error\": \"$error\", \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}]" "$STATE_FILE" > "$temp_file"
    mv "$temp_file" "$STATE_FILE"
}

# Save recovery point
save_recovery_point() {
    local point_name="$1"
    local temp_file=$(mktemp)
    
    jq ".rollback_points += [{\"name\": \"$point_name\", \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\", \"current_step\": .current_step}]" "$STATE_FILE" > "$temp_file"
    mv "$temp_file" "$STATE_FILE"
}

# Get current state
get_current_state() {
    if [[ -f "$STATE_FILE" ]]; then
        jq -r '.current_step' "$STATE_FILE"
    else
        echo "not_started"
    fi
}

# Check if step is completed
is_step_completed() {
    local step="$1"
    if [[ -f "$STATE_FILE" ]]; then
        jq -e ".completed_steps | contains([\"$step\"])" "$STATE_FILE" >/dev/null
    else
        return 1
    fi
}

# Start continuous monitoring
start_continuous_monitoring() {
    log_info "Starting continuous monitoring services..."
    
    # Start watchdog
    start_watchdog_service
    
    # Start health checks
    start_health_check_service
    
    # Add recovery script to crontab if not present
    if ! crontab -l 2>/dev/null | grep -q "auto-recovery"; then
        (crontab -l 2>/dev/null; echo "*/10 * * * * $RECOVERY_SCRIPT") | crontab -
        log_info "Auto-recovery scheduled every 10 minutes"
    fi
    
    log_info "Continuous monitoring services started"
}

# Stop monitoring services
stop_monitoring_services() {
    log_info "Stopping monitoring services..."
    
    # Kill watchdog
    pkill -f "mongodb-watchdog" || true
    
    # Remove from crontab
    local temp_cron=$(mktemp)
    crontab -l 2>/dev/null | grep -v -E "(health-check|auto-recovery|mongodb-watchdog)" > "$temp_cron" || true
    crontab "$temp_cron" 2>/dev/null || true
    rm "$temp_cron"
    
    log_info "Monitoring services stopped"
}

# Check system health
check_system_health() {
    local issues=()
    
    # Check MongoDB
    if ! systemctl is-active --quiet mongod; then
        issues+=("MongoDB service is not running")
    fi
    
    # Check disk space
    local disk_usage=$(df /var/lib/mongodb 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//' || echo "0")
    if [[ $disk_usage -gt 85 ]]; then
        issues+=("Disk usage is high: ${disk_usage}%")
    fi
    
    # Check memory
    local memory_usage=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}')
    if [[ $memory_usage -gt 90 ]]; then
        issues+=("Memory usage is high: ${memory_usage}%")
    fi
    
    # Check watchdog
    if ! pgrep -f "mongodb-watchdog" >/dev/null; then
        issues+=("MongoDB watchdog is not running")
    fi
    
    if [[ ${#issues[@]} -eq 0 ]]; then
        log_info "System health check passed"
        return 0
    else
        log_warning "System health issues detected:"
        for issue in "${issues[@]}"; do
            log_warning "  - $issue"
        done
        return 1
    fi
}

# Emergency recovery function
emergency_recovery() {
    log_error "Starting emergency recovery..."
    
    # Try to restart MongoDB
    if ! systemctl is-active --quiet mongod; then
        log_info "Emergency: Restarting MongoDB..."
        systemctl restart mongod
    fi
    
    # Restart monitoring
    start_continuous_monitoring
    
    # Run health check
    "$HEALTH_CHECK_SCRIPT"
    
    log_info "Emergency recovery completed"
}

# Rollback capabilities
create_rollback_script() {
    local rollback_script="${FAILSAFE_DIR}/rollback.sh"
    
    cat > "$rollback_script" << 'EOF'
#!/bin/bash

# MongoDB Hardening Rollback Script
ROLLBACK_LOG="/var/lib/mongodb-hardening/rollback.log"
STATE_FILE="/var/lib/mongodb-hardening/hardening-state.json"
BACKUP_DIR="/var/lib/mongodb-hardening/backups"

log_rollback() {
    echo "[$(date)] ROLLBACK: $*" >> "$ROLLBACK_LOG"
    echo "ROLLBACK: $*"
}

# Rollback MongoDB configuration
rollback_mongodb_config() {
    log_rollback "Rolling back MongoDB configuration..."
    
    # Stop MongoDB
    systemctl stop mongod 2>/dev/null || true
    
    # Restore original configuration if backup exists
    if [[ -f "$BACKUP_DIR/mongod.conf.backup" ]]; then
        cp "$BACKUP_DIR/mongod.conf.backup" /etc/mongod.conf
        log_rollback "MongoDB configuration restored from backup"
    fi
    
    # Disable MongoDB service if it was not originally enabled
    if [[ -f "$BACKUP_DIR/mongodb-was-disabled" ]]; then
        systemctl disable mongod
        log_rollback "MongoDB service disabled"
    fi
}

# Rollback firewall rules
rollback_firewall() {
    log_rollback "Rolling back firewall rules..."
    
    # Remove MongoDB port rules
    ufw delete allow 27017/tcp 2>/dev/null || true
    ufw delete allow 27018/tcp 2>/dev/null || true
    ufw delete allow 27019/tcp 2>/dev/null || true
    
    # Restore original UFW status
    if [[ -f "$BACKUP_DIR/ufw-was-inactive" ]]; then
        ufw --force disable
        log_rollback "UFW firewall disabled"
    fi
}

# Rollback SSL certificates
rollback_ssl() {
    log_rollback "Rolling back SSL certificates..."
    
    # Remove created certificates
    rm -rf /etc/ssl/mongodb/ 2>/dev/null || true
    rm -rf /etc/letsencrypt/live/mongodb* 2>/dev/null || true
    
    log_rollback "SSL certificates removed"
}

# Rollback user accounts
rollback_users() {
    log_rollback "Rolling back user accounts..."
    
    # Remove created users (if MongoDB is accessible)
    if systemctl is-active --quiet mongod; then
        mongo admin --quiet --eval '
            db.dropUser("mongoAdmin");
            db.dropUser("mongoBackup");
            db.dropUser("mongoMonitor");
        ' 2>/dev/null || true
    fi
    
    log_rollback "MongoDB users removed"
}

# Rollback system packages
rollback_packages() {
    log_rollback "Rolling back installed packages..."
    
    # Remove MongoDB if it was installed by the script
    if [[ -f "$BACKUP_DIR/mongodb-was-not-installed" ]]; then
        apt-get remove --purge -y mongodb-org mongodb-org-server mongodb-org-shell mongodb-org-mongos mongodb-org-tools 2>/dev/null || true
        rm -rf /var/lib/mongodb
        rm -rf /var/log/mongodb
        log_rollback "MongoDB completely removed"
    fi
}

# Rollback monitoring and cron jobs
rollback_monitoring() {
    log_rollback "Rolling back monitoring setup..."
    
    # Kill watchdog processes
    pkill -f "mongodb-watchdog" 2>/dev/null || true
    
    # Remove cron jobs
    crontab -l 2>/dev/null | grep -v -E "(mongodb|health-check|auto-recovery)" | crontab - 2>/dev/null || true
    
    # Remove monitoring scripts
    rm -f /var/lib/mongodb-hardening/mongodb-watchdog.sh
    rm -f /var/lib/mongodb-hardening/health-check.sh
    rm -f /var/lib/mongodb-hardening/auto-recovery.sh
    
    log_rollback "Monitoring services removed"
}

# Main rollback function
main_rollback() {
    local rollback_level="${1:-full}"
    
    log_rollback "Starting rollback process (level: $rollback_level)"
    
    case "$rollback_level" in
        "config")
            rollback_mongodb_config
            ;;
        "security")
            rollback_mongodb_config
            rollback_firewall
            rollback_ssl
            rollback_users
            ;;
        "monitoring")
            rollback_monitoring
            ;;
        "full")
            rollback_monitoring
            rollback_users
            rollback_ssl
            rollback_firewall
            rollback_mongodb_config
            rollback_packages
            ;;
        *)
            log_rollback "Unknown rollback level: $rollback_level"
            exit 1
            ;;
    esac
    
    log_rollback "Rollback process completed"
}

# Execute rollback
main_rollback "$@"
EOF
    
    chmod +x "$rollback_script"
    log_info "Rollback script created at $rollback_script"
}

# Create backup before critical operations
create_system_backup() {
    local backup_name="$1"
    local backup_dir="${FAILSAFE_DIR}/backups"
    
    mkdir -p "$backup_dir"
    
    log_info "Creating system backup: $backup_name"
    
    # Backup MongoDB configuration
    if [[ -f /etc/mongod.conf ]]; then
        cp /etc/mongod.conf "$backup_dir/mongod.conf.backup"
    fi
    
    # Check if MongoDB was originally installed
    if ! dpkg -l | grep -q mongodb-org; then
        touch "$backup_dir/mongodb-was-not-installed"
    fi
    
    # Check if MongoDB service was originally enabled
    if ! systemctl is-enabled --quiet mongod 2>/dev/null; then
        touch "$backup_dir/mongodb-was-disabled"
    fi
    
    # Check UFW status
    if ! ufw status | grep -q "Status: active"; then
        touch "$backup_dir/ufw-was-inactive"
    fi
    
    # Backup current crontab
    crontab -l > "$backup_dir/crontab.backup" 2>/dev/null || touch "$backup_dir/crontab.backup"
    
    # Save backup info to state
    local temp_file=$(mktemp)
    jq ".rollback_points += [{\"name\": \"$backup_name\", \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\", \"backup_dir\": \"$backup_dir\"}]" "$STATE_FILE" > "$temp_file"
    mv "$temp_file" "$STATE_FILE"
    
    log_info "System backup completed: $backup_name"
}

# Trigger rollback on critical failure
trigger_rollback() {
    local rollback_level="${1:-security}"
    local reason="${2:-Critical failure detected}"
    
    log_error "Triggering rollback due to: $reason"
    
    # Save current state
    update_state "rollback_initiated" "$reason"
    
    # Execute rollback
    local rollback_script="${FAILSAFE_DIR}/rollback.sh"
    if [[ -x "$rollback_script" ]]; then
        "$rollback_script" "$rollback_level"
    else
        log_error "Rollback script not found or not executable"
    fi
    
    # Update state
    update_state "rollback_completed" "Rollback executed: $rollback_level"
}

# Check if rollback is needed
check_rollback_needed() {
    local failed_steps_count=$(jq -r '.failed_steps | length' "$STATE_FILE" 2>/dev/null || echo "0")
    
    if [[ $failed_steps_count -gt 3 ]]; then
        log_warning "Multiple failures detected ($failed_steps_count), rollback may be needed"
        return 0
    fi
    
    return 1
}

# Export functions for external use
export -f init_failsafe_system
export -f check_for_recovery
export -f attempt_recovery
export -f update_state
export -f mark_step_completed
export -f mark_step_failed
export -f save_recovery_point
export -f get_current_state
export -f is_step_completed
export -f start_continuous_monitoring
export -f stop_monitoring_services
export -f check_system_health
export -f emergency_recovery
export -f create_rollback_script
export -f create_system_backup
export -f trigger_rollback
export -f check_rollback_needed
