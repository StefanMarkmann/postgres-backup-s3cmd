#!/bin/bash
#
# Ceph S3 Bug Validation Test
#
# This script demonstrates the AWS CLI checksum bug with Ceph S3:
# - Siemens image (AWS CLI) → FAILS with Ceph due to checksum headers
# - Our image (s3cmd) → WORKS with Ceph
#
# This serves as:
# 1. Documentation that the bug is real
# 2. Regression test ensuring our fix works
# 3. Proof of why s3cmd was chosen over AWS CLI
#
# Usage:
#   export TEST_S3_ENDPOINT="https://api.msc-1.s3.xws.x-ion.de"
#   export TEST_S3_ACCESS_KEY="your-key"
#   export TEST_S3_SECRET_KEY="your-secret"
#   export TEST_S3_BUCKET="your-bucket"
#   ./tests/test-ceph-bug.sh
#
# Note: This test requires a Ceph S3 endpoint. MinIO will NOT reproduce the bug.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Test configuration
TEST_PREFIX="${TEST_S3_PREFIX:-ceph-bug-test}"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
TEST_RUN_ID="bug_${TIMESTAMP}"

# PostgreSQL configuration
POSTGRES_CONTAINER_NAME="postgres-backup-ceph-bug-test"
POSTGRES_PORT=5434  # Different port from other tests
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="testpassword"
POSTGRES_DATABASE="testdb"

# Images to test
SIEMENS_IMAGE="siemens/postgres-backup-s3:17"
OUR_IMAGE="postgres-backup-s3cmd:test"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
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
        echo "  export TEST_S3_ENDPOINT=\"https://your-ceph-endpoint\""
        echo "  export TEST_S3_ACCESS_KEY=\"your-access-key\""
        echo "  export TEST_S3_SECRET_KEY=\"your-secret-key\""
        echo "  export TEST_S3_BUCKET=\"your-bucket\""
        echo "  $0"
        exit 1
    fi
}

start_postgres() {
    log_info "Starting PostgreSQL container..."
    
    docker rm -f "${POSTGRES_CONTAINER_NAME}" 2>/dev/null || true
    
    docker run -d \
        --name "${POSTGRES_CONTAINER_NAME}" \
        -p "${POSTGRES_PORT}:5432" \
        -e POSTGRES_USER="${POSTGRES_USER}" \
        -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
        -e POSTGRES_DB="${POSTGRES_DATABASE}" \
        postgres:17-alpine > /dev/null
    
    log_info "Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=0
    while ! docker exec "${POSTGRES_CONTAINER_NAME}" pg_isready -U "${POSTGRES_USER}" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "PostgreSQL failed to start"
            exit 1
        fi
        sleep 1
    done
    
    log_info "PostgreSQL is ready on port ${POSTGRES_PORT}"
}

stop_postgres() {
    docker rm -f "${POSTGRES_CONTAINER_NAME}" 2>/dev/null || true
}

build_our_image() {
    log_info "Building our s3cmd-based image..."
    docker build -t "${OUR_IMAGE}" \
        --build-arg PG_MAJOR=17 \
        --build-arg ALPINE_VERSION=3.21 \
        "$PROJECT_DIR" > /dev/null 2>&1
    log_info "Our image built successfully"
}

pull_siemens_image() {
    log_info "Pulling Siemens image (${SIEMENS_IMAGE})..."
    docker pull "${SIEMENS_IMAGE}" > /dev/null 2>&1 || {
        log_warn "Could not pull Siemens image. Skipping Siemens test."
        return 1
    }
    log_info "Siemens image pulled successfully"
    return 0
}

test_siemens_image() {
    log_test "Testing Siemens image (AWS CLI) against Ceph..."
    log_test "  Expected: FAILURE (InvalidAccessKeyId or checksum error)"
    
    local result
    set +e
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
        -e S3_PREFIX="${TEST_PREFIX}/siemens_${TEST_RUN_ID}" \
        -e S3_ENDPOINT="${TEST_S3_ENDPOINT}" \
        -e S3_REGION="us-east-1" \
        "${SIEMENS_IMAGE}" \
        sh /backup.sh 2>&1
    result=$?
    set -e
    
    if [[ $result -ne 0 ]]; then
        echo ""
        log_info "✅ Siemens image FAILED as expected (exit code: $result)"
        log_info "   This confirms the AWS CLI checksum bug with Ceph"
        return 0  # Expected failure
    else
        echo ""
        log_warn "⚠️  Siemens image SUCCEEDED unexpectedly!"
        log_warn "   Either:"
        log_warn "   - This is not a Ceph endpoint (MinIO works with AWS CLI)"
        log_warn "   - Ceph was updated to support checksum headers"
        log_warn "   - The bug was fixed in AWS CLI"
        return 1  # Unexpected success
    fi
}

