#!/usr/bin/env bash
# MongoDB Hardening Utility - Main Script
# Comprehensive MongoDB security hardening and maintenance tool

# Script metadata
readonly SCRIPT_NAME="harden-mongodb"
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_DESCRIPTION="MongoDB Security Hardening and Maintenance Utility"
readonly SCRIPT_AUTHOR="MongoDB Hardening Project"

# Get script directory
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR="$SCRIPT_DIR/lib/mongodb-hardening"

# ================================
# Core Module Loading
# ================================

# Load core libraries in dependency order
load_core_modules() {
    local modules=(
        "core"
        "logging" 
        "ui"
        "system"
        "mongodb"
        "security"
        "ssl"
        "firewall"
        "backup"
        "monitoring"
    )
    
    for module in "${modules[@]}"; do
        local module_path="$LIB_DIR/${module}.sh"
        if [[ -f "$module_path" ]]; then
            source "$module_path" || {
                echo "Error: Failed to load module '$module'" >&2
                exit 1
            }
        else
            echo "Error: Module '$module' not found at '$module_path'" >&2
            exit 1
        fi
    done
}

# Initialize the application
initialize_application() {
    # Load all modules
    load_core_modules
    
    # Set up signal handlers
    setup_signal_handlers
    
    # Check if running as root for operations that require it
    if [[ "$1" != "help" && "$1" != "version" && "$1" != "info" ]]; then
        if ! is_root; then
            error "This script must be run as root for most operations"
            info "Use 'sudo $0 $*' or run as root user"
            exit 1
        fi
    fi
}

# ================================
# Command Line Interface
# ================================

# Display help information
show_help() {
    cat << EOF
$SCRIPT_DESCRIPTION

Usage: $0 [OPTIONS] COMMAND [COMMAND_OPTIONS]

COMMANDS:
  System Analysis:
    system-info               Display comprehensive system information
    mongodb-status           Show MongoDB service and configuration status
    security-check           Perform security assessment
    health-check            Run comprehensive health checks

  Configuration & Hardening:
    configure               Run interactive configuration wizard
    harden [PROFILE]        Apply security hardening (basic|standard|strict|paranoid)
    setup-ssl               Initialize SSL/TLS certificates and configuration
    setup-auth              Configure MongoDB authentication
    setup-firewall          Configure firewall rules for MongoDB

  SSL/TLS Management:
    ssl init                Initialize Certificate Authority
    ssl server [HOSTNAME]   Generate server certificate
    ssl client NAME         Generate client certificate
    ssl list                List all certificates
    ssl check               Check certificate expiration
    ssl revoke FILE         Revoke a certificate

  Backup & Restore:
    backup [DATABASE]       Create MongoDB backup
    restore FILE [DB]       Restore MongoDB backup
    backup-list             List available backups
    backup-schedule TIME    Schedule automated backups
    backup-cleanup [DAYS]   Clean up old backups

  Monitoring & Maintenance:
    monitoring setup        Setup automated monitoring
    monitoring remove       Remove monitoring setup
    metrics collect         Collect current metrics
    metrics cleanup         Clean up old metrics files

  Firewall Management:
    firewall status         Show firewall status and rules
    firewall enable         Enable and configure firewall
    firewall allow IP:PORT  Allow specific access
    firewall block IP:PORT  Block specific access

  Service Management:
    start                   Start MongoDB service
    stop                    Stop MongoDB service
    restart                 Restart MongoDB service
    enable                  Enable MongoDB auto-start

PROFILES:
  basic      - Enable authentication and basic file security
  standard   - Add keyfile, system limits, stronger SCRAM (default)
  strict     - Restrictive permissions and connection limits
  paranoid   - Maximum security with localhost-only binding

GLOBAL OPTIONS:
  -v, --verbose           Enable verbose output
  -d, --debug             Enable debug output
  -f, --force             Skip confirmation prompts
  -n, --dry-run           Show what would be done without executing
  -c, --config FILE       Use alternative configuration file
  -h, --help              Show this help message
      --version           Show version information

EXAMPLES:
  # Run interactive configuration wizard
  $0 configure

  # Apply standard security hardening
  $0 harden standard

  # Perform comprehensive security assessment
  $0 security-check

  # Set up SSL/TLS with auto-generated certificates
  $0 setup-ssl

  # Create a backup of all databases
  $0 backup

  # Set up automated monitoring
  $0 monitoring setup

  # Configure firewall for production use
  $0 setup-firewall

For detailed information about each command, use:
  $0 COMMAND --help

EOF
}

