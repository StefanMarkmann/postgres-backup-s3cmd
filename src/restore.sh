#!/bin/sh
# restore.sh - Restore PostgreSQL backup from S3
#
# Usage:
#   restore.sh                    # Restore latest backup
#   restore.sh 2026-01-07T14:30:00  # Restore specific timestamp
#
# This script:
# 1. Downloads backup from S3 (latest or specific)
# 2. Optionally decrypts with GPG
# 3. Restores to PostgreSQL
#
# Exit behavior:
# - Any failure: exit non-zero (restore must be reliable)
#
# Restore semantics:
# - Single DB mode: Target database must exist, roles not recreated
# - pg_dumpall mode: Roles restored, empty cluster recommended
#
# WARNING: Restore is destructive! It drops and recreates database objects.

set -eu

# Source environment and common functions
. /env.sh
. /common.sh

s3_uri_base=$(get_s3_uri_base)

# -----------------------------------------------------------------------------
# Determine database prefix
# -----------------------------------------------------------------------------

if [ -n "${POSTGRES_DATABASE:-}" ]; then
  database_name="$POSTGRES_DATABASE"
else
  database_name="all"
fi

# -----------------------------------------------------------------------------
# Get backup to restore
# -----------------------------------------------------------------------------

backup_line=""

if [ $# -eq 1 ]; then
  # Restore specific timestamp
  timestamp="$1"
  backup_line=$(list_backups_raw | awk -F'|' -v ts="$timestamp" '$1 == ts { print; exit }')
  if [ -z "$backup_line" ]; then
    log_error "Backup not found for '${database_name}' at timestamp: ${timestamp}"
    log_error "Use 'list.sh' to see available backups."
    exit 1
  fi
  key_suffix=$(echo "$backup_line" | cut -d'|' -f2)
  s3_uri="${s3_uri_base}/${key_suffix}"
  log_info "Restoring backup from timestamp: ${timestamp}"
else
  # Restore latest backup
  log_info "Finding latest backup for '${database_name}'..."
  backup_line=$(get_latest_backup)
  if [ -z "$backup_line" ]; then
    log_error "No backup found for '${database_name}'"
    exit 1
  fi

  key_suffix=$(echo "$backup_line" | cut -d'|' -f2)
  s3_uri="${s3_uri_base}/${key_suffix}"
  log_info "Found: ${key_suffix}"
fi

# -----------------------------------------------------------------------------
# Download backup from S3
# -----------------------------------------------------------------------------

log_info "Downloading backup from S3..."
download_file=$(basename "$s3_uri")
s3cmd_exec get "$s3_uri" "$download_file"

# -----------------------------------------------------------------------------
# Decrypt backup (if encrypted)
# -----------------------------------------------------------------------------

work_file="$download_file"

if echo "$work_file" | grep -qE '\.gpg$'; then
  log_info "Decrypting backup..."
  decrypted_file="${work_file%.gpg}"
  gpg --decrypt --batch --pinentry-mode loopback --passphrase "$PASSPHRASE" "$work_file" > "$decrypted_file"
  rm "$work_file"
  work_file="$decrypted_file"
fi

# -----------------------------------------------------------------------------
# Decompress backup (if zstd)
# -----------------------------------------------------------------------------

if echo "$work_file" | grep -qE '\.zst$'; then
  log_info "Decompressing backup with zstd (verifies checksum)..."
  zstd -d -q --rm "$work_file"
  work_file="${work_file%.zst}"
fi

# -----------------------------------------------------------------------------
# Restore database
# -----------------------------------------------------------------------------

if [ -n "${POSTGRES_DATABASE:-}" ]; then
  # Single database restore using pg_restore
  # Note: Target database must already exist. Roles are NOT recreated.
  log_info "Restoring '${POSTGRES_DATABASE}' database..."
  log_warn "This will drop and recreate objects in '${POSTGRES_DATABASE}'!"
  
  pg_restore \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DATABASE" \
    --clean --if-exists \
    "$work_file"
else
  # Full cluster restore using psql
  # Note: Restores roles and globals. Target cluster should be empty/disposable.
  # We connect to 'postgres' database which always exists as the bootstrap database.
  log_info "Restoring all databases..."
  log_warn "This will drop and recreate all databases and roles!"
  
  psql \
    -h "$POSTGRES_HOST" \
    -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" \
    -d postgres \
    -f "$work_file"
fi

rm "$work_file"

log_info "Restore complete."