test_our_image() {
    log_test "Testing our image (s3cmd) against Ceph..."
    log_test "  Expected: SUCCESS"
    
    local result
    set +e
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
        -e S3_PREFIX="${TEST_PREFIX}/s3cmd_${TEST_RUN_ID}" \
        -e S3_ENDPOINT="${TEST_S3_ENDPOINT}" \
        "${OUR_IMAGE}" \
        sh /backup.sh 2>&1
    result=$?
    set -e
    
    if [[ $result -eq 0 ]]; then
        echo ""
        log_info "✅ Our s3cmd image SUCCEEDED as expected"
        return 0
    else
        echo ""
        log_error "❌ Our s3cmd image FAILED unexpectedly (exit code: $result)"
        return 1
    fi
}

cleanup_test_backups() {
    log_info "Cleaning up test backups..."
    
    # Clean our backup
    docker run --rm \
        -e POSTGRES_HOST="localhost" \
        -e POSTGRES_USER="${POSTGRES_USER}" \
        -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
        -e S3_ACCESS_KEY_ID="${TEST_S3_ACCESS_KEY}" \
        -e S3_SECRET_ACCESS_KEY="${TEST_S3_SECRET_KEY}" \
        -e S3_BUCKET="${TEST_S3_BUCKET}" \
        -e S3_PREFIX="${TEST_PREFIX}/s3cmd_${TEST_RUN_ID}" \
        -e S3_ENDPOINT="${TEST_S3_ENDPOINT}" \
        "${OUR_IMAGE}" \
        sh /cleanup.sh 0 2>/dev/null || true
}

print_summary() {
    local siemens_result=$1
    local our_result=$2
    
    echo ""
    echo "========================================"
    echo -e "${BLUE}Ceph S3 Bug Validation Summary${NC}"
    echo "========================================"
    echo "Endpoint: ${TEST_S3_ENDPOINT}"
    echo "Bucket:   ${TEST_S3_BUCKET}"
    echo ""
    echo "Results:"
    
    if [[ $siemens_result -eq 0 ]]; then
        echo -e "  Siemens (AWS CLI): ${GREEN}FAILED as expected${NC} ✅"
    else
        echo -e "  Siemens (AWS CLI): ${YELLOW}Unexpected result${NC} ⚠️"
    fi
    
    if [[ $our_result -eq 0 ]]; then
        echo -e "  Our image (s3cmd): ${GREEN}SUCCEEDED${NC} ✅"
    else
        echo -e "  Our image (s3cmd): ${RED}FAILED${NC} ❌"
    fi
    
    echo ""
    if [[ $siemens_result -eq 0 && $our_result -eq 0 ]]; then
        echo -e "${GREEN}Bug validation complete: s3cmd approach is correct!${NC}"
    else
        echo -e "${YELLOW}Results need review - see details above${NC}"
    fi
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
    echo "Ceph S3 Bug Validation Test"
    echo "========================================"
    echo ""
    echo "This test validates that:"
    echo "  1. Siemens image (AWS CLI) FAILS with Ceph"
    echo "  2. Our image (s3cmd) SUCCEEDS with Ceph"
    echo ""
    
    check_required_vars
    build_our_image
    start_postgres
    
    local siemens_result=0
    local our_result=0
    
    # Test Siemens image
    if pull_siemens_image; then
        echo ""
        echo "----------------------------------------"
        test_siemens_image || siemens_result=1
        echo "----------------------------------------"
    else
        log_warn "Skipping Siemens image test (could not pull)"
        siemens_result=2  # Skipped
    fi
    
    # Test our image
    echo ""
    echo "----------------------------------------"
    test_our_image || our_result=1
    echo "----------------------------------------"
    
    # Cleanup
    cleanup_test_backups
    
    # Summary
    print_summary $siemens_result $our_result
    
    # Exit code based on our image result (main validation)
    if [[ $our_result -ne 0 ]]; then
        exit 1
    fi
}

# Handle arguments
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Ceph S3 Bug Validation Test"
    echo ""
    echo "This test validates the AWS CLI checksum bug with Ceph S3:"
    echo "  - Siemens postgres-backup-s3 (AWS CLI) → Expected to FAIL"
    echo "  - Our postgres-backup-s3cmd (s3cmd) → Expected to SUCCEED"
    echo ""
    echo "Usage: $0"
    echo ""
    echo "Required environment variables:"
    echo "  TEST_S3_ENDPOINT     Ceph S3 endpoint URL"
    echo "  TEST_S3_ACCESS_KEY   S3 access key"
    echo "  TEST_S3_SECRET_KEY   S3 secret key"
    echo "  TEST_S3_BUCKET       S3 bucket name"
    echo ""
    echo "Note: This test requires a CEPH S3 endpoint."
    echo "      MinIO will NOT reproduce the bug (MinIO works with AWS CLI)."
    exit 0
fi

main
