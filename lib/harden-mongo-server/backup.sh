#!/usr/bin/env bash
# MongoDB Server Hardening Tool - Backup Library
# Encrypted daily backups (age + zstd), 7-day retention, restore support

# Prevent multiple inclusion
if [[ -n "${_HARDEN_MONGO_SERVER_BACKUP_LOADED:-}" ]]; then
    return 0
fi
readonly _HARDEN_MONGO_SERVER_BACKUP_LOADED=1

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
# Backup Constants
# ================================
readonly BACKUP_DIR="/var/backups/harden-mongo-server"
readonly BACKUP_KEY_FILE="/etc/harden-mongo-server/keys/backup.agekey"
readonly BACKUP_TIMER="harden-mongo-server-backup.timer"
readonly BACKUP_SERVICE="harden-mongo-server-backup.service"

# ================================
# Create Encrypted Backup
# ================================
create_encrypted_backup() {
    local database="${1:-all}"
    local backup_name="backup-$(date -u '+%Y-%m-%d')"
    local backup_path="$BACKUP_DIR/$backup_name"

    info "Creating encrypted backup: $backup_name"

    if ! check_backup_disk_space; then
        error "Insufficient disk space for backup"
        return 1
    fi

    if ! command_exists age; then
        error "age encryption tool not found - installing..."
        install_age_tool || return 1
    fi

    ensure_backup_key_exists || return 1

    local temp_backup_dir
    temp_backup_dir=$(mktemp -d "$BACKUP_DIR/temp-backup.XXXXXX")

    info "Creating MongoDB dump..."
    if ! create_mongodb_dump "$temp_backup_dir" "$database"; then
        error "Failed to create MongoDB dump"
        rm -rf "$temp_backup_dir"
        return 1
    fi

    info "Compressing backup with zstd..."
    local compressed_file="$temp_backup_dir/backup.tar.zst"
    if ! create_compressed_archive "$temp_backup_dir/dump" "$compressed_file"; then
        error "Failed to compress backup"
        rm -rf "$temp_backup_dir"
        return 1
    fi

    info "Encrypting backup..."
    local encrypted_file="$backup_path.age"
    if ! encrypt_backup_with_age "$compressed_file" "$encrypted_file"; then
        error "Failed to encrypt backup"
        rm -rf "$temp_backup_dir"
        return 1
    fi

    create_backup_metadata "$encrypted_file" "$database"

    rm -rf "$temp_backup_dir"

    chmod 600 "$encrypted_file"*
    chown root:root "$encrypted_file"*

    success "Encrypted backup created: $(basename "$encrypted_file")"

    cleanup_old_backups
    return 0
}

# Create MongoDB dump (x509 if available)
create_mongodb_dump() {
    local output_dir="$1"
    local database="$2"

    local mongodump_cmd="mongodump --out '$output_dir/dump'"
    local admin_cert="/etc/mongoCA/clients/admin.pem"
    local ca_cert="/etc/mongoCA/ca.crt"
    if [[ -f "$admin_cert" && -f "$ca_cert" ]]; then
        mongodump_cmd+=" --ssl --sslPEMKeyFile='$admin_cert' --sslCAFile='$ca_cert'"
        mongodump_cmd+=" --authenticationDatabase='\$external' --authenticationMechanism='MONGODB-X509'"
    fi
    [[ "$database" != "all" ]] && mongodump_cmd+=" --db '$database'"

    eval "$mongodump_cmd" >/dev/null 2>&1
}

# Create compressed archive with zstd
create_compressed_archive() {
    local source_dir="$1"
    local output_file="$2"
    if command_exists zstd; then
        tar -C "$(dirname "$source_dir")" -c "$(basename "$source_dir")" | zstd -3 > "$output_file"
    else
        warn "zstd not available, falling back to gzip"
        tar -C "$(dirname "$source_dir")" -czf "${output_file%.zst}.gz" "$(basename "$source_dir")"
        mv "${output_file%.zst}.gz" "$output_file"
    fi
}

# age encrypt/decrypt
encrypt_backup_with_age() {
    local input_file="$1"; local output_file="$2"
    age -e -i "$BACKUP_KEY_FILE" "$input_file" > "$output_file"
}

decrypt_backup_with_age() {
    local input_file="$1"; local output_file="$2"
    age -d -i "$BACKUP_KEY_FILE" "$input_file" > "$output_file"
}

