#!/usr/bin/env bash
# MongoDB Server Hardening Tool - Monitoring Library  
# Provides health checks, metrics collection, and monitoring setup functions

# Prevent multiple inclusion
if [[ -n "${_HARDEN_MONGO_SERVER_MONITORING_LOADED:-}" ]]; then
    return 0
fi
readonly _HARDEN_MONGO_SERVER_MONITORING_LOADED=1

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
# Monitoring Configuration Constants
# ================================

# Default monitoring settings
readonly DEFAULT_METRICS_DIR="/var/lib/harden-mongo-server/metrics"
readonly DEFAULT_LOG_RETENTION_DAYS="7"
readonly DEFAULT_CHECK_INTERVAL="300"  # 5 minutes
readonly DEFAULT_ALERT_THRESHOLD="80"  # 80%

# Health check types
readonly -A HEALTH_CHECKS=(
    [connection]="MongoDB connection test"
    [authentication]="Authentication system test"
    [replication]="Replica set status check"
    [performance]="Performance metrics check"
    [disk_space]="Disk space utilization check"
    [memory]="Memory usage check"
    [security]="Security configuration check"
)

# Alert levels
readonly -A ALERT_LEVELS=(
    [info]="Informational message"
    [warning]="Warning condition"
    [error]="Error condition"
    [critical]="Critical condition requiring immediate attention"
)

# ================================
# MongoDB Health Check Functions
# ================================

# Perform comprehensive MongoDB health check
mongodb_health_check() {
    local username="${1:-}"
    local password="${2:-}"
    local detailed="${3:-false}"
    
    print_header "MongoDB Health Check Report"
    
    local overall_status="healthy"
    local check_count=0
    local failed_checks=0
    
    # Connection check
    if ! check_mongodb_connection_health "$username" "$password"; then
        overall_status="unhealthy"
        ((failed_checks++))
    fi
    ((check_count++))
    
    # Service status check
    if ! check_mongodb_service_health; then
        overall_status="unhealthy" 
        ((failed_checks++))
    fi
    ((check_count++))
    
    # Performance check
    if ! check_mongodb_performance_health "$username" "$password"; then
        overall_status="degraded"
        ((failed_checks++))
    fi
    ((check_count++))
    
    # Resource utilization check
    if ! check_resource_utilization_health; then
        if [[ "$overall_status" == "healthy" ]]; then
            overall_status="degraded"
        fi
        ((failed_checks++))
    fi
    ((check_count++))
    
    # Security check (if detailed)
    if [[ "$detailed" == "true" ]]; then
        if ! check_mongodb_security_health; then
            if [[ "$overall_status" == "healthy" ]]; then
                overall_status="degraded"
            fi
            ((failed_checks++))
        fi
        ((check_count++))
    fi
    
    # Replication check (if applicable)
    if check_replication_enabled "$username" "$password"; then
        if ! check_mongodb_replication_health "$username" "$password"; then
            overall_status="unhealthy"
            ((failed_checks++))
        fi
        ((check_count++))
    fi
    
    # Summary
    print_section "Health Check Summary"
    print_kv "Overall Status" "$overall_status"
    print_kv "Checks Performed" "$check_count"
    print_kv "Failed Checks" "$failed_checks"
    print_kv "Success Rate" "$((((check_count - failed_checks) * 100) / check_count))%"
    
    case "$overall_status" in
        healthy)
            success "MongoDB is operating normally"
            return 0
            ;;
        degraded)
            warn "MongoDB is operational but with some issues"
            return 1
            ;;
        unhealthy)
            error "MongoDB has critical issues requiring attention"
            return 2
            ;;
    esac
}

