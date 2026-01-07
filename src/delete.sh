#!/bin/sh
# delete.sh - Delete a specific backup by timestamp
#
# Usage:
#   delete.sh <timestamp>             # Delete backup with exact timestamp
#   delete.sh <timestamp> --dry-run   # Show what would be deleted
#
# Example:
#   delete.sh 2026-01-07T14:30:00
#
# Exit codes:
#   0 - Success (backup deleted or dry-run complete)
#   1 - Error (S3 failed, backup not found, invalid arguments)
#
# Design:
#   - Requires EXACT timestamp match (no fuzzy matching)
#   - Shows what will be deleted before doing it
#   - Supports --dry-run for safety

set -eu

# Source environment and common functions
. /env.sh
. /common.sh

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

DRY_RUN=""
TIMESTAMP=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN="true"
      ;;
    --help|-h)
      echo "Usage: delete.sh <timestamp> [--dry-run]"
      echo ""
      echo "Arguments:"
      echo "  <timestamp>  Exact backup timestamp (e.g., 2026-01-07T14:30:00)"
      echo "  --dry-run    Show what would be deleted without deleting"
      echo ""
      echo "Exit codes:"
      echo "  0 - Success"
      echo "  1 - Error (backup not found, S3 failed, invalid arguments)"
      echo ""
      echo "Example:"
      echo "  delete.sh 2026-01-07T14:30:00"
      echo "  delete.sh 2026-01-07T14:30:00 --dry-run"
      exit 0
      ;;
    *)
      # First non-flag argument is the timestamp
      if [ -z "$TIMESTAMP" ]; then
        TIMESTAMP="$arg"
      else
        log_error "Unexpected argument: $arg"
        echo "Usage: delete.sh <timestamp> [--dry-run]" >&2
        exit 1
      fi
      ;;
  esac
done

# Validate timestamp is provided
if [ -z "$TIMESTAMP" ]; then
  log_error "Timestamp is required."
  echo "Usage: delete.sh <timestamp> [--dry-run]" >&2
  exit 1
fi

# Basic timestamp format validation (YYYY-MM-DDTHH:MM:SS)
if ! echo "$TIMESTAMP" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
  log_error "Invalid timestamp format: $TIMESTAMP"
  log_error "Expected format: YYYY-MM-DDTHH:MM:SS (e.g., 2026-01-07T14:30:00)"
  exit 1
fi

# -----------------------------------------------------------------------------
# Check S3 connectivity
# -----------------------------------------------------------------------------

if ! test_s3_connection; then
  log_error "S3 connection failed. Cannot delete backup."
  exit 1
fi

# -----------------------------------------------------------------------------
# Find the backup
# -----------------------------------------------------------------------------

database_prefix=$(get_database_prefix)
file_ext=$(get_file_extension)
s3_uri_base=$(get_s3_uri_base)

# Construct expected filename
expected_filename="${database_prefix}_${TIMESTAMP}${file_ext}"
expected_uri="${s3_uri_base}/${expected_filename}"

# Check if backup exists
log_info "Looking for backup: ${expected_filename}"

# Use s3cmd ls to verify the file exists
found_key=$(s3cmd ls "$expected_uri" 2>/dev/null | awk '{ print $4 }')

if [ -z "$found_key" ]; then
  log_error "Backup not found: ${expected_filename}"
  log_error "Use 'list.sh' to see available backups."
  exit 1
fi

# Get file size for confirmation
file_info=$(s3cmd ls "$expected_uri" 2>/dev/null)
file_size=$(echo "$file_info" | awk '{ print $3 }')
file_size_human=$(format_size "$file_size")

# -----------------------------------------------------------------------------
# Delete the backup
# -----------------------------------------------------------------------------

echo ""
echo "Backup to delete:"
echo "  File:      ${expected_filename}"
echo "  Size:      ${file_size_human}"
echo "  S3 URI:    ${expected_uri}"
echo ""

if [ -n "$DRY_RUN" ]; then
  log_info "[DRY-RUN] Would delete: ${expected_uri}"
  log_info "[DRY-RUN] No changes made."
  exit 0
fi

log_info "Deleting backup..."

if s3cmd del "$expected_uri"; then
  log_info "Backup deleted successfully: ${expected_filename}"
else
  log_error "Failed to delete backup: ${expected_filename}"
  exit 1
fi