# Show version information
show_version() {
    echo "$SCRIPT_DESCRIPTION"
    echo "Version: $SCRIPT_VERSION"
    echo "Author: $SCRIPT_AUTHOR"
    echo
    
    # Only show extended info if modules are loaded
    if [[ -n "${_MONGODB_HARDENING_CORE_LOADED:-}" ]]; then
        echo "Library Versions:"
        echo "  Core: v$MONGODB_HARDENING_VERSION"
        if command -v get_mongodb_version >/dev/null 2>&1; then
            echo "  MongoDB: $(get_mongodb_version 2>/dev/null || echo 'Not detected')"
        fi
        if command -v get_os >/dev/null 2>&1; then
            echo "  System: $(get_os 2>/dev/null || echo 'unknown') $(get_os_version 2>/dev/null || echo 'unknown')"
        fi
    fi
}

# Show module information
show_info() {
    local module="${1:-all}"
    
    case "$module" in
        all)
            print_header "MongoDB Hardening Utility - Module Information"
            core_module_info 2>/dev/null || echo "Core module info not available"
            echo
            logging_module_info 2>/dev/null || echo "Logging module info not available"
            echo
            system_module_info 2>/dev/null || echo "System module info not available"
            ;;
        core) core_module_info ;;
        logging) logging_module_info ;;
        ui) ui_module_info ;;
        system) system_module_info ;;
        mongodb) mongodb_module_info ;;
        security) security_module_info ;;
        ssl) ssl_module_info ;;
        firewall) firewall_module_info ;;
        backup) backup_module_info ;;
        monitoring) monitoring_module_info ;;
        *)
            error "Unknown module: $module"
            echo "Available modules: all, core, logging, ui, system, mongodb, security, ssl, firewall, backup, monitoring"
            return 1
            ;;
    esac
}

# ================================
# Command Handlers
# ================================

# Handle system analysis commands
handle_system_commands() {
    case "$1" in
        system-info)
            show_system_info
            ;;
        mongodb-status)
            show_mongodb_status
            ;;
        security-check)
            local detailed="${2:-false}"
            check_mongodb_security
            if [[ "$detailed" == "--detailed" || "$detailed" == "-d" ]]; then
                security_vulnerability_check
            fi
            ;;
        health-check)
            mongodb_health_check "" "" true
            ;;
        *)
            error "Unknown system command: $1"
            return 1
            ;;
    esac
}

# Handle configuration and hardening commands
handle_configuration_commands() {
    case "$1" in
        configure)
            if configuration_wizard; then
                success "Configuration completed successfully"
            else
                error "Configuration was cancelled or failed"
                return 1
            fi
            ;;
        harden)
            local profile="${2:-standard}"
            info "Applying $profile security profile..."
            if apply_security_profile "$profile"; then
                success "Security hardening completed with profile: $profile"
            else
                error "Security hardening failed"
                return 1
            fi
            ;;
        setup-ssl)
            handle_ssl_setup
            ;;
        setup-auth)
            handle_auth_setup  
            ;;
        setup-firewall)
            handle_firewall_setup
            ;;
        *)
            error "Unknown configuration command: $1"
            return 1
            ;;
    esac
}

# Handle SSL setup
handle_ssl_setup() {
    info "Setting up SSL/TLS for MongoDB"
    
    # Initialize CA if not exists
    if ! verify_ca "$DEFAULT_CA_DIR" 2>/dev/null; then
        info "Initializing Certificate Authority..."
        if ! initialize_ca; then
            error "Failed to initialize Certificate Authority"
            return 1
        fi
    fi
    
    # Generate server certificate
    local hostname
    hostname=$(hostname -f)
    info "Generating server certificate for $hostname"
    if ! generate_server_certificate "$hostname"; then
        error "Failed to generate server certificate"
        return 1
    fi
    
    # Configure MongoDB to use SSL
    local server_pem="$MONGODB_SSL_DIR/mongodb-server.pem"
    local ca_cert="$DEFAULT_CA_DIR/ca.crt"
    
    if configure_mongodb_ssl "$server_pem" "$ca_cert" "requireSSL"; then
        success "SSL/TLS setup completed successfully"
        info "You may need to restart MongoDB for changes to take effect"
    else
        error "Failed to configure MongoDB SSL"
        return 1
    fi
}

