#!/bin/sh
# common.sh - Shared functions for postgres-backup-s3cmd
#
# This script is sourced by other scripts to provide common functionality.
# Functions:
#   - Logging helpers
#   - Size formatting
#   - S3 connectivity testing
#   - Backup listing
#   - Timestamp utilities

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

log() {
  echo "[$(date -Iseconds)] $*"
}

log_info() {
  log "INFO: $*"
}

log_error() {
  log "ERROR: $*" >&2
}

log_warn() {
  log "WARN: $*"
}

# -----------------------------------------------------------------------------
# Size formatting
# -----------------------------------------------------------------------------

# Convert bytes to human-readable format
# Usage: format_size <bytes>
format_size() {
  bytes="$1"
  if [ "$bytes" -ge 1073741824 ]; then
    # GB
    awk "BEGIN {printf \"%.2f GB\", $bytes / 1073741824}"
  elif [ "$bytes" -ge 1048576 ]; then
    # MB
    awk "BEGIN {printf \"%.2f MB\", $bytes / 1048576}"
  elif [ "$bytes" -ge 1024 ]; then
    # KB
    awk "BEGIN {printf \"%.2f KB\", $bytes / 1024}"
  else
    echo "${bytes} B"
  fi
}

# -----------------------------------------------------------------------------
# S3 connectivity
# -----------------------------------------------------------------------------

# Run s3cmd with our generated (or mounted) config.
# env.sh exports S3CFG_PATH.
s3cmd_exec() {
  if [ -n "${S3CFG_PATH:-}" ]; then
    s3cmd -c "${S3CFG_PATH}" "$@"
  else
    s3cmd "$@"
  fi
}

# Test S3 connection by listing the prefix
# Returns 0 on success, non-zero on failure
test_s3_connection() {
  s3cmd_exec ls "s3://${S3_BUCKET}/${S3_PREFIX}/" >/dev/null 2>&1
}

# Get S3 URI base for backups
get_s3_uri_base() {
  echo "s3://${S3_BUCKET}/${S3_PREFIX}"
}

# -----------------------------------------------------------------------------
# Backup listing helpers
# -----------------------------------------------------------------------------

# Get database name prefix for backup files
get_database_prefix() {
  if [ -n "${POSTGRES_DATABASE:-}" ]; then
    echo "$POSTGRES_DATABASE"
  else
    echo "all"
  fi
}

# Get file extension based on encryption
get_file_extension() {
  ext=".dump"
  if [ "${COMPRESSION:-}" = "zstd" ]; then
    ext="${ext}.zst"
  fi
  if [ -n "${PASSPHRASE:-}" ]; then
    ext="${ext}.gpg"
  fi
  echo "$ext"
}

# Get a grep -E pattern for acceptable backup file suffixes for the current
# encryption mode. Compression is optional to allow restoring older backups.
get_backup_suffix_grep_pattern() {
  if [ -n "${PASSPHRASE:-}" ]; then
    # Encrypted backups: .dump.gpg or .dump.zst.gpg
    echo "\\.dump(\\.zst)?\\.gpg$"
  else
    # Unencrypted backups: .dump or .dump.zst
    echo "\\.dump(\\.zst)?$"
  fi
}

# List all backups (raw s3cmd output with size parsing)
# Output format: timestamp | filename | size_bytes
list_backups_raw() {
  database_prefix=$(get_database_prefix)
  suffix_pattern=$(get_backup_suffix_grep_pattern)
  s3_uri_base=$(get_s3_uri_base)
  
  s3cmd_exec ls "${s3_uri_base}/${database_prefix}_" 2>/dev/null \
    | grep -E "${suffix_pattern}" \
    | sort \
    | while read -r date time size uri; do
        # Extract filename from URI
        filename=$(basename "$uri")
        # Extract timestamp from filename (format: dbname_YYYY-MM-DDTHH:MM:SS.dump[.zst][.gpg])
        timestamp=$(echo "$filename" | sed "s/^${database_prefix}_//" | sed -E 's/\\.dump(\\.zst)?(\\.gpg)?$//')
        echo "${timestamp}|${filename}|${size}"
      done
}

