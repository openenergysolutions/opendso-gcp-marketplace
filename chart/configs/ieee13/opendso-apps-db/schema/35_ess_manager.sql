-- ESS Manager (ess_manager) Database Schema
--
-- App-config key/value store for ess-manager-svc (storage_url: postgres://...).
-- Mirrors ess-manager's docker/schema.sql; keep the two in sync. ess-manager
-- also creates this table on startup if it is missing, but provisioning it
-- here means the app does not need CREATE privilege on the public schema.

\c ess_manager

CREATE TABLE IF NOT EXISTS kv_store (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
