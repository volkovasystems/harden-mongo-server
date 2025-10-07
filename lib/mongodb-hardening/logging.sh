#!/usr/bin/env bash
# MongoDB Hardening Utility - Logging Library
# Provides structured logging, output formatting, and progress reporting

# Prevent multiple inclusion
if [[ -n "${_MONGODB_HARDENING_LOGGING_LOADED:-}" ]]; then
    return 0
fi
readonly _MONGODB_HARDENING_LOGGING_LOADED=1

# Load core module if not already loaded
if [[ -z "${_MONGODB_HARDENING_CORE_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
fi

# ================================
# Logging Configuration
# ================================

# Default log configuration
declare -g MONGODB_HARDENING_LOG_LEVEL=${MONGODB_HARDENING_LOG_LEVEL:-INFO}
declare -g MONGODB_HARDENING_LOG_FILE=${MONGODB_HARDENING_LOG_FILE:-"${MONGODB_HARDENING_LOG_DIR}/mongodb-hardening.log"}
declare -g MONGODB_HARDENING_LOG_TO_FILE=${MONGODB_HARDENING_LOG_TO_FILE:-true}
declare -g MONGODB_HARDENING_LOG_TO_SYSLOG=${MONGODB_HARDENING_LOG_TO_SYSLOG:-false}
declare -g MONGODB_HARDENING_USE_COLORS=${MONGODB_HARDENING_USE_COLORS:-true}
declare -g MONGODB_HARDENING_TIMESTAMP_FORMAT=${MONGODB_HARDENING_TIMESTAMP_FORMAT:-"%Y-%m-%d %H:%M:%S"}

# Log levels (numeric for comparison)
declare -gA LOG_LEVELS=(
    [DEBUG]=0
    [INFO]=1
    [WARN]=2
    [ERROR]=3
    [FATAL]=4
)

# Current log level numeric value
declare -gi CURRENT_LOG_LEVEL=${LOG_LEVELS[${MONGODB_HARDENING_LOG_LEVEL}]:-1}

# ================================
# Color and Formatting Functions
# ================================

# Check if colors should be used
use_colors() {
    [[ "$MONGODB_HARDENING_USE_COLORS" == "true" ]] && [[ -t 1 ]]
}

# Apply color/formatting to text
colorize() {
    local color="$1"
    local text="$2"
    
    if use_colors; then
        echo -e "${color}${text}${COLOR_NC}"
    else
        echo "$text"
    fi
}

# Format text with icon
format_with_icon() {
    local icon="$1"
    local text="$2"
    local color="${3:-}"
    
    if use_colors && [[ -n "$color" ]]; then
        echo -e "${color}${icon} ${text}${COLOR_NC}"
    else
        echo "${icon} ${text}"
    fi
}

# ================================
# Timestamp Functions
# ================================

# Get formatted timestamp
get_timestamp() {
    date "+${MONGODB_HARDENING_TIMESTAMP_FORMAT}"
}

# Get ISO timestamp for logs
get_iso_timestamp() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

# ================================
# Core Logging Functions
# ================================

# Initialize logging subsystem
init_logging() {
    # Skip logging setup in test mode
    if [[ "${MONGODB_HARDENING_TEST_MODE:-false}" == "true" ]]; then
        MONGODB_HARDENING_LOG_TO_FILE=false
        MONGODB_HARDENING_LOG_TO_SYSLOG=false
        return 0
    fi
    
    # Create log directory if needed
    if [[ "$MONGODB_HARDENING_LOG_TO_FILE" == "true" ]]; then
        local log_dir
        log_dir="$(dirname "$MONGODB_HARDENING_LOG_FILE")"
        create_dir_safe "$log_dir" 755 root:root
        
        # Test write access to log file
        if ! touch "$MONGODB_HARDENING_LOG_FILE" 2>/dev/null; then
            MONGODB_HARDENING_LOG_TO_FILE=false
            echo "Warning: Cannot write to log file $MONGODB_HARDENING_LOG_FILE, disabling file logging" >&2
        fi
    fi
}

# Check if log level should be output
should_log() {
    local level="$1"
    local level_num=${LOG_LEVELS[$level]:-1}
    ((level_num >= CURRENT_LOG_LEVEL))
}

# Write to log file
write_to_log_file() {
    local level="$1"
    local message="$2"
    
    if [[ "$MONGODB_HARDENING_LOG_TO_FILE" == "true" ]]; then
        echo "[$(get_iso_timestamp)] [$level] $message" >> "$MONGODB_HARDENING_LOG_FILE"
    fi
}

# Write to syslog
write_to_syslog() {
    local level="$1"
    local message="$2"
    local priority
    
    if [[ "$MONGODB_HARDENING_LOG_TO_SYSLOG" == "true" ]] && command_exists logger; then
        case "$level" in
            DEBUG) priority="user.debug" ;;
            INFO)  priority="user.info" ;;
            WARN)  priority="user.warning" ;;
            ERROR) priority="user.error" ;;
            FATAL) priority="user.crit" ;;
            *)     priority="user.info" ;;
        esac
        
        logger -p "$priority" -t "mongodb-hardening" "$message"
    fi
}

