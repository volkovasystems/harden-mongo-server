#!/usr/bin/env bash
# MongoDB Server Hardening Tool - Firewall Library
# Provides firewall rule management for different firewall systems

# Prevent multiple inclusion
if [[ -n "${_HARDEN_MONGO_SERVER_FIREWALL_LOADED:-}" ]]; then
    return 0
fi
readonly _HARDEN_MONGO_SERVER_FIREWALL_LOADED=1

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
# Firewall Configuration Constants
# ================================

# Default MongoDB ports (using from core.sh)
# MONGODB_DEFAULT_PORT is defined in core.sh
readonly MONGODB_CONFIG_SERVER_PORT="27019"
readonly MONGODB_SHARD_SERVER_PORT="27018"

# Firewall systems
readonly -A FIREWALL_SYSTEMS=(
    [ufw]="Uncomplicated Firewall (Ubuntu/Debian)"
    [firewalld]="FirewallD (RHEL/CentOS/Fedora)"
    [iptables]="IPTables (Generic Linux)"
    [nftables]="NFTables (Modern Linux)"
)

# Common service names
readonly -A SERVICE_PORTS=(
    [ssh]="22"
    [http]="80"
    [https]="443"
    [mongodb]="27017"
    [mongodb-config]="27019"
    [mongodb-shard]="27018"
)

# ================================
# Firewall Detection and Management
# ================================

# Detect active firewall system
detect_firewall_system() {
    local firewall_type="none"
    
    # Check for UFW (Ubuntu/Debian)
    if command_exists ufw; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            firewall_type="ufw"
        fi
    fi
    
    # Check for FirewallD (RHEL/CentOS/Fedora)
    if [[ "$firewall_type" == "none" ]] && command_exists firewall-cmd; then
        if firewall-cmd --state 2>/dev/null | grep -q "running"; then
            firewall_type="firewalld"
        fi
    fi
    
    # Check for iptables
    if [[ "$firewall_type" == "none" ]] && command_exists iptables; then
        if iptables -L -n 2>/dev/null | grep -q "Chain"; then
            local rule_count
            rule_count=$(iptables -L -n 2>/dev/null | wc -l)
            if ((rule_count > 10)); then  # More than basic chains
                firewall_type="iptables"
            fi
        fi
    fi
    
    # Check for nftables
    if [[ "$firewall_type" == "none" ]] && command_exists nft; then
        if nft list tables 2>/dev/null | grep -q "table"; then
            firewall_type="nftables"
        fi
    fi
    
    echo "$firewall_type"
}

# Get firewall status
get_firewall_status() {
    local firewall_type
    firewall_type=$(detect_firewall_system)
    
    case "$firewall_type" in
        ufw)
            ufw status verbose 2>/dev/null
            ;;
        firewalld)
            echo "FirewallD Status:"
            firewall-cmd --state 2>/dev/null
            echo "Active zones:"
            firewall-cmd --get-active-zones 2>/dev/null
            ;;
        iptables)
            echo "IPTables Rules:"
            iptables -L -n --line-numbers 2>/dev/null
            ;;
        nftables)
            echo "NFTables Rules:"
            nft list ruleset 2>/dev/null
            ;;
        *)
            echo "No active firewall detected"
            ;;
    esac
}

# Enable firewall
enable_firewall() {
    local firewall_type
    firewall_type=$(detect_firewall_system)
    
    if [[ "$firewall_type" == "none" ]]; then
        # Try to detect installed but inactive firewalls
        if command_exists ufw; then
            firewall_type="ufw"
        elif command_exists firewall-cmd; then
            firewall_type="firewalld"
        elif command_exists iptables; then
            firewall_type="iptables"
        else
            error "No supported firewall system found"
            return 1
        fi
    fi
    
    info "Enabling $firewall_type firewall"
    
    case "$firewall_type" in
        ufw)
            execute_or_simulate "Enable UFW firewall" "ufw --force enable"
            ;;
        firewalld)
            execute_or_simulate "Enable FirewallD" "systemctl enable --now firewalld"
            ;;
        iptables)
            info "IPTables is already active with custom rules"
            ;;
        nftables)
            execute_or_simulate "Enable NFTables" "systemctl enable --now nftables"
            ;;
        *)
            error "Unsupported firewall type: $firewall_type"
            return 1
            ;;
    esac
    
    success "Firewall enabled successfully"
}