# Check MongoDB connection health
check_mongodb_connection_health() {
    local username="${1:-}"
    local password="${2:-}"
    
    print_subsection "Connection Health Check"
    
    # Check if MongoDB port is open
    local mongodb_port="27017"
    if [[ -f "/etc/mongod.conf" ]]; then
        mongodb_port=$(grep "port:" /etc/mongod.conf | awk '{print $2}' 2>/dev/null || echo "27017")
    fi
    
    if ! port_in_use "$mongodb_port"; then
        error "MongoDB port $mongodb_port is not listening"
        return 1
    fi
    
    success "MongoDB port $mongodb_port is listening"
    
    # Test MongoDB connection
    local mongo_cmd="mongosh"
    if ! command_exists mongosh && command_exists mongo; then
        mongo_cmd="mongo"
    fi
    
    if ! command_exists "$mongo_cmd"; then
        warn "MongoDB client not available, skipping connection test"
        return 0
    fi
    
    local connection_test='db.runCommand({ping: 1})'
    local auth_options=""
    
    if [[ -n "$username" && -n "$password" ]]; then
        auth_options="--username '$username' --password '$password' --authenticationDatabase admin"
    fi
    
    if echo "$connection_test" | eval "$mongo_cmd $auth_options admin --quiet" >/dev/null 2>&1; then
        success "MongoDB connection test passed"
        return 0
    else
        error "MongoDB connection test failed"
        return 1
    fi
}

# Check MongoDB service health
check_mongodb_service_health() {
    print_subsection "Service Health Check"
    
    local service_status
    service_status=$(get_mongodb_service_status)
    
    case "$service_status" in
        active)
            success "MongoDB service is active"
            ;;
        inactive)
            error "MongoDB service is inactive"
            return 1
            ;;
        failed)
            error "MongoDB service is in failed state"
            return 1
            ;;
        *)
            warn "MongoDB service status is unknown: $service_status"
            return 1
            ;;
    esac
    
    # Check process information
    local mongodb_pid
    mongodb_pid=$(pgrep -f mongod | head -1)
    
    if [[ -n "$mongodb_pid" ]]; then
        local process_info
        process_info=$(ps -p "$mongodb_pid" -o pid,ppid,user,vsz,rss,pcpu,pmem,etime,cmd --no-headers 2>/dev/null)
        
        if [[ -n "$process_info" ]]; then
            info "MongoDB process details:"
            echo "  PID: $(echo "$process_info" | awk '{print $1}')"
            echo "  User: $(echo "$process_info" | awk '{print $3}')"
            echo "  Memory (VSZ): $(echo "$process_info" | awk '{print $4}') KB"
            echo "  Memory (RSS): $(echo "$process_info" | awk '{print $5}') KB"
            echo "  CPU: $(echo "$process_info" | awk '{print $6}')%"
            echo "  Runtime: $(echo "$process_info" | awk '{print $8}')"
            success "MongoDB process information collected"
        fi
    else
        warn "MongoDB process not found"
    fi
    
    return 0
}

# Check MongoDB performance health
check_mongodb_performance_health() {
    local username="${1:-}"
    local password="${2:-}"
    
    print_subsection "Performance Health Check"
    
    local mongo_cmd="mongosh"
    if ! command_exists mongosh && command_exists mongo; then
        mongo_cmd="mongo"
    fi
    
    if ! command_exists "$mongo_cmd"; then
        warn "MongoDB client not available, skipping performance check"
        return 0
    fi
    
    local auth_options=""
    if [[ -n "$username" && -n "$password" ]]; then
        auth_options="--username '$username' --password '$password' --authenticationDatabase admin"
    fi
    
    # Get server status
    local server_status_cmd='db.runCommand({serverStatus: 1})'
    local server_status
    server_status=$(echo "$server_status_cmd" | eval "$mongo_cmd $auth_options admin --quiet" 2>/dev/null)
    
    if [[ -n "$server_status" ]]; then
        # Parse key metrics (basic parsing, could be enhanced)
        info "MongoDB performance metrics collected"
        
        # Check for slow operations
        local current_ops_cmd='db.currentOp({"secs_running": {"$gte": 5}})'
        local slow_ops
        slow_ops=$(echo "$current_ops_cmd" | eval "$mongo_cmd $auth_options admin --quiet" 2>/dev/null | grep -c "secs_running" || echo "0")
        
        if ((slow_ops > 0)); then
            warn "$slow_ops slow operations detected (>5 seconds)"
        else
            success "No slow operations detected"
        fi
        
        return 0
    else
        error "Failed to collect MongoDB performance metrics"
        return 1
    fi
}

