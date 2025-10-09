#!/bin/bash

# MongoDB Hardening Script with Comprehensive Fail-safe Integration
# This example shows how to integrate the fail-safe system into the main orchestration script

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all library modules
source "${SCRIPT_DIR}/libs/system.bash"
source "${SCRIPT_DIR}/libs/ssl.bash"  
source "${SCRIPT_DIR}/libs/mongodb.bash"
source "${SCRIPT_DIR}/libs/security.bash"
source "${SCRIPT_DIR}/libs/monitoring.bash"
source "${SCRIPT_DIR}/libs/failsafe.bash"

# Main function with fail-safe integration
main() {
    # Initialize logging and basic system checks
    init_logging
    check_root_privileges
    
    # Initialize fail-safe system first
    log_info "Starting MongoDB Hardening with Fail-safe Protection"
    init_failsafe_system
    
    # Check if we need to resume from previous run
    if check_for_recovery; then
        log_info "Previous incomplete run detected, attempting recovery..."
        attempt_recovery
        
        # Ask user if they want to continue or start fresh
        if ! user_confirm "Do you want to continue from where the previous run left off?"; then
            log_info "Starting fresh installation..."
            # Create initial backup before starting fresh
            create_system_backup "fresh_start_backup"
            update_state "starting_fresh" "User chose to start fresh installation"
        else
            log_info "Resuming from previous run..."
            update_state "resuming" "Resuming from previous incomplete run"
        fi
    else
        log_info "Starting new MongoDB hardening process..."
        # Create initial system backup
        create_system_backup "initial_backup"
        update_state "starting_new" "Starting new hardening process"
    fi
    
    # Define all hardening steps
    local steps=(
        "system_preparation"
        "dependency_installation" 
        "mongodb_installation"
        "ssl_certificate_setup"
        "mongodb_configuration"
        "security_hardening"
        "firewall_configuration"
        "user_management"
        "monitoring_setup"
        "final_verification"
    )
    
    # Execute each step with fail-safe protection
    for step in "${steps[@]}"; do
        execute_step_with_failsafe "$step"
    done
    
    # Start continuous monitoring
    start_continuous_monitoring
    
    # Mark process as completed
    update_state "completed" "MongoDB hardening completed successfully"
    mark_step_completed "hardening_process"
    
    log_info "MongoDB hardening completed successfully with monitoring enabled!"
    
    # Final system health check
    if check_system_health; then
        log_info "Final health check: All systems operational"
    else
        log_warning "Final health check detected some issues, but hardening is complete"
    fi
}

# Execute individual step with comprehensive fail-safe protection
execute_step_with_failsafe() {
    local step="$1"
    
    # Skip if already completed
    if is_step_completed "$step"; then
        log_info "Step '$step' already completed, skipping..."
        return 0
    fi
    
    log_info "Executing step: $step"
    update_state "$step" "Starting step: $step"
    
    # Create backup before critical steps
    case "$step" in
        "mongodb_installation"|"mongodb_configuration"|"security_hardening")
            create_system_backup "before_$step"
            ;;
    esac
    
    # Execute the step with error handling
    if execute_hardening_step "$step"; then
        mark_step_completed "$step"
        log_info "Step '$step' completed successfully"
        save_recovery_point "completed_$step"
    else
        local error_msg="Step '$step' failed"
        log_error "$error_msg"
        mark_step_failed "$step" "$error_msg"
        
        # Check if we need to trigger rollback
        if check_rollback_needed; then
            log_warning "Multiple failures detected, considering rollback..."
            
            if user_confirm "Multiple failures detected. Do you want to rollback to the last stable state?"; then
                trigger_rollback "security" "User requested rollback after multiple failures"
                exit 1
            fi
        fi
        
        # Try to recover from the failure
        log_info "Attempting to recover from failure..."
        if recover_from_step_failure "$step"; then
            log_info "Recovery successful, continuing..."
            mark_step_completed "$step"
        else
            log_error "Recovery failed for step '$step'"
            
            # Emergency recovery
            emergency_recovery
            
            if user_confirm "Critical failure in step '$step'. Continue anyway? (Not recommended)"; then
                log_warning "Continuing despite failure (user override)"
            else
                log_error "Hardening process aborted due to critical failure"
                trigger_rollback "full" "Critical failure in step: $step"
                exit 1
            fi
        fi
    fi
}

