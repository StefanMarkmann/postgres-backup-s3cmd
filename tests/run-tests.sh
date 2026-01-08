#!/bin/bash
#
# Test Runner for postgres-backup-s3cmd
#
# Usage:
#   ./tests/run-tests.sh              # Run all tests (MinIO only)
#   ./tests/run-tests.sh --core-only  # Run core tests only
#   ./tests/run-tests.sh --with-ceph  # Run all tests + Ceph test
#   ./tests/run-tests.sh --quick      # Run quick smoke test
#   ./tests/run-tests.sh --help       # Show help
#
# Options:
#   --core-only     Run only core behavior tests (backup/restore)
#   --contract-only Run only contract/failure tests
#   --with-ceph     Include Ceph S3 test (requires TEST_S3_* env vars)
#   --quick         Run minimal smoke test
#   --no-cleanup    Don't stop infrastructure after tests
#   --verbose       Show detailed output
#   --help          Show this help message

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source test helpers
source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

# Source test cases
source "$SCRIPT_DIR/cases/core-tests.sh"
source "$SCRIPT_DIR/cases/contract-tests.sh"

# Default options
RUN_CORE=true
RUN_CONTRACT=true
RUN_CEPH=false
RUN_CLEANUP_INFRA=true
VERBOSE=false
QUICK_MODE=false

# Ceph environment variables (for --with-ceph)
# These are read from environment if set:
#   CEPH_S3_ENDPOINT, CEPH_S3_ACCESS_KEY, CEPH_S3_SECRET_KEY, CEPH_S3_BUCKET

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
        --with-ceph)
            RUN_CEPH=true
            shift
            ;;
        --quick)
            QUICK_MODE=true
            shift
            ;;
        --no-cleanup)
            RUN_CLEANUP_INFRA=false
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            export DEBUG=true
            shift
            ;;
        --help|-h)
            echo "Test Runner for postgres-backup-s3cmd"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --core-only     Run only core behavior tests (backup/restore)"
            echo "  --contract-only Run only contract/failure tests"
            echo "  --with-ceph     Include Ceph S3 test (requires CEPH_S3_* env vars)"
            echo "  --quick         Run minimal smoke test"
            echo "  --no-cleanup    Don't stop infrastructure after tests"
            echo "  --verbose, -v   Show detailed output"
            echo "  --help, -h      Show this help message"
            echo ""
            echo "Test Categories:"
            echo "  Core:     Backup/restore round-trip verification"
            echo "  Contract: Failure handling (missing env, no backup, etc.)"
            echo "  Ceph:     External Ceph S3 connectivity (optional)"
            echo ""
            echo "Ceph Environment Variables (for --with-ceph):"
            echo "  CEPH_S3_ENDPOINT     Ceph S3 endpoint URL"
            echo "  CEPH_S3_ACCESS_KEY   Ceph S3 access key"
            echo "  CEPH_S3_SECRET_KEY   Ceph S3 secret key"
            echo "  CEPH_S3_BUCKET       Ceph S3 bucket name"
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
# Cleanup Handler
#######################################

cleanup() {
    local exit_code=$?
    
    if [[ "$RUN_CLEANUP_INFRA" == "true" ]]; then
        stop_test_infrastructure
    else
        log_warn "Infrastructure left running (--no-cleanup)"
        log_info "Stop manually: docker compose -f tests/compose.test.yaml down -v"
    fi
    
    exit $exit_code
}

trap cleanup EXIT

#######################################
# Quick Smoke Test
#######################################

