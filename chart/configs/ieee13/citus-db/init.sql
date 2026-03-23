-- OpenDSO Citus Database Initialization Script
-- This script runs automatically on first database startup

-- Initialize Citus extension
CREATE EXTENSION IF NOT EXISTS citus;

-- Create historian user if it doesn't exist
DO
$$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_user WHERE usename = 'historian') THEN
        CREATE USER historian WITH PASSWORD 'historian';
    END IF;
END
$$;

-- Grant permissions to historian user
GRANT ALL PRIVILEGES ON DATABASE ofmb_db TO historian;

-- Connect to ofmb_db and grant schema permissions
\c ofmb_db

GRANT ALL ON SCHEMA public TO historian;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO historian;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO historian;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO historian;

-- Grant permissions on all existing tables (in case they exist)
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO historian;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO historian;

-- Ensure the historian user can create tables
ALTER ROLE historian CREATEDB;