# Metadata for encrypted backup
create_backup_metadata() {
    local backup_file="$1"; local database="$2"
    local metadata_file="${backup_file}.json"
    local backup_size
    backup_size=$(du -h "$backup_file" | cut -f1)
    cat > "$metadata_file" << EOF
{
  "backup_info": {
    "timestamp": "$(date -u -Iseconds)",
    "database": "$database",
    "size": "$backup_size",
    "compression": "zstd",
    "encryption": "age",
    "format": "mongodump"
  },
  "system_info": {
    "hostname": "$(hostname)",
    "mongodb_version": "$(get_mongodb_version)",
    "os": "$(get_os) $(get_os_version)"
  },
  "restore_command": "harden-mongo-server --restore '$backup_file'"
}
EOF
    chmod 600 "$metadata_file"
    chown root:root "$metadata_file"
}

# Restore encrypted backup
restore_encrypted_backup() {
    local backup_file="$1"; local target_database="${2:-}"
    info "Restoring encrypted backup: $(basename "$backup_file")"
    [[ ! -f "$backup_file" ]] && { error "Backup file not found: $backup_file"; return 1; }

    local temp_dir; temp_dir=$(mktemp -d "$BACKUP_DIR/restore.XXXXXX")
    local decrypted_file="$temp_dir/backup.tar.zst"
    decrypt_backup_with_age "$backup_file" "$decrypted_file" || { rm -rf "$temp_dir"; return 1; }

    local extract_dir="$temp_dir/extracted"; mkdir -p "$extract_dir"
    extract_compressed_archive "$decrypted_file" "$extract_dir" || { rm -rf "$temp_dir"; return 1; }

    local dump_dir; dump_dir=$(find "$extract_dir" -name "dump" -type d | head -1)
    [[ -z "$dump_dir" ]] && { error "Could not find dump directory in backup"; rm -rf "$temp_dir"; return 1; }

    restore_mongodb_dump "$dump_dir" "$target_database" || { rm -rf "$temp_dir"; return 1; }
    rm -rf "$temp_dir"
    success "Backup restored successfully"
}

# Extract compressed archive
extract_compressed_archive() {
    local archive_file="$1"; local output_dir="$2"
    if [[ "$archive_file" == *.zst ]]; then
        if command_exists zstd; then
            zstd -d "$archive_file" -c | tar -C "$output_dir" -x
        else
            error "zstd not available for decompression"; return 1
        fi
    elif [[ "$archive_file" == *.gz ]]; then
        tar -C "$output_dir" -xzf "$archive_file"
    else
        error "Unknown archive format: $archive_file"; return 1
    fi
}

# Restore mongorestore dump (x509 if available)
restore_mongodb_dump() {
    local dump_dir="$1"; local target_database="$2"
    local mongorestore_cmd="mongorestore"
    local admin_cert="/etc/mongoCA/clients/admin.pem"; local ca_cert="/etc/mongoCA/ca.crt"
    if [[ -f "$admin_cert" && -f "$ca_cert" ]]; then
        mongorestore_cmd+=" --ssl --sslPEMKeyFile='$admin_cert' --sslCAFile='$ca_cert'"
        mongorestore_cmd+=" --authenticationDatabase='\$external' --authenticationMechanism='MONGODB-X509'"
    fi
    [[ -n "$target_database" ]] && mongorestore_cmd+=" --db '$target_database'"
    mongorestore_cmd+=" '$dump_dir'"
    eval "$mongorestore_cmd" >/dev/null 2>&1
}

# Ensure backup encryption key exists
ensure_backup_key_exists() {
    if [[ ! -f "$BACKUP_KEY_FILE" ]]; then
        info "Creating backup encryption key..."
        mkdir -p "$(dirname "$BACKUP_KEY_FILE")"
        if command_exists age-keygen; then
            age-keygen > "$BACKUP_KEY_FILE" 2>/dev/null
        else
            error "age-keygen not found"; return 1
        fi
        chmod 600 "$BACKUP_KEY_FILE"; chown root:root "$BACKUP_KEY_FILE"
        success "Backup encryption key created"
    fi
}

# Install age tool
install_age_tool() {
    local os; os=$(get_os)
    info "Installing age encryption tool..."
    case "$os" in
        ubuntu|debian) apt-get update -qq && apt-get install -y age ;;
        centos|rhel|fedora) if command_exists dnf; then dnf install -y age; else yum install -y age; fi ;;
        *) error "Unsupported OS for automatic age installation: $os"; return 1 ;;
    esac
    command_exists age
}

