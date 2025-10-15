#!/usr/bin/env bash
# MongoDB Server Hardening Tool - Firewall Library
# 1.0.0 MVP (iptables-based)

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
# 1.0.0 MVP Firewall Functions
# ================================

# Execute firewall setup phase
execute_firewall_setup_phase() {
    info "Starting firewall setup phase..."

    enable_stealth_mode
    configure_vpn_only_access
    apply_allowed_ips
    configure_vpn_firewall

    success "Firewall setup phase completed"
}

# Enable stealth mode
enable_stealth_mode() {
    info "Enabling stealth mode..."

    local drop_unmatched
    drop_unmatched=$(get_config_value "firewall.stealth.dropUnmatchedPublic")
    local block_icmp_public
    block_icmp_public=$(get_config_value "firewall.stealth.blockIcmpEchoPublic")
    local allow_icmp_vpn
    allow_icmp_vpn=$(get_config_value "firewall.stealth.allowIcmpVpn")

    if [[ "$drop_unmatched" == "true" ]]; then
        local public_interface
        public_interface=$(get_public_interface)
        if [[ -n "$public_interface" ]]; then
            iptables -A INPUT -i "$public_interface" -j DROP
            success "Default DROP policy applied to public interface: $public_interface"
        fi
    fi

    if [[ "$block_icmp_public" == "true" ]]; then
        local public_interface
        public_interface=$(get_public_interface)
        if [[ -n "$public_interface" ]]; then
            iptables -A INPUT -i "$public_interface" -p icmp --icmp-type echo-request -j DROP
            success "ICMP echo blocked on public interface: $public_interface"
        fi
    fi

    if [[ "$allow_icmp_vpn" == "true" ]]; then
        local vpn_interface
        vpn_interface=$(get_vpn_interface)
        if [[ -n "$vpn_interface" ]]; then
            iptables -A INPUT -i "$vpn_interface" -p icmp -j ACCEPT
            success "ICMP allowed on VPN interface: $vpn_interface"
        fi
    fi

    success "Stealth mode enabled"
}

# Configure VPN-only access for MongoDB and SSH
configure_vpn_only_access() {
    info "Configuring VPN-only access for MongoDB and SSH..."

    local vpn_network
    vpn_network=$(get_config_value "openvpn.network")
    [[ -z "$vpn_network" || "$vpn_network" == "null" ]] && vpn_network="10.8.0.0/24"

    # Remove any existing broad rules (best-effort)
    iptables -D INPUT -p tcp --dport 27017 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true

    # MongoDB: allow localhost and VPN, drop others
    iptables -A INPUT -s 127.0.0.1 -p tcp --dport 27017 -j ACCEPT
    iptables -A INPUT -s "$vpn_network" -p tcp --dport 27017 -j ACCEPT
    iptables -A INPUT -p tcp --dport 27017 -j DROP

    # SSH: VPN-only if enabled
    if get_config_value "ssh.vpnOnly" | grep -q "true"; then
        iptables -A INPUT -s "$vpn_network" -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -p tcp --dport 22 -j DROP
    fi

    success "VPN-only access configured"
}

# Apply allowed IPs configuration
apply_allowed_ips() {
    info "Applying allowed IP configuration..."

    local allowed_ips
    allowed_ips=$(get_config_value "network.allowedIPs")

    if [[ -n "$allowed_ips" && "$allowed_ips" != "[]" && "$allowed_ips" != "null" ]]; then
        echo "$allowed_ips" | jq -r '.[]' | while read -r ip; do
            [[ -z "$ip" || "$ip" == "null" ]] && continue
            iptables -I INPUT -s "$ip" -p tcp --dport 27017 -j ACCEPT
            success "MongoDB access allowed for IP: $ip"
        done
    fi
}