# ================================
# MongoDB-Specific Firewall Rules
# ================================

# Allow MongoDB port from specific source
allow_mongodb_port() {
    local port="${1:-$MONGODB_DEFAULT_PORT}"
    local source_ip="${2:-any}"
    local interface="${3:-}"
    local firewall_type
    
    firewall_type=$(detect_firewall_system)
    
    if [[ "$firewall_type" == "none" ]]; then
        warn "No active firewall detected, enabling default firewall"
        if ! enable_firewall; then
            return 1
        fi
        firewall_type=$(detect_firewall_system)
    fi
    
    info "Adding MongoDB firewall rule: port $port from $source_ip"
    
    case "$firewall_type" in
        ufw)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Allow MongoDB port $port" \
                    "ufw allow $port/tcp"
            else
                execute_or_simulate "Allow MongoDB port $port from $source_ip" \
                    "ufw allow from $source_ip to any port $port proto tcp"
            fi
            ;;
        firewalld)
            local zone="public"
            if [[ -n "$interface" ]]; then
                zone=$(firewall-cmd --get-zone-of-interface="$interface" 2>/dev/null || echo "public")
            fi
            
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Allow MongoDB port $port" \
                    "firewall-cmd --permanent --zone=$zone --add-port=$port/tcp && firewall-cmd --reload"
            else
                execute_or_simulate "Allow MongoDB port $port from $source_ip" \
                    "firewall-cmd --permanent --zone=$zone --add-rich-rule='rule source address=\"$source_ip\" port protocol=\"tcp\" port=\"$port\" accept' && firewall-cmd --reload"
            fi
            ;;
        iptables)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Allow MongoDB port $port" \
                    "iptables -A INPUT -p tcp --dport $port -j ACCEPT"
            else
                execute_or_simulate "Allow MongoDB port $port from $source_ip" \
                    "iptables -A INPUT -p tcp -s $source_ip --dport $port -j ACCEPT"
            fi
            ;;
        nftables)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Allow MongoDB port $port" \
                    "nft add rule inet filter input tcp dport $port accept"
            else
                execute_or_simulate "Allow MongoDB port $port from $source_ip" \
                    "nft add rule inet filter input ip saddr $source_ip tcp dport $port accept"
            fi
            ;;
        *)
            error "Unsupported firewall type: $firewall_type"
            return 1
            ;;
    esac
    
    success "MongoDB firewall rule added successfully"
}

# Block MongoDB port from specific source or all
block_mongodb_port() {
    local port="${1:-$MONGODB_DEFAULT_PORT}"
    local source_ip="${2:-any}"
    local firewall_type
    
    firewall_type=$(detect_firewall_system)
    
    if [[ "$firewall_type" == "none" ]]; then
        warn "No active firewall detected"
        return 1
    fi
    
    info "Blocking MongoDB port $port from $source_ip"
    
    case "$firewall_type" in
        ufw)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Block MongoDB port $port" \
                    "ufw deny $port/tcp"
            else
                execute_or_simulate "Block MongoDB port $port from $source_ip" \
                    "ufw deny from $source_ip to any port $port proto tcp"
            fi
            ;;
        firewalld)
            local zone="public"
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Block MongoDB port $port" \
                    "firewall-cmd --permanent --zone=$zone --remove-port=$port/tcp && firewall-cmd --reload"
            else
                execute_or_simulate "Block MongoDB port $port from $source_ip" \
                    "firewall-cmd --permanent --zone=$zone --add-rich-rule='rule source address=\"$source_ip\" port protocol=\"tcp\" port=\"$port\" drop' && firewall-cmd --reload"
            fi
            ;;
        iptables)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Block MongoDB port $port" \
                    "iptables -A INPUT -p tcp --dport $port -j DROP"
            else
                execute_or_simulate "Block MongoDB port $port from $source_ip" \
                    "iptables -A INPUT -p tcp -s $source_ip --dport $port -j DROP"
            fi
            ;;
        nftables)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Block MongoDB port $port" \
                    "nft add rule inet filter input tcp dport $port drop"
            else
                execute_or_simulate "Block MongoDB port $port from $source_ip" \
                    "nft add rule inet filter input ip saddr $source_ip tcp dport $port drop"
            fi
            ;;
        *)
            error "Unsupported firewall type: $firewall_type"
            return 1
            ;;
    esac
    
    success "MongoDB port blocked successfully"
}