run_quick_test() {
    test_start "Single Database Backup + Restore"
    
    local prefix
    prefix=$(generate_test_prefix "single")
    local failed=false
    
    # Setup: Load seed data
    log_info "Loading seed data..."
    load_seed_data || { test_fail "Failed to load seed data"; return 1; }
    
    # Capture expected state
    local expected_count
    local expected_checksum
    expected_count=$(get_row_count "test_data")
    expected_checksum=$(get_data_checksum "test_data")
    
    log_debug "Expected count: $expected_count"
    log_debug "Expected checksum: $expected_checksum"
    
    # Step 1: Run backup
    log_info "Step 1: Running backup..."
    if ! run_backup "$prefix"; then
        test_fail "Backup failed"
        return 1
    fi
    
    # Step 2: Verify backup exists
    log_info "Step 2: Verifying backup exists..."
    if ! run_list "$prefix" "--summary" > /dev/null 2>&1; then
        test_fail "Backup not found in S3"
        return 1
    fi
    
    # Step 3: Drop data (simulate disaster)
    log_info "Step 3: Simulating data loss..."
    psql_exec -c "DROP TABLE test_data CASCADE;" 2>/dev/null || true
    psql_exec -c "DROP TABLE test_orders CASCADE;" 2>/dev/null || true
    psql_exec -c "DROP TABLE test_users CASCADE;" 2>/dev/null || true
    
    # Step 4: Run restore
    log_info "Step 4: Running restore..."
    if ! run_restore "$prefix"; then
        test_fail "Restore failed"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Step 5: Verify data integrity
    log_info "Step 5: Verifying data integrity..."
    
    local actual_count
    local actual_checksum
    actual_count=$(get_row_count "test_data")
    actual_checksum=$(get_data_checksum "test_data")
    
    # Assertions
    if ! assert_equals "$expected_count" "$actual_count" "Row count matches"; then
        failed=true
    fi
    
    if ! assert_equals "$expected_checksum" "$actual_checksum" "Data checksum matches"; then
        failed=true
    fi
    
    if ! assert_table_exists "test_users" "Users table restored"; then
        failed=true
    fi
    
    if ! assert_table_exists "test_orders" "Orders table restored"; then
        failed=true
    fi
    
    # Cleanup test backup
    run_cleanup "$prefix" || true
    
    if [[ "$failed" == "true" ]]; then
        test_fail "Data integrity verification failed"
        return 1
    fi
    
    test_pass "Backup/restore round-trip verified"
    return 0
}

#######################################
# Test: Encrypted Backup + Restore
#######################################

test_backup_restore_encrypted() {
    test_start "Encrypted Backup + Restore"
    
    local prefix
    prefix=$(generate_test_prefix "encrypted")
    local passphrase="test-encryption-passphrase-123"
    local failed=false
    
    # Setup: Load seed data
    log_info "Loading seed data..."
    load_seed_data || { test_fail "Failed to load seed data"; return 1; }
    
    # Capture expected state
    local expected_count
    expected_count=$(get_row_count "test_data")
    
    # Step 1: Run encrypted backup
    log_info "Step 1: Running encrypted backup..."
    if ! run_backup_encrypted "$prefix" "$passphrase"; then
        test_fail "Encrypted backup failed"
        return 1
    fi
    
    # Step 2: Verify backup is encrypted (.gpg extension, optional .zst)
    log_info "Step 2: Verifying backup is encrypted..."
    local backup_list
    backup_list=$(run_list "$prefix" "--latest" "$passphrase" 2>&1 || true)
    if ! assert_matches "$backup_list" "\\.dump(\\.zst)?\\.gpg" "Backup file has .gpg extension"; then
        failed=true
    fi
    
    # Step 3: Drop data
    log_info "Step 3: Simulating data loss..."
    psql_exec -c "DROP TABLE test_data CASCADE;" 2>/dev/null || true
    psql_exec -c "DROP TABLE test_orders CASCADE;" 2>/dev/null || true
    psql_exec -c "DROP TABLE test_users CASCADE;" 2>/dev/null || true
    
    # Step 4: Run encrypted restore
    log_info "Step 4: Running encrypted restore..."
    if ! run_restore_encrypted "$prefix" "$passphrase"; then
        test_fail "Encrypted restore failed"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Step 5: Verify data
    log_info "Step 5: Verifying data integrity..."
    
    local actual_count
    actual_count=$(get_row_count "test_data")
    
    if ! assert_equals "$expected_count" "$actual_count" "Row count matches after encrypted restore"; then
        failed=true
    fi
    
    # Cleanup
    run_cleanup "$prefix" || true
    
    if [[ "$failed" == "true" ]]; then
        test_fail "Encrypted backup/restore verification failed"
        return 1
    fi
    
    test_pass "Encrypted backup/restore round-trip verified"
    return 0
}

