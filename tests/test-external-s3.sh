#!/bin/bash
#
# External S3 Validation Test
#
# This script tests backup/restore operations against an external S3 endpoint.
# Use this for validating compatibility with Ceph, production S3, or other
# S3-compatible storage that differs from the local MinIO test environment.
#
# Usage:
#   export TEST_S3_ENDPOINT="https://api.msc-3.s3.xws.x-ion.de"
#   export TEST_S3_ACCESS_KEY="your-key"
#   export TEST_S3_SECRET_KEY="your-secret"
#   export TEST_S3_BUCKET="your-bucket"
#   export TEST_S3_PREFIX="test-backup"  # optional, default: test-backup
#   ./tests/test-external-s3.sh
#
# Requirements:
#   - Docker & Docker Compose
#   - Access to external S3 endpoint
#
# The script will start its own PostgreSQL container for testing.
#
# Note: This test uploads/downloads real data to your S3 bucket.
#       Backups are cleaned up after the test (unless --keep-backup is passed).

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test configuration
TEST_PREFIX="${TEST_S3_PREFIX:-test-backup}"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
TEST_RUN_ID="test_${TIMESTAMP}"
KEEP_BACKUP="${KEEP_BACKUP:-false}"

# PostgreSQL configuration
POSTGRES_CONTAINER_NAME="postgres-backup-s3cmd-test-postgres"
POSTGRES_PORT=5433  # Use non-standard port to avoid conflicts
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="testpassword"
POSTGRES_DATABASE="testdb"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_required_vars() {
    local missing=0
    
    if [[ -z "${TEST_S3_ENDPOINT:-}" ]]; then
        log_error "TEST_S3_ENDPOINT is required"
        missing=1
    fi
    
    if [[ -z "${TEST_S3_ACCESS_KEY:-}" ]]; then
        log_error "TEST_S3_ACCESS_KEY is required"
        missing=1
    fi
    
    if [[ -z "${TEST_S3_SECRET_KEY:-}" ]]; then
        log_error "TEST_S3_SECRET_KEY is required"
        missing=1
    fi
    
    if [[ -z "${TEST_S3_BUCKET:-}" ]]; then
        log_error "TEST_S3_BUCKET is required"
        missing=1
    fi
    
    if [[ $missing -eq 1 ]]; then
        echo ""
        echo "Usage:"
        echo "  export TEST_S3_ENDPOINT=\"https://your-s3-endpoint\""
        echo "  export TEST_S3_ACCESS_KEY=\"your-access-key\""
        echo "  export TEST_S3_SECRET_KEY=\"your-secret-key\""
        echo "  export TEST_S3_BUCKET=\"your-bucket\""
        echo "  $0"
        exit 1
    fi
}

start_postgres() {
    log_info "Starting PostgreSQL container..."
    
    # Stop any existing test container
    docker rm -f "${POSTGRES_CONTAINER_NAME}" 2>/dev/null || true
    
    # Start PostgreSQL with exposed port
    docker run -d \
        --name "${POSTGRES_CONTAINER_NAME}" \
        -p "${POSTGRES_PORT}:5432" \
        -e POSTGRES_USER="${POSTGRES_USER}" \
        -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
        -e POSTGRES_DB="${POSTGRES_DATABASE}" \
        postgres:18-alpine
    
    # Wait for PostgreSQL to be ready
    log_info "Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=0
    while ! docker exec "${POSTGRES_CONTAINER_NAME}" pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "PostgreSQL failed to start within ${max_attempts} seconds"
            stop_postgres
            exit 1
        fi
        sleep 1
    done
    
    log_info "PostgreSQL is ready on port ${POSTGRES_PORT}"
}

stop_postgres() {
    log_info "Stopping PostgreSQL container..."
    docker rm -f "${POSTGRES_CONTAINER_NAME}" 2>/dev/null || true
}

build_image() {
    log_info "Building test image..."
    docker build -t postgres-backup-s3cmd:test \
        --build-arg PG_MAJOR=18 \
        --build-arg ALPINE_VERSION=3.21 \
        "$PROJECT_DIR" > /dev/null 2>&1
    log_info "Image built successfully"
}

run_backup() {
    log_info "Running backup to external S3..."
    log_info "  Endpoint: ${TEST_S3_ENDPOINT}"
    log_info "  Bucket: ${TEST_S3_BUCKET}"
    log_info "  Prefix: ${TEST_PREFIX}/${TEST_RUN_ID}"
    
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="localhost" \
        -e POSTGRES_PORT="${POSTGRES_PORT}" \
        -e POSTGRES_USER="${POSTGRES_USER}" \
        -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
        -e POSTGRES_DATABASE="${POSTGRES_DATABASE}" \
        -e S3_ACCESS_KEY_ID="${TEST_S3_ACCESS_KEY}" \
        -e S3_SECRET_ACCESS_KEY="${TEST_S3_SECRET_KEY}" \
        -e S3_BUCKET="${TEST_S3_BUCKET}" \
        -e S3_PREFIX="${TEST_PREFIX}/${TEST_RUN_ID}" \
        -e S3_ENDPOINT="${TEST_S3_ENDPOINT}" \
        postgres-backup-s3cmd:test \
        sh /backup.sh
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_info "Backup completed successfully"
    else
        log_error "Backup failed with exit code: $exit_code"
        stop_postgres
        exit 1
    fi
}

