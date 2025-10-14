#!/usr/bin/env bash
# MongoDB Server Hardening Tool - System Library
# Provides system environment detection, validation, and compatibility checks

# Prevent multiple inclusion
if [[ -n "${_HARDEN_MONGO_SERVER_SYSTEM_LOADED:-}" ]]; then
    return 0
fi
readonly _HARDEN_MONGO_SERVER_SYSTEM_LOADED=1

# Load required modules
if [[ -z "${_HARDEN_MONGO_SERVER_CORE_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
fi

if [[ -z "${_HARDEN_MONGO_SERVER_LOGGING_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
fi

# ================================
# System Information Detection
# ================================

# Detect Linux distribution
detect_linux_distro() {
    local distro="unknown"
    local version="unknown"
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        distro="${ID:-unknown}"
        version="${VERSION_ID:-unknown}"
    elif [[ -f /etc/redhat-release ]]; then
        if grep -q "CentOS" /etc/redhat-release; then
            distro="centos"
        elif grep -q "Red Hat" /etc/redhat-release; then
            distro="rhel"
        elif grep -q "Fedora" /etc/redhat-release; then
            distro="fedora"
        fi
        version=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
    elif [[ -f /etc/debian_version ]]; then
        distro="debian"
        version=$(cat /etc/debian_version)
    fi
    
    echo "$distro $version"
}

# Get system architecture details
get_system_architecture() {
    local arch
    arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)
            echo "x86_64"
            ;;
        i386|i686)
            echo "i386"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l)
            echo "armv7"
            ;;
        *)
            echo "$arch"
            ;;
    esac
}

# Check if system is virtualized
is_virtualized() {
    local virt_type="none"
    
    # Check systemd-detect-virt if available
    if command_exists systemd-detect-virt; then
        virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
    fi
    
    # Check DMI information
    if [[ "$virt_type" == "none" && -r /sys/class/dmi/id/product_name ]]; then
        local product_name
        product_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
        case "$product_name" in
            *VMware*) virt_type="vmware" ;;
            *VirtualBox*) virt_type="virtualbox" ;;
            *KVM*) virt_type="kvm" ;;
            *QEMU*) virt_type="qemu" ;;
        esac
    fi
    
    # Check hypervisor flag in CPU
    if [[ "$virt_type" == "none" ]] && grep -q "^flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
        virt_type="unknown_hypervisor"
    fi
    
    echo "$virt_type"
}

# Get system uptime in seconds
get_system_uptime() {
    local uptime_seconds
    if [[ -r /proc/uptime ]]; then
        uptime_seconds=$(cut -d. -f1 /proc/uptime)
    else
        uptime_seconds=$(uptime -s | xargs -I{} date -d{} +%s)
        uptime_seconds=$(($(date +%s) - uptime_seconds))
    fi
    echo "$uptime_seconds"
}

# Get system load averages
get_system_load() {
    if [[ -r /proc/loadavg ]]; then
        cat /proc/loadavg | cut -d' ' -f1-3
    else
        uptime | grep -oE 'load average[s]?: [0-9.,]+' | cut -d: -f2 | tr -d ' '
    fi
}

# ================================
# Resource Detection
# ================================

# Get detailed memory information
get_memory_info() {
    local mem_total=0
    local mem_available=0
    local mem_free=0
    local swap_total=0
    local swap_free=0
    
    if [[ -r /proc/meminfo ]]; then
        mem_total=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
        mem_available=$(grep "^MemAvailable:" /proc/meminfo | awk '{print $2}' || echo "0")
        mem_free=$(grep "^MemFree:" /proc/meminfo | awk '{print $2}')
        swap_total=$(grep "^SwapTotal:" /proc/meminfo | awk '{print $2}')
        swap_free=$(grep "^SwapFree:" /proc/meminfo | awk '{print $2}')
        
        # Convert from KB to MB
        mem_total=$((mem_total / 1024))
        mem_available=$((mem_available / 1024))
        mem_free=$((mem_free / 1024))
        swap_total=$((swap_total / 1024))
        swap_free=$((swap_free / 1024))
    fi
    
    echo "total:$mem_total available:$mem_available free:$mem_free swap_total:$swap_total swap_free:$swap_free"
}