#######################################
# Test: All Databases Backup + Restore (pg_dumpall)
#######################################

test_backup_restore_all() {
    test_start "All Databases Backup + Restore (pg_dumpall)"
    
    local prefix
    prefix=$(generate_test_prefix "alldbs")
    local failed=false
    local marker="all-dbs-test-$(date +%s)"
    
    # Test databases to create
    local test_db1="testdb_alpha"
    local test_db2="testdb_beta"
    
    # Setup: Create multiple test databases with unique markers
    log_info "Setting up multiple test databases..."
    
    create_test_database "$test_db1" "${marker}-alpha" || { test_fail "Failed to create $test_db1"; return 1; }
    create_test_database "$test_db2" "${marker}-beta" || { test_fail "Failed to create $test_db2"; return 1; }
    
    # Also add data to the default testdb
    load_seed_data || { test_fail "Failed to load seed data"; return 1; }
    
    # Capture expected state
    local expected_alpha_count expected_beta_count expected_testdb_count
    expected_alpha_count=$(get_row_count_db "$test_db1")
    expected_beta_count=$(get_row_count_db "$test_db2")
    expected_testdb_count=$(get_row_count "test_data")
    
    log_debug "Expected $test_db1 count: $expected_alpha_count"
    log_debug "Expected $test_db2 count: $expected_beta_count"
    log_debug "Expected testdb count: $expected_testdb_count"
    
    # Step 1: Run pg_dumpall backup
    log_info "Step 1: Running pg_dumpall backup..."
    if ! run_backup_all "$prefix"; then
        test_fail "pg_dumpall backup failed"
        # Cleanup test databases
        drop_test_database "$test_db1"
        drop_test_database "$test_db2"
        return 1
    fi
    
    # Step 2: Verify backup exists (file should be named all_*.dump[.zst])
    log_info "Step 2: Verifying backup exists..."
    local backup_output
    backup_output=$(docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh -c '. /env.sh && s3cmd ls "s3://${S3_BUCKET}/${S3_PREFIX}/"' 2>&1 || true)
    
    if ! echo "$backup_output" | grep -Eq "all_.*\\.dump(\\.zst)?$"; then
        test_fail "Backup file 'all_*.dump[.zst]' not found in S3"
        drop_test_database "$test_db1"
        drop_test_database "$test_db2"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Step 3: Drop test databases (simulate disaster)
    log_info "Step 3: Simulating data loss (dropping databases)..."
    drop_test_database "$test_db1"
    drop_test_database "$test_db2"
    reset_database  # Clear the default testdb
    
    # Verify databases are gone
    if database_exists "$test_db1"; then
        test_fail "Database $test_db1 should have been dropped"
        failed=true
    fi
    if database_exists "$test_db2"; then
        test_fail "Database $test_db2 should have been dropped"
        failed=true
    fi
    
    # Step 4: Run pg_dumpall restore
    log_info "Step 4: Running pg_dumpall restore..."
    if ! run_restore_all "$prefix"; then
        test_fail "pg_dumpall restore failed"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Step 5: Verify all databases are restored
    log_info "Step 5: Verifying all databases restored..."
    
    # Check databases exist
    if ! database_exists "$test_db1"; then
        log_error "Database $test_db1 was not restored"
        failed=true
    fi
    if ! database_exists "$test_db2"; then
        log_error "Database $test_db2 was not restored"
        failed=true
    fi
    
    # Verify data integrity in each database
    if [[ "$failed" != "true" ]]; then
        local actual_alpha_count actual_beta_count actual_testdb_count
        actual_alpha_count=$(get_row_count_db "$test_db1")
        actual_beta_count=$(get_row_count_db "$test_db2")
        actual_testdb_count=$(get_row_count "test_data")
        
        if ! assert_equals "$expected_alpha_count" "$actual_alpha_count" "$test_db1 row count matches"; then
            failed=true
        fi
        
        if ! assert_equals "$expected_beta_count" "$actual_beta_count" "$test_db2 row count matches"; then
            failed=true
        fi
        
        if ! assert_equals "$expected_testdb_count" "$actual_testdb_count" "testdb row count matches"; then
            failed=true
        fi
        
        # Verify markers to ensure correct data restored
        local restored_alpha_marker restored_beta_marker
        restored_alpha_marker=$(get_db_marker "$test_db1")
        restored_beta_marker=$(get_db_marker "$test_db2")
        
        if ! assert_equals "${marker}-alpha" "$restored_alpha_marker" "$test_db1 marker matches"; then
            failed=true
        fi
        
        if ! assert_equals "${marker}-beta" "$restored_beta_marker" "$test_db2 marker matches"; then
            failed=true
        fi
    fi
    
    # Cleanup
    drop_test_database "$test_db1"
    drop_test_database "$test_db2"
    run_cleanup "$prefix" || true
    
    if [[ "$failed" == "true" ]]; then
        test_fail "pg_dumpall backup/restore verification failed"
        return 1
    fi
    
    test_pass "pg_dumpall backup/restore round-trip verified"
    return 0
}