# Configure MongoDB cluster firewall rules
configure_mongodb_cluster_firewall() {
    local mongodb_port="${1:-$MONGODB_DEFAULT_PORT}"
    local allowed_ips="${2:-127.0.0.1}"
    local allow_config_server="${3:-false}"
    local allow_shard_server="${4:-false}"
    
    info "Configuring MongoDB cluster firewall rules"
    
    # Convert comma-separated IPs to array
    IFS=',' read -ra ip_array <<< "$allowed_ips"
    
    # Allow MongoDB main port
    for ip in "${ip_array[@]}"; do
        ip=$(echo "$ip" | xargs)  # trim whitespace
        if [[ -n "$ip" ]]; then
            allow_mongodb_port "$mongodb_port" "$ip"
        fi
    done
    
    # Allow config server port if requested
    if [[ "$allow_config_server" == "true" ]]; then
        for ip in "${ip_array[@]}"; do
            ip=$(echo "$ip" | xargs)
            if [[ -n "$ip" ]]; then
                allow_mongodb_port "$MONGODB_CONFIG_SERVER_PORT" "$ip"
            fi
        done
    fi
    
    # Allow shard server port if requested
    if [[ "$allow_shard_server" == "true" ]]; then
        for ip in "${ip_array[@]}"; do
            ip=$(echo "$ip" | xargs)
            if [[ -n "$ip" ]]; then
                allow_mongodb_port "$MONGODB_SHARD_SERVER_PORT" "$ip"
            fi
        done
    fi
    
    success "MongoDB cluster firewall rules configured"
}

# ================================
# General Firewall Rule Management
# ================================

# Allow SSH access (critical for remote management)
allow_ssh_access() {
    local source_ip="${1:-any}"
    local ssh_port="${2:-22}"
    
    info "Ensuring SSH access is allowed"
    
    local firewall_type
    firewall_type=$(detect_firewall_system)
    
    case "$firewall_type" in
        ufw)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Allow SSH" "ufw allow $ssh_port/tcp"
            else
                execute_or_simulate "Allow SSH from $source_ip" \
                    "ufw allow from $source_ip to any port $ssh_port proto tcp"
            fi
            ;;
        firewalld)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Allow SSH" \
                    "firewall-cmd --permanent --add-service=ssh && firewall-cmd --reload"
            else
                execute_or_simulate "Allow SSH from $source_ip" \
                    "firewall-cmd --permanent --add-rich-rule='rule source address=\"$source_ip\" service name=\"ssh\" accept' && firewall-cmd --reload"
            fi
            ;;
        iptables)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Allow SSH" \
                    "iptables -A INPUT -p tcp --dport $ssh_port -j ACCEPT"
            else
                execute_or_simulate "Allow SSH from $source_ip" \
                    "iptables -A INPUT -p tcp -s $source_ip --dport $ssh_port -j ACCEPT"
            fi
            ;;
        nftables)
            if [[ "$source_ip" == "any" ]]; then
                execute_or_simulate "Allow SSH" \
                    "nft add rule inet filter input tcp dport $ssh_port accept"
            else
                execute_or_simulate "Allow SSH from $source_ip" \
                    "nft add rule inet filter input ip saddr $source_ip tcp dport $ssh_port accept"
            fi
            ;;
        *)
            warn "No firewall detected, SSH access management skipped"
            ;;
    esac
    
    success "SSH access configured"
}

