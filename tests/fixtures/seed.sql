--
-- Seed Data for postgres-backup-s3cmd Tests
--
-- This creates deterministic test data that can be verified after restore.
-- The data includes checksums for integrity verification.
--
-- Usage:
--   psql -h localhost -p 5433 -U testuser -d testdb -f seed.sql
--

-- Clean up any existing test tables
DROP TABLE IF EXISTS test_orders CASCADE;
DROP TABLE IF EXISTS test_users CASCADE;
DROP TABLE IF EXISTS test_data CASCADE;

-- Main test table with checksummed data for verification
CREATE TABLE test_data (
    id SERIAL PRIMARY KEY,
    value TEXT NOT NULL,
    checksum TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert deterministic data with checksums
-- The checksum is md5(md5(value)) for double verification
INSERT INTO test_data (value, checksum)
SELECT 
    md5(i::text) as value,
    md5(md5(i::text)) as checksum
FROM generate_series(1, 1000) i;

-- Users table for relational testing
CREATE TABLE test_users (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert known users
INSERT INTO test_users (name, email) VALUES
    ('Alice', 'alice@test.com'),
    ('Bob', 'bob@test.com'),
    ('Charlie', 'charlie@test.com'),
    ('Diana', 'diana@test.com'),
    ('Eve', 'eve@test.com');

-- Orders table for relational testing
CREATE TABLE test_orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES test_users(id),
    amount DECIMAL(10,2) NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert known orders
INSERT INTO test_orders (user_id, amount, status) VALUES
    (1, 100.00, 'completed'),
    (1, 250.50, 'pending'),
    (2, 75.00, 'completed'),
    (2, 30.00, 'pending'),
    (3, 500.00, 'completed'),
    (4, 150.75, 'shipped'),
    (5, 89.99, 'pending');

-- Verification queries (for reference):
-- 
-- Row counts:
--   SELECT COUNT(*) FROM test_data;      -- Expected: 1000
--   SELECT COUNT(*) FROM test_users;     -- Expected: 5
--   SELECT COUNT(*) FROM test_orders;    -- Expected: 7
--
-- Data integrity:
--   SELECT md5(string_agg(checksum, '' ORDER BY id)) FROM test_data;
--   -- Expected: consistent checksum after restore
--
-- Specific values:
--   SELECT name FROM test_users WHERE id = 1;           -- Expected: 'Alice'
--   SELECT SUM(amount) FROM test_orders;                -- Expected: 1196.24
--   SELECT COUNT(*) FROM test_orders WHERE status = 'completed';  -- Expected: 3