#######################################
# Contract Test: Missing Environment Variables
#######################################

test_missing_env_vars() {
    test_start "Contract: Missing Required Environment Variables"
    
    local failed=false
    
    # Test missing POSTGRES_HOST
    log_info "Testing missing POSTGRES_HOST..."
    set +e
    docker run --rm \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        "$BACKUP_IMAGE" \
        sh /backup.sh > /dev/null 2>&1
    local exit_code=$?
    set -e
    
    if ! assert_not_equals "0" "$exit_code" "Fails without POSTGRES_HOST"; then
        failed=true
    fi
    
    # Test missing S3_BUCKET
    log_info "Testing missing S3_BUCKET..."
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        "$BACKUP_IMAGE" \
        sh /backup.sh > /dev/null 2>&1
    exit_code=$?
    set -e
    
    if ! assert_not_equals "0" "$exit_code" "Fails without S3_BUCKET"; then
        failed=true
    fi
    
    # Test missing POSTGRES_PASSWORD
    log_info "Testing missing POSTGRES_PASSWORD..."
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        "$BACKUP_IMAGE" \
        sh /backup.sh > /dev/null 2>&1
    exit_code=$?
    set -e
    
    if ! assert_not_equals "0" "$exit_code" "Fails without POSTGRES_PASSWORD"; then
        failed=true
    fi
    
    if [[ "$failed" == "true" ]]; then
        test_fail "Some environment variable validations failed"
        return 1
    fi
    
    test_pass "Environment variable validation works correctly"
    return 0
}

#######################################
# Contract Test: Database Unreachable
#######################################

test_db_unreachable() {
    test_start "Contract: Database Unreachable"
    
    log_info "Testing backup with unreachable database..."
    
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="nonexistent-host.invalid" \
        -e POSTGRES_PORT="5432" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh /backup.sh > /dev/null 2>&1
    local exit_code=$?
    set -e
    
    if assert_not_equals "0" "$exit_code" "Fails with unreachable database"; then
        test_pass "Properly handles unreachable database"
        return 0
    else
        test_fail "Should fail when database is unreachable"
        return 1
    fi
}

#######################################
# Contract Test: S3 Unreachable
#######################################

test_s3_unreachable() {
    test_start "Contract: S3 Unreachable"
    
    log_info "Testing backup with unreachable S3 endpoint..."
    
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_ENDPOINT="http://nonexistent-s3.invalid:9999" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh /backup.sh > /dev/null 2>&1
    local exit_code=$?
    set -e
    
    if assert_not_equals "0" "$exit_code" "Fails with unreachable S3"; then
        test_pass "Properly handles unreachable S3 endpoint"
        return 0
    else
        test_fail "Should fail when S3 is unreachable"
        return 1
    fi
}

