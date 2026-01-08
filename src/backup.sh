#!/bin/sh
# backup.sh - Create PostgreSQL backup and upload to S3
#
# This script:
# 1. Creates a PostgreSQL dump (single DB or all DBs)
# 2. Optionally encrypts the dump with GPG
# 3. Uploads to S3-compatible storage
# 4. Logs backup statistics (size, upload time, speed)
# 5. Optionally runs retention cleanup
#
# Exit behavior:
# - Backup/upload failure: exit non-zero
# - Cleanup failure: backup still considered successful (exit zero)
#
# Design rule: set -e is enabled. Use || true for best-effort operations.

set -eu

# Source environment and common functions
. /env.sh
. /common.sh

timestamp=$(get_backup_timestamp)

# -----------------------------------------------------------------------------
# Create database dump
# -----------------------------------------------------------------------------

if [ -n "${POSTGRES_DATABASE:-}" ]; then
  # Single database backup using pg_dump
  log_info "Creating backup of ${POSTGRES_DATABASE} database..."
  # shellcheck disable=SC2086
  pg_dump --format=custom \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DATABASE" \
    $PGDUMP_EXTRA_OPTS \
    > db.dump
  database_name="$POSTGRES_DATABASE"
else
  # Full cluster backup using pg_dumpall
  log_info "Creating backup of all databases..."
  # shellcheck disable=SC2086
  pg_dumpall -c --if-exists \
    --host="$POSTGRES_HOST" \
    --port="$POSTGRES_PORT" \
    --username="$POSTGRES_USER" \
    $PGDUMP_EXTRA_OPTS \
    --file=db.dump
  database_name="all"
fi

# -----------------------------------------------------------------------------
# Encrypt backup (optional)
# -----------------------------------------------------------------------------

backup_basename="${database_name}_${timestamp}"
backup_ext=$(get_file_extension)
s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/${backup_basename}${backup_ext}"

# -----------------------------------------------------------------------------
# Compress backup (optional)
# -----------------------------------------------------------------------------

local_file="db.dump"

if [ "${COMPRESSION:-}" = "zstd" ]; then
  log_info "Compressing backup with zstd (level=${ZSTD_LEVEL}, checksum=${ZSTD_CHECKSUM})..."
  zstd_args="-${ZSTD_LEVEL} -q --rm"
  if [ "${ZSTD_CHECKSUM}" = "true" ]; then
    zstd_args="${zstd_args} --checksum"
  fi
  # shellcheck disable=SC2086
  zstd ${zstd_args} "$local_file"
  local_file="${local_file}.zst"
fi

if [ -n "${PASSPHRASE:-}" ]; then
  log_info "Encrypting backup..."
  gpg --symmetric --batch --pinentry-mode loopback --passphrase "$PASSPHRASE" "$local_file"
  rm "$local_file"
  local_file="${local_file}.gpg"
fi

# -----------------------------------------------------------------------------
# Capture file size before upload
# -----------------------------------------------------------------------------

file_size_bytes=$(stat -c%s "$local_file" 2>/dev/null || stat -f%z "$local_file" 2>/dev/null)

# -----------------------------------------------------------------------------
# Upload to S3 (with timing)
# -----------------------------------------------------------------------------

log_info "Uploading backup to s3://${S3_BUCKET}/${S3_PREFIX}/..."

upload_start=$(date +%s)
s3cmd_exec put "$local_file" "$s3_uri"
upload_end=$(date +%s)

upload_seconds=$((upload_end - upload_start))
# Avoid division by zero
if [ "$upload_seconds" -eq 0 ]; then
  upload_seconds=1
fi

rm "$local_file"

# -----------------------------------------------------------------------------
# Log backup statistics
# -----------------------------------------------------------------------------

log_info "Backup complete."
echo ""
echo "Summary:"
echo "  File:         $(basename "$s3_uri")"
echo "  Size:         $(format_size "$file_size_bytes")"
echo "  Upload time:  ${upload_seconds}s"

# Calculate speed in bytes per second, then format
speed_bps=$((file_size_bytes / upload_seconds))
echo "  Speed:        $(format_size "$speed_bps")/s"

# Machine-parseable stats for future monitoring integration
echo ""
echo "backup.stats.file=$(basename "$s3_uri")"
echo "backup.stats.size_bytes=${file_size_bytes}"
echo "backup.stats.upload_seconds=${upload_seconds}"
# Calculate MB/s with one decimal place
speed_mbps=$(awk "BEGIN {printf \"%.1f\", $file_size_bytes / $upload_seconds / 1048576}")
echo "backup.stats.upload_mbps=${speed_mbps}"
echo ""

# -----------------------------------------------------------------------------
# Cleanup old backups (best-effort, failure does not affect backup status)
# -----------------------------------------------------------------------------

if [ -n "${BACKUP_KEEP_DAYS:-}" ]; then
  log_info "Running retention cleanup..."
  /bin/sh /cleanup.sh || log_warn "Cleanup encountered errors, but backup succeeded."
fi

log_info "Done."
