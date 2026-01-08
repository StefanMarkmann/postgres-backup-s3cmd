case "$-" in
  *i*)
    cat <<'EOF'
Welcome to postgres-backup-s3cmd
Available commands:
  /backup.sh   Create a backup and upload to S3
  /restore.sh  Restore a backup from S3
  /list.sh     List backups in S3
  /cleanup.sh  Remove old backups based on retention
  /delete.sh   Delete a backup by name
  /run.sh      Start scheduled backups (cron)
EOF
    ;;
esac