# Configure VPN firewall rules
configure_vpn_firewall() {
    info "Configuring VPN firewall rules..."

    if ! get_config_value "openvpn.enabled" | grep -q "true"; then
        info "OpenVPN disabled in configuration, skipping VPN firewall setup"
        return 0
    fi

    local vpn_port vpn_proto vpn_network
    vpn_port=$(get_config_value "openvpn.port")
    vpn_proto=$(get_config_value "openvpn.proto")
    vpn_network=$(get_config_value "openvpn.network")

    # Allow VPN port from anywhere (needed for initial connection)
    iptables -A INPUT -p "$vpn_proto" --dport "$vpn_port" -j ACCEPT

    # Enable IP forwarding and NAT for VPN
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-harden-mongo-server-vpn.conf
    sysctl -p /etc/sysctl.d/99-harden-mongo-server-vpn.conf

    local public_interface
    public_interface=$(get_public_interface)
    if [[ -n "$public_interface" ]]; then
        iptables -t nat -A POSTROUTING -s "$vpn_network" -o "$public_interface" -j MASQUERADE
    fi

    local vpn_interface
    vpn_interface=$(get_vpn_interface)
    if [[ -n "$vpn_interface" ]]; then
        iptables -A INPUT -i "$vpn_interface" -j ACCEPT
        iptables -A FORWARD -i "$vpn_interface" -j ACCEPT
        iptables -A FORWARD -o "$vpn_interface" -j ACCEPT
    fi

    success "VPN firewall rules configured"
}

# Get public network interface (not loopback, not VPN)
get_public_interface() {
    local default_interface
    default_interface=$(ip route | grep '^default' | awk '{print $5}' | head -1)
    if [[ -n "$default_interface" && "$default_interface" != "lo" && ! "$default_interface" =~ ^tun ]]; then
        echo "$default_interface"
    fi
}

# Apply firewall configuration (used by IP add/remove handlers)
apply_firewall_config() {
    info "Applying firewall configuration changes..."
    apply_allowed_ips
    save_iptables_rules
    success "Firewall configuration applied"
}

# Save iptables rules
save_iptables_rules() {
    if command_exists iptables-save; then
        local save_paths=("/etc/iptables/rules.v4" "/etc/sysconfig/iptables" "/etc/iptables.rules")
        for save_path in "${save_paths[@]}"; do
            local save_dir
            save_dir=$(dirname "$save_path")
            if [[ -d "$save_dir" ]] || mkdir -p "$save_dir" 2>/dev/null; then
                if iptables-save > "$save_path" 2>/dev/null; then
                    info "Iptables rules saved to: $save_path"
                    return 0
                fi
            fi
        done
        warn "Could not save iptables rules to any standard location"
    fi
}

# Set up basic firewall foundation
setup_basic_firewall() {
    info "Setting up basic firewall foundation..."
    if ! command_exists iptables; then
        error "iptables not found - required for 1.0.0 MVP"
        return 1
    fi
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -j ACCEPT
    success "Basic firewall foundation configured"
}

# Reset firewall to clean state
reset_firewall() {
    info "Resetting firewall for 1.0.0 MVP setup..."
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    success "Firewall reset completed"
}

# Comprehensive firewall setup
setup_complete_firewall() {
    info "Setting up complete firewall configuration..."
    reset_firewall
    setup_basic_firewall
    execute_firewall_setup_phase
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    save_iptables_rules
    success "Complete firewall setup completed"
}

# ================================
# Module Information
# ================================
firewall_module_info() {
    cat << EOF
MongoDB Server Hardening Firewall Library v$HARDEN_MONGO_SERVER_VERSION

This module provides (1.0.0 MVP):
- Stealth mode on public interfaces (default DROP, block ICMP echo)
- Allow ICMP on VPN interface
- VPN-only access defaults for MongoDB and SSH
- Allowed IPs for MongoDB from config
- VPN firewall/NAT rules
- Save iptables rules

Dependencies: core.sh, logging.sh, system.sh, iptables
EOF
}
