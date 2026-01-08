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
backup_list_file=""

cleanup_backup_list() {
  if [ -n "${backup_list_file:-}" ] && [ -f "$backup_list_file" ]; then
    rm -f "$backup_list_file"
  fi
}

prompt_restore_confirmations() {
  confirm_yes=""
  confirm_detail=""
  backup_timestamp="$1"
  backup_filename="$2"

  printf "Type YES to proceed with restore: "
  read -r confirm_yes
  if [ "$confirm_yes" != "YES" ]; then
    log_error "Restore aborted: confirmation failed."
    exit 1
  fi

  printf "Type the backup timestamp or filename to confirm (%s): " "$backup_timestamp"
  read -r confirm_detail
  if [ "$confirm_detail" != "$backup_timestamp" ] && [ "$confirm_detail" != "$backup_filename" ]; then
    log_error "Restore aborted: confirmation mismatch."
    exit 1
  fi
}

if [ $# -eq 1 ]; then
  # Restore specific timestamp
  timestamp="$1"
  key_base="${database_name}_${timestamp}.dump"
  if [ -n "${PASSPHRASE:-}" ]; then
    candidates="${key_base}.zst.gpg ${key_base}.gpg"
  else
    candidates="${key_base}.zst ${key_base}"
  fi

  key_suffix=""
  for candidate in $candidates; do
    if s3cmd_exec ls "${s3_uri_base}/${candidate}" >/dev/null 2>&1; then
      key_suffix="$candidate"
      break
    fi
  done

  if [ -z "$key_suffix" ]; then
    log_error "Backup not found for '${database_name}' at timestamp: ${timestamp}"
    log_error "Use 'list.sh' to see available backups."
    exit 1
  fi
  s3_uri="${s3_uri_base}/${key_suffix}"
  log_info "Restoring backup from timestamp: ${timestamp}"
else
  # Restore latest backup (interactive selection)
  log_info "Listing available backups for '${database_name}'..."
  backup_list_file=$(mktemp)
  trap cleanup_backup_list EXIT
  list_backups_raw > "$backup_list_file"

  if [ ! -s "$backup_list_file" ]; then
    log_error "No backup found for '${database_name}'"
    exit 1
  fi

  index=0
  while IFS='|' read -r line_timestamp line_filename line_size; do
    index=$((index + 1))
    line_size_human=$(format_size "$line_size")
    printf "%s) %s | %s | %s\n" "$index" "$line_timestamp" "$line_filename" "$line_size_human"
  done < "$backup_list_file"

  total_backups=$(wc -l < "$backup_list_file" | tr -d ' ')
  while :; do
    printf "Select a backup by number (1-%s, Enter for latest): " "$total_backups"
    read -r selection
    if [ -z "$selection" ]; then
      selection="$total_backups"
      break
    fi
    case "$selection" in
      *[!0-9]*)
        log_error "Invalid selection '${selection}'. Enter a number between 1 and ${total_backups}."
        ;;
      *)
        if [ "$selection" -lt 1 ] || [ "$selection" -gt "$total_backups" ]; then
          log_error "Selection '${selection}' out of range. Enter 1-${total_backups}."
        else
          break
        fi
        ;;
    esac
  done

  backup_line=$(sed -n "${selection}p" "$backup_list_file")
  timestamp=$(echo "$backup_line" | cut -d'|' -f1)
  key_suffix=$(echo "$backup_line" | cut -d'|' -f2)
  s3_uri="${s3_uri_base}/${key_suffix}"
  log_info "Selected: ${key_suffix}"
fi

prompt_restore_confirmations "$timestamp" "$key_suffix"

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