# Get CPU information
get_cpu_info() {
    local cpu_count=1
    local cpu_model="unknown"
    local cpu_mhz="unknown"
    
    if [[ -r /proc/cpuinfo ]]; then
        cpu_count=$(grep -c "^processor" /proc/cpuinfo)
        cpu_model=$(grep "^model name" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
        cpu_mhz=$(grep "^cpu MHz" /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ *//')
    fi
    
    echo "count:$cpu_count model:$cpu_model mhz:$cpu_mhz"
}

# Get disk space information for key directories
get_disk_usage() {
    local path="${1:-/}"
    local usage_info
    
    if command_exists df; then
        usage_info=$(df -h "$path" 2>/dev/null | tail -1)
        if [[ -n "$usage_info" ]]; then
            local filesystem=$(echo "$usage_info" | awk '{print $1}')
            local size=$(echo "$usage_info" | awk '{print $2}')
            local used=$(echo "$usage_info" | awk '{print $3}')
            local available=$(echo "$usage_info" | awk '{print $4}')
            local percent=$(echo "$usage_info" | awk '{print $5}')
            
            echo "filesystem:$filesystem size:$size used:$used available:$available percent:$percent"
        else
            echo "error:cannot_read_disk_usage"
        fi
    else
        echo "error:df_command_not_available"
    fi
}

# ================================
# Network Information
# ================================

# Get network interface information
get_network_interfaces() {
    local interfaces=()
    
    if command_exists ip; then
        while IFS= read -r line; do
            if [[ $line =~ ^[0-9]+:\ ([^:]+): ]]; then
                local iface="${BASH_REMATCH[1]}"
                if [[ "$iface" != "lo" ]]; then
                    interfaces+=("$iface")
                fi
            fi
        done < <(ip link show 2>/dev/null)
    elif command_exists ifconfig; then
        while IFS= read -r line; do
            if [[ $line =~ ^([^:\ ]+): ]]; then
                local iface="${BASH_REMATCH[1]}"
                if [[ "$iface" != "lo" ]]; then
                    interfaces+=("$iface")
                fi
            fi
        done < <(ifconfig -a 2>/dev/null)
    fi
    
    echo "${interfaces[@]}"
}

# Get primary IP address
get_primary_ip() {
    local primary_ip="127.0.0.1"
    
    # Try to get IP from default route
    if command_exists ip; then
        local default_iface
        default_iface=$(ip route | grep '^default' | head -1 | sed 's/.*dev \([^ ]*\).*/\1/')
        if [[ -n "$default_iface" ]]; then
            primary_ip=$(ip addr show "$default_iface" 2>/dev/null | grep 'inet ' | head -1 | awk '{print $2}' | cut -d'/' -f1)
        fi
    elif command_exists route && command_exists ifconfig; then
        local default_iface
        default_iface=$(route -n | grep '^0.0.0.0' | head -1 | awk '{print $8}')
        if [[ -n "$default_iface" ]]; then
            primary_ip=$(ifconfig "$default_iface" 2>/dev/null | grep 'inet ' | head -1 | awk '{print $2}')
        fi
    fi
    
    echo "${primary_ip:-127.0.0.1}"
}

# Check if firewall is active
check_firewall_status() {
    local firewall_status="none"
    
    # Check various firewall systems
    if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        firewall_status="ufw_active"
    elif command_exists firewall-cmd && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        firewall_status="firewalld_active"
    elif command_exists iptables && [[ $(iptables -L 2>/dev/null | wc -l) -gt 8 ]]; then
        firewall_status="iptables_active"
    elif systemctl is-active --quiet iptables 2>/dev/null; then
        firewall_status="iptables_service_active"
    fi
    
    echo "$firewall_status"
}

# ================================
# Service and Package Management
# ================================

# Detect package manager
detect_package_manager() {
    local pkg_manager="unknown"
    
    if command_exists apt; then
        pkg_manager="apt"
    elif command_exists yum; then
        pkg_manager="yum"
    elif command_exists dnf; then
        pkg_manager="dnf"
    elif command_exists zypper; then
        pkg_manager="zypper"
    elif command_exists pacman; then
        pkg_manager="pacman"
    fi
    
    echo "$pkg_manager"
}

# Check if package is installed
is_package_installed() {
    local package="$1"
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    case "$pkg_manager" in
        apt)
            dpkg -l "$package" 2>/dev/null | grep -q "^ii"
            ;;
        yum|dnf)
            rpm -q "$package" >/dev/null 2>&1
            ;;
        zypper)
            zypper search -i "$package" 2>/dev/null | grep -q "^i"
            ;;
        pacman)
            pacman -Q "$package" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# Get service manager type
