#!/bin/bash
#
# Contract Tests for postgres-backup-s3cmd
#
# These tests verify proper failure handling and error messages.
# They can be run standalone or sourced by a test runner.
#
# Dependencies:
#   - Source lib/test-helpers.sh and lib/assertions.sh before running
#   - PostgreSQL and MinIO/S3 must be accessible
#   - Backup image must be built

set -euo pipefail

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
# Contract Test: Cron Setup
#######################################

test_crontab_setup() {
    test_start "Contract: Cron Setup"
    
    local failed=false
    local schedule="*/5 * * * *"
    local output
    
    set +e
    output=$(docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e POSTGRES_DATABASE="$TEST_PG_DATABASE" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        -e SCHEDULE="$schedule" \
        "$BACKUP_IMAGE" \
        sh -c '(/bin/sh /run.sh >/tmp/cron.log 2>&1) & pid=$!; \
          for i in $(seq 1 20); do \
            if [ -s /cron.sh ] && [ -s /cron.env ] && grep -q "/cron.sh" /etc/crontabs/root 2>/dev/null; then \
              break; \
            fi; \
            sleep 0.1; \
          done; \
          echo "__CRONTAB__"; cat /etc/crontabs/root; \
          echo "__CRONSH__"; cat /cron.sh 2>/dev/null || true; \
          echo "__CRONENV__"; cat /cron.env 2>/dev/null || true; \
          kill "$pid" >/dev/null 2>&1 || true')
    local exit_code=$?
    set -e
    
    if ! assert_exit_code "0" "$exit_code" "Container exits cleanly after cron inspection"; then
        failed=true
    fi
    
    if [[ "$exit_code" -eq 0 ]]; then
        local crontab
        local cron_sh
        local cron_env
        local schedule_regex
        
        crontab=$(printf "%s\n" "$output" | awk '/__CRONTAB__/ {show=1; next} /__CRONSH__/ {show=0} show')
        cron_sh=$(printf "%s\n" "$output" | awk '/__CRONSH__/ {show=1; next} /__CRONENV__/ {show=0} show')
        cron_env=$(printf "%s\n" "$output" | awk '/__CRONENV__/ {show=1; next} show')
        
        schedule_regex=$(printf "%s" "$schedule" | sed 's/[][\\.^$*+?(){}|]/\\\\&/g')
        
        if ! assert_matches "$crontab" "^SHELL=/bin/sh" "Crontab sets shell"; then
            failed=true
        fi
        
        if ! assert_contains "$crontab" "${schedule} /bin/sh /cron.sh" "Crontab includes schedule"; then
            failed=true
        fi
        
        if ! assert_matches "$cron_sh" "\\. /cron.env" "cron.sh sources env"; then
            failed=true
        fi
        
        if ! assert_matches "$cron_sh" "exec /bin/sh /backup.sh" "cron.sh runs backup"; then
            failed=true
        fi
        
        if ! assert_matches "$cron_env" "export POSTGRES_HOST='${TEST_PG_HOST}'" "cron.env exports POSTGRES_HOST"; then
            failed=true
        fi
        
        if ! assert_matches "$cron_env" "export S3_BUCKET='${TEST_S3_BUCKET}'" "cron.env exports S3_BUCKET"; then
            failed=true
        fi
    fi
    
    if [[ "$failed" == "true" ]]; then
        test_fail "Crontab setup validation failed"
        return 1
    fi
    
    test_pass "Crontab setup looks correct"
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