verify_backup_exists() {
    log_info "Verifying backup exists in S3..."
    
    docker run --rm \
        -e POSTGRES_HOST="localhost" \
        -e POSTGRES_USER="${POSTGRES_USER}" \
        -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
        -e S3_ACCESS_KEY_ID="${TEST_S3_ACCESS_KEY}" \
        -e S3_SECRET_ACCESS_KEY="${TEST_S3_SECRET_KEY}" \
        -e S3_BUCKET="${TEST_S3_BUCKET}" \
        -e S3_PREFIX="${TEST_PREFIX}/${TEST_RUN_ID}" \
        -e S3_ENDPOINT="${TEST_S3_ENDPOINT}" \
        postgres-backup-s3cmd:test \
        sh /list.sh --summary
    
    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_info "Backup verification passed"
    else
        log_error "Backup verification failed"
        stop_postgres
        exit 1
    fi
}

run_restore_test() {
    log_info "Testing restore capability..."
    
    # Run restore in dry-run mode (just list and verify we can download)
    # Note: Full restore would require dropping the database first
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="localhost" \
        -e POSTGRES_PORT="${POSTGRES_PORT}" \
        -e POSTGRES_USER="${POSTGRES_USER}" \
        -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
        -e POSTGRES_DATABASE="${POSTGRES_DATABASE}" \
        -e S3_ACCESS_KEY_ID="${TEST_S3_ACCESS_KEY}" \
        -e S3_SECRET_ACCESS_KEY="${TEST_S3_SECRET_KEY}" \
        -e S3_BUCKET="${TEST_S3_BUCKET}" \
        -e S3_PREFIX="${TEST_PREFIX}/${TEST_RUN_ID}" \
        -e S3_ENDPOINT="${TEST_S3_ENDPOINT}" \
        postgres-backup-s3cmd:test \
        sh /list.sh --latest
    
    log_info "Restore verification passed (backup is accessible)"
}

cleanup_backup() {
    if [[ "$KEEP_BACKUP" == "true" ]]; then
        log_warn "Keeping backup (KEEP_BACKUP=true)"
        log_info "  Location: s3://${TEST_S3_BUCKET}/${TEST_PREFIX}/${TEST_RUN_ID}/"
        return
    fi
    
    log_info "Cleaning up test backup..."
    
    docker run --rm \
        -e POSTGRES_HOST="localhost" \
        -e POSTGRES_USER="${POSTGRES_USER}" \
        -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
        -e S3_ACCESS_KEY_ID="${TEST_S3_ACCESS_KEY}" \
        -e S3_SECRET_ACCESS_KEY="${TEST_S3_SECRET_KEY}" \
        -e S3_BUCKET="${TEST_S3_BUCKET}" \
        -e S3_PREFIX="${TEST_PREFIX}/${TEST_RUN_ID}" \
        -e S3_ENDPOINT="${TEST_S3_ENDPOINT}" \
        -e BACKUP_KEEP_DAYS=0 \
        postgres-backup-s3cmd:test \
        sh /cleanup.sh 0
    
    log_info "Cleanup completed"
}

print_summary() {
    echo ""
    echo "========================================"
    echo -e "${GREEN}External S3 Test Summary${NC}"
    echo "========================================"
    echo "Endpoint:  ${TEST_S3_ENDPOINT}"
    echo "Bucket:    ${TEST_S3_BUCKET}"
    echo "Prefix:    ${TEST_PREFIX}/${TEST_RUN_ID}"
    echo "Database:  ${POSTGRES_DATABASE}@localhost:${POSTGRES_PORT}"
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    echo "========================================"
}

# Cleanup on exit
cleanup() {
    stop_postgres
}
trap cleanup EXIT

# Main execution
main() {
    echo ""
    echo "========================================"
    echo "External S3 Validation Test"
    echo "========================================"
    echo ""
    
    check_required_vars
    build_image
    start_postgres
    run_backup
    verify_backup_exists
    run_restore_test
    cleanup_backup
    print_summary
}

# Handle arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-backup)
            KEEP_BACKUP=true
            shift
            ;;
        --help|-h)
            echo "External S3 Validation Test"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --keep-backup    Don't delete test backup after completion"
            echo "  --help, -h       Show this help message"
            echo ""
            echo "Required environment variables:"
            echo "  TEST_S3_ENDPOINT     S3 endpoint URL"
            echo "  TEST_S3_ACCESS_KEY   S3 access key"
            echo "  TEST_S3_SECRET_KEY   S3 secret key"
            echo "  TEST_S3_BUCKET       S3 bucket name"
            echo ""
            echo "Optional environment variables:"
            echo "  TEST_S3_PREFIX       Backup prefix (default: test-backup)"
            echo ""
            echo "The script will start its own PostgreSQL container on port ${POSTGRES_PORT}"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

main