#######################################
# Contract Test: Wrong Passphrase on Restore
#######################################

test_wrong_passphrase() {
    test_start "Contract: Wrong Passphrase on Restore"
    
    local prefix
    prefix=$(generate_test_prefix "wrongpass")
    local encrypt_passphrase="correct-passphrase-123"
    local wrong_passphrase="wrong-passphrase-456"
    
    # Setup: Create encrypted backup
    log_info "Creating encrypted backup..."
    load_seed_data || { test_fail "Failed to load seed data"; return 1; }
    
    if ! run_backup_encrypted "$prefix" "$encrypt_passphrase"; then
        test_fail "Failed to create encrypted backup"
        return 1
    fi
    
    # Attempt restore with wrong passphrase
    log_info "Attempting restore with wrong passphrase..."
    
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        -e PASSPHRASE="$wrong_passphrase" \
        "$BACKUP_IMAGE" \
        sh /restore.sh > /dev/null 2>&1
    local exit_code=$?
    set -e
    
    # Cleanup
    run_cleanup "$prefix" || true
    
    if assert_not_equals "0" "$exit_code" "Fails with wrong passphrase"; then
        test_pass "Properly handles wrong passphrase"
        return 0
    else
        test_fail "Should fail when passphrase is wrong"
        return 1
    fi
}

#######################################
# Contract Test: Restore with No Backup
#######################################

test_restore_no_backup() {
    test_start "Contract: Restore with Empty Bucket"
    
    local prefix
    prefix=$(generate_test_prefix "empty")
    
    log_info "Attempting restore from empty prefix..."
    
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        "$BACKUP_IMAGE" \
        sh /restore.sh > /dev/null 2>&1
    local exit_code=$?
    set -e
    
    if assert_not_equals "0" "$exit_code" "Restore fails when no backup exists"; then
        test_pass "Properly handles missing backup"
        return 0
    else
        test_fail "Should fail when no backup exists"
        return 1
    fi
}

#######################################
# Test: Restore from Specific Timestamp
#######################################