# Allow loopback traffic (essential for system operation)
allow_loopback_traffic() {
    local firewall_type
    firewall_type=$(detect_firewall_system)
    
    info "Ensuring loopback traffic is allowed"
    
    case "$firewall_type" in
        ufw)
            execute_or_simulate "Allow loopback traffic" \
                "ufw allow in on lo && ufw allow out on lo"
            ;;
        firewalld)
            # FirewallD allows loopback by default
            info "FirewallD allows loopback traffic by default"
            ;;
        iptables)
            execute_or_simulate "Allow loopback input" \
                "iptables -A INPUT -i lo -j ACCEPT"
            execute_or_simulate "Allow loopback output" \
                "iptables -A OUTPUT -o lo -j ACCEPT"
            ;;
        nftables)
            execute_or_simulate "Allow loopback traffic" \
                "nft add rule inet filter input iif lo accept"
            ;;
        *)
            warn "No firewall detected, loopback configuration skipped"
            ;;
    esac
    
    success "Loopback traffic allowed"
}

# Set default firewall policies
set_default_firewall_policy() {
    local input_policy="${1:-drop}"
    local output_policy="${2:-accept}"
    local forward_policy="${3:-drop}"
    
    local firewall_type
    firewall_type=$(detect_firewall_system)
    
    info "Setting default firewall policies: input=$input_policy, output=$output_policy"
    
    case "$firewall_type" in
        ufw)
            execute_or_simulate "Set UFW default policies" \
                "ufw --force default $input_policy incoming && ufw --force default $output_policy outgoing"
            ;;
        firewalld)
            # FirewallD uses zone-based approach, default zone policies
            local zone="public"
            case "$input_policy" in
                drop|DROP)
                    execute_or_simulate "Set FirewallD default target" \
                        "firewall-cmd --permanent --zone=$zone --set-target=DROP && firewall-cmd --reload"
                    ;;
                accept|ACCEPT)
                    execute_or_simulate "Set FirewallD default target" \
                        "firewall-cmd --permanent --zone=$zone --set-target=ACCEPT && firewall-cmd --reload"
                    ;;
            esac
            ;;
        iptables)
            execute_or_simulate "Set iptables default policies" \
                "iptables -P INPUT ${input_policy^^} && iptables -P OUTPUT ${output_policy^^} && iptables -P FORWARD ${forward_policy^^}"
            ;;
        nftables)
            execute_or_simulate "Set nftables default policies" \
                "nft add chain inet filter input { type filter hook input priority 0 \\; policy ${input_policy} \\; }"
            execute_or_simulate "Set nftables output policy" \
                "nft add chain inet filter output { type filter hook output priority 0 \\; policy ${output_policy} \\; }"
            ;;
        *)
            error "No supported firewall detected"
            return 1
            ;;
    esac
    
    success "Default firewall policies set"
}

# ================================
# Firewall Rule Analysis and Reporting
# ================================

# List MongoDB-related firewall rules
list_mongodb_firewall_rules() {
    local firewall_type
    firewall_type=$(detect_firewall_system)
    
    print_section "MongoDB Firewall Rules"
    
    case "$firewall_type" in
        ufw)
            info "UFW rules related to MongoDB:"
            ufw status numbered 2>/dev/null | grep -E "(27017|27018|27019|mongodb)" || echo "No MongoDB-specific rules found"
            ;;
        firewalld)
            info "FirewallD rules related to MongoDB:"
            echo "Ports:"
            firewall-cmd --list-ports 2>/dev/null | grep -E "(27017|27018|27019)" || echo "No MongoDB ports found"
            echo "Rich rules:"
            firewall-cmd --list-rich-rules 2>/dev/null | grep -E "(27017|27018|27019)" || echo "No MongoDB rich rules found"
            ;;
        iptables)
            info "IPTables rules related to MongoDB:"
            iptables -L -n --line-numbers 2>/dev/null | grep -E "(27017|27018|27019)" || echo "No MongoDB-specific rules found"
            ;;
        nftables)
            info "NFTables rules related to MongoDB:"
            nft list ruleset 2>/dev/null | grep -E "(27017|27018|27019)" || echo "No MongoDB-specific rules found"
            ;;
        *)
            warn "No supported firewall detected"
            ;;
    esac
}

