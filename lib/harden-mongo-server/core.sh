#!/usr/bin/env bash
# MongoDB Server Hardening Tool - Core Library
# Provides common utilities, constants, and base functionality

# Prevent multiple inclusion
if [[ -n "${_HARDEN_MONGO_SERVER_CORE_LOADED:-}" ]]; then
    return 0
fi
readonly _HARDEN_MONGO_SERVER_CORE_LOADED=1

# ================================
# Core Constants and Configuration
# ================================

# Script metadata
readonly HARDEN_MONGO_SERVER_VERSION="$( { lib_dir=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"; parent_dir=\"$(cd \"$lib_dir/..\" && pwd)\"; if [[ -f \"$lib_dir/VERSION\" ]]; then sed -n '1p' \"$lib_dir/VERSION\"; elif [[ -f \"$parent_dir/VERSION\" ]]; then sed -n '1p' \"$parent_dir/VERSION\"; else echo \"0.0.0\"; fi; } 2>/dev/null)"
readonly HARDEN_MONGO_SERVER_NAME="MongoDB Server Hardening Tool"
readonly HARDEN_MONGO_SERVER_DESCRIPTION="A tool to harden MongoDB servers with comprehensive security and maintenance features"

# Default paths and directories
readonly DEFAULT_DB_PATH="/var/lib/mongodb"
readonly DEFAULT_LOG_PATH="/var/log/mongodb/mongod.log"
readonly DEFAULT_BACKUP_PATH="/var/backups/mongodb"
readonly DEFAULT_CA_DIR="/etc/mongoCA"
readonly DEFAULT_CLIENT_DIR="/etc/mongoCA/clients"

# Configuration file paths
readonly HARDEN_MONGO_SERVER_CONF_DIR="/etc/harden-mongo-server"
readonly HARDEN_MONGO_SERVER_LIB_DIR="/usr/lib/harden-mongo-server"
readonly HARDEN_MONGO_SERVER_SHARE_DIR="/usr/share/harden-mongo-server"
readonly HARDEN_MONGO_SERVER_VAR_DIR="/var/lib/harden-mongo-server"
readonly HARDEN_MONGO_SERVER_LOG_DIR="/var/log/harden-mongo-server"

# Runtime directories
readonly HARDEN_MONGO_SERVER_RUN_DIR="/var/run/harden-mongo-server"
readonly HARDEN_MONGO_SERVER_TEMP_DIR="${TMPDIR:-/tmp}/harden-mongo-server"

# ================================
# Global Variables
# ================================

# Execution context
declare -g HARDEN_MONGO_SERVER_VERBOSE=${HARDEN_MONGO_SERVER_VERBOSE:-false}
declare -g HARDEN_MONGO_SERVER_DEBUG=${HARDEN_MONGO_SERVER_DEBUG:-false}
declare -g HARDEN_MONGO_SERVER_DRY_RUN=${HARDEN_MONGO_SERVER_DRY_RUN:-false}
declare -g HARDEN_MONGO_SERVER_FORCE=${HARDEN_MONGO_SERVER_FORCE:-false}

# Counters for summary
declare -gi HARDEN_MONGO_SERVER_ISSUES_FOUND=0
declare -gi HARDEN_MONGO_SERVER_ISSUES_FIXED=0
declare -gi HARDEN_MONGO_SERVER_WARNINGS=0

# Color codes for output
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_MAGENTA='\033[0;35m'
readonly COLOR_BOLD='\033[1m'
readonly COLOR_NC='\033[0m'

# Icons for output
readonly ICON_INFO="ℹ"
readonly ICON_SUCCESS="✓"
readonly ICON_WARNING="⚠"
readonly ICON_ERROR="✗"
readonly ICON_FIXED="🔧"
readonly ICON_QUERY="?"
readonly ICON_SECURITY="🔒"
readonly ICON_EXPLAIN="📋"

# ================================
# Utility Functions
# ================================

# Get the library directory path
harden_mongo_server_lib_dir() {
    if [[ -d "$HARDEN_MONGO_SERVER_LIB_DIR" ]]; then
        echo "$HARDEN_MONGO_SERVER_LIB_DIR"
    else
        # Fallback to relative path from script location
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        echo "$script_dir"
    fi
}

# Load a library module
# Usage: load_module module_name
load_module() {
    local module_name="$1"
    local lib_dir
lib_dir="$(harden_mongo_server_lib_dir)"
    local module_path="$lib_dir/${module_name}.sh"
    
    if [[ ! -f "$module_path" ]]; then
        echo "Error: Module '$module_name' not found at '$module_path'" >&2
        return 1
    fi
    
    source "$module_path"
}