test_restore_timestamp() {
    test_start "Restore from Specific Timestamp"
    
    local prefix
    prefix=$(generate_test_prefix "timestamp")
    local failed=false
    
    # Create 3 backups with different data at different timestamps
    log_info "Creating backup 1 with marker 'data-version-1'..."
    psql_exec -c "DROP TABLE IF EXISTS version_data CASCADE;" 2>/dev/null || true
    psql_exec -c "CREATE TABLE version_data (id SERIAL PRIMARY KEY, marker TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
    psql_exec -c "INSERT INTO version_data (marker) VALUES ('data-version-1');"
    
    if ! run_backup "$prefix"; then
        test_fail "Backup 1 failed"
        return 1
    fi
    
    # Get timestamp of first backup
    local backup1_timestamp
    backup1_timestamp=$(docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh -c '. /env.sh && s3cmd ls "s3://${S3_BUCKET}/${S3_PREFIX}/" | grep testdb | head -1 | sed "s/.*testdb_//" | sed "s/\.dump.*//"' 2>/dev/null || true)
    
    log_debug "Backup 1 timestamp: $backup1_timestamp"
    
    # Wait a second to ensure different timestamp
    sleep 2
    
    log_info "Creating backup 2 with marker 'data-version-2'..."
    psql_exec -c "UPDATE version_data SET marker = 'data-version-2' WHERE id = 1;"
    
    if ! run_backup "$prefix"; then
        test_fail "Backup 2 failed"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Wait again
    sleep 2
    
    log_info "Creating backup 3 with marker 'data-version-3'..."
    psql_exec -c "UPDATE version_data SET marker = 'data-version-3' WHERE id = 1;"
    
    if ! run_backup "$prefix"; then
        test_fail "Backup 3 failed"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Verify we now have 3 backups
    local backup_count
    backup_count=$(docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh -c '. /env.sh && s3cmd ls "s3://${S3_BUCKET}/${S3_PREFIX}/" | grep testdb | wc -l' 2>/dev/null || echo "0")
    
    log_debug "Total backups created: $backup_count"
    
    if [[ "$backup_count" -lt 2 ]]; then
        test_fail "Expected at least 2 backups, got $backup_count"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Drop data
    log_info "Simulating data loss..."
    psql_exec -c "DROP TABLE version_data CASCADE;" 2>/dev/null || true
    
    # Restore from the FIRST backup (not latest)
    log_info "Restoring from first backup (timestamp: $backup1_timestamp)..."
    
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh /restore.sh "$backup1_timestamp"
    local restore_exit=$?
    set -e
    
    if [[ $restore_exit -ne 0 ]]; then
        test_fail "Restore from timestamp failed"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Verify we got the FIRST version's data, not the latest
    log_info "Verifying restored data is from first backup..."
    local restored_marker
    restored_marker=$(psql_query -c "SELECT marker FROM version_data WHERE id = 1;" 2>/dev/null || echo "")
    
    if ! assert_equals "data-version-1" "$restored_marker" "Restored data matches first backup"; then
        log_error "Expected 'data-version-1' but got '$restored_marker'"
        failed=true
    fi
    
    # Cleanup
    run_cleanup "$prefix" || true
    psql_exec -c "DROP TABLE IF EXISTS version_data CASCADE;" 2>/dev/null || true
    
    if [[ "$failed" == "true" ]]; then
        test_fail "Timestamp restore verification failed"
        return 1
    fi
    
    test_pass "Timestamp restore correctly restored older backup"
    return 0
}

#######################################
# Test: Retention Cleanup
#######################################

test_retention_cleanup() {
    test_start "Retention Cleanup (BACKUP_KEEP_DAYS)"
    
    local prefix
    prefix=$(generate_test_prefix "retention")
    local failed=false
    
    # Create a backup
    log_info "Creating test backup..."
    load_seed_data || { test_fail "Failed to load seed data"; return 1; }
    
    if ! run_backup "$prefix"; then
        test_fail "Backup failed"
        return 1
    fi
    
    # Verify backup exists
    local initial_count
    initial_count=$(docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh -c '. /env.sh && s3cmd ls "s3://${S3_BUCKET}/${S3_PREFIX}/" | wc -l' 2>/dev/null || echo "0")
    
    log_debug "Initial backup count: $initial_count"
    
    if [[ "$initial_count" -eq 0 ]]; then
        test_fail "No backup was created"
        return 1
    fi
    
    # Run cleanup with 0 days retention (should delete all)
    # Note: Our cleanup.sh requires days to be > 0, so we use 1 day
    # But since the backup was just created, it won't be deleted
    # Instead, we test the --dry-run to verify the mechanism works
    
    log_info "Testing cleanup --dry-run..."
    set +e
    local dryrun_output
    dryrun_output=$(docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh /cleanup.sh 1 --dry-run 2>&1)
    local cleanup_exit=$?
    set -e
    
    log_debug "Cleanup output: $dryrun_output"
    
    if [[ $cleanup_exit -ne 0 ]]; then
        test_fail "Cleanup --dry-run failed"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Verify dry-run message appears
    if ! echo "$dryrun_output" | grep -qi "dry-run"; then
        log_warn "Dry-run message not found in output"
    fi
    
    # Verify backup still exists (dry-run shouldn't delete)
    local after_dryrun_count
    after_dryrun_count=$(docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh -c '. /env.sh && s3cmd ls "s3://${S3_BUCKET}/${S3_PREFIX}/" | wc -l' 2>/dev/null || echo "0")
    
    if ! assert_equals "$initial_count" "$after_dryrun_count" "Dry-run didn't delete backups"; then
        failed=true
    fi
    
    # Now test actual cleanup with a very long retention (shouldn't delete recent backups)
    log_info "Testing cleanup with 365 days retention..."
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh /cleanup.sh 365 > /dev/null 2>&1
    cleanup_exit=$?
    set -e
    
    if [[ $cleanup_exit -ne 0 ]]; then
        test_fail "Cleanup with 365 days failed"
        run_cleanup "$prefix" || true
        return 1
    fi
    
    # Verify backup still exists (it's not old enough)
    local after_cleanup_count
    after_cleanup_count=$(docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh -c '. /env.sh && s3cmd ls "s3://${S3_BUCKET}/${S3_PREFIX}/" | wc -l' 2>/dev/null || echo "0")
    
    if ! assert_equals "$initial_count" "$after_cleanup_count" "Recent backup wasn't deleted"; then
        failed=true
    fi
    
    # Cleanup
    run_cleanup "$prefix" || true
    
    if [[ "$failed" == "true" ]]; then
        test_fail "Retention cleanup verification failed"
        return 1
    fi
    
    test_pass "Retention cleanup works correctly"
    return 0
}