# Generic log function
log_message() {
    local level="$1"
    local message="$2"
    local icon="${3:-}"
    local color="${4:-}"
    
    # Check if we should log this level
    if ! should_log "$level"; then
        return 0
    fi
    
    # Format console output
    local console_message
    if [[ -n "$icon" ]]; then
        console_message="$(format_with_icon "$icon" "$message" "$color")"
    elif [[ -n "$color" ]] && use_colors; then
        console_message="$(colorize "$color" "$message")"
    else
        console_message="$message"
    fi
    
    # Output to console
    case "$level" in
        ERROR|FATAL)
            echo "$console_message" >&2
            ;;
        *)
            echo "$console_message"
            ;;
    esac
    
    # Write to log destinations
    write_to_log_file "$level" "$message"
    write_to_syslog "$level" "$message"
}

# ================================
# Specific Log Level Functions
# ================================

# Debug messages
debug() {
    local message="$1"
    log_message "DEBUG" "$message" "$ICON_INFO" "$COLOR_CYAN"
}

# Info messages
info() {
    local message="$1"
    log_message "INFO" "$message" "$ICON_INFO" "$COLOR_BLUE"
}

# Success messages
success() {
    local message="$1"
    log_message "INFO" "$message" "$ICON_SUCCESS" "$COLOR_GREEN"
}

# Warning messages
warn() {
    local message="$1"
    log_message "WARN" "$message" "$ICON_WARNING" "$COLOR_YELLOW"
    ((MONGODB_HARDENING_WARNINGS++))
}

# Error messages
error() {
    local message="$1"
    log_message "ERROR" "$message" "$ICON_ERROR" "$COLOR_RED"
}

# Fatal error messages
fatal() {
    local message="$1"
    log_message "FATAL" "$message" "$ICON_ERROR" "$COLOR_RED"
    exit 1
}

# Security-related messages
security() {
    local message="$1"
    log_message "INFO" "$message" "$ICON_SECURITY" "$COLOR_MAGENTA"
}

# Fixed/resolved messages
fixed() {
    local message="$1"
    log_message "INFO" "$message" "$ICON_FIXED" "$COLOR_GREEN"
    ((MONGODB_HARDENING_ISSUES_FIXED++))
}

# Explanation/detailed messages
explain() {
    local message="$1"
    log_message "INFO" "$message" "$ICON_EXPLAIN" "$COLOR_CYAN"
}

# ================================
# Specialized Output Functions
# ================================

# Print header with decorative border
print_header() {
    local title="$1"
    local width="${2:-60}"
    local char="${3:-=}"
    
    local border
    border=$(printf "%*s" "$width" "" | tr ' ' "$char")
    
    echo
    colorize "$COLOR_BOLD" "$border"
    colorize "$COLOR_BOLD" " $title"
    colorize "$COLOR_BOLD" "$border"
    echo
}

# Print section header
print_section() {
    local title="$1"
    local width="${2:-40}"
    local char="${3:--}"
    
    local border
    border=$(printf "%*s" "$width" "" | tr ' ' "$char")
    
    echo
    colorize "$COLOR_BOLD" "$title"
    colorize "$COLOR_BLUE" "$border"
}

# Print subsection
print_subsection() {
    local title="$1"
    echo
    colorize "$COLOR_CYAN" "• $title"
}

# Print key-value pair
print_kv() {
    local key="$1"
    local value="$2"
    local key_width="${3:-20}"
    
    printf "%-${key_width}s: %s\n" "$key" "$value"
}

# Print indented message
print_indent() {
    local message="$1"
    local level="${2:-1}"
    local indent_char="${3:- }"
    
    local indent
    indent=$(printf "%*s" $((level * 2)) "" | tr ' ' "$indent_char")
    echo "${indent}${message}"
}

# ================================
# Progress and Status Functions
# ================================

# Show progress spinner
show_spinner() {
    local pid="$1"
    local message="${2:-Working...}"
    local delay=0.1
    local spinstr='|/-\'
    
    echo -n "$message "
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b"
    done
    printf "\b\b\b   \b\b\b"
    echo
}

# Progress bar
show_progress() {
    local current="$1"
    local total="$2"
    local width="${3:-50}"
    local prefix="${4:-Progress}"
    
    local percent=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    printf "\r%s: [" "$prefix"
    printf "%*s" "$filled" "" | tr ' ' '█'
    printf "%*s" "$empty" "" | tr ' ' '░'
    printf "] %d%%" "$percent"
    
    if ((current == total)); then
        echo
    fi
}

# ================================
# Issue Tracking Functions
# ================================

