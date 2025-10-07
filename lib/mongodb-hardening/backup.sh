#!/usr/bin/env bash
# MongoDB Hardening Utility - Backup Library
# Provides backup and restore operations, scheduling, and maintenance functions

# Prevent multiple inclusion
if [[ -n "${_MONGODB_HARDENING_BACKUP_LOADED:-}" ]]; then
    return 0
fi
readonly _MONGODB_HARDENING_BACKUP_LOADED=1

# Load required modules
if [[ -z "${_MONGODB_HARDENING_CORE_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/core.sh"
fi

if [[ -z "${_MONGODB_HARDENING_LOGGING_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
fi

if [[ -z "${_MONGODB_HARDENING_SYSTEM_LOADED:-}" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/system.sh"
fi

# ================================
# Backup Configuration Constants
# ================================

# Default backup settings
readonly DEFAULT_BACKUP_DIR="/var/backups/mongodb"
readonly DEFAULT_RETENTION_DAYS="30"
readonly DEFAULT_COMPRESSION="gzip"
readonly BACKUP_TIMESTAMP_FORMAT="%Y%m%d_%H%M%S"

# Backup types
readonly -A BACKUP_TYPES=(
    [full]="Complete database backup"
    [incremental]="Changes since last backup"
    [differential]="Changes since last full backup"
    [oplog]="Operations log backup"
)

# Compression methods
readonly -A COMPRESSION_METHODS=(
    [none]="No compression"
    [gzip]="GZip compression"
    [bzip2]="BZip2 compression"
    [xz]="XZ compression"
    [lz4]="LZ4 compression"
)

# ================================
# MongoDB Backup Functions
# ================================

# Create MongoDB backup using mongodump
create_mongodb_backup() {
    local backup_dir="${1:-$DEFAULT_BACKUP_DIR}"
    local database="${2:-all}"
    local collection="${3:-}"
    local backup_type="${4:-full}"
    local compression="${5:-$DEFAULT_COMPRESSION}"
    local username="${6:-}"
    local password="${7:-}"
    
    local timestamp
    timestamp=$(date "+$BACKUP_TIMESTAMP_FORMAT")
    local backup_name="mongodb_${backup_type}_${timestamp}"
    local backup_path="$backup_dir/$backup_name"
    
    info "Creating MongoDB $backup_type backup: $backup_name"
    
    # Create backup directory
    create_dir_safe "$backup_dir" 755 mongodb:mongodb
    create_dir_safe "$backup_path" 750 mongodb:mongodb
    
    # Check if mongodump is available
    if ! command_exists mongodump; then
        error "mongodump command not found. Please install mongodb-tools."
        return 1
    fi
    
    # Build mongodump command
    local mongodump_cmd="mongodump --out '$backup_path'"
    
    # Add authentication if provided
    if [[ -n "$username" && -n "$password" ]]; then
        mongodump_cmd="$mongodump_cmd --username '$username' --password '$password' --authenticationDatabase admin"
    fi
    
    # Add database selection
    if [[ "$database" != "all" ]]; then
        mongodump_cmd="$mongodump_cmd --db '$database'"
        
        # Add collection selection if specified
        if [[ -n "$collection" ]]; then
            mongodump_cmd="$mongodump_cmd --collection '$collection'"
        fi
    fi
    
    # Add backup type specific options
    case "$backup_type" in
        oplog)
            mongodump_cmd="$mongodump_cmd --oplog"
            ;;
        incremental|differential)
            # These require custom logic with timestamps
            warn "Incremental and differential backups require additional implementation"
            ;;
    esac
    
    # Execute backup
    local start_time
    start_time=$(date +%s)
    
    if execute_or_simulate "Create MongoDB backup" "$mongodump_cmd"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        success "MongoDB backup completed in ${duration}s"
        
        # Create backup metadata
        create_backup_metadata "$backup_path" "$backup_type" "$database" "$collection" "$duration"
        
        # Apply compression if requested
        if [[ "$compression" != "none" ]]; then
            compress_backup "$backup_path" "$compression"
        fi
        
        # Set proper permissions
        if ! is_dry_run; then
            chown -R mongodb:mongodb "$backup_path"
            find "$backup_path" -type f -exec chmod 640 {} \;
            find "$backup_path" -type d -exec chmod 750 {} \;
        fi
        
        echo "$backup_path"
    else
        error "MongoDB backup failed"
        return 1
    fi
}

# Create backup metadata file
create_backup_metadata() {
    local backup_path="$1"
    local backup_type="$2"
    local database="$3"
    local collection="$4"
    local duration="$5"
    
    local metadata_file="$backup_path/backup_metadata.json"
    local backup_size
    backup_size=$(du -sh "$backup_path" 2>/dev/null | cut -f1 || echo "unknown")
    
    local metadata_content="{
  \"backup_info\": {
    \"timestamp\": \"$(date -Iseconds)\",
    \"type\": \"$backup_type\",
    \"database\": \"$database\",
    \"collection\": \"$collection\",
    \"duration_seconds\": $duration,
    \"size\": \"$backup_size\",
    \"mongodb_version\": \"$(get_mongodb_version)\",
    \"hostname\": \"$(hostname)\",
    \"created_by\": \"mongodb-hardening v$MONGODB_HARDENING_VERSION\"
  },
  \"system_info\": {
    \"os\": \"$(get_os)\",
    \"architecture\": \"$(get_architecture)\",
    \"memory_gb\": $(get_memory_gb)
  }
}"
    
    if ! is_dry_run; then
        echo "$metadata_content" > "$metadata_file"
        chmod 640 "$metadata_file"
        chown mongodb:mongodb "$metadata_file"
    fi
    
    verbose "Backup metadata created: $metadata_file"
}

# Compress backup directory
compress_backup() {
    local backup_path="$1"
    local compression_method="${2:-gzip}"
    
    info "Compressing backup with $compression_method"
    
    local backup_dir
    backup_dir="$(dirname "$backup_path")"
    local backup_name
    backup_name="$(basename "$backup_path")"
    
    case "$compression_method" in
        gzip)
            execute_or_simulate "Compress backup with gzip" \
                "cd '$backup_dir' && tar -czf '$backup_name.tar.gz' '$backup_name' && rm -rf '$backup_name'"
            ;;
        bzip2)
            execute_or_simulate "Compress backup with bzip2" \
                "cd '$backup_dir' && tar -cjf '$backup_name.tar.bz2' '$backup_name' && rm -rf '$backup_name'"
            ;;
        xz)
            execute_or_simulate "Compress backup with xz" \
                "cd '$backup_dir' && tar -cJf '$backup_name.tar.xz' '$backup_name' && rm -rf '$backup_name'"
            ;;
        lz4)
            if command_exists lz4; then
                execute_or_simulate "Compress backup with lz4" \
                    "cd '$backup_dir' && tar -c '$backup_name' | lz4 > '$backup_name.tar.lz4' && rm -rf '$backup_name'"
            else
                warn "lz4 not available, falling back to gzip"
                compress_backup "$backup_path" "gzip"
            fi
            ;;
        *)
            warn "Unknown compression method: $compression_method, skipping compression"
            ;;
    esac
}

