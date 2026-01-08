#!/bin/bash
#
# CI Test Runner for postgres-backup-s3cmd
#
# This runner is designed for CI environments where PostgreSQL and MinIO
# services are already running (e.g., GitHub Actions services).
#
# Unlike run-tests.sh, this script does NOT start/stop infrastructure.
# It expects services to be accessible via environment variables.
#
# Usage:
#   ./tests/run-ci-tests.sh              # Run all tests
#   ./tests/run-ci-tests.sh --core-only  # Run core tests only
#   ./tests/run-ci-tests.sh --help       # Show help
#
# Required Environment Variables (with defaults for local testing):
#   TEST_PG_HOST         PostgreSQL host (default: localhost)
#   TEST_PG_PORT         PostgreSQL port (default: 5432)
#   TEST_PG_USER         PostgreSQL user (default: testuser)
#   TEST_PG_PASSWORD     PostgreSQL password (default: testpassword)
#   TEST_PG_DATABASE     PostgreSQL database (default: testdb)
#   TEST_S3_ENDPOINT     S3 endpoint URL (default: http://localhost:9000)
#   TEST_S3_ACCESS_KEY   S3 access key (default: minioadmin)
#   TEST_S3_SECRET_KEY   S3 secret key (default: minioadmin)
#   TEST_S3_BUCKET       S3 bucket name (default: test-backups)
#   BACKUP_IMAGE         Backup image to test (default: postgres-backup-s3cmd:test)

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source test libraries
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

# Source test cases
source "$SCRIPT_DIR/cases/core-tests.sh"
source "$SCRIPT_DIR/cases/contract-tests.sh"

# Default options
RUN_CORE=true
RUN_CONTRACT=true
VERBOSE=false

#######################################
# Parse Arguments
#######################################

while [[ $# -gt 0 ]]; do
    case $1 in
        --core-only)
            RUN_CORE=true
            RUN_CONTRACT=false
            shift
            ;;
        --contract-only)
            RUN_CORE=false
            RUN_CONTRACT=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            export DEBUG=true
            shift
            ;;
        --help|-h)
            echo "CI Test Runner for postgres-backup-s3cmd"
            echo ""
            echo "This runner expects PostgreSQL and MinIO services to already be running."
            echo "Configure via environment variables (see header for list)."
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --core-only       Run only core behavior tests (backup/restore)"
            echo "  --contract-only   Run only contract/failure tests"
            echo "  --verbose, -v     Show detailed output"
            echo "  --help, -h        Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  TEST_PG_HOST       PostgreSQL host (default: localhost)"
            echo "  TEST_PG_PORT       PostgreSQL port (default: 5432)"
            echo "  TEST_PG_USER       PostgreSQL user (default: testuser)"
            echo "  TEST_PG_PASSWORD   PostgreSQL password (default: testpassword)"
            echo "  TEST_PG_DATABASE   PostgreSQL database (default: testdb)"
            echo "  TEST_S3_ENDPOINT   S3 endpoint URL (default: http://localhost:9000)"
            echo "  TEST_S3_ACCESS_KEY S3 access key (default: minioadmin)"
            echo "  TEST_S3_SECRET_KEY S3 secret key (default: minioadmin)"
            echo "  TEST_S3_BUCKET     S3 bucket name (default: test-backups)"
            echo "  BACKUP_IMAGE       Backup image to test (default: postgres-backup-s3cmd:test)"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

#######################################
# Pre-flight Checks
#######################################

preflight_checks() {
    log_info "Running pre-flight checks..."
    
    # Check PostgreSQL connectivity
    log_info "Checking PostgreSQL connectivity at $TEST_PG_HOST:$TEST_PG_PORT..."
    if ! wait_for_postgres; then
        log_error "Cannot connect to PostgreSQL at $TEST_PG_HOST:$TEST_PG_PORT"
        log_error "Ensure PostgreSQL is running and accessible"
        exit 1
    fi
    log_info "PostgreSQL is accessible"
    
    # Check S3/MinIO connectivity
    log_info "Checking S3 connectivity at $TEST_S3_ENDPOINT..."
    if ! wait_for_minio; then
        log_error "Cannot connect to S3/MinIO at $TEST_S3_ENDPOINT"
        log_error "Ensure MinIO is running and accessible"
        exit 1
    fi
    log_info "S3/MinIO is accessible"
    
    # Check backup image exists
    log_info "Checking backup image: $BACKUP_IMAGE..."
    if ! docker image inspect "$BACKUP_IMAGE" > /dev/null 2>&1; then
        log_error "Backup image '$BACKUP_IMAGE' not found"
        log_error "Build the image first or set BACKUP_IMAGE environment variable"
        exit 1
    fi
    log_info "Backup image is available"
    
    log_info "Pre-flight checks passed!"
}

#######################################
# Main Execution
#######################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║       postgres-backup-s3cmd CI Test Suite                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Show configuration
    echo "Configuration:"
    echo "  PostgreSQL: $TEST_PG_HOST:$TEST_PG_PORT"
    echo "  S3 Endpoint: $TEST_S3_ENDPOINT"
    echo "  S3 Bucket: $TEST_S3_BUCKET"
    echo "  Backup Image: $BACKUP_IMAGE"
    echo ""
    
    # Run pre-flight checks
    preflight_checks
    
    # Run tests
    local failed=false
    
    if [[ "$RUN_CORE" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "CORE BEHAVIOR TESTS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        reset_database
        test_backup_restore_single || failed=true
        
        reset_database
        test_backup_restore_encrypted || failed=true
        
        reset_database
        test_backup_restore_all || failed=true
        
        reset_database
        test_restore_timestamp || failed=true
        
        reset_database
        test_retention_cleanup || failed=true
    fi
    
    if [[ "$RUN_CONTRACT" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "CONTRACT TESTS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        test_missing_env_vars || failed=true
        test_crontab_setup || failed=true
        test_db_unreachable || failed=true
        test_s3_unreachable || failed=true
        test_restore_no_backup || failed=true
        
        reset_database
        test_wrong_passphrase || failed=true
    fi
    
    # Print summary
    print_test_summary
    
    if [[ "$failed" == "true" ]]; then
        return 1
    fi
    return 0
}

main
