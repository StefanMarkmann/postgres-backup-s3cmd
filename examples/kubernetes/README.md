# Kubernetes Examples

Reference manifests for deploying postgres-backup-s3cmd on Kubernetes.

> **Note:** These are reference manifests, not a supported operator. Adapt to your environment.

## Files

- `secret.yaml` - Template for storing credentials
- `cronjob.yaml` - CronJob for scheduled backups

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

### 2. Configure CronJob

Edit `cronjob.yaml`:
- Set `POSTGRES_HOST` to your PostgreSQL service
- Set `POSTGRES_DATABASE` (or remove for pg_dumpall)
- Set `S3_BUCKET` and `S3_ENDPOINT`
- Adjust schedule as needed

Then apply:

```bash
kubectl apply -f cronjob.yaml
```

### 3. Manual Backup

Trigger a backup manually:

```bash
kubectl create job --from=cronjob/postgres-backup postgres-backup-manual
```

### 4. Restore

For restore, run a one-off pod:

```bash
kubectl run postgres-restore --rm -it \
  --image=stefanmarkmann/postgres-backup-s3cmd:17 \
  --env-from=secret/postgres-backup-secret \
  --command -- sh /restore.sh
```

## Security Notes

- Store credentials in Kubernetes Secrets (or external secret managers)
- Consider using ServiceAccount with minimal permissions
- Review and restrict network policies as needed