# Check firewall configuration for security issues
check_firewall_security() {
    print_section "Firewall Security Assessment"
    
    local firewall_type
    firewall_type=$(detect_firewall_system)
    local issues_found=0
    
    if [[ "$firewall_type" == "none" ]]; then
        report_issue "high" "No active firewall detected" \
            "Enable and configure a firewall system"
        ((issues_found++))
        return $issues_found
    fi
    
    success "Active firewall detected: $firewall_type"
    
    # Check for overly permissive rules
    case "$firewall_type" in
        ufw)
            # Check for rules allowing from anywhere
            if ufw status 2>/dev/null | grep -q "Anywhere"; then
                local anywhere_count
                anywhere_count=$(ufw status 2>/dev/null | grep -c "Anywhere")
                if ((anywhere_count > 2)); then  # SSH and maybe one service
                    report_issue "medium" "Multiple services allow access from anywhere" \
                        "Review and restrict access to specific IP addresses"
                    ((issues_found++))
                fi
            fi
            
            # Check if UFW is inactive
            if ! ufw status 2>/dev/null | grep -q "Status: active"; then
                report_issue "high" "UFW is installed but not active" \
                    "Enable UFW with 'ufw enable'"
                ((issues_found++))
            fi
            ;;
        firewalld)
            # Check public zone configuration
            local public_ports
            public_ports=$(firewall-cmd --zone=public --list-ports 2>/dev/null || echo "")
            if [[ "$public_ports" == *"27017"* ]]; then
                report_issue "medium" "MongoDB port 27017 is open to public zone" \
                    "Restrict access using rich rules with specific source IPs"
                ((issues_found++))
            fi
            ;;
        iptables)
            # Check for ACCEPT rules without source restrictions
            if iptables -L INPUT -n 2>/dev/null | grep -q "ACCEPT.*0.0.0.0/0.*27017"; then
                report_issue "high" "MongoDB port 27017 accepts connections from anywhere" \
                    "Add source IP restrictions to MongoDB iptables rules"
                ((issues_found++))
            fi
            ;;
    esac
    
    # Check for MongoDB port exposure
    local mongodb_ports=("27017" "27018" "27019")
    for port in "${mongodb_ports[@]}"; do
        if port_in_use "$port"; then
            local port_exposed=false
            
            case "$firewall_type" in
                ufw)
                    if ufw status 2>/dev/null | grep -q "$port.*Anywhere"; then
                        port_exposed=true
                    fi
                    ;;
                firewalld)
                    if firewall-cmd --list-ports 2>/dev/null | grep -q "$port"; then
                        port_exposed=true
                    fi
                    ;;
                iptables)
                    if iptables -L INPUT -n 2>/dev/null | grep -q "ACCEPT.*dpt:$port"; then
                        port_exposed=true
                    fi
                    ;;
            esac
            
            if [[ "$port_exposed" == "true" ]]; then
                info "MongoDB port $port is accessible through firewall"
            fi
        fi
    done
    
    if ((issues_found == 0)); then
        success "No critical firewall security issues found"
    else
        warn "$issues_found firewall security issues identified"
    fi
    
    return $((issues_found > 0 ? 1 : 0))
}

# ================================
# Firewall Backup and Restore
# ================================