# Execute actual hardening step
execute_hardening_step() {
    local step="$1"
    
    case "$step" in
        "system_preparation")
            update_packages_cache
            install_dependencies
            setup_mongodb_directories
            ;;
            
        "dependency_installation")
            install_required_packages
            verify_dependencies
            ;;
            
        "mongodb_installation") 
            install_mongodb
            verify_mongodb_installation
            ;;
            
        "ssl_certificate_setup")
            setup_ssl_certificates
            configure_ssl_directory_permissions
            ;;
            
        "mongodb_configuration")
            generate_mongodb_config
            apply_mongodb_configuration
            ;;
            
        "security_hardening")
            configure_mongodb_authentication
            harden_mongodb_permissions
            ;;
            
        "firewall_configuration")
            configure_firewall_rules
            apply_network_security
            ;;
            
        "user_management")
            create_mongodb_users
            test_authentication
            ;;
            
        "monitoring_setup")
            setup_log_rotation
            create_backup_scripts
            configure_maintenance_scripts
            ;;
            
        "final_verification")
            verify_mongodb_security
            run_security_audit
            generate_status_report
            ;;
            
        *)
            log_error "Unknown hardening step: $step"
            return 1
            ;;
    esac
}

# Recovery function for specific step failures
recover_from_step_failure() {
    local step="$1"
    
    log_info "Attempting recovery for failed step: $step"
    
    case "$step" in
        "mongodb_installation")
            # Try alternative installation method
            log_info "Trying alternative MongoDB installation..."
            cleanup_failed_mongodb_installation
            install_mongodb_alternative
            ;;
            
        "ssl_certificate_setup")
            # Retry with self-signed certificates
            log_info "SSL setup failed, trying self-signed certificates..."
            create_self_signed_certificates
            ;;
            
        "mongodb_configuration")
            # Restore backup and try minimal config
            log_info "Configuration failed, trying minimal configuration..."
            restore_mongodb_config_backup
            apply_minimal_mongodb_config
            ;;
            
        "security_hardening")
            # Try basic security setup
            log_info "Full security hardening failed, applying basic security..."
            apply_basic_security_configuration
            ;;
            
        "firewall_configuration")
            # Try basic firewall rules
            log_info "Advanced firewall failed, applying basic rules..."
            apply_basic_firewall_rules
            ;;
            
        *)
            log_warning "No specific recovery method for step: $step"
            return 1
            ;;
    esac
}

# Cleanup functions for recovery
cleanup_failed_mongodb_installation() {
    log_info "Cleaning up failed MongoDB installation..."
    systemctl stop mongod 2>/dev/null || true
    apt-get remove --purge -y mongodb-org* 2>/dev/null || true
    rm -rf /var/lib/mongodb /var/log/mongodb /etc/mongod.conf 2>/dev/null || true
}

install_mongodb_alternative() {
    log_info "Installing MongoDB using alternative method..."
    # Implementation would go here
    return 0
}

restore_mongodb_config_backup() {
    log_info "Restoring MongoDB configuration backup..."
    if [[ -f "/var/lib/mongodb-hardening/backups/mongod.conf.backup" ]]; then
        cp "/var/lib/mongodb-hardening/backups/mongod.conf.backup" /etc/mongod.conf
        return 0
    fi
    return 1
}

apply_minimal_mongodb_config() {
    log_info "Applying minimal MongoDB configuration..."
    # Implementation would go here
    return 0
}

apply_basic_security_configuration() {
    log_info "Applying basic security configuration..."
    # Implementation would go here  
    return 0
}

apply_basic_firewall_rules() {
    log_info "Applying basic firewall rules..."
    ufw allow 22/tcp    # SSH
    ufw allow 27017/tcp # MongoDB
    ufw --force enable
    return 0
}

# Signal handler for graceful shutdown
graceful_shutdown() {
    log_info "Graceful shutdown initiated..."
    
    # Stop any running monitoring processes
    stop_monitoring_services
    
    # Save current state
    update_state "shutdown" "Graceful shutdown requested"
    
    log_info "Shutdown complete. Run the script again to resume."
    exit 0
}