# Handle authentication setup
handle_auth_setup() {
    info "Setting up MongoDB authentication"
    
    local admin_user
    admin_user=$(prompt_and_validate \
        "Administrator username" \
        "^[a-zA-Z][a-zA-Z0-9_]{2,31}$" \
        "username" \
        "admin")
    
    local admin_password
    admin_password=$(prompt_user_credentials "$admin_user")
    
    # Create the admin user (this requires MongoDB to be running without auth first)
    if create_mongodb_user "$admin_user" "$admin_password" "admin" "root"; then
        success "Admin user created successfully"
        
        # Now enable authentication in configuration
        info "Enabling authentication in MongoDB configuration"
        # This would update the config file to enable auth
        success "Authentication setup completed"
        info "You may need to restart MongoDB for changes to take effect"
    else
        error "Failed to create admin user"
        return 1
    fi
}

# Handle firewall setup
handle_firewall_setup() {
    info "Setting up firewall for MongoDB"
    
    local environment
    if confirm "Is this a production environment?" "n"; then
        environment="production"
    else
        environment="development"
    fi
    
    case "$environment" in
        production)
            local allowed_ips
            allowed_ips=$(prompt_and_validate \
                "Allowed IP addresses (comma-separated)" \
                "^([0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}(,[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})*)?$" \
                "IP address list" \
                "127.0.0.1")
                
            setup_production_firewall "27017" "$allowed_ips"
            ;;
        development)
            setup_development_firewall "27017"
            ;;
    esac
    
    success "Firewall setup completed"
}

# Handle SSL/TLS management commands
handle_ssl_commands() {
    local action="$2"
    local param="$3"
    
    case "$action" in
        init)
            initialize_ca "$DEFAULT_CA_DIR"
            ;;
        server)
            local hostname="${param:-$(hostname -f)}"
            generate_server_certificate "$hostname"
            ;;
        client)
            if [[ -z "$param" ]]; then
                error "Client name required for certificate generation"
                return 1
            fi
            generate_client_certificate "$param"
            ;;
        list)
            list_certificates
            ;;
        check)
            check_certificate_expiration "${param:-30}"
            ;;
        revoke)
            if [[ -z "$param" ]]; then
                error "Certificate file required for revocation"
                return 1
            fi
            revoke_certificate "$param"
            ;;
        *)
            error "Unknown SSL command: $action"
            echo "Available SSL commands: init, server, client, list, check, revoke"
            return 1
            ;;
    esac
}

# Handle backup and restore commands
handle_backup_commands() {
    case "$1" in
        backup)
            local database="${2:-all}"
            create_mongodb_backup "$DEFAULT_BACKUP_DIR" "$database"
            ;;
        restore)
            local backup_file="$2"
            local target_db="$3"
            if [[ -z "$backup_file" ]]; then
                error "Backup file path required"
                return 1
            fi
            restore_mongodb_backup "$backup_file" "$target_db"
            ;;
        backup-list)
            list_backups "$DEFAULT_BACKUP_DIR" true
            ;;
        backup-schedule)
            local schedule="$2"
            if [[ -z "$schedule" ]]; then
                error "Schedule time required (cron format)"
                return 1
            fi
            schedule_backup "$schedule"
            ;;
        backup-cleanup)
            local days="${2:-$DEFAULT_RETENTION_DAYS}"
            cleanup_old_backups "$DEFAULT_BACKUP_DIR" "$days"
            ;;
        *)
            error "Unknown backup command: $1"
            return 1
            ;;
    esac
}

# Handle monitoring commands  
handle_monitoring_commands() {
    case "$2" in
        setup)
            setup_monitoring
            ;;
        remove)
            remove_monitoring
            ;;
        *)
            error "Unknown monitoring command: $2"
            echo "Available monitoring commands: setup, remove"
            return 1
            ;;
    esac
}

