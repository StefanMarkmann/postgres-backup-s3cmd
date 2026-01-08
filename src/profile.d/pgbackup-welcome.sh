case "$-" in
  *i*)
    alias backup='/backup.sh'
    alias restore='/restore.sh'
    alias list='/list.sh'
    alias cleanup='/cleanup.sh'
    alias delete='/delete.sh'
    alias run='/run.sh'
    cat <<'EOF'
Welcome to postgres-backup-s3cmd
Available commands:
  backup   Create a backup and upload to S3 (alias for /backup.sh)
  restore  Restore a backup from S3 (alias for /restore.sh)
  list     List backups in S3 (alias for /list.sh)
  cleanup  Remove old backups based on retention (alias for /cleanup.sh)
  delete   Delete a backup by name (alias for /delete.sh)
  run      Start scheduled backups (cron) (alias for /run.sh)

Absolute paths still work:
  /backup.sh   Create a backup and upload to S3
  /restore.sh  Restore a backup from S3
  /list.sh     List backups in S3
  /cleanup.sh  Remove old backups based on retention
  /delete.sh   Delete a backup by name
  /run.sh      Start scheduled backups (cron)
EOF
    ;;
esac
