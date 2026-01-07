#!/bin/sh
# list.sh - List PostgreSQL backups in S3
#
# Usage:
#   list.sh               # List all backups (table format)
#   list.sh --summary     # Show summary (count, total size, latest)
#   list.sh --latest      # Show latest backup (machine-friendly)
#
# Exit codes:
#   0 - Success
#   1 - S3 connection failed or invalid arguments

set -eu

# Source environment and common functions
. /env.sh
. /common.sh

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

MODE="table"

if [ $# -ge 1 ]; then
  case "$1" in
    --summary)
      MODE="summary"
      ;;
    --latest)
      MODE="latest"
      ;;
    --help|-h)
      echo "Usage: list.sh [--summary|--latest]"
      echo ""
      echo "Options:"
      echo "  (none)      List all backups in table format"
      echo "  --summary   Show summary (count, total size, latest)"
      echo "  --latest    Show latest backup only (machine-friendly)"
      echo ""
      echo "Exit codes:"
      echo "  0 - Success"
      echo "  1 - Error (S3 connection failed, invalid arguments)"
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      echo "Usage: list.sh [--summary|--latest]" >&2
      exit 1
      ;;
  esac
fi

# -----------------------------------------------------------------------------
# Check S3 connectivity
# -----------------------------------------------------------------------------

if ! test_s3_connection; then
  log_error "S3 connection failed. Cannot list backups."
  exit 1
fi

# -----------------------------------------------------------------------------
# Output based on mode
# -----------------------------------------------------------------------------

case "$MODE" in
  table)
    # Table format: TIMESTAMP  FILENAME  SIZE
    backups=$(list_backups_raw)
    
    if [ -z "$backups" ]; then
      echo "No backups found."
      exit 0
    fi
    
    # Print header
    printf "%-24s  %-50s  %12s\n" "TIMESTAMP" "FILENAME" "SIZE"
    printf "%-24s  %-50s  %12s\n" "------------------------" "--------------------------------------------------" "------------"
    
    # Print each backup
    echo "$backups" | while IFS='|' read -r timestamp filename size; do
      size_human=$(format_size "$size")
      printf "%-24s  %-50s  %12s\n" "$timestamp" "$filename" "$size_human"
    done
    ;;
    
  summary)
    # Summary format: count, total size, latest
    backup_count=$(count_backups)
    
    if [ "$backup_count" -eq 0 ]; then
      echo "Backups found: 0"
      exit 0
    fi
    
    total_size=$(get_total_size)
    latest=$(get_latest_backup)
    latest_timestamp=$(echo "$latest" | cut -d'|' -f1)
    
    echo "Backups found: ${backup_count}"
    echo "Latest:        ${latest_timestamp}"
    echo "Total size:    $(format_size "$total_size")"
    ;;
    
  latest)
    # Machine-friendly format for scripting: timestamp|filename|size_bytes
    latest=$(get_latest_backup)
    
    if [ -z "$latest" ]; then
      # No backups found, exit successfully but with no output
      exit 0
    fi
    
    echo "$latest"
    ;;
esac
