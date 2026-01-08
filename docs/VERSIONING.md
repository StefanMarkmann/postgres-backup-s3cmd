# Versioning & Tag Policy

This document describes the versioning strategy and image tagging policy for postgres-backup-s3cmd.

## Tag Contract

This project uses **semantic versioning with PostgreSQL compatibility suffixes**. Tags are either:

- **Immutable release tags** — never change, safe for audit/compliance
- **Compatibility aliases** — move forward within defined boundaries, safe for auto-updates

| Tag Pattern | Example | Mutability | Use Case |
|-------------|---------|------------|----------|
| `vX.Y.Z-pgNN` | `v1.0.0-pg18` | Immutable | Audit, air-gapped, rollback |
| `vX.Y-pgNN` | `v1.0-pg18` | Mutable (patch) | Bugfixes only, conservative |
| `vX-pgNN` | `v1-pg18` | Mutable (minor) | Features + bugfixes |
| `NN` | `18` | Mutable | Always latest for PG major |

## How Compatibility Aliases Move

- `v1.0-pg18` only moves within `v1.0.x` — never to `v1.1+`
- `v1-pg18` moves within `v1.x.y` — never to `v2+`
- `18` always points to the latest stable release for PostgreSQL 18
- `17` always points to the latest stable release for PostgreSQL 17

Mutable aliases always point to a **new image digest**; images are never rebuilt in place.

## Current Images

| PG Version | Latest Release | Recommended Tag |
|------------|----------------|-----------------|
| PostgreSQL 18 | v1.0.0-pg18 | `18` or `v1-pg18` |
| PostgreSQL 17 | v1.0.0-pg17 | `17` or `v1-pg17` |
| PostgreSQL 16 | v1.0.0-pg16 | `16` or `v1-pg16` |
| PostgreSQL 15 | v1.0.0-pg15 | `15` or `v1-pg15` |

## Why No Alpine Version in Tags?

For backup tools, Alpine patch versions rarely matter to users. To reduce tag complexity:

- Alpine version is **not** included in tags
- Full version info is available via **OCI labels** (`docker inspect`)
- If you need Alpine pinning for compliance, use immutable release tags

## GitOps / Renovate Configuration

| Strategy | Recommended Tag | Renovate Config |
|----------|-----------------|-----------------|
| Auto-update (bugfixes) | `v1.0-pg18` | Track `vX.Y-pgNN` pattern |
| Auto-update (features) | `v1-pg18` | Track `vX-pgNN` pattern |
| Manual updates only | `v1.0.0-pg18` | Disabled or manual PRs |
| PG-version tracking | `18` | Track `NN` pattern |

### Renovate Examples

**Track bugfixes only (conservative):**

```json
{
  "packageRules": [
    {
      "matchPackageNames": ["stefanmarkmann/postgres-backup-s3cmd"],
      "versioning": "regex:^v(?<major>\\d+)\\.(?<minor>\\d+)-pg(?<compatibility>\\d+)$",
      "extractVersion": "^v(?<version>\\d+\\.\\d+)-pg\\d+$"
    }
  ]
}
```

**Track all updates within major version:**

```json
{
  "packageRules": [
    {
      "matchPackageNames": ["stefanmarkmann/postgres-backup-s3cmd"],
      "versioning": "regex:^v(?<major>\\d+)-pg(?<compatibility>\\d+)$"
    }
  ]
}
```

## No `latest` Tag

There is no `latest` tag. Backup tools should use explicit versions to ensure:

- Predictable behavior in GitOps workflows
- Clear upgrade intent
- Reproducible deployments

## Failure Behavior by Version

Understanding failure modes (v1.0):

| Operation | On Failure | Exit Code |
|-----------|------------|-----------|
| Backup creation | Container exits | Non-zero |
| S3 upload | Container exits | Non-zero |
| Retention cleanup | Backup still successful | Zero |
| Restore | Container exits | Non-zero |

No automatic retry logic in v1.0. Use orchestrator-level retries if needed.

## Startup Behavior

On startup, the container performs these checks before starting the scheduler or backup:

1. Validates required environment variables
2. Tests S3 connection
3. Reports existing backup count and latest backup timestamp

The container **exits with non-zero status** if:
- Required environment variables are missing
- S3 connection test fails

This ensures misconfigurations surface immediately in Kubernetes (CrashLoopBackOff) rather than waiting until the first backup fails.

### Example Startup Output

```
postgres-backup-s3cmd v1.0.0
[2026-01-07T20:00:00+00:00] Starting...

Configuration:
  S3_BUCKET:         my-backups
  S3_PREFIX:         postgres/prod
  S3_ENDPOINT:       https://minio.example.com
  POSTGRES_HOST:     postgres.example.com:5432
  POSTGRES_DATABASE: mydb (single DB mode)
  SCHEDULE:          0 2 * * *
  BACKUP_KEEP_DAYS:  7
  ENCRYPTION:        enabled
  COMPRESSION:       zstd (level=3, checksum=true)

Checking S3 connection...
  S3 connection: OK
  Existing backups: 7
  Latest:           2026-01-07T14:30:00
  Total size:       896.00 MB

[2026-01-07T20:00:00+00:00] Scheduler started.
```

## Backup Statistics Output

After each backup, statistics are logged:

```
[2026-01-07T14:30:15+00:00] Backup complete.

Summary:
  File:         mydb_2026-01-07T14:30:00.dump.zst.gpg
  Size:         128.00 MB
  Upload time:  12s
  Speed:        10.67 MB/s

backup.stats.file=mydb_2026-01-07T14:30:00.dump.zst.gpg
backup.stats.size_bytes=134217728
backup.stats.upload_seconds=12
backup.stats.upload_mbps=10.7
```

The `backup.stats.*` lines are machine-parseable for monitoring integration.

## Retention Policy

Backup retention is based on object timestamps as reported by `s3cmd ls`, not metadata files.

- Set `BACKUP_KEEP_DAYS` to automatically delete old backups
- Cleanup runs after each successful backup
- Cleanup failure does not affect backup success status
