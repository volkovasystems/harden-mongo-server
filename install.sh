#!/usr/bin/env bash
# MongoDB Hardening Utility - Installation Script
# Sets up the MongoDB hardening utility system-wide

set -euo pipefail

# Script metadata
readonly INSTALLER_VERSION="2.0.0"
readonly UTILITY_NAME="mongodb-hardening"

# Installation paths
readonly INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
readonly BIN_DIR="$INSTALL_PREFIX/bin"
readonly LIB_DIR="$INSTALL_PREFIX/lib/$UTILITY_NAME"
readonly SHARE_DIR="$INSTALL_PREFIX/share/$UTILITY_NAME"
readonly CONFIG_DIR="/etc/$UTILITY_NAME"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

fatal() {
    error "$1"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "This installer must be run as root. Use 'sudo $0' or run as root user."
    fi
}

# Check system requirements
check_requirements() {
    info "Checking system requirements..."
    
    # Check bash version
    if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
        fatal "Bash 4.0 or higher is required (found ${BASH_VERSION})"
    fi
    
    # Check required commands
    local required_commands=(openssl awk grep sed find)
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        error "Missing required commands: ${missing_commands[*]}"
        info "Please install the missing commands and try again"
        exit 1
    fi
    
    success "System requirements check passed"
}

# Create directory structure
create_directories() {
    info "Creating installation directories..."
    
    local directories=(
        "$BIN_DIR"
        "$LIB_DIR"
        "$SHARE_DIR"
        "$SHARE_DIR/examples"
        "$SHARE_DIR/docs"
        "$CONFIG_DIR"
        "/var/lib/$UTILITY_NAME"
        "/var/log/$UTILITY_NAME"
        "/var/lib/$UTILITY_NAME/metrics"
    )
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            info "Created directory: $dir"
        fi
    done
    
    # Set proper permissions
    chmod 755 "$BIN_DIR" "$LIB_DIR" "$SHARE_DIR"
    chmod 750 "$CONFIG_DIR"
    chmod 755 "/var/lib/$UTILITY_NAME"
    chmod 755 "/var/log/$UTILITY_NAME"
    
    success "Directory structure created"
}

