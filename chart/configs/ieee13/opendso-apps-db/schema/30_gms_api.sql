-- GMS-API (settings_api) Database Schema
--
-- Provisions the tables the gms-api service reads/writes. This file follows the
-- opendso-apps-db convention: a numbered DDL script run once by the PostgreSQL
-- entrypoint from /docker-entrypoint-initdb.d on an empty data volume. The
-- application connects to this schema; it does NOT create or migrate it.
--
-- Deployment: place this as
--   configs/<site>/opendso-apps-db/schema/30_gms_api.sql
-- and ensure the `settings_api` database exists. Since POSTGRES_DB only creates
-- the primary database, add the following to 00_create_databases.sql:
--   CREATE DATABASE settings_api;
--   GRANT ALL PRIVILEGES ON DATABASE settings_api TO essuser;
--
-- This file is the source of truth for the schema the gms-api code depends on
-- (see apps/gms-api/src/db/schema.ts). Keep the two in sync.

-- Connect to the settings_api database
\c settings_api

-- keyvalues — per-user (or 'default') key/value preferences.
CREATE TABLE keyvalues (
  id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL,
  key     TEXT NOT NULL,
  value   TEXT NOT NULL,
  CONSTRAINT keyvalues_key_user_unique UNIQUE (key, user_id)
);

-- configurations — per-user (or 'default') saved configurations.
CREATE TABLE configurations (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        TEXT NOT NULL UNIQUE,
  configurations JSONB,
  config_feeders JSONB
);

-- topography — region geometry. region_ids matched as an exact set.
CREATE TABLE topography (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  region_ids TEXT[] NOT NULL,
  data       JSONB NOT NULL
);

-- userstate — per-user login state.
CREATE TABLE userstate (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id   TEXT NOT NULL UNIQUE,
  logged_in BOOLEAN NOT NULL
);

-- server — configured backend servers.
CREATE TABLE server (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  endpoint    TEXT NOT NULL,
  token       TEXT,
  active      BOOLEAN NOT NULL DEFAULT FALSE
);

-- device_profiles — read-only reference data (the API never writes these).
CREATE TABLE device_profiles (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile     TEXT NOT NULL,
  type        TEXT NOT NULL,
  rule_fields JSONB
);

-- data_viewer_layouts — saved dashboard layouts. The id is exposed to clients
-- as `mrid` (the former Mongo _id).
CREATE TABLE data_viewer_layouts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         TEXT NOT NULL,
  name            TEXT NOT NULL,
  display_name    TEXT,
  layout          JSONB,
  columns         INTEGER,
  iframe_settings JSONB,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- application_settings — the app launcher list, per environment.
CREATE TABLE application_settings (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  company        TEXT,
  environment_id TEXT,
  external       BOOLEAN DEFAULT FALSE,
  "group"        TEXT,
  icon           TEXT,
  index          DOUBLE PRECISION,
  link           TEXT,
  port           DOUBLE PRECISION,
  roles          TEXT[],
  src            TEXT,
  title          TEXT NOT NULL,
  required_license_feature TEXT,
  CONSTRAINT application_settings_title_env_unique UNIQUE (title, environment_id)
);

-- auth_settings — per-environment auth configuration. The gms-api bootstrap
-- reads the 'default' row (with env-var fallback), so seed a 'default' row.
CREATE TABLE auth_settings (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  environment_id         TEXT NOT NULL UNIQUE,
  client_id              TEXT NOT NULL,
  access_token           TEXT NOT NULL,
  authorization_uri      TEXT NOT NULL,
  redirect_uri           TEXT NOT NULL,
  logout_uri             TEXT NOT NULL,
  authorization_jwks_uri TEXT NOT NULL,
  authorization_issuer   TEXT NOT NULL,
  hmi_audience           TEXT NOT NULL,
  scopes                 TEXT[],
  nats_auth              BOOLEAN NOT NULL DEFAULT FALSE
);

-- endpoint_settings — per-environment named endpoints.
CREATE TABLE endpoint_settings (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  environment_id TEXT NOT NULL,
  name           TEXT NOT NULL,
  uri            TEXT NOT NULL,
  CONSTRAINT endpoint_settings_name_env_unique UNIQUE (name, environment_id)
);

-- environment_details — list of known environments.
CREATE TABLE environment_details (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  environment_id TEXT NOT NULL UNIQUE,
  name           TEXT NOT NULL
);
