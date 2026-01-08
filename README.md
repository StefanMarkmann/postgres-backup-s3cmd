# postgres-backup-s3cmd

Simple PostgreSQL dump backups to S3-compatible storage using s3cmd.

[![Docker Pulls](https://img.shields.io/docker/pulls/stefanmarkmann/postgres-backup-s3cmd)](https://hub.docker.com/r/stefanmarkmann/postgres-backup-s3cmd)
[![Build Status](https://github.com/StefanMarkmann/postgres-backup-s3cmd/actions/workflows/build-and-push.yml/badge.svg)](https://github.com/StefanMarkmann/postgres-backup-s3cmd/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

This project provides Docker images to periodically back up PostgreSQL databases to S3-compatible object storage, and restore from backups as needed.

**Why s3cmd?**

Unlike AWS CLI, `s3cmd` works reliably with S3-compatible storage providers that don't implement all AWS-specific features (like checksum response headers). This makes it ideal for:

- MinIO
- Ceph RGW
- Wasabi
- DigitalOcean Spaces
- Backblaze B2
- Any S3-compatible storage

**Compression + integrity**

Backups are compressed with `zstd` by default. `zstd` frame checksums are enabled so corruption is detected automatically during restore (decompression fails).

## Non-Goals

This tool is intentionally simple. It is **not**:

- ❌ A Point-in-Time Recovery (PITR) solution — no WAL archiving
- ❌ An incremental backup system — full dumps only
- ❌ A pgBackRest replacement — use pgBackRest for enterprise needs
- ❌ Multi-cluster aware — one database/cluster per container

If you need these features, consider [pgBackRest](https://pgbackrest.org/) or [Barman](https://pgbarman.org/).

## Quick Start

```yaml
services:
  postgres:
    image: postgres:18
    environment:
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
      POSTGRES_DB: mydb

  backup:
    image: stefanmarkmann/postgres-backup-s3cmd:18
    environment:
      SCHEDULE: '@daily'
      BACKUP_KEEP_DAYS: 7
      S3_ACCESS_KEY_ID: your-access-key
      S3_SECRET_ACCESS_KEY: your-secret-key
      S3_BUCKET: my-backup-bucket
      S3_ENDPOINT: https://s3.example.com  # Optional: for non-AWS S3
      POSTGRES_HOST: postgres
      POSTGRES_DATABASE: mydb
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
```

## Image Tags

Images are tagged by PostgreSQL major version with semantic versioning:

| PG Version | Recommended Tag | Immutable Tag |
|------------|-----------------|---------------|
| PostgreSQL 18 | `18` or `v1-pg18` | `v1.0.2-pg18` |
| PostgreSQL 17 | `17` or `v1-pg17` | `v1.0.2-pg17` |
| PostgreSQL 16 | `16` or `v1-pg16` | `v1.0.2-pg16` |
| PostgreSQL 15 | `15` or `v1-pg15` | `v1.0.2-pg15` |

> **Note:** There is no `latest` tag. Use explicit versions for predictable deployments.
>
> For detailed versioning policy and GitOps/Renovate configuration, see [docs/VERSIONING.md](docs/VERSIONING.md).

## Environment Variables

### Required

| Variable | Description |
|----------|-------------|
| `POSTGRES_HOST` | PostgreSQL server hostname |
| `POSTGRES_USER` | PostgreSQL username |
| `POSTGRES_PASSWORD` | PostgreSQL password |
| `S3_ACCESS_KEY_ID` | S3 access key |
| `S3_SECRET_ACCESS_KEY` | S3 secret key |
| `S3_BUCKET` | S3 bucket name |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_PORT` | `5432` | PostgreSQL port |
| `POSTGRES_DATABASE` | - | Database name (omit for pg_dumpall) |
| `PGDUMP_EXTRA_OPTS` | - | Additional pg_dump options |
| `S3_REGION` | `us-east-1` | S3 region (for AWS S3) |
| `S3_PREFIX` | `backup` | S3 key prefix (folder) |
| `S3_ENDPOINT` | - | Custom S3 endpoint URL |
| `S3_BUCKET_STYLE` | `virtual` | Bucket URL style for custom endpoints (`virtual` or `path`) |
| `S3CFG_PATH` | `/root/.s3cfg` | Path to s3cmd config file (generated unless `S3CFG_USE_EXISTING=true`) |
| `S3CFG_USE_EXISTING` | - | If set to `true`, use existing `S3CFG_PATH` and allow omitting `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` |
| `SCHEDULE` | - | Cron schedule (omit for single run) |
| `PASSPHRASE` | - | GPG encryption passphrase |
| `BACKUP_KEEP_DAYS` | - | Auto-delete backups older than N days |
| `COMPRESSION` | `zstd` | Compression algorithm (`zstd` or `none`) |
| `ZSTD_LEVEL` | `3` | zstd compression level (1–19) |
| `ZSTD_CHECKSUM` | `true` | Enable zstd frame checksums (detect corruption on restore) |

## Usage

### Scheduled Backups

Set `SCHEDULE` to enable periodic backups:

```yaml
environment:
  SCHEDULE: '@daily'       # Daily at midnight
  # SCHEDULE: '@hourly'    # Every hour
  # SCHEDULE: '0 2 * * *'  # Daily at 2 AM
```

Use standard cron syntax (including `@daily`, `@hourly`) for `SCHEDULE`.

### Manual Backup

```bash
docker exec <container> sh backup.sh
```

### List Backups

```bash
docker exec <container> sh list.sh            # Table format
docker exec <container> sh list.sh --summary  # Count, size, latest
docker exec <container> sh list.sh --latest   # Latest backup only
```

### Delete Specific Backup

```bash
docker exec <container> sh delete.sh 2026-01-05T14:30:00 --dry-run  # Preview
docker exec <container> sh delete.sh 2026-01-05T14:30:00            # Delete
```

### Manual Cleanup

```bash
docker exec <container> sh cleanup.sh           # Use BACKUP_KEEP_DAYS
docker exec <container> sh cleanup.sh 7         # Override to 7 days
docker exec <container> sh cleanup.sh --dry-run # Preview deletions
```

### Backup All Databases

Omit `POSTGRES_DATABASE` to use `pg_dumpall`:

```yaml
environment:
  POSTGRES_HOST: postgres
  POSTGRES_USER: postgres
  POSTGRES_PASSWORD: secret
  # POSTGRES_DATABASE not set - backs up all databases
```

### Encrypted Backups

Set `PASSPHRASE` to encrypt backups with GPG:

```yaml
environment:
  PASSPHRASE: my-secret-passphrase
```

## Restore

### Restore Latest Backup

```bash
docker exec <container> sh restore.sh
```

Running without arguments now lists available backups with sizes and prompts for a selection (press Enter for the latest). The script then requires two confirmations: typing `YES`, followed by either the timestamp or the filename shown in the list. In non-interactive environments, it automatically selects the latest backup and skips confirmations.

### Restore Specific Backup

```bash
docker exec <container> sh restore.sh 2026-01-07T14:30:00
```

Restoring a specific timestamp still prompts for the same two confirmations before download and restore. In non-interactive environments, it skips the confirmations.

> ⚠️ **Warning:** Restore is destructive. It will drop and recreate database objects.

| Mode | Behavior |
|------|----------|
| Single DB (`POSTGRES_DATABASE` set) | Target database must exist; roles not restored |
| All DBs (`pg_dumpall`) | Roles restored; use empty/disposable cluster |

If backups are compressed (`.zst`), restore automatically decompresses with `zstd -d`, which verifies the embedded checksum and fails fast on corruption.

## S3 Provider Examples

### MinIO

```yaml
environment:
  S3_ENDPOINT: http://minio:9000
  S3_ACCESS_KEY_ID: minioadmin
  S3_SECRET_ACCESS_KEY: minioadmin
  S3_BUCKET: backups
```

### Wasabi

```yaml
environment:
  S3_ENDPOINT: https://s3.wasabisys.com
  S3_REGION: us-east-1
  S3_ACCESS_KEY_ID: your-access-key
  S3_SECRET_ACCESS_KEY: your-secret-key
  S3_BUCKET: my-bucket
```

### AWS S3

```yaml
environment:
  S3_REGION: eu-central-1
  S3_ACCESS_KEY_ID: AKIA...
  S3_SECRET_ACCESS_KEY: ...
  S3_BUCKET: my-bucket
  # S3_ENDPOINT not needed for AWS
```

## Security Considerations

- Credentials are written to `/root/.s3cfg` inside the container
- Container assumes a trusted runtime environment

**Recommendations:**
- Use Docker secrets or Kubernetes secrets for credentials
- Prefer mounting a pre-created s3cmd config as a secret (`S3CFG_USE_EXISTING=true`, `S3CFG_PATH=/run/secrets/s3cfg`) to avoid generating credential files at runtime
- Run with read-only root filesystem where possible
- Limit container capabilities

## Kubernetes

See [examples/kubernetes/](examples/kubernetes/) for reference manifests.

## Development

### Build Locally

```bash
docker build \
  --build-arg ALPINE_VERSION=3.23 \
  --build-arg PG_MAJOR=18 \
  -t postgres-backup-s3cmd:18 .
```

### Test with Docker Compose

```bash
cp template.env .env
# Edit .env with your settings
docker compose up -d
```

## Migration from eeshugerman/postgres-backup-s3

This project is a reimplementation inspired by [eeshugerman/postgres-backup-s3](https://github.com/eeshugerman/postgres-backup-s3).

### Breaking Changes

| Change | Before | After |
|--------|--------|-------|
| S3 client | AWS CLI | s3cmd |
| Prefix variable | `S3_PATH` | `S3_PREFIX` |
| Signature option | `S3_S3V4` | Removed (automatic) |

### Compatible

- All PostgreSQL connection variables
- `SCHEDULE`, `PASSPHRASE`, `BACKUP_KEEP_DAYS`
- Backup file naming (`<db>_<timestamp>.dump[.zst][.gpg]`)
- Encrypted backups (GPG symmetric)

## Acknowledgements

This project is inspired by:
- [eeshugerman/postgres-backup-s3](https://github.com/eeshugerman/postgres-backup-s3) (archived)
- [schickling/postgres-backup-s3](https://github.com/schickling/dockerfiles/tree/master/postgres-backup-s3) (original)

## License

MIT License - see [LICENSE](LICENSE)