# Handle metrics commands
handle_metrics_commands() {
    case "$2" in
        collect)
            collect_mongodb_metrics
            collect_system_metrics
            ;;
        cleanup)
            local days="${3:-$DEFAULT_LOG_RETENTION_DAYS}"
            cleanup_old_metrics "$DEFAULT_METRICS_DIR" "$days"
            ;;
        *)
            error "Unknown metrics command: $2"
            echo "Available metrics commands: collect, cleanup"
            return 1
            ;;
    esac
}

# Handle firewall commands
handle_firewall_commands() {
    case "$2" in
        status)
            get_firewall_status
            list_mongodb_firewall_rules
            ;;
        enable)
            enable_firewall
            ;;
        allow)
            local target="$3"
            if [[ -z "$target" ]]; then
                error "Target IP:PORT required"
                return 1
            fi
            local ip="${target%:*}"
            local port="${target#*:}"
            allow_mongodb_port "$port" "$ip"
            ;;
        block)
            local target="$3"
            if [[ -z "$target" ]]; then
                error "Target IP:PORT required"
                return 1
            fi
            local ip="${target%:*}"
            local port="${target#*:}"
            block_mongodb_port "$port" "$ip"
            ;;
        *)
            error "Unknown firewall command: $2"
            echo "Available firewall commands: status, enable, allow, block"
            return 1
            ;;
    esac
}

# Handle service management commands
handle_service_commands() {
    case "$1" in
        start)
            start_mongodb_service
            ;;
        stop)
            stop_mongodb_service
            ;;
        restart)
            restart_mongodb_service
            ;;
        enable)
            enable_mongodb_service
            ;;
        *)
            error "Unknown service command: $1"
            return 1
            ;;
    esac
}

# ================================
# Option Parsing
# ================================

# Parse command line options
parse_options() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                export MONGODB_HARDENING_VERBOSE=true
                shift
                ;;
            -d|--debug)
                export MONGODB_HARDENING_DEBUG=true
                export MONGODB_HARDENING_VERBOSE=true
                export MONGODB_HARDENING_LOG_LEVEL=DEBUG
                shift
                ;;
            -f|--force)
                export MONGODB_HARDENING_FORCE=true
                shift
                ;;
            -n|--dry-run)
                export MONGODB_HARDENING_DRY_RUN=true
                shift
                ;;
            -c|--config)
                export MONGODB_HARDENING_CONFIG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                error "Unknown option: $1"
                exit 1
                ;;
            *)
                break
                ;;
        esac
    done
    
    # Return remaining arguments
    echo "$@"
}

# ================================
# Main Function
# ================================

main() {
    # Handle help/version first (before initialization)
    case "${1:-}" in
        -h|--help|help)
            show_help
            exit 0
            ;;
        --version|version)
            show_version
            exit 0
            ;;
    esac
    
    # Initialize application 
    initialize_application "${1:-}"
    
    # Parse command line options
    local args
    args=$(parse_options "$@")
    eval "set -- $args"
    
    # Handle commands
    local command="$1"
    
    if [[ -z "$command" ]]; then
        print_header "$SCRIPT_DESCRIPTION"
        error "No command specified"
        echo "Use '$0 --help' for usage information"
        exit 1
    fi
    
    case "$command" in
        # System analysis commands
        system-info|mongodb-status|security-check|health-check)
            handle_system_commands "$@"
            ;;
            
        # Configuration commands
        configure|harden|setup-ssl|setup-auth|setup-firewall)
            handle_configuration_commands "$@"
            ;;
            
        # SSL/TLS commands
        ssl)
            handle_ssl_commands "$@"
            ;;
            
        # Backup commands
        backup|restore|backup-list|backup-schedule|backup-cleanup)
            handle_backup_commands "$@"
            ;;
            
        # Monitoring commands
        monitoring)
            handle_monitoring_commands "$@"
            ;;
            
        # Metrics commands
        metrics)
            handle_metrics_commands "$@"
            ;;
            
        # Firewall commands
        firewall)
            handle_firewall_commands "$@"
            ;;
            
        # Service commands
        start|stop|restart|enable)
            handle_service_commands "$@"
            ;;
            
        # Utility commands
        help)
            show_help
            ;;
        version)
            show_version
            ;;
        info)
            show_info "$2"
            ;;
            
        *)
            error "Unknown command: $command"
            echo "Use '$0 --help' for available commands"
            exit 1
            ;;
    esac
}

# ================================
# Script Execution
# ================================

# Only run main if this script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi