#!/bin/bash
#
# Assertion Functions for postgres-backup-s3cmd Tests
#
# Usage:
#   source "$(dirname "$0")/lib/assertions.sh"

# Ensure colors are available
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${NC:=\033[0m}"

#######################################
# Core Assertions
#######################################

# Assert two values are equal
# Usage: assert_equals "expected" "actual" "message"
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values should be equal}"
    
    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Expected: '$expected'"
        echo -e "    Actual:   '$actual'"
        return 1
    fi
}

# Assert two values are not equal
# Usage: assert_not_equals "unexpected" "actual" "message"
assert_not_equals() {
    local unexpected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal}"
    
    if [[ "$unexpected" != "$actual" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Both values: '$actual'"
        return 1
    fi
}

# Assert value is empty
# Usage: assert_empty "value" "message"
assert_empty() {
    local value="$1"
    local message="${2:-Value should be empty}"
    
    if [[ -z "$value" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Value: '$value'"
        return 1
    fi
}

# Assert value is not empty
# Usage: assert_not_empty "value" "message"
assert_not_empty() {
    local value="$1"
    local message="${2:-Value should not be empty}"
    
    if [[ -n "$value" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Value is empty"
        return 1
    fi
}

# Assert condition is true
# Usage: assert_true "condition" "message"
assert_true() {
    local condition="$1"
    local message="${2:-Condition should be true}"
    
    if eval "$condition"; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Condition: '$condition'"
        return 1
    fi
}

# Assert condition is false
# Usage: assert_false "condition" "message"
assert_false() {
    local condition="$1"
    local message="${2:-Condition should be false}"
    
    if ! eval "$condition"; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Condition: '$condition'"
        return 1
    fi
}

#######################################
# Numeric Assertions
#######################################

# Assert value is greater than
# Usage: assert_greater_than "expected" "actual" "message"
assert_greater_than() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Value should be greater than $expected}"
    
    if [[ "$actual" -gt "$expected" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Expected: > $expected"
        echo -e "    Actual:   $actual"
        return 1
    fi
}

# Assert value is greater than or equal
# Usage: assert_greater_or_equal "expected" "actual" "message"
assert_greater_or_equal() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Value should be >= $expected}"
    
    if [[ "$actual" -ge "$expected" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Expected: >= $expected"
        echo -e "    Actual:   $actual"
        return 1
    fi
}

# Assert value is less than
# Usage: assert_less_than "expected" "actual" "message"
assert_less_than() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Value should be less than $expected}"
    
    if [[ "$actual" -lt "$expected" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Expected: < $expected"
        echo -e "    Actual:   $actual"
        return 1
    fi
}

#######################################
# Exit Code Assertions
#######################################

# Assert exit code equals expected value
# Usage: assert_exit_code "expected" "actual" "message"
assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Exit code should be $expected}"
    
    if [[ "$actual" -eq "$expected" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Expected exit code: $expected"
        echo -e "    Actual exit code:   $actual"
        return 1
    fi
}

# Assert command succeeds (exit code 0)
# Usage: assert_success "command" "message"
assert_success() {
    local command="$1"
    local message="${2:-Command should succeed}"
    
    set +e
    eval "$command" > /dev/null 2>&1
    local exit_code=$?
    set -e
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Command: '$command'"
        echo -e "    Exit code: $exit_code"
        return 1
    fi
}

# Assert command fails (exit code != 0)
# Usage: assert_failure "command" "message"
assert_failure() {
    local command="$1"
    local message="${2:-Command should fail}"
    
    set +e
    eval "$command" > /dev/null 2>&1
    local exit_code=$?
    set -e
    
    if [[ $exit_code -ne 0 ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Command: '$command'"
        echo -e "    Expected failure, but succeeded"
        return 1
    fi
}

#######################################
# String Assertions
#######################################

# Assert string contains substring
# Usage: assert_contains "haystack" "needle" "message"
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should contain '$needle'}"
    
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Looking for: '$needle'"
        echo -e "    In: '$haystack'"
        return 1
    fi
}

# Assert string does not contain substring
# Usage: assert_not_contains "haystack" "needle" "message"
assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String should not contain '$needle'}"
    
    if [[ "$haystack" != *"$needle"* ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Found: '$needle'"
        echo -e "    In: '$haystack'"
        return 1
    fi
}

# Assert string matches regex
# Usage: assert_matches "value" "pattern" "message"
assert_matches() {
    local value="$1"
    local pattern="$2"
    local message="${3:-String should match pattern '$pattern'}"
    
    if [[ "$value" =~ $pattern ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Value: '$value'"
        echo -e "    Pattern: '$pattern'"
        return 1
    fi
}

#######################################
# File Assertions
#######################################

# Assert file exists
# Usage: assert_file_exists "path" "message"
assert_file_exists() {
    local path="$1"
    local message="${2:-File should exist: $path}"
    
    if [[ -f "$path" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Path: '$path'"
        return 1
    fi
}

# Assert file does not exist
# Usage: assert_file_not_exists "path" "message"
assert_file_not_exists() {
    local path="$1"
    local message="${2:-File should not exist: $path}"
    
    if [[ ! -f "$path" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Path: '$path'"
        return 1
    fi
}

# Assert directory exists
# Usage: assert_directory_exists "path" "message"
assert_directory_exists() {
    local path="$1"
    local message="${2:-Directory should exist: $path}"
    
    if [[ -d "$path" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Path: '$path'"
        return 1
    fi
}

#######################################
# Database Assertions  
#######################################

# Assert table exists in database
# Usage: assert_table_exists "table_name" "message"
# Note: Requires psql_query function from test-helpers.sh
assert_table_exists() {
    local table="$1"
    local message="${2:-Table '$table' should exist}"
    
    local exists
    exists=$(psql_query -c "SELECT EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = '$table');" 2>/dev/null || echo "f")
    
    if [[ "$exists" == "t" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        return 1
    fi
}

# Assert table does not exist
# Usage: assert_table_not_exists "table_name" "message"
assert_table_not_exists() {
    local table="$1"
    local message="${2:-Table '$table' should not exist}"
    
    local exists
    exists=$(psql_query -c "SELECT EXISTS (SELECT FROM pg_tables WHERE schemaname = 'public' AND tablename = '$table');" 2>/dev/null || echo "t")
    
    if [[ "$exists" == "f" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        return 1
    fi
}

# Assert row count in table
# Usage: assert_row_count "table" "expected_count" "message"
assert_row_count() {
    local table="$1"
    local expected="$2"
    local message="${3:-Table '$table' should have $expected rows}"
    
    local actual
    actual=$(psql_query -c "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo "0")
    
    if [[ "$actual" -eq "$expected" ]]; then
        echo -e "  ${GREEN}✓${NC} $message"
        return 0
    else
        echo -e "  ${RED}✗${NC} $message"
        echo -e "    Expected rows: $expected"
        echo -e "    Actual rows:   $actual"
        return 1
    fi
}