# Check resource utilization health  
check_resource_utilization_health() {
    print_subsection "Resource Utilization Health Check"
    
    local issues_found=0
    
    # Check disk space
    local disk_usage
    disk_usage=$(get_disk_usage /)
    local disk_percent
    disk_percent=$(echo "$disk_usage" | grep -o "percent:[^:]*" | cut -d: -f2 | sed 's/%$//')
    
    if [[ -n "$disk_percent" && "$disk_percent" =~ ^[0-9]+$ ]]; then
        if ((disk_percent >= 90)); then
            error "Critical disk space usage: ${disk_percent}%"
            ((issues_found++))
        elif ((disk_percent >= 80)); then
            warn "High disk space usage: ${disk_percent}%"
            ((issues_found++))
        else
            success "Disk space usage is normal: ${disk_percent}%"
        fi
    fi
    
    # Check memory usage
    local mem_info
    mem_info=$(get_memory_info)
    local mem_total
    local mem_available
    mem_total=$(echo "$mem_info" | grep -o "total:[0-9]*" | cut -d: -f2)
    mem_available=$(echo "$mem_info" | grep -o "available:[0-9]*" | cut -d: -f2)
    
    if [[ -n "$mem_total" && -n "$mem_available" && "$mem_total" -gt 0 ]]; then
        local mem_used_percent=$(((mem_total - mem_available) * 100 / mem_total))
        
        if ((mem_used_percent >= 95)); then
            error "Critical memory usage: ${mem_used_percent}%"
            ((issues_found++))
        elif ((mem_used_percent >= 85)); then
            warn "High memory usage: ${mem_used_percent}%"
            ((issues_found++))
        else
            success "Memory usage is normal: ${mem_used_percent}%"
        fi
    fi
    
    # Check system load
    local load_avg
    load_avg=$(get_system_load)
    local load_1min
    load_1min=$(echo "$load_avg" | cut -d' ' -f1)
    
    local cpu_count
    cpu_count=$(get_cpu_info | grep -o "count:[0-9]*" | cut -d: -f2)
    
    if [[ -n "$load_1min" && -n "$cpu_count" && "$cpu_count" -gt 0 ]]; then
        local load_per_cpu
        load_per_cpu=$(echo "scale=2; $load_1min / $cpu_count" | bc 2>/dev/null || echo "0")
        
        if (( $(echo "$load_per_cpu > 2.0" | bc -l 2>/dev/null || echo "0") )); then
            error "Critical system load: $load_1min (${load_per_cpu} per CPU)"
            ((issues_found++))
        elif (( $(echo "$load_per_cpu > 1.5" | bc -l 2>/dev/null || echo "0") )); then
            warn "High system load: $load_1min (${load_per_cpu} per CPU)"
            ((issues_found++))
        else
            success "System load is normal: $load_1min"
        fi
    fi
    
    return $((issues_found == 0 ? 0 : 1))
}

# Check MongoDB security health
check_mongodb_security_health() {
    print_subsection "Security Health Check"
    
    # Use existing security check from security module
    if command_exists check_mongodb_security; then
        return $(check_mongodb_security >/dev/null 2>&1; echo $?)
    else
        warn "Security check function not available"
        return 0
    fi
}

# Check if replication is enabled
check_replication_enabled() {
    local username="${1:-}"
    local password="${2:-}"
    
    local mongo_cmd="mongosh"
    if ! command_exists mongosh && command_exists mongo; then
        mongo_cmd="mongo"
    fi
    
    if ! command_exists "$mongo_cmd"; then
        return 1
    fi
    
    local auth_options=""
    if [[ -n "$username" && -n "$password" ]]; then
        auth_options="--username '$username' --password '$password' --authenticationDatabase admin"
    fi
    
    local repl_status_cmd='rs.status()'
    local repl_output
    repl_output=$(echo "$repl_status_cmd" | eval "$mongo_cmd $auth_options admin --quiet" 2>/dev/null)
    
    # Check if replica set is configured
    if echo "$repl_output" | grep -q "not running with --replSet"; then
        return 1
    else
        return 0
    fi
}