# Set up signal handlers
trap graceful_shutdown SIGTERM SIGINT

# Usage function
usage() {
    cat << EOF
MongoDB Hardening Script with Fail-safe Protection

Usage: $0 [OPTIONS]

Options:
    -h, --help          Show this help message
    -r, --recovery      Force recovery mode
    -c, --check         Check system health only
    -s, --status        Show current hardening status
    --rollback [LEVEL]  Rollback to previous state
                        LEVELS: config, security, monitoring, full
    --no-monitoring     Skip continuous monitoring setup
    --force             Force execution without confirmations

Examples:
    $0                  # Normal execution with fail-safe protection
    $0 --recovery       # Force recovery from previous incomplete run
    $0 --check          # Check current system health
    $0 --status         # Show hardening status
    $0 --rollback full  # Complete rollback to initial state
EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -r|--recovery)
                FORCE_RECOVERY=true
                ;;
            -c|--check)
                CHECK_ONLY=true
                ;;
            -s|--status)
                STATUS_ONLY=true
                ;;
            --rollback)
                ROLLBACK_LEVEL="${2:-full}"
                ROLLBACK_MODE=true
                shift
                ;;
            --no-monitoring)
                SKIP_MONITORING=true
                ;;
            --force)
                FORCE_MODE=true
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

# Handle special modes
handle_special_modes() {
    if [[ "${CHECK_ONLY:-false}" == "true" ]]; then
        log_info "Performing system health check..."
        init_failsafe_system
        if check_system_health; then
            log_info "System health check: PASSED"
            exit 0
        else
            log_error "System health check: FAILED"
            exit 1
        fi
    fi
    
    if [[ "${STATUS_ONLY:-false}" == "true" ]]; then
        log_info "Showing hardening status..."
        show_hardening_status
        exit 0
    fi
    
    if [[ "${ROLLBACK_MODE:-false}" == "true" ]]; then
        log_info "Performing rollback (level: ${ROLLBACK_LEVEL})..."
        init_failsafe_system
        trigger_rollback "$ROLLBACK_LEVEL" "Manual rollback requested"
        exit 0
    fi
    
    if [[ "${FORCE_RECOVERY:-false}" == "true" ]]; then
        log_info "Forcing recovery mode..."
        init_failsafe_system
        attempt_recovery
        exit 0
    fi
}

# Show hardening status
show_hardening_status() {
    if [[ ! -f "/var/lib/mongodb-hardening/hardening-state.json" ]]; then
        log_info "No hardening state found. MongoDB hardening has not been run."
        return
    fi
    
    log_info "MongoDB Hardening Status:"
    echo "=================================="
    
    local current_step=$(jq -r '.current_step' /var/lib/mongodb-hardening/hardening-state.json)
    local completed_steps=$(jq -r '.completed_steps | length' /var/lib/mongodb-hardening/hardening-state.json)
    local failed_steps=$(jq -r '.failed_steps | length' /var/lib/mongodb-hardening/hardening-state.json)
    local last_updated=$(jq -r '.last_updated' /var/lib/mongodb-hardening/hardening-state.json)
    
    echo "Current Step: $current_step"
    echo "Completed Steps: $completed_steps"
    echo "Failed Steps: $failed_steps" 
    echo "Last Updated: $last_updated"
    echo ""
    
    # Show service status
    echo "Service Status:"
    if systemctl is-active --quiet mongod; then
        echo "  MongoDB: ✓ Running"
    else
        echo "  MongoDB: ✗ Not Running"
    fi
    
    if pgrep -f "mongodb-watchdog" >/dev/null; then
        echo "  Watchdog: ✓ Active"
    else
        echo "  Watchdog: ✗ Not Active"  
    fi
    
    echo ""
    check_system_health
}

# Entry point
main_entry() {
    # Initialize default values
    FORCE_RECOVERY=false
    CHECK_ONLY=false
    STATUS_ONLY=false
    ROLLBACK_MODE=false
    ROLLBACK_LEVEL="full"
    SKIP_MONITORING=false
    FORCE_MODE=false
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Handle special modes
    handle_special_modes
    
    # Run main hardening process
    main
}

# Execute if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_entry "$@"
fi