# Backup firewall rules
backup_firewall_rules() {
    local backup_dir="${1:-/var/backups/firewall}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    
    info "Backing up firewall rules to $backup_dir"
    
    create_dir_safe "$backup_dir" 755 root:root
    
    local firewall_type
    firewall_type=$(detect_firewall_system)
    
    case "$firewall_type" in
        ufw)
            execute_or_simulate "Backup UFW rules" \
                "cp -r /etc/ufw '$backup_dir/ufw_$timestamp' && cp /lib/ufw/user*.rules '$backup_dir/' 2>/dev/null || true"
            ;;
        firewalld)
            execute_or_simulate "Backup FirewallD configuration" \
                "cp -r /etc/firewalld '$backup_dir/firewalld_$timestamp'"
            ;;
        iptables)
            execute_or_simulate "Backup iptables rules" \
                "iptables-save > '$backup_dir/iptables_$timestamp.rules'"
            ;;
        nftables)
            execute_or_simulate "Backup nftables rules" \
                "nft list ruleset > '$backup_dir/nftables_$timestamp.rules'"
            ;;
        *)
            warn "No supported firewall detected for backup"
            return 1
            ;;
    esac
    
    success "Firewall rules backed up successfully"
}

# ================================
# Quick Setup Functions
# ================================

# Quick MongoDB firewall setup for development
setup_development_firewall() {
    local mongodb_port="${1:-$MONGODB_DEFAULT_PORT}"
    
    print_section "Setting up Development MongoDB Firewall"
    
    # Enable firewall if not active
    enable_firewall
    
    # Allow loopback traffic
    allow_loopback_traffic
    
    # Allow SSH access
    allow_ssh_access
    
    # Allow MongoDB only from localhost
    allow_mongodb_port "$mongodb_port" "127.0.0.1"
    
    # Set restrictive default policies
    set_default_firewall_policy "drop" "accept"
    
    success "Development firewall setup completed"
}

# Quick MongoDB firewall setup for production
setup_production_firewall() {
    local mongodb_port="${1:-$MONGODB_DEFAULT_PORT}"
    local allowed_ips="${2:-127.0.0.1}"
    local ssh_source="${3:-any}"
    
    print_section "Setting up Production MongoDB Firewall"
    
    # Backup existing rules
    backup_firewall_rules
    
    # Enable firewall if not active
    enable_firewall
    
    # Allow loopback traffic
    allow_loopback_traffic
    
    # Allow SSH access from specified source
    allow_ssh_access "$ssh_source"
    
    # Configure MongoDB cluster rules
    configure_mongodb_cluster_firewall "$mongodb_port" "$allowed_ips"
    
    # Set restrictive default policies
    set_default_firewall_policy "drop" "accept"
    
    success "Production firewall setup completed"
}

# ================================
# Module Information
# ================================

# Module information
firewall_module_info() {
    cat << EOF
MongoDB Server Hardening Firewall Library v$HARDEN_MONGO_SERVER_VERSION

This module provides:
- Multi-firewall system support (UFW, FirewallD, IPTables, NFTables)
- MongoDB-specific firewall rule management
- Cluster firewall configuration for replica sets and sharding
- SSH and essential service access management
- Firewall security assessment and rule analysis
- Quick setup templates for development and production
- Firewall rule backup and restore functionality

Functions:
- detect_firewall_system: Identify active firewall system
- enable_firewall: Activate firewall system
- allow_mongodb_port: Add MongoDB access rules
- configure_mongodb_cluster_firewall: Setup cluster access
- allow_ssh_access: Ensure SSH connectivity
- set_default_firewall_policy: Configure default policies
- check_firewall_security: Security assessment
- setup_development_firewall: Quick dev environment setup
- setup_production_firewall: Production-ready configuration

Supported Firewalls:
- UFW (Uncomplicated Firewall) - Ubuntu/Debian default
- FirewallD - RHEL/CentOS/Fedora default
- IPTables - Traditional Linux firewall
- NFTables - Modern Linux firewall replacement

MongoDB Ports:
- 27017: Default MongoDB instance
- 27018: Shard server default
- 27019: Config server default

Dependencies: core.sh, logging.sh, system.sh
EOF
}