# ================================
# MongoDB Restore Functions
# ================================

# Restore MongoDB backup using mongorestore
restore_mongodb_backup() {
    local backup_path="$1"
    local target_database="${2:-}"
    local drop_existing="${3:-false}"
    local username="${4:-}"
    local password="${5:-}"
    
    info "Restoring MongoDB backup from: $backup_path"
    
    # Check if mongorestore is available
    if ! command_exists mongorestore; then
        error "mongorestore command not found. Please install mongodb-tools."
        return 1
    fi
    
    # Check if backup path exists
    if [[ ! -e "$backup_path" ]]; then
        error "Backup path not found: $backup_path"
        return 1
    fi
    
    # Decompress backup if it's compressed
    local restore_path="$backup_path"
    if [[ -f "$backup_path" ]]; then
        restore_path=$(decompress_backup "$backup_path")
        if [[ $? -ne 0 ]]; then
            return 1
        fi
    fi
    
    # Validate backup structure
    if ! validate_backup_structure "$restore_path"; then
        error "Invalid backup structure"
        return 1
    fi
    
    # Build mongorestore command
    local mongorestore_cmd="mongorestore"
    
    # Add authentication if provided
    if [[ -n "$username" && -n "$password" ]]; then
        mongorestore_cmd="$mongorestore_cmd --username '$username' --password '$password' --authenticationDatabase admin"
    fi
    
    # Add drop option if requested
    if [[ "$drop_existing" == "true" ]]; then
        mongorestore_cmd="$mongorestore_cmd --drop"
    fi
    
    # Add target database if specified
    if [[ -n "$target_database" ]]; then
        mongorestore_cmd="$mongorestore_cmd --db '$target_database'"
    fi
    
    # Add backup path
    mongorestore_cmd="$mongorestore_cmd '$restore_path'"
    
    # Execute restore
    local start_time
    start_time=$(date +%s)
    
    if execute_or_simulate "Restore MongoDB backup" "$mongorestore_cmd"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        success "MongoDB restore completed in ${duration}s"
        
        # Clean up temporary decompressed files if needed
        if [[ "$restore_path" != "$backup_path" && -d "$restore_path" ]]; then
            execute_or_simulate "Clean up temporary files" "rm -rf '$restore_path'"
        fi
    else
        error "MongoDB restore failed"
        return 1
    fi
}