detect_service_manager() {
    local service_manager="unknown"
    
    if command_exists systemctl && [[ -d /run/systemd/system ]]; then
        service_manager="systemd"
    elif command_exists service && [[ -d /etc/init.d ]]; then
        service_manager="sysvinit"
    elif command_exists rc-service && [[ -d /etc/init.d ]]; then
        service_manager="openrc"
    fi
    
    echo "$service_manager"
}

# ================================
# Security Features Detection
# ================================

# Check SELinux status
check_selinux_status() {
    local selinux_status="not_available"
    
    if command_exists getenforce; then
        case "$(getenforce 2>/dev/null)" in
            Enforcing) selinux_status="enforcing" ;;
            Permissive) selinux_status="permissive" ;;
            Disabled) selinux_status="disabled" ;;
        esac
    elif [[ -f /etc/selinux/config ]]; then
        if grep -q "^SELINUX=enforcing" /etc/selinux/config; then
            selinux_status="enforcing"
        elif grep -q "^SELINUX=permissive" /etc/selinux/config; then
            selinux_status="permissive"
        elif grep -q "^SELINUX=disabled" /etc/selinux/config; then
            selinux_status="disabled"
        fi
    fi
    
    echo "$selinux_status"
}

# Check AppArmor status
check_apparmor_status() {
    local apparmor_status="not_available"
    
    if command_exists aa-status; then
        if aa-status --enabled 2>/dev/null; then
            apparmor_status="active"
        else
            apparmor_status="inactive"
        fi
    elif [[ -d /sys/module/apparmor ]]; then
        apparmor_status="loaded"
    fi
    
    echo "$apparmor_status"
}

# Check for available security modules
get_security_modules() {
    local modules=()
    
    local selinux_status
    selinux_status=$(check_selinux_status)
    if [[ "$selinux_status" != "not_available" ]]; then
        modules+=("selinux:$selinux_status")
    fi
    
    local apparmor_status
    apparmor_status=$(check_apparmor_status)
    if [[ "$apparmor_status" != "not_available" ]]; then
        modules+=("apparmor:$apparmor_status")
    fi
    
    echo "${modules[@]}"
}

# ================================
# System Requirements Validation
# ================================

# Check minimum system requirements for MongoDB
validate_mongodb_requirements() {
    local errors=0
    local warnings=0
    
    info "Validating system requirements for MongoDB..."
    
    # Check architecture
    local arch
    arch=$(get_system_architecture)
    case "$arch" in
        x86_64|arm64)
            verbose "Architecture check passed: $arch"
            ;;
        *)
            warn "MongoDB may not be fully supported on architecture: $arch"
            ((warnings++))
            ;;
    esac
    
    # Check memory (minimum 1GB recommended)
    local mem_info
    mem_info=$(get_memory_info)
    local mem_total
    mem_total=$(echo "$mem_info" | grep -o "total:[0-9]*" | cut -d: -f2)
    
    if ((mem_total < 1024)); then
        warn "Low memory detected: ${mem_total}MB (minimum 1GB recommended)"
        ((warnings++))
    elif ((mem_total < 2048)); then
        info "Memory: ${mem_total}MB (consider upgrading for better performance)"
    else
        verbose "Memory check passed: ${mem_total}MB"
    fi
    
    # Check disk space (minimum 5GB for data directory)
    local disk_usage
    disk_usage=$(get_disk_usage /)
    local available
    available=$(echo "$disk_usage" | grep -o "available:[^:]*" | cut -d: -f2 | sed 's/G$//')
    
    if [[ "$available" =~ ^[0-9]+$ ]] && ((available < 5)); then
        error "Insufficient disk space: ${available}GB (minimum 5GB required)"
        ((errors++))
    else
        verbose "Disk space check passed: ${available}GB available"
    fi
    
    # Check for required commands
    local required_commands=(openssl ss netstat)
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            warn "Recommended command not found: $cmd"
            ((warnings++))
        else
            verbose "Command available: $cmd"
        fi
    done
    
    # Summary
    if ((errors == 0 && warnings == 0)); then
        success "All system requirements validated successfully"
    elif ((errors == 0)); then
        warn "System requirements met with $warnings warning(s)"
    else
        error "System requirements validation failed with $errors error(s) and $warnings warning(s)"
    fi
    
    return $((errors > 0 ? 1 : 0))
}