# Check if running as root
is_root() {
    [[ $EUID -eq 0 ]]
}

# Check if command exists
command_exists() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1
}

# Check if service exists
service_exists() {
    local service="$1"
    systemctl list-unit-files | grep -q "^${service}\\." 2>/dev/null
}

# Check if port is in use
port_in_use() {
    local port="$1"
    ss -tuln | grep -q ":${port} " 2>/dev/null
}

# Get system architecture
get_architecture() {
    uname -m
}

# Get system OS
get_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

# Get OS version
get_os_version() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "${VERSION_ID:-unknown}"
    else
        echo "unknown"
    fi
}

# Get available memory in GB
get_memory_gb() {
    local mem_kb
    mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo $((mem_kb / 1024 / 1024))
}

# Get available disk space in GB
get_disk_space_gb() {
    local path="${1:-/}"
    df -BG "$path" | awk 'NR==2 {gsub(/G/, "", $4); print $4}'
}

# Generate random string
generate_random_string() {
    local length="${1:-32}"
    openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

# Validate IP address
is_valid_ip() {
    local ip="$1"
    local pattern="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    
    if [[ $ip =~ $pattern ]]; then
        local -a octets
        IFS='.' read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Validate domain name
is_valid_domain() {
    local domain="$1"
    local pattern="^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$"
    [[ $domain =~ $pattern ]]
}

# Validate email address
is_valid_email() {
    local email="$1"
    local pattern="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
    [[ $email =~ $pattern ]]
}

# Validate port number
is_valid_port() {
    local port="$1"
    [[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

# Create directory with proper permissions
create_dir_safe() {
    local dir="$1"
    local mode="${2:-755}"
    local owner="${3:-root:root}"
    
    # Skip directory creation in test mode
if [[ "${HARDEN_MONGO_SERVER_TEST_MODE:-false}" == "true" ]]; then
        return 0
    fi
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        chmod "$mode" "$dir"
        chown "$owner" "$dir"
    fi
}

# Create temporary directory
create_temp_dir() {
    local temp_dir
temp_dir=$(mktemp -d "${HARDEN_MONGO_SERVER_TEMP_DIR}/harden-mongo-server.XXXXXX")
    echo "$temp_dir"
}

# Cleanup function for traps
cleanup_harden_mongo_server() {
    local temp_dirs
temp_dirs=$(find "${HARDEN_MONGO_SERVER_TEMP_DIR}" -name "harden-mongo-server.*" -type d 2>/dev/null || true)
    
    if [[ -n "$temp_dirs" ]]; then
        rm -rf $temp_dirs
    fi
}

# Set up signal handlers
setup_signal_handlers() {
trap 'cleanup_harden_mongo_server; exit 130' INT TERM
    trap 'cleanup_harden_mongo_server' EXIT
}

# Initialize the core module
init_harden_mongo_server_core() {
    # Create required directories
create_dir_safe "$HARDEN_MONGO_SERVER_TEMP_DIR" 755 root:root
    create_dir_safe "$HARDEN_MONGO_SERVER_RUN_DIR" 755 root:root
    
    # Set up signal handlers
    setup_signal_handlers
    
    # Set up logging if module is available
    if command_exists load_module && load_module logging 2>/dev/null; then
        init_logging
    fi
}

# Version information
version() {
echo "$HARDEN_MONGO_SERVER_NAME v$HARDEN_MONGO_SERVER_VERSION"
}

# Module information
module_info() {
    cat << EOF
MongoDB Server Hardening Core Library v$HARDEN_MONGO_SERVER_VERSION

This module provides:
- Core constants and configuration
- Utility functions for system interaction
- Input validation functions
- Temporary directory management
- Signal handling and cleanup

Dependencies: bash >= 4.0
EOF
}

# Validate core requirements
validate_core_requirements() {
    local errors=0
    
    # Check bash version
    if ((BASH_VERSINFO[0] < 4)); then
        echo "Error: Bash 4.0 or higher required (found ${BASH_VERSION})" >&2
        ((errors++))
    fi
    
    # Check required commands
    local required_commands=(openssl awk grep sed)
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            echo "Error: Required command '$cmd' not found" >&2
            ((errors++))
        fi
    done
    
    return $errors
}

# Auto-initialize when sourced (unless explicitly disabled)
if [[ "${HARDEN_MONGO_SERVER_NO_AUTO_INIT:-false}" != "true" ]]; then
    if validate_core_requirements; then
        init_harden_mongo_server_core
    fi
fi