# Decompress backup file
decompress_backup() {
    local backup_file="$1"
    local temp_dir
    temp_dir=$(create_temp_dir)
    
    info "Decompressing backup file"
    
    case "$backup_file" in
        *.tar.gz)
            execute_or_simulate "Decompress gzip backup" \
                "tar -xzf '$backup_file' -C '$temp_dir'"
            ;;
        *.tar.bz2)
            execute_or_simulate "Decompress bzip2 backup" \
                "tar -xjf '$backup_file' -C '$temp_dir'"
            ;;
        *.tar.xz)
            execute_or_simulate "Decompress xz backup" \
                "tar -xJf '$backup_file' -C '$temp_dir'"
            ;;
        *.tar.lz4)
            if command_exists lz4; then
                execute_or_simulate "Decompress lz4 backup" \
                    "lz4 -dc '$backup_file' | tar -x -C '$temp_dir'"
            else
                error "lz4 not available for decompression"
                return 1
            fi
            ;;
        *)
            error "Unknown backup file format: $backup_file"
            return 1
            ;;
    esac
    
    # Find the extracted directory
    local extracted_dir
    extracted_dir=$(find "$temp_dir" -maxdepth 1 -type d -name "mongodb_*" | head -1)
    
    if [[ -n "$extracted_dir" ]]; then
        echo "$extracted_dir"
    else
        error "Could not find extracted backup directory"
        return 1
    fi
}

# Validate backup structure
validate_backup_structure() {
    local backup_path="$1"
    
    # Check if path exists
    if [[ ! -d "$backup_path" ]]; then
        error "Backup directory not found: $backup_path"
        return 1
    fi
    
    # Check for BSON files (indicating a valid mongodump backup)
    local bson_count
    bson_count=$(find "$backup_path" -name "*.bson" | wc -l)
    
    if ((bson_count == 0)); then
        error "No BSON files found in backup directory"
        return 1
    fi
    
    # Check for metadata files
    local metadata_count
    metadata_count=$(find "$backup_path" -name "*.metadata.json" | wc -l)
    
    if ((metadata_count == 0)); then
        warn "No metadata files found in backup"
    fi
    
    success "Backup structure validation passed"
    return 0
}

# ================================
# Backup Management Functions
# ================================

