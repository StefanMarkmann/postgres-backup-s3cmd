# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

(No changes yet)

## [1.0.2] - 2026-01-08

### Changed

- Scheduled backups now use cron (cronie) instead of go-cron when `SCHEDULE` is set

## [1.0.0] - 2026-01-08

Initial public release.

### Added

- PostgreSQL backup using `pg_dump` (single database) or `pg_dumpall` (all databases)
- S3-compatible storage support via `s3cmd`
- GPG encryption support with `PASSPHRASE` environment variable
- zstd compression with embedded frame checksums (`ZSTD_CHECKSUM=true`) for integrity verification
- Scheduled backups using go-cron with `SCHEDULE` variable
- Automatic backup retention with `BACKUP_KEEP_DAYS`
- Custom S3 endpoint support for non-AWS providers
- Restore from latest or specific timestamp
- Multi-architecture support (amd64, arm64)
- PostgreSQL 18, 17, 16, 15 support
- Backup listing with `list.sh` (table, summary, latest modes)
- Manual cleanup with `cleanup.sh` (supports --dry-run)
- Specific backup deletion with `delete.sh`
- Fail-fast startup validation (S3 connection test)
- Machine-parseable backup statistics output

### Notes

This is a reimplementation inspired by [eeshugerman/postgres-backup-s3](https://github.com/eeshugerman/postgres-backup-s3) (archived).

**Key differences from upstream:**

- Uses `s3cmd` instead of AWS CLI for better S3-compatible storage support
- `S3_PATH` renamed to `S3_PREFIX` for consistency
- `S3_S3V4` option removed (s3cmd handles signature versions automatically)

[Unreleased]: https://github.com/StefanMarkmann/postgres-backup-s3cmd/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/StefanMarkmann/postgres-backup-s3cmd/compare/v1.0.0...v1.0.2
[1.0.0]: https://github.com/StefanMarkmann/postgres-backup-s3cmd/releases/tag/v1.0.0
