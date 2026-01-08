#!/bin/sh
# env.sh - Validate environment and configure s3cmd
#
# This script is sourced by backup.sh and restore.sh.
# It validates required environment variables and generates .s3cfg.
#
# Design decisions:
# - Credentials are written to /root/.s3cfg (assumes trusted runtime)
# - S3 signature version is handled automatically by s3cmd

# -----------------------------------------------------------------------------
# Validate required environment variables
# -----------------------------------------------------------------------------

if [ -z "${S3_BUCKET:-}" ]; then
  echo "ERROR: S3_BUCKET environment variable is required."
  exit 1
fi

# Optional: allow using a pre-provisioned s3cmd config (e.g., Docker/K8s secret)
# If enabled, we won't require S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY here.
S3CFG_PATH="${S3CFG_PATH:-/root/.s3cfg}"
S3CFG_USE_EXISTING="${S3CFG_USE_EXISTING:-}"

if [ -z "${S3CFG_USE_EXISTING:-}" ]; then
  if [ -z "${S3_ACCESS_KEY_ID:-}" ]; then
    echo "ERROR: S3_ACCESS_KEY_ID environment variable is required (or set S3CFG_USE_EXISTING=true with S3CFG_PATH)."
    exit 1
  fi

  if [ -z "${S3_SECRET_ACCESS_KEY:-}" ]; then
    echo "ERROR: S3_SECRET_ACCESS_KEY environment variable is required (or set S3CFG_USE_EXISTING=true with S3CFG_PATH)."
    exit 1
  fi
else
  if [ ! -f "${S3CFG_PATH}" ]; then
    echo "ERROR: S3CFG_USE_EXISTING is set but S3CFG_PATH does not exist: ${S3CFG_PATH}"
    exit 1
  fi
fi

if [ -z "${POSTGRES_HOST:-}" ]; then
  echo "ERROR: POSTGRES_HOST environment variable is required."
  exit 1
fi

if [ -z "${POSTGRES_USER:-}" ]; then
  echo "ERROR: POSTGRES_USER environment variable is required."
  exit 1
fi

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
  echo "ERROR: POSTGRES_PASSWORD environment variable is required."
  exit 1
fi

# -----------------------------------------------------------------------------
# Set defaults for optional variables
# -----------------------------------------------------------------------------

POSTGRES_PORT="${POSTGRES_PORT:-5432}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_PREFIX="${S3_PREFIX:-backup}"
PGDUMP_EXTRA_OPTS="${PGDUMP_EXTRA_OPTS:-}"
COMPRESSION="${COMPRESSION:-zstd}"
ZSTD_LEVEL="${ZSTD_LEVEL:-3}"
ZSTD_CHECKSUM="${ZSTD_CHECKSUM:-true}"

case "$COMPRESSION" in
  ""|none)
    COMPRESSION=""
    ;;
  zstd)
    if ! command -v zstd >/dev/null 2>&1; then
      echo "ERROR: COMPRESSION=zstd but 'zstd' is not installed in the image."
      exit 1
    fi
    if ! echo "$ZSTD_LEVEL" | grep -qE '^[0-9]+$'; then
      echo "ERROR: ZSTD_LEVEL must be an integer."
      exit 1
    fi
    if [ "$ZSTD_LEVEL" -lt 1 ] || [ "$ZSTD_LEVEL" -gt 19 ]; then
      echo "ERROR: ZSTD_LEVEL must be between 1 and 19."
      exit 1
    fi
    case "$ZSTD_CHECKSUM" in
      true|false) ;;
      *)
        echo "ERROR: ZSTD_CHECKSUM must be 'true' or 'false'."
        exit 1
        ;;
    esac
    ;;
  *)
    echo "ERROR: Unsupported COMPRESSION value: ${COMPRESSION} (supported: zstd, none)"
    exit 1
    ;;
esac

# Note about POSTGRES_DATABASE:
# If not set, pg_dumpall will be used to backup all databases.
if [ -z "${POSTGRES_DATABASE:-}" ]; then
  echo "INFO: POSTGRES_DATABASE not set, will use pg_dumpall for all databases."
fi

# -----------------------------------------------------------------------------
# Configure s3cmd
# -----------------------------------------------------------------------------

# If user provided an s3cmd config file, use it as-is.
if [ -n "${S3CFG_USE_EXISTING:-}" ]; then
  export S3CFG_PATH
else
  # Determine S3 endpoint host and protocol
  if [ -n "${S3_ENDPOINT:-}" ]; then
    # Custom endpoint (MinIO, Ceph, Wasabi, etc.)
    S3_HOST=$(echo "$S3_ENDPOINT" | sed 's|https\?://||' | sed 's|/.*||')
    if echo "$S3_ENDPOINT" | grep -q '^https'; then
      S3_USE_HTTPS="True"
    else
      S3_USE_HTTPS="False"
    fi
    # For custom endpoints, use virtual-hosted style by default
    # Set S3_BUCKET_STYLE=path for path-style URLs (bucket in URL path)
    if [ "${S3_BUCKET_STYLE:-}" = "path" ]; then
      # Path-style: bucket in URL path, not DNS
      S3_HOST_BUCKET="${S3_HOST}"
    else
      # Virtual-hosted style: bucket.endpoint (default)
      S3_HOST_BUCKET="%(bucket)s.${S3_HOST}"
    fi
  else
    # AWS S3 - uses virtual-hosted style by default
    S3_HOST="s3.${S3_REGION}.amazonaws.com"
    S3_USE_HTTPS="True"
    S3_HOST_BUCKET="%(bucket)s.${S3_HOST}"
  fi
  
  # Generate s3cmd configuration file
  # Note: This writes credentials to disk. Container runtime must be trusted.
  umask 077
  cat > "${S3CFG_PATH}" << EOF
[default]
access_key = ${S3_ACCESS_KEY_ID}
secret_key = ${S3_SECRET_ACCESS_KEY}
host_base = ${S3_HOST}
host_bucket = ${S3_HOST_BUCKET}
use_https = ${S3_USE_HTTPS}
signature_v2 = False
EOF
  chmod 600 "${S3CFG_PATH}" 2>/dev/null || true
  export S3CFG_PATH
fi

# -----------------------------------------------------------------------------
# Export PostgreSQL password for pg_dump/pg_restore
# -----------------------------------------------------------------------------

export PGPASSWORD="${POSTGRES_PASSWORD}"
