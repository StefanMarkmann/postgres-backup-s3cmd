# Kubernetes Examples

Reference manifests for deploying postgres-backup-s3cmd on Kubernetes.

> **Note:** These are reference manifests, not a supported operator. Adapt to your environment.

## Files

- `secret.yaml` - Template for storing credentials
- `deployment.yaml` - Deployment with internal scheduler

## Usage

### 1. Create Secret

Edit `secret.yaml` with your credentials:

```bash
# Encode your credentials
echo -n 'your-password' | base64
```

Then apply:

```bash
kubectl apply -f secret.yaml
```

### 2. Configure Deployment

Edit `deployment.yaml`:
- Set `SCHEDULE` to your desired cron schedule (remove for a single run)
- Set `POSTGRES_HOST` to your PostgreSQL service
- Set `POSTGRES_DATABASE` (or remove for pg_dumpall)
- Set `S3_BUCKET` and `S3_ENDPOINT`

Then apply:

```bash
kubectl apply -f deployment.yaml
```

### 3. Restore

For restore, run a one-off pod:

```bash
kubectl run postgres-restore --rm -it \
  --image=stefanmarkmann/postgres-backup-s3cmd:17 \
  --env-from=secret/postgres-backup-secret \
  --command -- sh /restore.sh
```

### 4. Manual Backup/Restore via exec

You can also run one-off backups or restores in the running Deployment using `kubectl exec`:

```bash
POD_NAME=$(kubectl get pods -l app=postgres-backup -o jsonpath='{.items[0].metadata.name}')

# Run a backup immediately
kubectl exec "$POD_NAME" -- sh /backup.sh

# Restore the latest backup
kubectl exec "$POD_NAME" -- sh /restore.sh

# Restore a specific timestamp
kubectl exec "$POD_NAME" -- sh /restore.sh 2026-01-07T14:30:00
```

The test suite exercises these scripts directly (for example, `tests/run-tests.sh` calls
`sh /backup.sh` and `sh /restore.sh`) so the manual commands align with how backups and
restores are validated in CI.

## Security Notes

- Store credentials in Kubernetes Secrets (or external secret managers)
- Consider using ServiceAccount with minimal permissions
- Review and restrict network policies as needed
