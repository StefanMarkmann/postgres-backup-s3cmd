#!/bin/bash
#
# Core Behavior Tests for postgres-backup-s3cmd
#
# These tests verify the fundamental backup/restore functionality.
# They can be run standalone or sourced by a test runner.
#
# Dependencies:
#   - Source lib/test-helpers.sh and lib/assertions.sh before running
#   - PostgreSQL and MinIO/S3 must be accessible
#   - Backup image must be built

set -euo pipefail

#######################################
# Test: Single Database Backup + Restore
#######################################

test_backup_restore_single() {
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
    
    # Step 2: Verify backup is encrypted (.gpg extension)
    log_info "Step 2: Verifying backup is encrypted..."
    local backup_list
    backup_list=$(run_list "$prefix" "--latest" "$passphrase" 2>&1 || true)
    if ! assert_contains "$backup_list" ".dump.gpg" "Backup file has .gpg extension"; then
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
    
    # Step 2: Verify backup exists (file should be named all_*.dump)
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
    
    if ! echo "$backup_output" | grep -q "all_"; then
        test_fail "Backup file 'all_*.dump' not found in S3"
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
    
    # Test cleanup --dry-run
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
    
    # Test actual cleanup with 365 days retention (shouldn't delete recent backups)
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
