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
# - If SCHEDULE is set: run cron scheduler
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

  cron_env="/cron.env"
  cron_sh="/cron.sh"
  cron_tab="/etc/crontabs/root"

  umask 077
  : > "$cron_env"

  write_env_var() {
    var_name="$1"
    eval "var_value=\${${var_name}:-}"
    escaped_value=$(printf "%s" "$var_value" | sed "s/'/'\"'\"'/g")
    printf "export %s='%s'\n" "$var_name" "$escaped_value" >> "$cron_env"
  }

  write_env_var "POSTGRES_HOST"
  write_env_var "POSTGRES_PORT"
  write_env_var "POSTGRES_USER"
  write_env_var "POSTGRES_PASSWORD"
  write_env_var "POSTGRES_DATABASE"
  write_env_var "PGDUMP_EXTRA_OPTS"
  write_env_var "S3_ACCESS_KEY_ID"
  write_env_var "S3_SECRET_ACCESS_KEY"
  write_env_var "S3_BUCKET"
  write_env_var "S3_REGION"
  write_env_var "S3_PREFIX"
  write_env_var "S3_ENDPOINT"
  write_env_var "S3_BUCKET_STYLE"
  write_env_var "S3CFG_PATH"
  write_env_var "S3CFG_USE_EXISTING"
  write_env_var "PASSPHRASE"
  write_env_var "BACKUP_KEEP_DAYS"
  write_env_var "COMPRESSION"
  write_env_var "ZSTD_LEVEL"
  write_env_var "ZSTD_CHECKSUM"

  cat > "$cron_sh" << 'EOF'
#!/bin/sh
set -eu
. /cron.env
exec /bin/sh /backup.sh
EOF
  chmod 0700 "$cron_sh"

  cat > "$cron_tab" << EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${SCHEDULE} /bin/sh /cron.sh >> /proc/1/fd/1 2>> /proc/1/fd/2
EOF
  chmod 0600 "$cron_tab"

  exec crond -n -s
else
  log_info "Running single backup..."
  exec /bin/sh /backup.sh
fi