# Get latest backup info
# Output format: timestamp | filename | size_bytes
get_latest_backup() {
  list_backups_raw | tail -n 1
}

# Count total backups
count_backups() {
  list_backups_raw | wc -l | tr -d ' '
}

# Get total size of all backups (in bytes)
get_total_size() {
  list_backups_raw | awk -F'|' '{ sum += $3 } END { print sum + 0 }'
}

# -----------------------------------------------------------------------------
# Timestamp utilities
# -----------------------------------------------------------------------------

# Get current ISO8601 timestamp for backup naming
get_backup_timestamp() {
  date +"%Y-%m-%dT%H:%M:%S"
}

# Calculate seconds elapsed since start
# Usage: start_time=$(date +%s); ... ; elapsed=$(elapsed_seconds $start_time)
elapsed_seconds() {
  start="$1"
  end=$(date +%s)
  echo $((end - start))
}

# -----------------------------------------------------------------------------
# Version info
# -----------------------------------------------------------------------------

# Get version from build-time version file, fallback to "dev"
get_version() {
  if [ -f /VERSION ]; then
    cat /VERSION
  else
    echo "dev"
  fi
}

# -----------------------------------------------------------------------------
# Startup banner
# -----------------------------------------------------------------------------

print_banner() {
  version=$(get_version)
  echo "==============================================="
  echo "postgres-backup-s3cmd ${version}"
  echo "==============================================="
  log "Starting..."
  echo ""
}

# Print configuration summary (safe, no secrets)
print_config() {
  database_prefix=$(get_database_prefix)
  
  echo "Configuration:"
  echo "  S3_BUCKET:         ${S3_BUCKET}"
  echo "  S3_PREFIX:         ${S3_PREFIX}"
  if [ -n "${S3_ENDPOINT:-}" ]; then
    echo "  S3_ENDPOINT:       ${S3_ENDPOINT}"
  else
    echo "  S3_REGION:         ${S3_REGION}"
  fi
  echo "  POSTGRES_HOST:     ${POSTGRES_HOST}:${POSTGRES_PORT}"
  if [ -n "${POSTGRES_DATABASE:-}" ]; then
    echo "  POSTGRES_DATABASE: ${POSTGRES_DATABASE} (single DB mode)"
  else
    echo "  POSTGRES_DATABASE: (all databases mode)"
  fi
  if [ -n "${SCHEDULE:-}" ]; then
    echo "  SCHEDULE:          ${SCHEDULE}"
  else
    echo "  SCHEDULE:          (single run mode)"
  fi
  if [ -n "${BACKUP_KEEP_DAYS:-}" ]; then
    echo "  BACKUP_KEEP_DAYS:  ${BACKUP_KEEP_DAYS}"
  else
    echo "  BACKUP_KEEP_DAYS:  (disabled)"
  fi
  if [ -n "${PASSPHRASE:-}" ]; then
    echo "  ENCRYPTION:        enabled"
  else
    echo "  ENCRYPTION:        disabled"
  fi
  if [ "${COMPRESSION:-}" = "zstd" ]; then
    echo "  COMPRESSION:       zstd (level=${ZSTD_LEVEL}, checksum=${ZSTD_CHECKSUM})"
  else
    echo "  COMPRESSION:       disabled"
  fi
  echo "  S3_ACCESS_KEY_ID:  set"
  echo "  S3_SECRET_KEY:     set"
  echo ""
}

# Print S3 connection status and backup summary
print_s3_status() {
  echo "Checking S3 connection..."
  if ! test_s3_connection; then
    log_error "S3 connection failed!"
    log_error "Please verify: credentials, endpoint, bucket name, and permissions."
    return 1
  fi
  echo "  S3 connection: OK"
  
  backup_count=$(count_backups)
  if [ "$backup_count" -eq 0 ]; then
    echo "  Existing backups: none"
  else
    total_size=$(get_total_size)
    latest=$(get_latest_backup)
    latest_timestamp=$(echo "$latest" | cut -d'|' -f1)
    
    echo "  Existing backups: ${backup_count}"
    echo "  Latest:           ${latest_timestamp}"
    echo "  Total size:       $(format_size "$total_size")"
  fi
  echo ""
  return 0
}
