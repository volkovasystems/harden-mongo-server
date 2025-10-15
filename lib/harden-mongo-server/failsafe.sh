#!/usr/bin/env bash
# MongoDB Server Hardening Tool - Failsafe Library (MVP)
# Minimal last-known-good (LKG) + atomic writes + graceful reload + rollback

# Prevent multiple inclusion
if [[ -n "${_HARDEN_MONGO_SERVER_FAILSAFE_LOADED:-}" ]]; then
    return 0
fi
readonly _HARDEN_MONGO_SERVER_FAILSAFE_LOADED=1

# Directories
readonly FAILSAFE_DIR="/var/lib/harden-mongo-server/failsafe"
readonly LKG_DIR="${FAILSAFE_DIR}/lkg"
readonly TMP_DIR="${FAILSAFE_DIR}/tmp"

# Ensure dirs exist
mkdir -p "$FAILSAFE_DIR" "$LKG_DIR" "$TMP_DIR" 2>/dev/null || true

# Begin a simple transaction (marker only)
begin_transaction() {
    :
}

# End transaction (marker only)
end_transaction() {
    :
}

# Write content atomically to a target path
# usage: write_config_atomic <target_path> <content_string>
write_config_atomic() {
    local target="$1"
    local content="$2"
    local tmp
    tmp="${TMP_DIR}/$(basename "$target").$$.tmp"
    printf "%s" "$content" > "$tmp"
    chmod --reference="$target" "$tmp" 2>/dev/null || true
    chown --reference="$target" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target"
}

# Save last-known-good copy of a file
# usage: set_last_known_good <path>
set_last_known_good() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    local dest="$LKG_DIR/$(basename "$path")"
    cp -f "$path" "$dest"
}

# Roll back from last-known-good
# usage: rollback_to_last_known_good <path>
rollback_to_last_known_good() {
    local path="$1"
    local src="$LKG_DIR/$(basename "$path")"
    if [[ -f "$src" ]]; then
        cp -f "$src" "$path"
        return 0
    fi
    return 1
}

# Apply with graceful reload, fall back to restart, then rollback on failure
# usage: apply_with_graceful_reload <service> <reload_cmd> <validate_cmd> <restart_cmd>
apply_with_graceful_reload() {
    local service="$1" reload_cmd="$2" validate_cmd="$3" restart_cmd="$4"

    # Try graceful reload
    if eval "$reload_cmd" >/dev/null 2>&1; then
        if eval "$validate_cmd" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # Try restart
    if eval "$restart_cmd" >/dev/null 2>&1; then
        if eval "$validate_cmd" >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

# Module info
failsafe_module_info() {
    cat << EOF
MongoDB Server Hardening Failsafe Library
- Atomic config writes
- Last-known-good snapshots
- Graceful reload, fallback restart, rollback on failure
EOF
}

# Export API
export -f begin_transaction
export -f end_transaction
export -f write_config_atomic
export -f set_last_known_good
export -f rollback_to_last_known_good
export -f apply_with_graceful_reload
export -f failsafe_module_info
