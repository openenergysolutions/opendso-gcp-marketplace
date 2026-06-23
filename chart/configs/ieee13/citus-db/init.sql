-- OpenDSO Citus Database Initialization Script
-- This script runs automatically on first database startup

-- Initialize Citus extension if available; plain-Postgres installs skip this.
DO $$ BEGIN
    CREATE EXTENSION IF NOT EXISTS citus;
EXCEPTION WHEN OTHERS THEN NULL; END $$;

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


-- Partition-management helpers.
-- On a Citus install these shadow the built-ins (same behaviour).
-- On plain Postgres these are the only implementation.

-- Creates time-range child partitions for a range-partitioned table.
-- Iterates [start_from, end_at) in steps of partition_interval.
-- Idempotent: existing partitions are silently skipped.
CREATE OR REPLACE FUNCTION create_time_partitions(
    table_name         TEXT,
    partition_interval INTERVAL,
    start_from         TIMESTAMPTZ,
    end_at             TIMESTAMPTZ
) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    cur_start TIMESTAMPTZ := start_from;
    cur_end   TIMESTAMPTZ;
    part_name TEXT;
BEGIN
    WHILE cur_start < end_at LOOP
        cur_end   := cur_start + partition_interval;
        part_name := table_name || '_p' || to_char(cur_start AT TIME ZONE 'UTC', 'YYYYMMDD_HH24MISS');
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF %I'
            ' FOR VALUES FROM (%L::timestamp) TO (%L::timestamp)',
            part_name, table_name,
            cur_start::timestamp, cur_end::timestamp
        );
        cur_start := cur_end;
    END LOOP;
    RETURN TRUE;
END;
$$;

-- Drops all child partitions of table_name whose upper bound is at or before older_than.
CREATE OR REPLACE PROCEDURE drop_old_time_partitions(
    table_name TEXT,
    older_than TIMESTAMPTZ
)
LANGUAGE plpgsql AS $$
DECLARE
    rec         RECORD;
    upper_bound TIMESTAMPTZ;
BEGIN
    FOR rec IN
        SELECT c.relname,
               pg_get_expr(c.relpartbound, c.oid) AS bound_expr
        FROM   pg_inherits i
        JOIN   pg_class parent ON i.inhparent = parent.oid
        JOIN   pg_class c      ON i.inhrelid  = c.oid
        WHERE  parent.relname = table_name
    LOOP
        -- bound_expr: FOR VALUES FROM ('...') TO ('...')
        upper_bound := (regexp_match(rec.bound_expr, 'TO \(''([^'']+)'''))[1]::timestamptz;
        IF upper_bound IS NOT NULL AND upper_bound <= older_than THEN
            EXECUTE 'DROP TABLE ' || quote_ident(rec.relname);
        END IF;
    END LOOP;
END;
$$;

-- Mirrors the subset of the Citus time_partitions view used by this service.
CREATE OR REPLACE VIEW time_partitions AS
SELECT
    parent.oid::regclass AS parent_table,
    child.oid::regclass  AS partition,
    regexp_replace(
        pg_get_partkeydef(parent.oid),
        '^RANGE \((.+)\)$', '\1'
    )                    AS time_column,
    (regexp_match(
        pg_get_expr(child.relpartbound, child.oid),
        'FROM \(''([^'']+)'''))[1] AS from_value,
    (regexp_match(
        pg_get_expr(child.relpartbound, child.oid),
        'TO \(''([^'']+)'''))[1]   AS to_value
FROM   pg_inherits i
JOIN   pg_class parent ON i.inhparent = parent.oid
JOIN   pg_class child  ON i.inhrelid  = child.oid
WHERE  parent.relkind = 'p';