# Check MongoDB replication health
check_mongodb_replication_health() {
    local username="${1:-}"
    local password="${2:-}"
    
    print_subsection "Replication Health Check"
    
    local mongo_cmd="mongosh"
    if ! command_exists mongosh && command_exists mongo; then
        mongo_cmd="mongo"
    fi
    
    local auth_options=""
    if [[ -n "$username" && -n "$password" ]]; then
        auth_options="--username '$username' --password '$password' --authenticationDatabase admin"
    fi
    
    # Check replica set status
    local repl_status_cmd='rs.status()'
    local repl_status
    repl_status=$(echo "$repl_status_cmd" | eval "$mongo_cmd $auth_options admin --quiet" 2>/dev/null)
    
    if [[ -n "$repl_status" ]]; then
        # Basic replication health indicators
        if echo "$repl_status" | grep -q "PRIMARY"; then
            success "Replica set has a primary member"
        else
            error "No primary member found in replica set"
            return 1
        fi
        
        # Check for unhealthy members
        local unhealthy_members
        unhealthy_members=$(echo "$repl_status" | grep -c "health.*0" 2>/dev/null || echo "0")
        
        if ((unhealthy_members > 0)); then
            warn "$unhealthy_members unhealthy replica set members detected"
            return 1
        else
            success "All replica set members appear healthy"
        fi
        
        return 0
    else
        error "Failed to retrieve replica set status"
        return 1
    fi
}

# ================================
# Metrics Collection Functions
# ================================

# Collect MongoDB metrics
collect_mongodb_metrics() {
    local metrics_file="${1:-$DEFAULT_METRICS_DIR/mongodb_metrics_$(date +%Y%m%d_%H%M%S).json}"
    local username="${2:-}"
    local password="${3:-}"
    
    info "Collecting MongoDB metrics to $metrics_file"
    
    # Create metrics directory
    create_dir_safe "$(dirname "$metrics_file")" 755 mongodb:mongodb
    
    local mongo_cmd="mongosh"
    if ! command_exists mongosh && command_exists mongo; then
        mongo_cmd="mongo"
    fi
    
    if ! command_exists "$mongo_cmd"; then
        error "MongoDB client not available for metrics collection"
        return 1
    fi
    
    local auth_options=""
    if [[ -n "$username" && -n "$password" ]]; then
        auth_options="--username '$username' --password '$password' --authenticationDatabase admin"
    fi
    
    # Collect comprehensive metrics
    local metrics_script='
    var metrics = {
        timestamp: new Date(),
        server_status: db.runCommand({serverStatus: 1}),
        database_stats: {},
        collection_stats: {},
        replica_status: null,
        current_operations: db.currentOp()
    };
    
    // Get database statistics
    db.adminCommand("listDatabases").databases.forEach(function(database) {
        if (database.name !== "local" && database.name !== "config") {
            metrics.database_stats[database.name] = db.getSiblingDB(database.name).stats();
        }
    });
    
    // Get replica set status if applicable
    try {
        metrics.replica_status = rs.status();
    } catch (e) {
        metrics.replica_status = {error: "Not a replica set"};
    }
    
    print(JSON.stringify(metrics, null, 2));
    '
    
    if echo "$metrics_script" | eval "$mongo_cmd $auth_options admin --quiet" > "$metrics_file" 2>/dev/null; then
        success "MongoDB metrics collected successfully"
        
        # Set proper permissions
        if ! is_dry_run; then
            chmod 640 "$metrics_file"
            chown mongodb:mongodb "$metrics_file"
        fi
        
        return 0
    else
        error "Failed to collect MongoDB metrics"
        return 1
    fi
}