# Disk space safety
check_backup_disk_space() {
    local backup_dir; backup_dir=$(dirname "$BACKUP_DIR")
    local free_space_gb; free_space_gb=$(df -BG "$backup_dir" | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
    (( free_space_gb < 1 )) && { error "Insufficient disk space for backup (need 1GB, have ${free_space_gb}GB)"; return 1; }
    local used_percent; used_percent=$(df "$backup_dir" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
    (( used_percent > 80 )) && warn "Disk usage is high (${used_percent}%) - consider cleanup"
}

# Retention cleanup (daily=7)
cleanup_old_backups() {
    local retention_days; retention_days=$(get_config_value "backups.retention.daily")
    [[ -z "$retention_days" || "$retention_days" == "null" ]] && retention_days=7
    info "Cleaning up backups older than $retention_days days..."
    local deleted_count=0
    while IFS= read -r -d '' backup_file; do
        rm -f "$backup_file" "${backup_file}.json"; ((deleted_count++))
    done < <(find "$BACKUP_DIR" -name "backup-*.age" -mtime "+$retention_days" -print0 2>/dev/null)
    (( deleted_count > 0 )) && info "Removed $deleted_count old backup files"
}

# Automated daily backups: systemd service + timer
setup_automated_backups() {
    info "Setting up automated daily backups..."
    create_backup_script
    create_backup_service
    create_backup_timer
    systemctl enable "$BACKUP_TIMER"; systemctl start "$BACKUP_TIMER"
    success "Automated daily backups configured"
}

create_backup_script() {
    local backup_script="/usr/local/bin/harden-mongo-server-backup.sh"
    cat > "$backup_script" << 'EOF'
#!/bin/bash
LOG_FILE="/var/log/harden-mongo-server/backup.log"
log_message() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
source /usr/local/lib/harden-mongo-server/backup.sh
main() {
  log_message "Starting daily backup"
  if create_encrypted_backup "all"; then
    log_message "Daily backup completed successfully"
  else
    log_message "Daily backup failed"; exit 1
  fi
}
main "$@"
EOF
    chmod 755 "$backup_script"; chown root:root "$backup_script"
}

create_backup_service() {
    cat > "/etc/systemd/system/$BACKUP_SERVICE" << EOF
[Unit]
Description=MongoDB Daily Backup Service
After=mongod.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/harden-mongo-server-backup.sh
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/log/harden-mongo-server /var/backups/harden-mongo-server
EOF
    systemctl daemon-reload
}

create_backup_timer() {
    local schedule; schedule=$(get_config_value "backups.schedule"); [[ -z "$schedule" || "$schedule" == "null" ]] && schedule="02:00"
    cat > "/etc/systemd/system/$BACKUP_TIMER" << EOF
[Unit]
Description=Daily MongoDB Backup Timer
Requires=$BACKUP_SERVICE
[Timer]
OnCalendar=*-*-* $schedule
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
}

# Execute backup setup phase
execute_backup_setup_phase() {
    info "Starting backup setup phase..."
    if ! get_config_value "backups.enabled" | grep -q "true"; then
        info "Backups disabled in configuration"; return 0
    fi
    create_dir_safe "$BACKUP_DIR" 750 root:root
    if ! command_exists zstd; then
        info "Installing zstd compression tool..."
        local os; os=$(get_os)
        case "$os" in
            ubuntu|debian) apt-get update -qq && apt-get install -y zstd ;;
            centos|rhel|fedora) if command_exists dnf; then dnf install -y zstd; else yum install -y zstd; fi ;;
        esac
    fi
    command_exists age || install_age_tool || return 1
    ensure_backup_key_exists || return 1
    setup_automated_backups || return 1
    success "Backup setup phase completed"
}

# ================================
# Module Information
# ================================
backup_module_info() {
    cat << EOF
MongoDB Server Hardening Backup Library v$HARDEN_MONGO_SERVER_VERSION

This module provides:
- Encrypted daily backups using age and zstd
- Initial encrypted backup before any changes
- 7-day retention for daily backups
- Disk space safety checks
- Encrypted restore support
- Systemd service/timer for automation

Dependencies: core.sh, logging.sh, system.sh, mongodump, age, zstd
EOF
}

