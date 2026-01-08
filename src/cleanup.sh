#!/bin/sh
# cleanup.sh - Remove old backups based on retention policy
#
# Usage:
#   cleanup.sh              # Use BACKUP_KEEP_DAYS from environment
#   cleanup.sh <days>       # Override retention days
#   cleanup.sh --dry-run    # Show what would be deleted
#   cleanup.sh <days> --dry-run
#
# Exit codes:
#   0 - Success (including no backups matched)
#   1 - Error (S3 connection failed, invalid arguments)
#
# Design:
#   - Idempotent: safe to run multiple times
#   - Safe if no backups match: exits 0
#   - Deletion failures are logged but don't fail the script

set -eu

# Source environment and common functions
. /env.sh
. /common.sh

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

DRY_RUN=""
DAYS=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN="true"
      ;;
    --help|-h)
      echo "Usage: cleanup.sh [<days>] [--dry-run]"
      echo ""
      echo "Arguments:"
      echo "  <days>      Retention period in days (overrides BACKUP_KEEP_DAYS)"
      echo "             Use 0 to delete everything under the prefix"
      echo "  --dry-run   Show what would be deleted without deleting"
      echo ""
      echo "Environment:"
      echo "  BACKUP_KEEP_DAYS  Default retention period if <days> not specified"
      echo ""
      echo "Exit codes:"
      echo "  0 - Success"
      echo "  1 - Error"
      exit 0
      ;;
    *)
      # Assume it's the days argument
      if echo "$arg" | grep -qE '^[0-9]+$'; then
        DAYS="$arg"
      else
        log_error "Invalid argument: $arg"
        echo "Usage: cleanup.sh [<days>] [--dry-run]" >&2
        exit 1
      fi
      ;;
  esac
done

# Use BACKUP_KEEP_DAYS if days not provided
if [ -z "$DAYS" ]; then
  if [ -z "${BACKUP_KEEP_DAYS:-}" ]; then
    log_info "No retention period specified (BACKUP_KEEP_DAYS not set). Nothing to clean."
    exit 0
  fi
  DAYS="$BACKUP_KEEP_DAYS"
fi

# Validate days is a positive integer
# Days may be 0 (delete everything under the prefix).
if ! echo "$DAYS" | grep -qE '^[0-9]+$'; then
  log_error "Retention days must be a non-negative integer: $DAYS"
  exit 1
fi

# -----------------------------------------------------------------------------
# Check S3 connectivity
# -----------------------------------------------------------------------------

if ! test_s3_connection; then
  log_error "S3 connection failed. Cannot perform cleanup."
  exit 1
fi

# -----------------------------------------------------------------------------
# Calculate cutoff date
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Find and delete old backups
# -----------------------------------------------------------------------------

s3_uri_base=$(get_s3_uri_base)
deleted_count=0
failed_count=0

if [ "$DAYS" -eq 0 ]; then
  if [ -n "$DRY_RUN" ]; then
    log_info "[DRY-RUN] Would remove ALL backups under ${s3_uri_base}/"
  else
    log_info "Removing ALL backups under ${s3_uri_base}/..."
  fi

  s3cmd_exec ls "${s3_uri_base}/" 2>/dev/null \
    | awk '{ print $4 }' \
    | while read -r key; do
        if [ -n "$key" ]; then
          if [ -n "$DRY_RUN" ]; then
            log_info "[DRY-RUN] Would delete: $key"
          else
            log_info "Deleting: $key"
            if s3cmd_exec del "$key" 2>/dev/null; then
              : # success
            else
              log_warn "Failed to delete: $key"
            fi
          fi
        fi
      done || true
else
  # Note: Uses BusyBox date syntax
  sec=$((86400 * DAYS))
  cutoff_date=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)

  if [ -n "$DRY_RUN" ]; then
    log_info "[DRY-RUN] Would remove backups older than ${cutoff_date} (${DAYS} days)"
  else
    log_info "Removing backups older than ${cutoff_date} (${DAYS} days)..."
  fi

  # List objects and process those older than cutoff
  s3cmd_exec ls "${s3_uri_base}/" 2>/dev/null \
    | awk -v cutoff="$cutoff_date" '$1 < cutoff { print $4 }' \
    | while read -r key; do
        if [ -n "$key" ]; then
          if [ -n "$DRY_RUN" ]; then
            log_info "[DRY-RUN] Would delete: $key"
          else
            log_info "Deleting: $key"
            if s3cmd_exec del "$key" 2>/dev/null; then
              : # success
            else
              log_warn "Failed to delete: $key"
            fi
          fi
        fi
      done || true
fi

if [ -n "$DRY_RUN" ]; then
  log_info "[DRY-RUN] Cleanup simulation complete."
else
  log_info "Cleanup complete."
fi