# Report an issue found
report_issue() {
    local severity="$1"  # high, medium, low
    local description="$2"
    local recommendation="${3:-}"
    
    ((MONGODB_HARDENING_ISSUES_FOUND++))
    
    case "$severity" in
        high|critical)
            error "ISSUE: $description"
            ;;
        medium)
            warn "ISSUE: $description"
            ;;
        low)
            info "ISSUE: $description"
            ;;
        *)
            info "ISSUE: $description"
            ;;
    esac
    
    if [[ -n "$recommendation" ]]; then
        print_indent "Recommendation: $recommendation" 1
    fi
}

# Report issue resolution
report_fix() {
    local description="$1"
    local details="${2:-}"
    
    fixed "FIXED: $description"
    
    if [[ -n "$details" ]]; then
        print_indent "$details" 1
    fi
}

# ================================
# Summary and Reporting Functions
# ================================

# Print execution summary
print_summary() {
    local operation="${1:-MongoDB Hardening}"
    
    print_header "Execution Summary"
    
    print_kv "Operation" "$operation"
    print_kv "Timestamp" "$(get_timestamp)"
    print_kv "Issues Found" "$MONGODB_HARDENING_ISSUES_FOUND"
    print_kv "Issues Fixed" "$MONGODB_HARDENING_ISSUES_FIXED"
    print_kv "Warnings" "$MONGODB_HARDENING_WARNINGS"
    
    echo
    
    if ((MONGODB_HARDENING_ISSUES_FOUND == 0)); then
        success "No security issues found - system appears properly configured"
    elif ((MONGODB_HARDENING_ISSUES_FIXED == MONGODB_HARDENING_ISSUES_FOUND)); then
        success "All identified issues have been resolved"
    else
        local remaining=$((MONGODB_HARDENING_ISSUES_FOUND - MONGODB_HARDENING_ISSUES_FIXED))
        warn "$remaining issue(s) require manual attention"
    fi
}

# ================================
# Dry Run Functions
# ================================

# Execute or simulate command based on dry-run setting
execute_or_simulate() {
    local description="$1"
    local command="$2"
    
    if [[ "$MONGODB_HARDENING_DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would execute: $description"
        debug "Command: $command"
    else
        info "Executing: $description"
        debug "Command: $command"
        eval "$command"
    fi
}

# Check if in dry-run mode
is_dry_run() {
    [[ "$MONGODB_HARDENING_DRY_RUN" == "true" ]]
}

# ================================
# Verbose Output Functions
# ================================

# Verbose output
verbose() {
    local message="$1"
    if [[ "$MONGODB_HARDENING_VERBOSE" == "true" ]]; then
        debug "$message"
    fi
}

# Check if verbose mode is enabled
is_verbose() {
    [[ "$MONGODB_HARDENING_VERBOSE" == "true" ]]
}

# ================================
# Confirmation and User Input
# ================================

# Ask for user confirmation
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response
    
    # Skip confirmation in force mode
    if [[ "$MONGODB_HARDENING_FORCE" == "true" ]]; then
        info "Force mode enabled, proceeding without confirmation"
        return 0
    fi
    
    # Format prompt based on default
    case "$default" in
        [Yy]|[Yy][Ee][Ss])
            prompt="$prompt [Y/n]: "
            ;;
        [Nn]|[Nn][Oo])
            prompt="$prompt [y/N]: "
            ;;
        *)
            prompt="$prompt [y/n]: "
            ;;
    esac
    
    # Get user input
    while true; do
        echo -n "$(format_with_icon "$ICON_QUERY" "$prompt")"
        read -r response
        
        # Use default if no response
        if [[ -z "$response" ]]; then
            response="$default"
        fi
        
        case "$response" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo])
                return 1
                ;;
            *)
                warn "Please answer yes or no"
                ;;
        esac
    done
}

# ================================
# Module Information
# ================================

# Module information
logging_module_info() {
    cat << EOF
MongoDB Hardening Logging Library v$MONGODB_HARDENING_VERSION

This module provides:
- Structured logging with multiple levels (DEBUG, INFO, WARN, ERROR, FATAL)
- Colored console output with icons
- File and syslog logging support
- Progress reporting and status messages
- Issue tracking and summary reporting
- User confirmation and interaction
- Dry-run simulation support

Configuration:
- MONGODB_HARDENING_LOG_LEVEL: Current log level ($MONGODB_HARDENING_LOG_LEVEL)
- MONGODB_HARDENING_LOG_FILE: Log file path ($MONGODB_HARDENING_LOG_FILE)
- MONGODB_HARDENING_USE_COLORS: Color output ($MONGODB_HARDENING_USE_COLORS)
- MONGODB_HARDENING_VERBOSE: Verbose mode ($MONGODB_HARDENING_VERBOSE)
- MONGODB_HARDENING_DRY_RUN: Dry run mode ($MONGODB_HARDENING_DRY_RUN)

Dependencies: core.sh
EOF
}