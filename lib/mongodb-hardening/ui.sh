#!/usr/bin/env bash
# MongoDB Hardening Utility - User Interface Library
# Provides user interaction functions, prompts, and input validation

# Prevent multiple inclusion
if [[ -n "${_MONGODB_HARDENING_UI_LOADED:-}" ]]; then
    return 0
fi
readonly _MONGODB_HARDENING_UI_LOADED=1

# Load required modules
if [[ -z "${_MONGODB_HARDENING_CORE_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
fi

if [[ -z "${_MONGODB_HARDENING_LOGGING_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
fi

# ================================
# Input Validation Functions
# ================================

# Validate user input against a pattern
validate_input() {
    local input="$1"
    local pattern="$2"
    local description="$3"
    
    if [[ $input =~ $pattern ]]; then
        return 0
    else
        error "Invalid $description: '$input'"
        return 1
    fi
}

# Validate and prompt for input until valid
prompt_and_validate() {
    local prompt="$1"
    local pattern="$2"
    local description="$3"
    local default="${4:-}"
    local hide_input="${5:-false}"
    local input
    
    while true; do
        if [[ -n "$default" ]]; then
            prompt_text="$prompt [$default]: "
        else
            prompt_text="$prompt: "
        fi
        
        echo -n "$(format_with_icon "$ICON_QUERY" "$prompt_text")"
        
        if [[ "$hide_input" == "true" ]]; then
            read -rs input
            echo  # Add newline after hidden input
        else
            read -r input
        fi
        
        # Use default if no input provided
        if [[ -z "$input" && -n "$default" ]]; then
            input="$default"
        fi
        
        # Skip validation if input is empty and no default
        if [[ -z "$input" && -z "$default" ]]; then
            warn "Input cannot be empty"
            continue
        fi
        
        if validate_input "$input" "$pattern" "$description"; then
            echo "$input"
            return 0
        fi
    done
}

# ================================
# Menu and Selection Functions
# ================================

# Display a menu and get user selection
show_menu() {
    local title="$1"
    shift
    local options=("$@")
    local choice
    
    print_section "$title"
    
    local i=1
    for option in "${options[@]}"; do
        echo "  $i) $option"
        ((i++))
    done
    echo "  0) Exit/Cancel"
    echo
    
    while true; do
        echo -n "$(format_with_icon "$ICON_QUERY" "Please select an option [0-$((${#options[@]}))]"): "
        read -r choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if ((choice == 0)); then
                return 255  # Special return code for exit/cancel
            elif ((choice >= 1 && choice <= ${#options[@]})); then
                return $((choice - 1))  # Return 0-based index
            fi
        fi
        
        warn "Invalid selection. Please choose a number between 0 and ${#options[@]}"
    done
}

# Multi-select menu
show_multi_select() {
    local title="$1"
    shift
    local options=("$@")
    local -a selected
    local choice
    local i
    
    # Initialize selection array
    for ((i=0; i<${#options[@]}; i++)); do
        selected[i]=false
    done
    
    while true; do
        clear
        print_section "$title"
        echo "Select multiple options (toggle with number, 'd' when done):"
        echo
        
        for ((i=0; i<${#options[@]}; i++)); do
            local marker="[ ]"
            if [[ "${selected[i]}" == "true" ]]; then
                marker="[x]"
            fi
            echo "  $((i+1))) $marker ${options[i]}"
        done
        echo
        echo "  d) Done"
        echo "  0) Cancel"
        echo
        
        echo -n "$(format_with_icon "$ICON_QUERY" "Selection"): "
        read -r choice
        
        case "$choice" in
            [dD]*)
                # Return selected indices
                local selected_indices=()
                for ((i=0; i<${#options[@]}; i++)); do
                    if [[ "${selected[i]}" == "true" ]]; then
                        selected_indices+=("$i")
                    fi
                done
                echo "${selected_indices[@]}"
                return 0
                ;;
            0)
                return 255  # Cancel
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#options[@]})); then
                    local index=$((choice - 1))
                    if [[ "${selected[index]}" == "true" ]]; then
                        selected[index]=false
                    else
                        selected[index]=true
                    fi
                else
                    warn "Invalid selection"
                    sleep 1
                fi
                ;;
        esac
    done
}

# ================================
# Specialized Prompts
# ================================

# Prompt for MongoDB configuration
prompt_mongodb_config() {
    print_section "MongoDB Configuration"
    
    local db_path
    local log_path
    local port
    local bind_ip
    
    # Database path
    db_path=$(prompt_and_validate \
        "MongoDB data directory" \
        "^/[a-zA-Z0-9/_.-]+$" \
        "directory path" \
        "$DEFAULT_DB_PATH")
    
    # Log path
    log_path=$(prompt_and_validate \
        "MongoDB log file path" \
        "^/[a-zA-Z0-9/_.-]+\\.log$" \
        "log file path" \
        "$DEFAULT_LOG_PATH")
    
    # Port
    port=$(prompt_and_validate \
        "MongoDB port" \
        "^[0-9]+$" \
        "port number" \
        "27017")
    
    if ! is_valid_port "$port"; then
        error "Invalid port number: $port"
        return 1
    fi
    
    # Bind IP
    bind_ip=$(prompt_and_validate \
        "Bind IP address (127.0.0.1 for localhost only)" \
        "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$" \
        "IP address" \
        "127.0.0.1")
    
    if ! is_valid_ip "$bind_ip"; then
        error "Invalid IP address: $bind_ip"
        return 1
    fi
    
    # Return configuration as array
    echo "$db_path" "$log_path" "$port" "$bind_ip"
}

# Prompt for SSL configuration
prompt_ssl_config() {
    print_section "SSL/TLS Configuration"
    
    local ca_dir
    local country
    local state
    local city
    local org
    local email
    local key_size
    local validity_days
    
    # CA directory
    ca_dir=$(prompt_and_validate \
        "CA directory path" \
        "^/[a-zA-Z0-9/_.-]+$" \
        "directory path" \
        "$DEFAULT_CA_DIR")
    
    # Certificate details
    country=$(prompt_and_validate \
        "Country code (2 letters)" \
        "^[A-Z]{2}$" \
        "country code" \
        "US")
    
    state=$(prompt_and_validate \
        "State or Province" \
        "^[a-zA-Z ]{2,}$" \
        "state name" \
        "California")
    
    city=$(prompt_and_validate \
        "City" \
        "^[a-zA-Z ]{2,}$" \
        "city name" \
        "San Francisco")
    
    org=$(prompt_and_validate \
        "Organization" \
        "^[a-zA-Z0-9 ]{2,}$" \
        "organization name" \
        "MongoDB CA")
    
    email=$(prompt_and_validate \
        "Email address" \
        "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$" \
        "email address" \
        "admin@$(hostname -d 2>/dev/null || echo "example.com")")
    
    # Key size
    local key_options=("2048" "4096")
    show_menu "Select RSA key size" "${key_options[@]}"
    local key_choice=$?
    if ((key_choice == 255)); then
        return 1
    fi
    key_size="${key_options[key_choice]}"
    
    # Validity period
    validity_days=$(prompt_and_validate \
        "Certificate validity (days)" \
        "^[0-9]+$" \
        "number of days" \
        "365")
    
    # Return configuration
    echo "$ca_dir" "$country" "$state" "$city" "$org" "$email" "$key_size" "$validity_days"
}

# Prompt for backup configuration
prompt_backup_config() {
    print_section "Backup Configuration"
    
    local backup_path
    local retention_days
    local compression
    
    # Backup path
    backup_path=$(prompt_and_validate \
        "Backup directory path" \
        "^/[a-zA-Z0-9/_.-]+$" \
        "directory path" \
        "$DEFAULT_BACKUP_PATH")
    
    # Retention period
    retention_days=$(prompt_and_validate \
        "Backup retention period (days)" \
        "^[0-9]+$" \
        "number of days" \
        "30")
    
    # Compression
    if confirm "Enable backup compression" "y"; then
        compression="true"
    else
        compression="false"
    fi
    
    echo "$backup_path" "$retention_days" "$compression"
}

# Prompt for user credentials
prompt_user_credentials() {
    local username="$1"
    local prompt_password="${2:-true}"
    local password=""
    
    if [[ "$prompt_password" == "true" ]]; then
        while true; do
            password=$(prompt_and_validate \
                "Password for user '$username'" \
                ".{8,}" \
                "password (minimum 8 characters)" \
                "" \
                "true")
            
            local password_confirm
            password_confirm=$(prompt_and_validate \
                "Confirm password" \
                ".*" \
                "password confirmation" \
                "" \
                "true")
            
            if [[ "$password" == "$password_confirm" ]]; then
                break
            else
                error "Passwords do not match. Please try again."
            fi
        done
    fi
    
    echo "$password"
}

# ================================
# Progress and Status Display
# ================================

# Show operation progress with steps
show_operation_progress() {
    local operation="$1"
    local total_steps="$2"
    local current_step="${3:-0}"
    
    print_subsection "$operation"
    show_progress "$current_step" "$total_steps" 50 "Progress"
}

# Display system information
show_system_info() {
    print_section "System Information"
    
    print_kv "Operating System" "$(get_os) $(get_os_version)"
    print_kv "Architecture" "$(get_architecture)"
    print_kv "Memory" "$(get_memory_gb) GB"
    print_kv "Available Disk Space" "$(get_disk_space_gb /) GB"
    print_kv "Hostname" "$(hostname)"
    print_kv "Current User" "$(whoami)"
    
    if is_root; then
        print_kv "Privileges" "Administrator (root)"
    else
        print_kv "Privileges" "Standard user"
    fi
    
    echo
}

# Display MongoDB status
show_mongodb_status() {
    print_section "MongoDB Status"
    
    if service_exists "mongod"; then
        local status
        status=$(systemctl is-active mongod 2>/dev/null || echo "unknown")
        print_kv "Service Status" "$status"
        
        local enabled
        enabled=$(systemctl is-enabled mongod 2>/dev/null || echo "unknown")
        print_kv "Auto Start" "$enabled"
        
        if [[ "$status" == "active" ]]; then
            local pid
            pid=$(pgrep -f mongod | head -1)
            if [[ -n "$pid" ]]; then
                print_kv "Process ID" "$pid"
                
                # Check port
                if port_in_use "27017"; then
                    print_kv "Port 27017" "In use"
                else
                    print_kv "Port 27017" "Available"
                fi
            fi
        fi
    else
        print_kv "MongoDB Service" "Not installed"
    fi
    
    echo
}

# ================================
# Interactive Configuration Wizard
# ================================

# Run interactive configuration wizard
configuration_wizard() {
    print_header "MongoDB Hardening Configuration Wizard"
    
    info "This wizard will help you configure MongoDB security settings."
    info "You can modify these settings later by editing the configuration file."
    echo
    
    if ! confirm "Do you want to proceed with the configuration wizard" "y"; then
        return 1
    fi
    
    local -A config
    
    # Basic MongoDB configuration
    local mongodb_config
    mongodb_config=($(prompt_mongodb_config))
    config[db_path]="${mongodb_config[0]}"
    config[log_path]="${mongodb_config[1]}"
    config[port]="${mongodb_config[2]}"
    config[bind_ip]="${mongodb_config[3]}"
    
    # SSL configuration
    if confirm "Configure SSL/TLS encryption" "y"; then
        local ssl_config
        ssl_config=($(prompt_ssl_config))
        config[ssl_enabled]="true"
        config[ca_dir]="${ssl_config[0]}"
        config[ssl_country]="${ssl_config[1]}"
        config[ssl_state]="${ssl_config[2]}"
        config[ssl_city]="${ssl_config[3]}"
        config[ssl_org]="${ssl_config[4]}"
        config[ssl_email]="${ssl_config[5]}"
        config[ssl_key_size]="${ssl_config[6]}"
        config[ssl_validity]="${ssl_config[7]}"
    else
        config[ssl_enabled]="false"
    fi
    
    # Authentication configuration
    if confirm "Enable MongoDB authentication" "y"; then
        config[auth_enabled]="true"
        
        local admin_user
        admin_user=$(prompt_and_validate \
            "Administrator username" \
            "^[a-zA-Z][a-zA-Z0-9_]{2,31}$" \
            "username" \
            "admin")
        config[admin_user]="$admin_user"
        
        local admin_password
        admin_password=$(prompt_user_credentials "$admin_user")
        config[admin_password]="$admin_password"
    else
        config[auth_enabled]="false"
    fi
    
    # Backup configuration
    if confirm "Configure automatic backups" "y"; then
        local backup_config
        backup_config=($(prompt_backup_config))
        config[backup_enabled]="true"
        config[backup_path]="${backup_config[0]}"
        config[backup_retention]="${backup_config[1]}"
        config[backup_compression]="${backup_config[2]}"
    else
        config[backup_enabled]="false"
    fi
    
    # Firewall configuration
    if confirm "Configure firewall rules" "y"; then
        config[firewall_enabled]="true"
        
        local allowed_ips
        allowed_ips=$(prompt_and_validate \
            "Allowed IP addresses (comma-separated, blank for localhost only)" \
            "^([0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}(,[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})*)?$" \
            "IP address list" \
            "")
        config[allowed_ips]="$allowed_ips"
    else
        config[firewall_enabled]="false"
    fi
    
    # Display configuration summary
    print_header "Configuration Summary"
    
    print_kv "Database Path" "${config[db_path]}"
    print_kv "Log Path" "${config[log_path]}"
    print_kv "Port" "${config[port]}"
    print_kv "Bind IP" "${config[bind_ip]}"
    print_kv "SSL/TLS" "${config[ssl_enabled]}"
    print_kv "Authentication" "${config[auth_enabled]}"
    print_kv "Backups" "${config[backup_enabled]}"
    print_kv "Firewall" "${config[firewall_enabled]}"
    echo
    
    if confirm "Apply this configuration" "y"; then
        # Save configuration to file
        local config_file="$MONGODB_HARDENING_CONF_DIR/mongodb-hardening.conf"
        create_dir_safe "$MONGODB_HARDENING_CONF_DIR" 755 root:root
        
        {
            echo "# MongoDB Hardening Configuration"
            echo "# Generated on $(get_timestamp)"
            echo
            for key in "${!config[@]}"; do
                echo "${key}=${config[$key]}"
            done
        } > "$config_file"
        
        chmod 600 "$config_file"
        success "Configuration saved to $config_file"
        
        # Return configuration for use by calling script
        for key in "${!config[@]}"; do
            echo "$key=${config[$key]}"
        done
        
        return 0
    else
        warn "Configuration cancelled"
        return 1
    fi
}

# ================================
# Module Information
# ================================

# Module information
ui_module_info() {
    cat << EOF
MongoDB Hardening UI Library v$MONGODB_HARDENING_VERSION

This module provides:
- Interactive prompts and input validation
- Menu systems and multi-select options
- Configuration wizards and setup dialogs
- Progress display and status reporting
- System information display
- User credential management

Functions:
- validate_input: Validate input against patterns
- prompt_and_validate: Prompt with validation loop
- show_menu: Display selection menu
- show_multi_select: Multi-choice selection
- prompt_mongodb_config: MongoDB configuration wizard
- prompt_ssl_config: SSL/TLS setup dialog
- configuration_wizard: Complete setup wizard

Dependencies: core.sh, logging.sh
EOF
}