# Collect system metrics
collect_system_metrics() {
    local metrics_file="${1:-$DEFAULT_METRICS_DIR/system_metrics_$(date +%Y%m%d_%H%M%S).json}"
    
    info "Collecting system metrics to $metrics_file"
    
    # Create metrics directory
    create_dir_safe "$(dirname "$metrics_file")" 755 mongodb:mongodb
    
    # Gather system metrics
    local system_metrics="{
  \"timestamp\": \"$(date -Iseconds)\",
  \"hostname\": \"$(hostname)\",
  \"uptime\": $(get_system_uptime),
  \"load_average\": \"$(get_system_load)\",
  \"memory\": $(get_memory_info | sed 's/:/": "/g; s/ /", "/g' | sed 's/^/"/; s/$/"/'),
  \"disk_usage\": \"$(get_disk_usage / | sed 's/:/": "/g; s/ /", "/g')\",
  \"cpu_info\": \"$(get_cpu_info | sed 's/:/": "/g; s/ /", "/g')\",
  \"network_interfaces\": [$(get_network_interfaces | sed 's/ /", "/g; s/^/"/; s/$/"/')]
}"
    
    if ! is_dry_run; then
        echo "$system_metrics" > "$metrics_file"
        chmod 640 "$metrics_file"
        chown mongodb:mongodb "$metrics_file"
    fi
    
    execute_or_simulate "Write system metrics" "echo 'System metrics written to $metrics_file'"
    success "System metrics collected successfully"
}

# Clean up old metrics files
cleanup_old_metrics() {
    local metrics_dir="${1:-$DEFAULT_METRICS_DIR}"
    local retention_days="${2:-$DEFAULT_LOG_RETENTION_DAYS}"
    
    info "Cleaning up metrics older than $retention_days days"
    
    if [[ ! -d "$metrics_dir" ]]; then
        warn "Metrics directory does not exist: $metrics_dir"
        return 0
    fi
    
    local cleanup_count=0
    
    # Find and remove old metrics files
    while IFS= read -r -d '' metrics_file; do
        local file_age_days
        file_age_days=$(( ($(date +%s) - $(stat -c %Y "$metrics_file")) / 86400 ))
        
        if ((file_age_days > retention_days)); then
            execute_or_simulate "Delete old metrics file" "rm -f '$metrics_file'"
            ((cleanup_count++))
        fi
    done < <(find "$metrics_dir" -name "*_metrics_*.json" -type f -print0)
    
    if ((cleanup_count > 0)); then
        success "Cleaned up $cleanup_count old metrics files"
    else
        info "No old metrics files found for cleanup"
    fi
}

# ================================
# Monitoring Setup Functions
# ================================

# Setup automated monitoring
setup_monitoring() {
    local check_interval="${1:-$DEFAULT_CHECK_INTERVAL}"
    local enable_metrics="${2:-true}"
    local metrics_interval="${3:-3600}"  # 1 hour
    local retention_days="${4:-$DEFAULT_LOG_RETENTION_DAYS}"
    
    print_section "Setting up MongoDB Monitoring"
    
    # Create monitoring directories
    create_dir_safe "$DEFAULT_METRICS_DIR" 755 mongodb:mongodb
create_dir_safe "/var/log/harden-mongo-server" 755 mongodb:mongodb
    
    # Create monitoring script
local monitoring_script="/usr/local/bin/harden-mongo-server-monitoring.sh"
    create_monitoring_script "$monitoring_script" "$check_interval" "$enable_metrics" "$metrics_interval" "$retention_days"
    
    # Setup cron jobs
    setup_monitoring_cron "$monitoring_script" "$check_interval" "$enable_metrics" "$metrics_interval"
    
    success "MongoDB monitoring setup completed"
}

# Create monitoring script
create_monitoring_script() {
    local script_path="$1"
    local check_interval="$2"
    local enable_metrics="$3"
    local metrics_interval="$4"
    local retention_days="$5"
    
    local script_content="#!/bin/bash
# MongoDB Monitoring Script
# Generated by MongoDB Hardening Utility

# Set environment
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Source the monitoring library
source \"$(harden_mongo_server_lib_dir)/monitoring.sh\"

# Configuration
METRICS_DIR=\"$DEFAULT_METRICS_DIR\"
RETENTION_DAYS=\"$retention_days\"
LOG_FILE=\"/var/log/harden-mongo-server/monitoring.log\"

# Logging function
log_message() {
    echo \"[\$(date -Iseconds)] \$1\" >> \"\$LOG_FILE\"
}

# Health check function
run_health_check() {
    log_message \"Starting MongoDB health check\"
    
    if mongodb_health_check >/dev/null 2>&1; then
        log_message \"Health check passed\"
        return 0
    else
        log_message \"Health check failed\"
        return 1
    fi
}

# Metrics collection function  
run_metrics_collection() {
    if [[ \"$enable_metrics\" == \"true\" ]]; then
        log_message \"Collecting MongoDB metrics\"
        
        if collect_mongodb_metrics; then
            log_message \"MongoDB metrics collected\"
        fi
        
        if collect_system_metrics; then
            log_message \"System metrics collected\"
        fi
        
        # Clean up old metrics
        cleanup_old_metrics \"\$METRICS_DIR\" \"\$RETENTION_DAYS\"
    fi
}

# Main execution
case \"\${1:-health}\" in
    health)
        run_health_check
        ;;
    metrics)
        run_metrics_collection
        ;;
    *)
        echo \"Usage: \$0 {health|metrics}\"
        exit 1
        ;;
esac
"
    
    if ! is_dry_run; then
        echo "$script_content" > "$script_path"
        chmod 755 "$script_path"
        chown root:root "$script_path"
    fi
    
    execute_or_simulate "Create monitoring script" "echo 'Monitoring script created at $script_path'"
}

# Setup monitoring cron jobs
setup_monitoring_cron() {
    local script_path="$1"
    local check_interval="$2"
    local enable_metrics="$3"
    local metrics_interval="$4"
    
    # Convert intervals to cron format
    local health_check_cron="*/$((check_interval / 60)) * * * *"
    if ((check_interval >= 3600)); then
        health_check_cron="0 */$((check_interval / 3600)) * * *"
    fi
    
    local metrics_cron=""
    if [[ "$enable_metrics" == "true" ]]; then
        metrics_cron="0 */$((metrics_interval / 3600)) * * *"
    fi
    
    # Create cron file
local cron_file="/etc/cron.d/harden-mongo-server-monitoring"
    local cron_content="# MongoDB monitoring cron jobs
# Health checks
$health_check_cron root $script_path health >/dev/null 2>&1"
    
    if [[ -n "$metrics_cron" ]]; then
        cron_content="$cron_content
# Metrics collection  
$metrics_cron root $script_path metrics >/dev/null 2>&1"
    fi
    
    if ! is_dry_run; then
        echo "$cron_content" > "$cron_file"
        chmod 644 "$cron_file"
    fi
    
    execute_or_simulate "Setup monitoring cron jobs" "echo 'Monitoring cron jobs configured'"
    success "Monitoring scheduled successfully"
}

# Remove monitoring setup
remove_monitoring() {
    info "Removing MongoDB monitoring setup"
    
local monitoring_script="/usr/local/bin/harden-mongo-server-monitoring.sh"
    local cron_file="/etc/cron.d/harden-mongo-server-monitoring"
    
    # Remove cron job
    if [[ -f "$cron_file" ]]; then
        execute_or_simulate "Remove monitoring cron job" "rm -f '$cron_file'"
    fi
    
    # Remove monitoring script
    if [[ -f "$monitoring_script" ]]; then
        execute_or_simulate "Remove monitoring script" "rm -f '$monitoring_script'"
    fi
    
    success "MongoDB monitoring removed"
}

# ================================
# Alerting Functions
# ================================

# Send alert notification
send_alert() {
    local level="$1"
    local message="$2"
    local recipient="${3:-root}"
    
    local subject="MongoDB Alert [$level]: $(hostname)"
    local full_message="MongoDB Alert from $(hostname) at $(date)

Alert Level: $level
Message: $message

System Information:
- Hostname: $(hostname)
- Timestamp: $(date -Iseconds)
- MongoDB Status: $(get_mongodb_service_status)

This is an automated message from MongoDB Hardening Utility."
    
    # Send email if mail command is available
    if command_exists mail; then
        echo "$full_message" | mail -s "$subject" "$recipient"
        success "Alert sent via email to $recipient"
    elif command_exists logger; then
logger -p daemon.warning -t harden-mongo-server "$subject: $message"
        info "Alert logged to syslog"
    else
        warn "No alerting mechanism available (install mail or logger)"
    fi
}

# Check thresholds and send alerts
check_alert_thresholds() {
    local disk_threshold="${1:-90}"
    local memory_threshold="${2:-90}"
    local load_threshold="${3:-2.0}"
    
    # Check disk space
    local disk_usage
    disk_usage=$(get_disk_usage /)
    local disk_percent
    disk_percent=$(echo "$disk_usage" | grep -o "percent:[^:]*" | cut -d: -f2 | sed 's/%$//')
    
    if [[ -n "$disk_percent" && "$disk_percent" =~ ^[0-9]+$ ]] && ((disk_percent >= disk_threshold)); then
        send_alert "critical" "Disk space usage is at ${disk_percent}% (threshold: ${disk_threshold}%)"
    fi
    
    # Check memory usage
    local mem_info
    mem_info=$(get_memory_info)
    local mem_total
    local mem_available
    mem_total=$(echo "$mem_info" | grep -o "total:[0-9]*" | cut -d: -f2)
    mem_available=$(echo "$mem_info" | grep -o "available:[0-9]*" | cut -d: -f2)
    
    if [[ -n "$mem_total" && -n "$mem_available" && "$mem_total" -gt 0 ]]; then
        local mem_used_percent=$(((mem_total - mem_available) * 100 / mem_total))
        if ((mem_used_percent >= memory_threshold)); then
            send_alert "warning" "Memory usage is at ${mem_used_percent}% (threshold: ${memory_threshold}%)"
        fi
    fi
    
    # Check system load
    local load_avg
    load_avg=$(get_system_load)
    local load_1min
    load_1min=$(echo "$load_avg" | cut -d' ' -f1)
    
    if [[ -n "$load_1min" ]] && (( $(echo "$load_1min > $load_threshold" | bc -l 2>/dev/null || echo "0") )); then
        send_alert "warning" "System load is at $load_1min (threshold: $load_threshold)"
    fi
}

# ================================
# Module Information
# ================================

# Module information
monitoring_module_info() {
    cat << EOF
MongoDB Server Hardening Monitoring Library v$HARDEN_MONGO_SERVER_VERSION

This module provides:
- Comprehensive MongoDB health checking
- Connection, service, and performance monitoring
- Resource utilization monitoring (disk, memory, CPU)
- Replication status monitoring
- Automated metrics collection (MongoDB and system)
- Configurable alerting and notifications
- Automated monitoring setup with cron scheduling
- Metrics retention and cleanup management

Functions:
- mongodb_health_check: Comprehensive health assessment
- check_mongodb_connection_health: Test MongoDB connectivity
- check_mongodb_service_health: Verify service status
- check_mongodb_performance_health: Monitor performance metrics
- check_resource_utilization_health: System resource monitoring
- collect_mongodb_metrics: Gather detailed MongoDB metrics
- collect_system_metrics: Gather system performance data
- setup_monitoring: Configure automated monitoring
- send_alert: Send alert notifications
- check_alert_thresholds: Monitor and alert on thresholds

Health Check Categories:
- Connection: MongoDB connectivity and port status
- Service: Process status and system integration
- Performance: Query performance and operations
- Resources: Disk space, memory, and CPU utilization
- Security: Security configuration validation
- Replication: Replica set health and status

Monitoring Features:
- Configurable check intervals
- JSON-formatted metrics collection
- Email and syslog alerting
- Automated cleanup of old metrics
- Cron-based scheduling

Default Settings:
- Metrics Directory: $DEFAULT_METRICS_DIR
- Check Interval: $DEFAULT_CHECK_INTERVAL seconds
- Metrics Retention: $DEFAULT_LOG_RETENTION_DAYS days
- Alert Threshold: $DEFAULT_ALERT_THRESHOLD%

Dependencies: core.sh, logging.sh, system.sh, mongosh/mongo
EOF
}