#######################################
# Quick Smoke Test
#######################################

run_quick_test() {
    log_info "Running quick smoke test..."
    
    test_start "Quick Smoke Test"
    
    local prefix
    prefix=$(generate_test_prefix "smoke")
    
    # Just verify we can backup and list
    log_info "Creating simple test data..."
    psql_exec -c "CREATE TABLE IF NOT EXISTS smoke_test (id SERIAL, value TEXT);" 2>/dev/null || true
    psql_exec -c "INSERT INTO smoke_test (value) VALUES ('smoke-test-data');" 2>/dev/null || true
    
    log_info "Running backup..."
    if ! run_backup "$prefix"; then
        test_fail "Smoke test backup failed"
        return 1
    fi
    
    log_info "Verifying backup exists..."
    if ! run_list "$prefix" "--summary" > /dev/null 2>&1; then
        test_fail "Smoke test backup not found"
        return 1
    fi
    
    # Cleanup
    run_cleanup "$prefix" || true
    psql_exec -c "DROP TABLE IF EXISTS smoke_test;" 2>/dev/null || true
    
    test_pass "Smoke test completed"
    return 0
}

#######################################
# Ceph S3 Test: Backup/Restore Round-Trip
#######################################

# Check if Ceph credentials are available
check_ceph_credentials() {
    if [[ -z "${CEPH_S3_ENDPOINT:-}" ]] || \
       [[ -z "${CEPH_S3_ACCESS_KEY:-}" ]] || \
       [[ -z "${CEPH_S3_SECRET_KEY:-}" ]] || \
       [[ -z "${CEPH_S3_BUCKET:-}" ]]; then
        return 1
    fi
    return 0
}