# Check system compatibility
check_system_compatibility() {
    local distro_info
    distro_info=$(detect_linux_distro)
    local distro=$(echo "$distro_info" | cut -d' ' -f1)
    local version=$(echo "$distro_info" | cut -d' ' -f2)
    
    print_section "System Compatibility Check"
    
    print_kv "Distribution" "$distro"
    print_kv "Version" "$version"
    print_kv "Architecture" "$(get_system_architecture)"
    print_kv "Virtualization" "$(is_virtualized)"
    print_kv "Package Manager" "$(detect_package_manager)"
    print_kv "Service Manager" "$(detect_service_manager)"
    
    local security_modules
    security_modules=$(get_security_modules)
    if [[ -n "$security_modules" ]]; then
        print_kv "Security Modules" "${security_modules[*]}"
    else
        print_kv "Security Modules" "none detected"
    fi
    
    echo
    
    # Check known compatible distributions
    case "$distro" in
        ubuntu|debian)
            success "Fully supported distribution"
            return 0
            ;;
        centos|rhel|fedora)
            success "Fully supported distribution"
            return 0
            ;;
        opensuse*|sles)
            success "Supported distribution"
            return 0
            ;;
        arch|manjaro)
            warn "Community supported distribution"
            return 0
            ;;
        *)
            warn "Unknown or untested distribution: $distro"
            warn "MongoDB hardening may require manual adjustments"
            return 1
            ;;
    esac
}

# ================================
# Hardware and Performance Analysis
# ================================

# Analyze system performance characteristics
analyze_system_performance() {
    print_section "System Performance Analysis"
    
    local cpu_info
    cpu_info=$(get_cpu_info)
    local cpu_count=$(echo "$cpu_info" | grep -o "count:[0-9]*" | cut -d: -f2)
    local cpu_model=$(echo "$cpu_info" | grep -o "model:.*" | cut -d: -f2-)
    
    print_kv "CPU Cores" "$cpu_count"
    print_kv "CPU Model" "$cpu_model"
    
    local mem_info
    mem_info=$(get_memory_info)
    local mem_total=$(echo "$mem_info" | grep -o "total:[0-9]*" | cut -d: -f2)
    local mem_available=$(echo "$mem_info" | grep -o "available:[0-9]*" | cut -d: -f2)
    
    print_kv "Total Memory" "${mem_total}MB"
    print_kv "Available Memory" "${mem_available}MB"
    
    local load_avg
    load_avg=$(get_system_load)
    print_kv "Load Average" "$load_avg"
    
    local uptime_seconds
    uptime_seconds=$(get_system_uptime)
    local uptime_days=$((uptime_seconds / 86400))
    print_kv "System Uptime" "${uptime_days} days"
    
    echo
    
    # Performance recommendations
    info "Performance Recommendations:"
    
    if ((cpu_count < 2)); then
        print_indent "Consider upgrading to multi-core CPU for better MongoDB performance"
    fi
    
    if ((mem_total < 4096)); then
        print_indent "Consider adding more RAM for optimal MongoDB performance"
    fi
    
    local virt_type
    virt_type=$(is_virtualized)
    if [[ "$virt_type" != "none" ]]; then
        print_indent "Running on virtualized environment ($virt_type) - monitor I/O performance"
    fi
    
    echo
}

# ================================
# Module Information
# ================================

# Comprehensive system report
generate_system_report() {
    print_header "System Analysis Report"
    
    # Basic system information
    show_system_info
    
    # Compatibility check
    check_system_compatibility
    
    # Performance analysis
    analyze_system_performance
    
    # Requirements validation
    validate_mongodb_requirements
    
    print_header "End of System Report"
}

# Module information
system_module_info() {
    cat << EOF
MongoDB Server Hardening System Library v$HARDEN_MONGO_SERVER_VERSION

This module provides:
- Linux distribution detection and identification
- System resource analysis (CPU, memory, disk, network)
- Hardware and virtualization detection
- Package manager and service manager detection
- Security module status (SELinux, AppArmor)
- System compatibility validation
- MongoDB requirements checking
- Performance analysis and recommendations

Functions:
- detect_linux_distro: Identify OS distribution and version
- get_system_architecture: Get normalized architecture string
- is_virtualized: Detect virtualization platform
- get_memory_info: Detailed memory information
- get_cpu_info: CPU specifications and count
- get_network_interfaces: Available network interfaces
- check_firewall_status: Firewall system detection
- validate_mongodb_requirements: System requirement validation
- generate_system_report: Comprehensive system analysis

Dependencies: core.sh, logging.sh
EOF
}