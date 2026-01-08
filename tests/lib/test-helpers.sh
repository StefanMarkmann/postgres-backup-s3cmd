#!/bin/bash
#
# Test Helpers for postgres-backup-s3cmd
#
# Common functions used across all test scripts.
# Source this file in your test scripts:
#   source "$(dirname "$0")/lib/test-helpers.sh"

set -euo pipefail

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export NC='\033[0m' # No Color

# Test infrastructure settings (can be overridden by environment)
export TEST_COMPOSE_FILE="${TEST_COMPOSE_FILE:-compose.test.yaml}"
export TEST_PROJECT_NAME="${TEST_PROJECT_NAME:-postgres-backup-test}"
export TEST_NETWORK="${TEST_NETWORK:-${TEST_PROJECT_NAME}_backup-test}"

# PostgreSQL settings (defaults match compose.test.yaml, can be overridden for CI)
export TEST_PG_HOST="${TEST_PG_HOST:-localhost}"
export TEST_PG_PORT="${TEST_PG_PORT:-5433}"
export TEST_PG_USER="${TEST_PG_USER:-testuser}"
export TEST_PG_PASSWORD="${TEST_PG_PASSWORD:-testpassword}"
export TEST_PG_DATABASE="${TEST_PG_DATABASE:-testdb}"

# MinIO/S3 settings (defaults match compose.test.yaml, can be overridden for CI)
export TEST_S3_ENDPOINT="${TEST_S3_ENDPOINT:-http://localhost:9002}"
export TEST_S3_ACCESS_KEY="${TEST_S3_ACCESS_KEY:-minioadmin}"
export TEST_S3_SECRET_KEY="${TEST_S3_SECRET_KEY:-minioadmin}"
export TEST_S3_BUCKET="${TEST_S3_BUCKET:-test-backups}"
export TEST_S3_BUCKET_STYLE="${TEST_S3_BUCKET_STYLE:-path}"  # MinIO requires path-style URLs

# Backup image (can be overridden for CI with pre-built image)
export BACKUP_IMAGE="${BACKUP_IMAGE:-postgres-backup-s3cmd:test}"

# Local test container names (only used for local docker-compose runs)
export TEST_POSTGRES_CONTAINER="${TEST_POSTGRES_CONTAINER:-backup-test-postgres}"

# Test state
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0
TEST_SKIPPED=0
CURRENT_TEST_NAME=""

# Determine script locations
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"

#######################################
# Logging Functions
#######################################

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

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

#######################################
# Test Infrastructure
#######################################

# Start test infrastructure (PostgreSQL + MinIO)
start_test_infrastructure() {
    log_info "Starting test infrastructure..."
    
    cd "$TESTS_DIR"
    docker compose -f "$TEST_COMPOSE_FILE" up -d postgres minio
    
    # Wait for services to be healthy
    log_info "Waiting for PostgreSQL to be ready..."
    wait_for_postgres
    
    log_info "Waiting for MinIO to be ready..."
    wait_for_minio
    
    # Initialize MinIO bucket
    docker compose -f "$TEST_COMPOSE_FILE" up minio-init
    
    log_info "Test infrastructure is ready"
}