# Install library modules
install_libraries() {
    info "Installing library modules..."
    
    local lib_source_dir="$(dirname "${BASH_SOURCE[0]}")/lib/mongodb-hardening"
    
    if [[ ! -d "$lib_source_dir" ]]; then
        fatal "Library source directory not found: $lib_source_dir"
    fi
    
    # Copy library modules
    cp -r "$lib_source_dir"/* "$LIB_DIR/"
    
    # Set proper permissions
    find "$LIB_DIR" -name "*.sh" -exec chmod 644 {} \;
    
    success "Library modules installed to $LIB_DIR"
}

# Install main executable
install_executable() {
    info "Installing main executable..."
    
    local source_script="$(dirname "${BASH_SOURCE[0]}")/harden-mongodb.sh"
    local target_script="$BIN_DIR/harden-mongodb"
    
    if [[ ! -f "$source_script" ]]; then
        fatal "Main script not found: $source_script"
    fi
    
    # Copy and modify the script to use system paths
    cp "$source_script" "$target_script"
    
    # Update library path in the installed script
    sed -i "s|readonly LIB_DIR=\"\$SCRIPT_DIR/lib/mongodb-hardening\"|readonly LIB_DIR=\"$LIB_DIR\"|" "$target_script"
    
    chmod 755 "$target_script"
    
    success "Main executable installed to $target_script"
}

# Install documentation and examples
install_documentation() {
    info "Installing documentation and examples..."
    
    local source_dir="$(dirname "${BASH_SOURCE[0]}")"
    
    # Install README
    if [[ -f "$source_dir/README.md" ]]; then
        cp "$source_dir/README.md" "$SHARE_DIR/"
    fi
    
    # Install examples
    if [[ -d "$source_dir/examples" ]]; then
        cp -r "$source_dir/examples"/* "$SHARE_DIR/examples/"
    fi
    
    # Install additional documentation
    local doc_files=(CHANGELOG.md LICENSE CONTRIBUTING.md)
    for doc in "${doc_files[@]}"; do
        if [[ -f "$source_dir/$doc" ]]; then
            cp "$source_dir/$doc" "$SHARE_DIR/docs/"
        fi
    done
    
    success "Documentation and examples installed"
}

# Create symlink for easy access
create_symlink() {
    info "Creating system symlink..."
    
    local system_bin="/usr/bin/harden-mongodb"
    
    if [[ -L "$system_bin" ]] || [[ -f "$system_bin" ]]; then
        rm -f "$system_bin"
    fi
    
    ln -s "$BIN_DIR/harden-mongodb" "$system_bin"
    
    success "System symlink created: $system_bin -> $BIN_DIR/harden-mongodb"
}

# Install systemd service files if systemd is available
install_systemd_services() {
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemd not available, skipping service installation"
        return 0
    fi
    
    info "Installing systemd service files..."
    
    local service_dir="/etc/systemd/system"
    
    # Create monitoring service
    cat > "$service_dir/mongodb-hardening-monitor.service" << 'EOF'
[Unit]
Description=MongoDB Hardening Monitor
After=mongod.service
Requires=mongod.service

[Service]
Type=oneshot
ExecStart=/usr/bin/harden-mongodb health-check
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Create monitoring timer
    cat > "$service_dir/mongodb-hardening-monitor.timer" << 'EOF'
[Unit]
Description=MongoDB Hardening Monitor Timer
Requires=mongodb-hardening-monitor.service

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Create metrics collection service
    cat > "$service_dir/mongodb-hardening-metrics.service" << 'EOF'
[Unit]
Description=MongoDB Hardening Metrics Collection
After=mongod.service
Requires=mongod.service

[Service]
Type=oneshot
ExecStart=/usr/bin/harden-mongodb metrics collect
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Create metrics timer
    cat > "$service_dir/mongodb-hardening-metrics.timer" << 'EOF'
[Unit]
Description=MongoDB Hardening Metrics Timer
Requires=mongodb-hardening-metrics.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Reload systemd
    systemctl daemon-reload
    
    success "systemd service files installed"
    info "To enable monitoring: systemctl enable --now mongodb-hardening-monitor.timer"
    info "To enable metrics: systemctl enable --now mongodb-hardening-metrics.timer"
}

# Set up log rotation
setup_log_rotation() {
    info "Setting up log rotation..."
    
    cat > "/etc/logrotate.d/$UTILITY_NAME" << EOF
/var/log/$UTILITY_NAME/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    copytruncate
    create 644 root root
}
EOF
    
    success "Log rotation configured"
}

# Create uninstall script
create_uninstaller() {
    info "Creating uninstaller..."
    
    local uninstall_script="$BIN_DIR/uninstall-mongodb-hardening"
    
    cat > "$uninstall_script" << EOF
#!/usr/bin/env bash
# MongoDB Hardening Utility - Uninstaller

set -euo pipefail

echo "Uninstalling MongoDB Hardening Utility..."

# Stop and disable services
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop mongodb-hardening-monitor.timer 2>/dev/null || true
    systemctl stop mongodb-hardening-metrics.timer 2>/dev/null || true
    systemctl disable mongodb-hardening-monitor.timer 2>/dev/null || true
    systemctl disable mongodb-hardening-metrics.timer 2>/dev/null || true
fi

# Remove files and directories
rm -rf "$LIB_DIR"
rm -rf "$SHARE_DIR"
rm -f "$BIN_DIR/harden-mongodb"
rm -f "/usr/bin/harden-mongodb"
rm -f "/etc/systemd/system/mongodb-hardening-"*
rm -f "/etc/logrotate.d/$UTILITY_NAME"
rm -f "$uninstall_script"

# Reload systemd
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
fi

echo "MongoDB Hardening Utility uninstalled successfully"
echo "Note: Configuration files in $CONFIG_DIR and data in /var/lib/$UTILITY_NAME have been preserved"
EOF

    chmod 755 "$uninstall_script"
    success "Uninstaller created: $uninstall_script"
}

# Display installation summary
show_summary() {
    cat << EOF

${GREEN}✓ MongoDB Hardening Utility Installation Complete${NC}

Installation Details:
  Version: $INSTALLER_VERSION
  Executable: $BIN_DIR/harden-mongodb
  Libraries: $LIB_DIR
  Documentation: $SHARE_DIR
  Configuration: $CONFIG_DIR
  System Link: /usr/bin/harden-mongodb

Usage:
  harden-mongodb --help          Show help information
  harden-mongodb system-info     Display system information
  harden-mongodb configure       Run configuration wizard
  harden-mongodb harden standard Apply standard security hardening

Optional Services:
  systemctl enable --now mongodb-hardening-monitor.timer  # Enable monitoring
  systemctl enable --now mongodb-hardening-metrics.timer  # Enable metrics

To uninstall:
  $BIN_DIR/uninstall-mongodb-hardening

${YELLOW}Next Steps:${NC}
1. Review the documentation: $SHARE_DIR/README.md
2. Check example configurations: $SHARE_DIR/examples/
3. Run 'harden-mongodb system-info' to analyze your system
4. Run 'harden-mongodb configure' for interactive setup

EOF
}

# Main installation function
main() {
    echo "MongoDB Hardening Utility Installer v$INSTALLER_VERSION"
    echo "============================================"
    echo
    
    check_root
    check_requirements
    create_directories
    install_libraries
    install_executable
    install_documentation
    create_symlink
    install_systemd_services
    setup_log_rotation
    create_uninstaller
    
    show_summary
}

# Run installer if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi