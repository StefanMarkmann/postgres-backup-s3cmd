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
# Determine file type (encrypted or not)
# -----------------------------------------------------------------------------

if [ -n "${PASSPHRASE:-}" ]; then
  file_type=".dump.gpg"
else
  file_type=".dump"
fi

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

if [ $# -eq 1 ]; then
  # Restore specific timestamp
  timestamp="$1"
  key_suffix="${database_name}_${timestamp}${file_type}"
  s3_uri="${s3_uri_base}/${key_suffix}"
  log_info "Restoring backup from timestamp: ${timestamp}"
else
  # Restore latest backup
  log_info "Finding latest backup for '${database_name}'..."
  
  # Find the latest backup by sorting s3cmd ls output
  latest_key=$(
    s3cmd ls "${s3_uri_base}/${database_name}_" 2>/dev/null \
      | grep "${file_type}$" \
      | sort \
      | tail -n 1 \
      | awk '{ print $4 }'
  )
  
  if [ -z "$latest_key" ]; then
    log_error "No backup found for '${database_name}'"
    exit 1
  fi
  
  s3_uri="$latest_key"
  key_suffix=$(echo "$latest_key" | sed "s|${s3_uri_base}/||")
  log_info "Found: ${key_suffix}"
fi

# -----------------------------------------------------------------------------
# Download backup from S3
# -----------------------------------------------------------------------------

log_info "Downloading backup from S3..."
s3cmd get "$s3_uri" "db${file_type}"

# -----------------------------------------------------------------------------
# Decrypt backup (if encrypted)
# -----------------------------------------------------------------------------

if [ -n "${PASSPHRASE:-}" ]; then
  log_info "Decrypting backup..."
  gpg --decrypt --batch --passphrase "$PASSPHRASE" db.dump.gpg > db.dump
  rm db.dump.gpg
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
    db.dump
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
    -f db.dump
fi

rm db.dump

log_info "Restore complete."
