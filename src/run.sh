#!/bin/sh
# run.sh - Container entrypoint
#
# Startup sequence:
# 1. Banner / version
# 2. Configuration validation (via env.sh)
# 3. Configuration summary
# 4. S3 connectivity check (fail-fast)
# 5. Backup state introspection
# 6. Scheduler start OR single backup
#
# Behavior:
# - If SCHEDULE is set: run go-cron scheduler
# - If SCHEDULE is not set: run single backup and exit
#
# Exit codes:
# - 0: Success
# - 1: Configuration error or S3 connection failed

set -eu

# -----------------------------------------------------------------------------
# Phase 1: Source environment (validation happens here)
# -----------------------------------------------------------------------------

. /env.sh
. /common.sh

# -----------------------------------------------------------------------------
# Phase 2: Banner
# -----------------------------------------------------------------------------

print_banner

# -----------------------------------------------------------------------------
# Phase 3: Configuration summary
# -----------------------------------------------------------------------------

print_config

# -----------------------------------------------------------------------------
# Phase 4: S3 connectivity check (fail-fast)
# -----------------------------------------------------------------------------

if ! print_s3_status; then
  log_error "Startup aborted: S3 connection required for backup operations."
  exit 1
fi

# -----------------------------------------------------------------------------
# Phase 5: Start scheduler or run single backup
# -----------------------------------------------------------------------------

if [ -n "${SCHEDULE:-}" ]; then
  log_info "Scheduler started. Backups will run on schedule: ${SCHEDULE}"
  exec go-cron "${SCHEDULE}" -- /bin/sh /backup.sh
else
  log_info "Running single backup..."
  exec /bin/sh /backup.sh
fi