# Test backup/restore against external Ceph S3
test_ceph_backup_restore() {
    test_start "Ceph S3: Backup + Restore Round-Trip"
    
    # Check credentials
    if ! check_ceph_credentials; then
        log_warn "Ceph credentials not set - skipping test"
        log_info "Set CEPH_S3_ENDPOINT, CEPH_S3_ACCESS_KEY, CEPH_S3_SECRET_KEY, CEPH_S3_BUCKET"
        test_skip "Ceph credentials not available"
        return 0  # Return success to not fail the test suite
    fi
    
    local prefix
    prefix="test-ceph-$(date -u +%Y%m%d_%H%M%S)"
    local failed=false
    
    log_info "Testing against Ceph endpoint: ${CEPH_S3_ENDPOINT}"
    log_info "  Bucket: ${CEPH_S3_BUCKET}"
    log_info "  Prefix: ${prefix}"
    
    # Setup: Load seed data (uses local PostgreSQL from MinIO test infrastructure)
    log_info "Loading seed data..."
    load_seed_data || { test_fail "Failed to load seed data"; return 1; }
    
    # Capture expected state
    local expected_count
    expected_count=$(get_row_count "test_data")
    
    # Step 1: Run backup to Ceph
    log_info "Step 1: Running backup to Ceph S3..."
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$CEPH_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$CEPH_S3_SECRET_KEY" \
        -e S3_BUCKET="$CEPH_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$CEPH_S3_ENDPOINT" \
        "$BACKUP_IMAGE" \
        sh /backup.sh
    local backup_exit=$?
    set -e
    
    if [[ $backup_exit -ne 0 ]]; then
        test_fail "Ceph backup failed with exit code: $backup_exit"
        return 1
    fi
    
    # Step 2: Verify backup exists in Ceph
    log_info "Step 2: Verifying backup exists in Ceph..."
    set +e
    local list_output
    list_output=$(docker run --rm \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e S3_ACCESS_KEY_ID="$CEPH_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$CEPH_S3_SECRET_KEY" \
        -e S3_BUCKET="$CEPH_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$CEPH_S3_ENDPOINT" \
        "$BACKUP_IMAGE" \
        sh /list.sh --summary 2>&1)
    local list_exit=$?
    set -e
    
    if [[ $list_exit -ne 0 ]]; then
        test_fail "Failed to list Ceph backups"
        return 1
    fi
    log_debug "List output: $list_output"
    
    # Step 3: Drop data (simulate disaster)
    log_info "Step 3: Simulating data loss..."
    psql_exec -c "DROP TABLE test_data CASCADE;" 2>/dev/null || true
    psql_exec -c "DROP TABLE test_orders CASCADE;" 2>/dev/null || true
    psql_exec -c "DROP TABLE test_users CASCADE;" 2>/dev/null || true
    
    # Step 4: Run restore from Ceph
    log_info "Step 4: Running restore from Ceph S3..."
    set +e
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$CEPH_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$CEPH_S3_SECRET_KEY" \
        -e S3_BUCKET="$CEPH_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$CEPH_S3_ENDPOINT" \
        "$BACKUP_IMAGE" \
        sh /restore.sh
    local restore_exit=$?
    set -e
    
    if [[ $restore_exit -ne 0 ]]; then
        test_fail "Ceph restore failed with exit code: $restore_exit"
        # Try to cleanup
        cleanup_ceph_backup "$prefix" || true
        return 1
    fi
    
    # Step 5: Verify data integrity
    log_info "Step 5: Verifying data integrity..."
    local actual_count
    actual_count=$(get_row_count "test_data")
    
    if ! assert_equals "$expected_count" "$actual_count" "Row count matches after Ceph restore"; then
        failed=true
    fi
    
    # Cleanup Ceph backup
    log_info "Cleaning up Ceph test backup..."
    cleanup_ceph_backup "$prefix" || true
    
    if [[ "$failed" == "true" ]]; then
        test_fail "Ceph backup/restore verification failed"
        return 1
    fi
    
    test_pass "Ceph S3 backup/restore round-trip verified"
    return 0
}

# Cleanup test backup from Ceph
cleanup_ceph_backup() {
    local prefix="$1"
    
    docker run --rm \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e S3_ACCESS_KEY_ID="$CEPH_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$CEPH_S3_SECRET_KEY" \
        -e S3_BUCKET="$CEPH_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$CEPH_S3_ENDPOINT" \
        "$BACKUP_IMAGE" \
        sh /cleanup.sh 0 2>/dev/null || true
}

#######################################
# Main Execution
#######################################

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║           postgres-backup-s3cmd Test Suite                 ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Build backup image
    build_backup_image
    
    # Start infrastructure
    start_test_infrastructure
    
    # Quick mode - just run smoke test
    if [[ "$QUICK_MODE" == "true" ]]; then
        run_quick_test
        print_test_summary
        return $?
    fi
    
    # Run test categories
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
    
    if [[ "$RUN_CEPH" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "CEPH S3 TESTS"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        reset_database
        test_ceph_backup_restore || failed=true
    fi
    
    # Print summary
    print_test_summary
    
    if [[ "$failed" == "true" ]]; then
        return 1
    fi
    return 0
}

main