# List available backups
list_backups() {
    local backup_dir="${1:-$DEFAULT_BACKUP_DIR}"
    local show_details="${2:-false}"
    
    print_section "Available MongoDB Backups"
    
    if [[ ! -d "$backup_dir" ]]; then
        warn "Backup directory does not exist: $backup_dir"
        return 1
    fi
    
    local backup_count=0
    
    # List directories and compressed files
    for backup_item in "$backup_dir"/mongodb_* "$backup_dir"/*.tar.*; do
        if [[ -e "$backup_item" ]]; then
            local backup_name
            backup_name=$(basename "$backup_item")
            local backup_size
            backup_size=$(du -sh "$backup_item" 2>/dev/null | cut -f1 || echo "unknown")
            local backup_date
            backup_date=$(stat -c %y "$backup_item" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
            
            echo "  $backup_name"
            print_indent "Size: $backup_size" 2
            print_indent "Date: $backup_date" 2
            
            # Show detailed information if requested
            if [[ "$show_details" == "true" ]]; then
                show_backup_details "$backup_item"
            fi
            
            echo
            ((backup_count++))
        fi
    done
    
    if ((backup_count == 0)); then
        info "No backups found in $backup_dir"
    else
        info "Total backups: $backup_count"
    fi
}

# Show detailed backup information
show_backup_details() {
    local backup_item="$1"
    
    # Check if it's a compressed file
    if [[ -f "$backup_item" ]]; then
        print_indent "Type: Compressed backup" 2
        return 0
    fi
    
    # Check for metadata file
    local metadata_file="$backup_item/backup_metadata.json"
    if [[ -f "$metadata_file" ]]; then
        local backup_type
        local database
        local duration
        backup_type=$(grep '"type"' "$metadata_file" | cut -d'"' -f4 2>/dev/null || echo "unknown")
        database=$(grep '"database"' "$metadata_file" | cut -d'"' -f4 2>/dev/null || echo "unknown")
        duration=$(grep '"duration_seconds"' "$metadata_file" | cut -d':' -f2 | tr -d ' ,' 2>/dev/null || echo "unknown")
        
        print_indent "Type: $backup_type" 2
        print_indent "Database: $database" 2
        print_indent "Duration: ${duration}s" 2
    else
        print_indent "Type: Legacy backup (no metadata)" 2
    fi
}

# Clean up old backups based on retention policy
cleanup_old_backups() {
    local backup_dir="${1:-$DEFAULT_BACKUP_DIR}"
    local retention_days="${2:-$DEFAULT_RETENTION_DAYS}"
    local dry_run="${3:-false}"
    
    info "Cleaning up backups older than $retention_days days"
    
    if [[ ! -d "$backup_dir" ]]; then
        warn "Backup directory does not exist: $backup_dir"
        return 0
    fi
    
    local cleanup_count=0
    local total_size=0
    
    # Find and process old backups
    while IFS= read -r -d '' backup_item; do
        local backup_age_days
        backup_age_days=$(( ($(date +%s) - $(stat -c %Y "$backup_item")) / 86400 ))
        
        if ((backup_age_days > retention_days)); then
            local item_size
            item_size=$(du -s "$backup_item" 2>/dev/null | cut -f1 || echo "0")
            total_size=$((total_size + item_size))
            
            if [[ "$dry_run" == "true" ]]; then
                info "[DRY RUN] Would delete: $(basename "$backup_item") (${backup_age_days} days old)"
            else
                info "Deleting old backup: $(basename "$backup_item") (${backup_age_days} days old)"
                execute_or_simulate "Delete old backup" "rm -rf '$backup_item'"
            fi
            
            ((cleanup_count++))
        fi
    done < <(find "$backup_dir" -maxdepth 1 \( -name "mongodb_*" -o -name "*.tar.*" \) -print0)
    
    local total_size_mb=$((total_size / 1024))
    
    if ((cleanup_count > 0)); then
        success "Cleaned up $cleanup_count old backups, freed ${total_size_mb}MB"
    else
        info "No old backups found for cleanup"
    fi
}

# ================================
# Backup Scheduling Functions
# ================================

# Create cron job for automated backups
schedule_backup() {
    local schedule="${1:-0 2 * * *}"  # Default: daily at 2 AM
    local backup_type="${2:-full}"
    local retention_days="${3:-$DEFAULT_RETENTION_DAYS}"
    local script_path="${4:-/usr/local/bin/mongodb-backup.sh}"
    
    info "Scheduling automated MongoDB backups"
    
    # Create backup script
    create_backup_script "$script_path" "$backup_type" "$retention_days"
    
    # Add cron job
    local cron_entry="$schedule root $script_path >/var/log/mongodb-backup.log 2>&1"
    local cron_file="/etc/cron.d/mongodb-backup"
    
    if ! is_dry_run; then
        echo "$cron_entry" > "$cron_file"
        chmod 644 "$cron_file"
    fi
    
    execute_or_simulate "Create backup cron job" "echo '$cron_entry' > '$cron_file'"
    success "Backup scheduled: $schedule"
    
    # Verify cron service is running
    if systemctl is-active --quiet cron || systemctl is-active --quiet crond; then
        success "Cron service is running"
    else
        warn "Cron service is not running, backups will not execute automatically"
    fi
}

# Create automated backup script
create_backup_script() {
    local script_path="$1"
    local backup_type="$2"
    local retention_days="$3"
    
    local script_content="#!/bin/bash
# Automated MongoDB Backup Script
# Generated by MongoDB Hardening Utility

# Set environment
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Source the backup library
source \"$(mongodb_hardening_lib_dir)/backup.sh\"

# Configuration
BACKUP_DIR=\"$DEFAULT_BACKUP_DIR\"
BACKUP_TYPE=\"$backup_type\"
RETENTION_DAYS=\"$retention_days\"

# Log start
logger \"MongoDB backup started (type: \$BACKUP_TYPE)\"

# Create backup
if backup_result=\$(create_mongodb_backup \"\$BACKUP_DIR\" \"all\" \"\" \"\$BACKUP_TYPE\"); then
    logger \"MongoDB backup completed: \$backup_result\"
    
    # Clean up old backups
    cleanup_old_backups \"\$BACKUP_DIR\" \"\$RETENTION_DAYS\"
    
    logger \"MongoDB backup cleanup completed\"
else
    logger \"MongoDB backup failed\"
    exit 1
fi
"
    
    if ! is_dry_run; then
        echo "$script_content" > "$script_path"
        chmod 755 "$script_path"
        chown root:root "$script_path"
    fi
    
    execute_or_simulate "Create backup script" "echo 'Backup script created at $script_path'"
}

# Remove backup scheduling
unschedule_backup() {
    local cron_file="/etc/cron.d/mongodb-backup"
    local script_path="/usr/local/bin/mongodb-backup.sh"
    
    info "Removing automated backup scheduling"
    
    # Remove cron job
    if [[ -f "$cron_file" ]]; then
        execute_or_simulate "Remove backup cron job" "rm -f '$cron_file'"
    fi
    
    # Remove backup script
    if [[ -f "$script_path" ]]; then
        execute_or_simulate "Remove backup script" "rm -f '$script_path'"
    fi
    
    success "Backup scheduling removed"
}

# ================================
# Backup Verification Functions
# ================================

# Verify backup integrity
verify_backup() {
    local backup_path="$1"
    
    info "Verifying backup integrity: $(basename "$backup_path")"
    
    # Check if backup exists
    if [[ ! -e "$backup_path" ]]; then
        error "Backup not found: $backup_path"
        return 1
    fi
    
    # If compressed, verify archive integrity
    if [[ -f "$backup_path" ]]; then
        case "$backup_path" in
            *.tar.gz)
                if execute_or_simulate "Verify gzip archive" "gzip -t '$backup_path' 2>/dev/null"; then
                    success "Archive integrity verified"
                else
                    error "Archive corruption detected"
                    return 1
                fi
                ;;
            *.tar.bz2)
                if execute_or_simulate "Verify bzip2 archive" "bzip2 -t '$backup_path' 2>/dev/null"; then
                    success "Archive integrity verified"
                else
                    error "Archive corruption detected"
                    return 1
                fi
                ;;
            *.tar.xz)
                if execute_or_simulate "Verify xz archive" "xz -t '$backup_path' 2>/dev/null"; then
                    success "Archive integrity verified"
                else
                    error "Archive corruption detected"
                    return 1
                fi
                ;;
        esac
        return 0
    fi
    
    # For directory backups, validate structure and files
    if ! validate_backup_structure "$backup_path"; then
        return 1
    fi
    
    # Check BSON file integrity
    local bson_files
    local corrupt_files=0
    
    while IFS= read -r -d '' bson_file; do
        if ! file "$bson_file" | grep -q "BSON"; then
            error "Corrupt BSON file: $bson_file"
            ((corrupt_files++))
        fi
    done < <(find "$backup_path" -name "*.bson" -print0)
    
    if ((corrupt_files > 0)); then
        error "$corrupt_files corrupt BSON files found"
        return 1
    fi
    
    success "Backup verification passed"
    return 0
}

# Test backup restore (dry run)
test_backup_restore() {
    local backup_path="$1"
    local test_database="${2:-backup_test_$(date +%s)}"
    
    info "Testing backup restore to temporary database: $test_database"
    
    # Restore to test database
    if restore_mongodb_backup "$backup_path" "$test_database" "false"; then
        # Verify restored data exists
        local mongo_cmd="mongosh"
        if ! command_exists mongosh && command_exists mongo; then
            mongo_cmd="mongo"
        fi
        
        if command_exists "$mongo_cmd"; then
            local collection_count
            collection_count=$($mongo_cmd "$test_database" --eval "db.stats().collections" --quiet 2>/dev/null || echo "0")
            
            if ((collection_count > 0)); then
                success "Restore test passed: $collection_count collections found"
                
                # Clean up test database
                execute_or_simulate "Drop test database" \
                    "$mongo_cmd '$test_database' --eval 'db.dropDatabase()' --quiet"
                
                return 0
            else
                error "Restore test failed: no collections found"
                return 1
            fi
        else
            warn "MongoDB client not available, cannot verify restored data"
            return 0
        fi
    else
        error "Restore test failed"
        return 1
    fi
}

# ================================
# Module Information
# ================================

# Module information
backup_module_info() {
    cat << EOF
MongoDB Hardening Backup Library v$MONGODB_HARDENING_VERSION

This module provides:
- Full database backup using mongodump
- Selective database and collection backup
- Multiple compression options (gzip, bzip2, xz, lz4)
- Backup restoration with mongorestore
- Automated backup scheduling with cron
- Backup retention management and cleanup
- Backup verification and integrity testing
- Detailed backup metadata and logging

Functions:
- create_mongodb_backup: Create database backups
- restore_mongodb_backup: Restore from backup
- list_backups: Display available backups
- cleanup_old_backups: Remove old backups based on retention
- schedule_backup: Set up automated backup jobs
- verify_backup: Check backup integrity
- test_backup_restore: Test restore functionality

Backup Types:
- full: Complete database backup (default)
- oplog: Operations log backup for point-in-time recovery
- incremental: Changes since last backup (planned)
- differential: Changes since last full backup (planned)

Compression Methods:
- gzip: Standard compression (default)
- bzip2: Higher compression ratio
- xz: Best compression ratio
- lz4: Fastest compression
- none: No compression

Default Settings:
- Backup Directory: $DEFAULT_BACKUP_DIR
- Retention Period: $DEFAULT_RETENTION_DAYS days
- Compression: $DEFAULT_COMPRESSION

Dependencies: core.sh, logging.sh, system.sh, mongodump, mongorestore
EOF
}