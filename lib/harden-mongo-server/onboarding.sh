#!/usr/bin/env bash
# MongoDB Server Hardening Tool - Onboarding Module (1.0.0 MVP)
# Handles automated onboarding via Cloudflare Quick Tunnel

# Prevent multiple inclusion
if [[ -n "${_HARDEN_MONGO_SERVER_ONBOARDING_LOADED:-}" ]]; then
    return 0
fi
readonly _HARDEN_MONGO_SERVER_ONBOARDING_LOADED=1

# ================================
# Onboarding Constants
# ================================

readonly ONBOARDING_TEMP_DIR="/tmp/harden-mongo-server-onboarding"
readonly ONBOARDING_ARCHIVE_PREFIX="hms-onboarding"
readonly CLOUDFLARED_TIMEOUT=600  # 10 minutes
readonly ONBOARDING_PORT=8080     # Local ephemeral server port

# ================================
# Certificate Packaging Functions
# ================================

# Package all certificates and VPN profiles into a single archive
# Returns the path to the created archive
package_onboarding_files() {
    local date_stamp
    date_stamp=$(date -u '+%Y-%m-%d')
    local archive_name="${ONBOARDING_ARCHIVE_PREFIX}-${date_stamp}.zip"
    local temp_dir
    temp_dir=$(mktemp -d "$ONBOARDING_TEMP_DIR/package.XXXXXX")
    local archive_path="$temp_dir/$archive_name"
    
    info "Packaging onboarding files for $date_stamp"
    
    # Create temporary directory for files to package
    local package_dir="$temp_dir/files"
    mkdir -p "$package_dir"
    
    # Package VPN profiles (admin and viewer)
    if ! package_vpn_profiles "$package_dir" "$date_stamp"; then
        error "Failed to package VPN profiles"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Package database certificates
    if ! package_database_certificates "$package_dir" "$date_stamp"; then
        error "Failed to package database certificates"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Create the zip archive (flat structure, no subdirectories)
    cd "$package_dir" || return 1
    if ! zip -q "$archive_path" ./*; then
        error "Failed to create onboarding archive"
        rm -rf "$temp_dir"
        return 1
    fi
    cd - >/dev/null || return 1
    
    # Clean up temporary files but keep the archive
    rm -rf "$package_dir"
    
    echo "$archive_path"
}

# Package VPN profiles with embedded certificates
package_vpn_profiles() {
    local package_dir="$1"
    local date_stamp="$2"
    
    local vpn_config_dir="/etc/openvpn/server"
    local ca_cert="$vpn_config_dir/ca.crt"
    local server_cert="$vpn_config_dir/server.crt"
    
    # Package admin VPN profile
    if [[ -f "$vpn_config_dir/admin.crt" && -f "$vpn_config_dir/admin.key" ]]; then
        create_ovpn_profile "admin" "$package_dir/admin-${date_stamp}.ovpn" \
            "$ca_cert" "$vpn_config_dir/admin.crt" "$vpn_config_dir/admin.key"
    else
        error "Admin VPN certificates not found"
        return 1
    fi
    
    # Package viewer VPN profile
    if [[ -f "$vpn_config_dir/viewer.crt" && -f "$vpn_config_dir/viewer.key" ]]; then
        create_ovpn_profile "viewer" "$package_dir/viewer-${date_stamp}.ovpn" \
            "$ca_cert" "$vpn_config_dir/viewer.crt" "$vpn_config_dir/viewer.key"
    else
        error "Viewer VPN certificates not found"
        return 1
    fi
    
    return 0
}

# Create OpenVPN client profile with embedded certificates
create_ovpn_profile() {
    local name="$1"
    local output_file="$2"
    local ca_cert="$3"
    local client_cert="$4"
    local client_key="$5"
    
    local server_ip
    server_ip=$(get_public_ip)
    local vpn_port
    vpn_port=$(get_config_value "openvpn.port")
    local vpn_proto
    vpn_proto=$(get_config_value "openvpn.proto")
    
    cat > "$output_file" << EOF
# OpenVPN Client Configuration for $name
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# MongoDB Server Hardening Tool 1.0.0

client
dev tun
proto $vpn_proto
remote $server_ip $vpn_port
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
auth SHA256
tls-version-min 1.2
remote-cert-tls server
verb 3

<ca>
$(cat "$ca_cert")
</ca>

<cert>
$(cat "$client_cert")
</cert>

<key>
$(cat "$client_key")
</key>

<tls-crypt>
$(cat /etc/openvpn/server/ta.key)
</tls-crypt>
EOF
    
    chmod 600 "$output_file"
}

# Package database client certificates
package_database_certificates() {
    local package_dir="$1"
    local date_stamp="$2"
    
    local ssl_dir="/etc/mongoCA"
    local clients_dir="$ssl_dir/clients"
    
    # Package database CA certificate
    if [[ -f "$ssl_dir/ca.crt" ]]; then
        cp "$ssl_dir/ca.crt" "$package_dir/db-ca-${date_stamp}.pem"
    else
        error "Database CA certificate not found"
        return 1
    fi
    
    # Package client certificates (cert + key in single PEM file)
    local roles=("root" "admin" "app" "backup")
    for role in "${roles[@]}"; do
        local cert_file="$clients_dir/${role}.crt"
        local key_file="$clients_dir/${role}.key"
        local output_file="$package_dir/db-${role}-${date_stamp}.pem"
        
        if [[ -f "$cert_file" && -f "$key_file" ]]; then
            # Combine certificate and key into single PEM file
            cat "$cert_file" "$key_file" > "$output_file"
            chmod 600 "$output_file"
        else
            error "Database $role certificates not found"
            return 1
        fi
    done
    
    return 0
}

# ================================
# Cloudflare Quick Tunnel Functions
# ================================

# Check if cloudflared is available
check_cloudflared() {
    if ! command_exists cloudflared; then
        error "cloudflared is required for onboarding but not found"
        info "Install cloudflared: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
        return 1
    fi
}

# Start ephemeral file server for the archive
start_ephemeral_server() {
    local archive_path="$1"
    local token
    token=$(generate_random_string 32)
    local server_pid
    
    # Create a simple HTTP server that serves only our archive
    {
        while true; do
            read -r line || break
            if [[ $line == *"GET /download/$token"* ]]; then
                echo "HTTP/1.1 200 OK"
                echo "Content-Type: application/zip"
                echo "Content-Disposition: attachment; filename=\"$(basename "$archive_path")\""
                echo "Content-Length: $(stat -c%s "$archive_path")"
                echo ""
                cat "$archive_path"
                # Delete archive after successful download (single-use)
                rm -f "$archive_path"
                break
            else
                echo "HTTP/1.1 404 Not Found"
                echo "Content-Length: 0"
                echo ""
            fi
        done
    } | nc -l -p "$ONBOARDING_PORT" &
    
    server_pid=$!
    echo "$server_pid $token"
}

# Create Cloudflare Quick Tunnel
create_quick_tunnel() {
    local server_pid="$1"
    local token="$2"
    local expiry_minutes
    expiry_minutes=$(get_config_value "onboarding.expiryMinutes")
    
    info "Creating Cloudflare Quick Tunnel (expires in ${expiry_minutes} minutes)..."
    
    # Start cloudflared and capture URL from stderr
    local log_file
    log_file="${ONBOARDING_TEMP_DIR}/cloudflared.$$.log"
    timeout "$CLOUDFLARED_TIMEOUT" cloudflared tunnel --url "http://localhost:$ONBOARDING_PORT" --no-autoupdate 2>"$log_file" &
    local cloudflared_pid=$!
    
    # Wait for tunnel URL to appear in logs
    local tunnel_url=""
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$log_file" >/dev/null 2>&1; then
            tunnel_url=$(grep -Eo 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' "$log_file" | head -n1)
            break
        fi
        sleep 2
        ((attempts++))
    done
    
    if [[ -z "$tunnel_url" ]]; then
        error "Failed to create Cloudflare Quick Tunnel"
        kill "$server_pid" "$cloudflared_pid" 2>/dev/null || true
        rm -f "$log_file"
        return 1
    fi
    
    # Schedule cleanup after expiry
    (
        sleep $((expiry_minutes * 60))
        kill "$server_pid" "$cloudflared_pid" 2>/dev/null || true
        rm -rf "$ONBOARDING_TEMP_DIR"
    ) &
    
    rm -f "$log_file"
    echo "$tunnel_url/download/$token"
}

# ================================
# Main Onboarding Functions
# ================================

# Generate onboarding script and print instructions
generate_onboarding_script() {
    if ! check_cloudflared; then
        error "Unable to generate onboarding script. Please contact a human administrator to help download the files."
        return 1
    fi
    
    # Create temporary directory
    mkdir -p "$ONBOARDING_TEMP_DIR"
    
    # Package all files
    local archive_path
    archive_path=$(package_onboarding_files)
    if [[ -z "$archive_path" || ! -f "$archive_path" ]]; then
        error "Failed to package onboarding files"
        return 1
    fi
    
    info "Starting ephemeral file server..."
    local server_info
    server_info=$(start_ephemeral_server "$archive_path")
    local server_pid
    server_pid=$(echo "$server_info" | cut -d' ' -f1)
    local token
    token=$(echo "$server_info" | cut -d' ' -f2)
    
    # Create Quick Tunnel
    local download_url
    download_url=$(create_quick_tunnel "$server_pid" "$token")
    if [[ -z "$download_url" ]]; then
        error "Failed to create download URL"
        kill "$server_pid" 2>/dev/null
        return 1
    fi
    
    # Print download commands
    print_download_commands "$download_url" "$archive_path"
    
    return 0
}

# Print the one-liner download commands for different platforms
print_download_commands() {
    local download_url="$1"
    local archive_path="$2"
    local archive_name
    archive_name="$(basename "$archive_path")"
    
    echo "Linux/macOS:"
    echo "  curl -fsSL \"$download_url\" -o $archive_name && unzip -q $archive_name && rm $archive_name"
    echo
    echo "Windows (PowerShell):"
    echo "  iwr -UseBasicParsing \"$download_url\" -OutFile $archive_name; Expand-Archive -Force .\\$archive_name .; Remove-Item .\\$archive_name"
    echo
    echo "URL expires in $(get_config_value "onboarding.expiryMinutes") minutes and is single-use only."
}

# Get the public IP address of this server
get_public_ip() {
    # Try multiple methods to get public IP
    local ip
    
    # Try curl methods
    ip=$(curl -s -4 ifconfig.me 2>/dev/null) || \
    ip=$(curl -s -4 icanhazip.com 2>/dev/null) || \
    ip=$(curl -s -4 ipecho.net/plain 2>/dev/null)
    
    # Fallback to local IP if no internet access
    if [[ -z "$ip" ]]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    
    echo "$ip"
}

# ================================
# Module Information
# ================================

onboarding_module_info() {
    cat << EOF
MongoDB Server Hardening Onboarding Module v$HARDEN_MONGO_SERVER_VERSION

This module provides:
- Cloudflare Quick Tunnel integration for secure file distribution
- Automated packaging of VPN profiles and database certificates
- One-liner download commands for client setup
- Single-use, time-limited file access

Dependencies: cloudflared, zip, nc (netcat)
EOF
}

# Validate onboarding requirements
validate_onboarding_requirements() {
    local errors=0
    
    # Check required commands
    local required_commands=(cloudflared zip nc curl)
    for cmd in "${required_commands[@]}"; do
        if ! command_exists "$cmd"; then
            echo "Warning: Recommended command '$cmd' not found for onboarding" >&2
            if [[ "$cmd" == "cloudflared" ]]; then
                ((errors++))
            fi
        fi
    done
    
    return $errors
}