# Stop test infrastructure
stop_test_infrastructure() {
    log_info "Stopping test infrastructure..."
    cd "$TESTS_DIR"
    docker compose -f "$TEST_COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}

# Wait for PostgreSQL to be ready
wait_for_postgres() {
    local max_attempts=30
    local attempt=0

    if command -v pg_isready >/dev/null 2>&1; then
        while ! pg_isready -h "$TEST_PG_HOST" -p "$TEST_PG_PORT" -U "$TEST_PG_USER" > /dev/null 2>&1; do
            attempt=$((attempt + 1))
            if [[ $attempt -ge $max_attempts ]]; then
                log_error "PostgreSQL failed to start within ${max_attempts} seconds"
                return 1
            fi
            sleep 1
        done
        return 0
    fi

    # Fallback for local runs without a host PostgreSQL client installed.
    # Uses the dockerized postgres container started by tests/compose.test.yaml.
    while ! docker exec "$TEST_POSTGRES_CONTAINER" pg_isready -U "$TEST_PG_USER" -d "$TEST_PG_DATABASE" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "PostgreSQL failed to start within ${max_attempts} seconds"
            return 1
        fi
        sleep 1
    done
}

# Wait for MinIO to be ready
wait_for_minio() {
    local max_attempts=30
    local attempt=0
    
    while ! curl -sf "$TEST_S3_ENDPOINT/minio/health/live" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [[ $attempt -ge $max_attempts ]]; then
            log_error "MinIO failed to start within ${max_attempts} seconds"
            return 1
        fi
        sleep 1
    done
}

# Check if test infrastructure is running
is_infrastructure_running() {
    docker ps --format '{{.Names}}' | grep -q "backup-test-postgres" && \
    docker ps --format '{{.Names}}' | grep -q "backup-test-minio"
}

#######################################
# Build Functions
#######################################

# Build the backup image for testing
build_backup_image() {
    local pg_version="${1:-17}"
    
    log_info "Building backup image (PG ${pg_version})..."
    
    docker build -t "$BACKUP_IMAGE" \
        --build-arg PG_MAJOR="$pg_version" \
        --build-arg ALPINE_VERSION=3.21 \
        "$PROJECT_DIR" > /dev/null 2>&1
    
    log_info "Backup image built successfully"
}

#######################################
# Database Functions
#######################################

# Execute SQL against test database
psql_exec() {
    if command -v psql >/dev/null 2>&1; then
        PGPASSWORD="$TEST_PG_PASSWORD" psql \
            -h "$TEST_PG_HOST" \
            -p "$TEST_PG_PORT" \
            -U "$TEST_PG_USER" \
            -d "$TEST_PG_DATABASE" \
            "$@"
    else
        docker exec -i -e PGPASSWORD="$TEST_PG_PASSWORD" "$TEST_POSTGRES_CONTAINER" \
            psql -U "$TEST_PG_USER" -d "$TEST_PG_DATABASE" "$@"
    fi
}

# Execute SQL and return result (no formatting)
psql_query() {
    if command -v psql >/dev/null 2>&1; then
        PGPASSWORD="$TEST_PG_PASSWORD" psql \
            -h "$TEST_PG_HOST" \
            -p "$TEST_PG_PORT" \
            -U "$TEST_PG_USER" \
            -d "$TEST_PG_DATABASE" \
            -t -A \
            "$@"
    else
        docker exec -i -e PGPASSWORD="$TEST_PG_PASSWORD" "$TEST_POSTGRES_CONTAINER" \
            psql -U "$TEST_PG_USER" -d "$TEST_PG_DATABASE" -t -A "$@"
    fi
}

# Load seed data into database
load_seed_data() {
    local seed_file="${1:-$TESTS_DIR/fixtures/seed.sql}"
    
    if [[ ! -f "$seed_file" ]]; then
        log_error "Seed file not found: $seed_file"
        return 1
    fi
    
    log_info "Loading seed data from $seed_file..."
    if command -v psql >/dev/null 2>&1; then
        psql_exec -f "$seed_file"
    else
        docker exec -i -e PGPASSWORD="$TEST_PG_PASSWORD" "$TEST_POSTGRES_CONTAINER" \
            psql -U "$TEST_PG_USER" -d "$TEST_PG_DATABASE" < "$seed_file"
    fi
}

# Reset database to clean state
reset_database() {
    log_info "Resetting database to clean state..."
    
    # Drop all user tables in testdb
    psql_exec -c "
        DO \$\$ 
        DECLARE r RECORD;
        BEGIN
            FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
                EXECUTE 'DROP TABLE IF EXISTS public.' || quote_ident(r.tablename) || ' CASCADE';
            END LOOP;
        END \$\$;
    " 2>/dev/null || true
}

# Get data checksum for verification
get_data_checksum() {
    local table="${1:-test_data}"
    psql_query -c "SELECT md5(string_agg(checksum, '' ORDER BY id)) FROM $table;" 2>/dev/null || echo ""
}

# Get row count
get_row_count() {
    local table="${1:-test_data}"
    psql_query -c "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo "0"
}

# Execute SQL against a specific database (for multi-db tests)
psql_exec_db() {
    local database="$1"
    shift
    if command -v psql >/dev/null 2>&1; then
        PGPASSWORD="$TEST_PG_PASSWORD" psql \
            -h "$TEST_PG_HOST" \
            -p "$TEST_PG_PORT" \
            -U "$TEST_PG_USER" \
            -d "$database" \
            "$@"
    else
        docker exec -i -e PGPASSWORD="$TEST_PG_PASSWORD" "$TEST_POSTGRES_CONTAINER" \
            psql -U "$TEST_PG_USER" -d "$database" "$@"
    fi
}

# Execute SQL against postgres database (for CREATE/DROP DATABASE)
psql_admin() {
    if command -v psql >/dev/null 2>&1; then
        PGPASSWORD="$TEST_PG_PASSWORD" psql \
            -h "$TEST_PG_HOST" \
            -p "$TEST_PG_PORT" \
            -U "$TEST_PG_USER" \
            -d "postgres" \
            "$@"
    else
        docker exec -i -e PGPASSWORD="$TEST_PG_PASSWORD" "$TEST_POSTGRES_CONTAINER" \
            psql -U "$TEST_PG_USER" -d "postgres" "$@"
    fi
}

# Create a test database with sample data
create_test_database() {
    local dbname="$1"
    local marker="${2:-default}"
    
    log_info "Creating test database: $dbname"
    
    # Create database (ignore if exists)
    psql_admin -c "CREATE DATABASE $dbname;" 2>/dev/null || true
    
    # Create and populate test table
    psql_exec_db "$dbname" -c "
        DROP TABLE IF EXISTS db_test_data;
        CREATE TABLE db_test_data (
            id SERIAL PRIMARY KEY,
            db_name TEXT NOT NULL,
            marker TEXT NOT NULL,
            value TEXT NOT NULL
        );
        INSERT INTO db_test_data (db_name, marker, value) VALUES
            ('$dbname', '$marker', 'test-value-1'),
            ('$dbname', '$marker', 'test-value-2'),
            ('$dbname', '$marker', 'test-value-3');
    "
}

# Drop a test database
drop_test_database() {
    local dbname="$1"
    
    log_info "Dropping test database: $dbname"
    
    # Terminate connections first
    psql_admin -c "
        SELECT pg_terminate_backend(pid) 
        FROM pg_stat_activity 
        WHERE datname = '$dbname' AND pid <> pg_backend_pid();
    " 2>/dev/null || true
    
    psql_admin -c "DROP DATABASE IF EXISTS $dbname;" 2>/dev/null || true
}

# Check if a database exists
database_exists() {
    local dbname="$1"
    local exists
    if command -v psql >/dev/null 2>&1; then
        exists=$(PGPASSWORD="$TEST_PG_PASSWORD" psql \
            -h "$TEST_PG_HOST" \
            -p "$TEST_PG_PORT" \
            -U "$TEST_PG_USER" \
            -d "postgres" \
            -t -A \
            -c "SELECT 1 FROM pg_database WHERE datname = '$dbname';" 2>/dev/null || echo "")
    else
        exists=$(docker exec -i -e PGPASSWORD="$TEST_PG_PASSWORD" "$TEST_POSTGRES_CONTAINER" \
            psql -U "$TEST_PG_USER" -d "postgres" -t -A \
            -c "SELECT 1 FROM pg_database WHERE datname = '$dbname';" 2>/dev/null || echo "")
    fi
    [[ "$exists" == "1" ]]
}

# Get row count from a specific database
get_row_count_db() {
    local database="$1"
    local table="${2:-db_test_data}"
    if command -v psql >/dev/null 2>&1; then
        PGPASSWORD="$TEST_PG_PASSWORD" psql \
            -h "$TEST_PG_HOST" \
            -p "$TEST_PG_PORT" \
            -U "$TEST_PG_USER" \
            -d "$database" \
            -t -A \
            -c "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo "0"
    else
        docker exec -i -e PGPASSWORD="$TEST_PG_PASSWORD" "$TEST_POSTGRES_CONTAINER" \
            psql -U "$TEST_PG_USER" -d "$database" -t -A \
            -c "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo "0"
    fi
}

# Get marker value from test database (for verification)
get_db_marker() {
    local database="$1"
    if command -v psql >/dev/null 2>&1; then
        PGPASSWORD="$TEST_PG_PASSWORD" psql \
            -h "$TEST_PG_HOST" \
            -p "$TEST_PG_PORT" \
            -U "$TEST_PG_USER" \
            -d "$database" \
            -t -A \
            -c "SELECT DISTINCT marker FROM db_test_data LIMIT 1;" 2>/dev/null || echo ""
    else
        docker exec -i -e PGPASSWORD="$TEST_PG_PASSWORD" "$TEST_POSTGRES_CONTAINER" \
            psql -U "$TEST_PG_USER" -d "$database" -t -A \
            -c "SELECT DISTINCT marker FROM db_test_data LIMIT 1;" 2>/dev/null || echo ""
    fi
}

#######################################
# Backup Functions
#######################################

# Run backup with default test settings
run_backup() {
    local prefix="${1:-test-backup}"
    local extra_args="${2:-}"
    
    log_info "Running backup (prefix: $prefix)..."
    
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
        $extra_args \
        "$BACKUP_IMAGE" \
        sh /backup.sh
}

# Run backup with encryption
run_backup_encrypted() {
    local prefix="${1:-test-backup}"
    local passphrase="${2:-testpassphrase123}"
    
    log_info "Running encrypted backup (prefix: $prefix)..."
    
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
        -e PASSPHRASE="$passphrase" \
        "$BACKUP_IMAGE" \
        sh /backup.sh
}

# Run restore
run_restore() {
    local prefix="${1:-test-backup}"
    local extra_args="${2:-}"
    
    log_info "Running restore (prefix: $prefix)..."
    
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
        $extra_args \
        "$BACKUP_IMAGE" \
        sh /restore.sh
}

# Run restore with encryption
run_restore_encrypted() {
    local prefix="${1:-test-backup}"
    local passphrase="${2:-testpassphrase123}"
    
    log_info "Running encrypted restore (prefix: $prefix)..."
    
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
        -e PASSPHRASE="$passphrase" \
        "$BACKUP_IMAGE" \
        sh /restore.sh
}

# List backups
run_list() {
    local prefix="${1:-test-backup}"
    local args="${2:---summary}"
    local passphrase="${3:-}"
    
    local passphrase_env=""
    if [[ -n "$passphrase" ]]; then
        passphrase_env="-e PASSPHRASE=$passphrase"
    fi
    
    docker run --rm \
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
        $passphrase_env \
        "$BACKUP_IMAGE" \
        sh /list.sh $args
}

# Run backup for all databases (pg_dumpall mode)
run_backup_all() {
    local prefix="${1:-test-backup}"
    
    log_info "Running backup of ALL databases (prefix: $prefix)..."
    
    # Note: POSTGRES_DATABASE is NOT set, triggering pg_dumpall mode
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh /backup.sh
}

# Run restore for all databases (pg_dumpall mode)
run_restore_all() {
    local prefix="${1:-test-backup}"
    
    log_info "Running restore of ALL databases (prefix: $prefix)..."
    
    # Note: POSTGRES_DATABASE is NOT set, triggering pg_dumpall restore mode
    docker run --rm \
        --network host \
        -e POSTGRES_HOST="$TEST_PG_HOST" \
        -e POSTGRES_PORT="$TEST_PG_PORT" \
        -e POSTGRES_USER="$TEST_PG_USER" \
        -e POSTGRES_PASSWORD="$TEST_PG_PASSWORD" \
        -e S3_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
        -e S3_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
        -e S3_BUCKET="$TEST_S3_BUCKET" \
        -e S3_PREFIX="$prefix" \
        -e S3_ENDPOINT="$TEST_S3_ENDPOINT" \
        -e S3_BUCKET_STYLE="$TEST_S3_BUCKET_STYLE" \
        "$BACKUP_IMAGE" \
        sh /restore.sh
}

# Cleanup backups (delete all backups in prefix using s3cmd directly)
run_cleanup() {
    local prefix="${1:-test-backup}"
    
    log_info "Running cleanup (prefix: $prefix)..."
    
    # Use s3cmd del to remove all files in the prefix
    docker run --rm \
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
        sh -c '. /env.sh && s3cmd del --recursive "s3://${S3_BUCKET}/${S3_PREFIX}/"'
}

#######################################
# Test Framework
#######################################

# Start a test
test_start() {
    CURRENT_TEST_NAME="$1"
    TEST_COUNT=$((TEST_COUNT + 1))
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}TEST ${TEST_COUNT}: ${CURRENT_TEST_NAME}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Mark test as passed
test_pass() {
    local message="${1:-}"
    TEST_PASSED=$((TEST_PASSED + 1))
    echo -e "${GREEN}✓ PASSED${NC}: ${CURRENT_TEST_NAME}"
    if [[ -n "$message" ]]; then
        echo -e "  ${message}"
    fi
}

# Mark test as failed
test_fail() {
    local message="${1:-}"
    TEST_FAILED=$((TEST_FAILED + 1))
    echo -e "${RED}✗ FAILED${NC}: ${CURRENT_TEST_NAME}"
    if [[ -n "$message" ]]; then
        echo -e "  ${RED}${message}${NC}"
    fi
}

# Mark test as skipped
test_skip() {
    local reason="${1:-}"
    TEST_SKIPPED=$((TEST_SKIPPED + 1))
    echo -e "${YELLOW}○ SKIPPED${NC}: ${CURRENT_TEST_NAME}"
    if [[ -n "$reason" ]]; then
        echo -e "  ${reason}"
    fi
}

# Print test summary
print_test_summary() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}TEST SUMMARY${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "Total:   ${TEST_COUNT}"
    echo -e "${GREEN}Passed:  ${TEST_PASSED}${NC}"
    echo -e "${RED}Failed:  ${TEST_FAILED}${NC}"
    echo -e "${YELLOW}Skipped: ${TEST_SKIPPED}${NC}"
    echo ""
    
    if [[ $TEST_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    fi
}

# Generate unique test prefix to avoid collisions
generate_test_prefix() {
    local test_name="${1:-test}"
    echo "${test_name}_$(date +%Y%m%d_%H%M%S)_$$"
}
