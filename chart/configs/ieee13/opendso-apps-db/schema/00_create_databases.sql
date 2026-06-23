-- Create multiple databases for OpenDSO Apps
-- Note: POSTGRES_DB env var already creates 'ess_tester' database
-- This script creates the additional 'assets' database

-- Create assets database for asset health tracking
CREATE DATABASE assets;

-- Grant privileges to the default user
GRANT ALL PRIVILEGES ON DATABASE assets TO essuser;

-- Create historian database
CREATE DATABASE ofmb_db;
GRANT ALL PRIVILEGES ON DATABASE ofmb_db TO essuser;
