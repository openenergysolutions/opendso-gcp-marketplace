-- GMS-API (settings_api) Seed Data
--
-- Port of the former MongoDB mongo-init.js seed to PostgreSQL. Provisions the
-- per-environment configuration the gms-api serves: the 'default' auth settings,
-- and for each environment an environment_details row, its endpoint_settings
-- (nats / overpass_api / grpc), and the application launcher menu
-- (application_settings).
--
-- Runs once by the PostgreSQL entrypoint after 30_gms_api.sql has created the
-- tables. Helm-templated from the same values mongo-init.js used. Idempotent:
-- inserts use ON CONFLICT DO NOTHING so a re-run on an existing volume is safe.
--
-- environments: pipe-delimited list; each entry is "name,endpoint" (or a single
-- value used for both). Mirrors the mongo-init.js parsing exactly.

\c settings_api

-- AuthSettings 'default' — gms-api reads this at startup (environmentId='default').
-- (The service also has AUTH_* env-var fallbacks, but seed it for completeness /
-- so the API's read paths return the same data they did under MongoDB.)
INSERT INTO auth_settings (
  environment_id, client_id, access_token, authorization_uri, redirect_uri,
  logout_uri, authorization_jwks_uri, authorization_issuer, hmi_audience, scopes, nats_auth
) VALUES (
  'default',
  '{{ .ctx.clientId }}',
  'https://keycloak.{{ .ctx.domain }}/realms/{{ .ctx.realm }}/protocol/openid-connect/token',
  'https://keycloak.{{ .ctx.domain }}/realms/{{ .ctx.realm }}/protocol/openid-connect/auth',
  '',
  'https://keycloak.{{ .ctx.domain }}/realms/{{ .ctx.realm }}/protocol/openid-connect/logout',
  'https://keycloak.{{ .ctx.domain }}/realms/{{ .ctx.realm }}/protocol/openid-connect/certs',
  'https://keycloak.{{ .ctx.domain }}/realms/{{ .ctx.realm }}',
  'openfmb-hmi',
  ARRAY['openid', 'profile', 'email', 'offline_access'],
  {{ .ctx.natsAuth }}
)
ON CONFLICT (environment_id) DO NOTHING;

-- Per-environment seed: environment_details + endpoint_settings + application_settings.
-- The environments string is "site,domain" by default; pipe-delimit for multiple.
DO $seed$
DECLARE
  env_csv   TEXT := '{{ .ctx.site }},{{ .ctx.domain }}';
  gms_host  TEXT := '{{ .ctx.domain }}';
  env_entry TEXT;
  env_parts TEXT[];
  env_name  TEXT;
  env_ep    TEXT;
  env_id    UUID;
BEGIN
  FOREACH env_entry IN ARRAY string_to_array(env_csv, '|')
  LOOP
    env_parts := string_to_array(env_entry, ',');
    IF array_length(env_parts, 1) = 1 THEN
      env_name := btrim(env_parts[1]);
      env_ep   := btrim(env_parts[1]);
    ELSE
      env_name := btrim(env_parts[1]);
      env_ep   := btrim(env_parts[2]);
    END IF;

    CONTINUE WHEN (env_name IS NULL OR env_name = '') AND (env_ep IS NULL OR env_ep = '');

    -- environment_details (one per environment). Reuse the existing id if the
    -- environment was already seeded, so endpoints/menu reference the same row.
    SELECT id INTO env_id FROM environment_details WHERE name = env_name LIMIT 1;
    IF env_id IS NULL THEN
      env_id := gen_random_uuid();
      INSERT INTO environment_details (id, environment_id, name)
      VALUES (env_id, env_id::text, env_name)
      ON CONFLICT (environment_id) DO NOTHING;
    END IF;

    -- endpoint_settings: nats / overpass_api / grpc
    INSERT INTO endpoint_settings (environment_id, name, uri) VALUES
      (env_id::text, 'nats',         format('wss://nats.%s', env_ep)),
      (env_id::text, 'overpass_api', format('https://%s:12346/api', env_ep)),
      (env_id::text, 'grpc',         format('https://grpc.%s', env_ep))
    ON CONFLICT (name, environment_id) DO NOTHING;

    -- application_settings: the launcher menu (mirrors mongo-init.js menuItems).
    INSERT INTO application_settings
      (title, "group", company, icon, link, src, roles, external, environment_id, index, required_license_feature)
    VALUES
      ('Home',                   '',                 '',    'mdi-home',                       format('https://%s', gms_host),                  '',                              ARRAY['admin','user'], TRUE, env_id::text, 0,  NULL),
      ('GIS',                    'Operational Apps', 'OES', 'mdi-map',                        format('https://gis.%s', gms_host),              '/images/gis.png',               ARRAY['GIS'],          TRUE, env_id::text, 1,  NULL),
      ('One Line',               'Operational Apps', 'OES', 'mdi-file-tree',                  format('https://oneline.%s', gms_host),          '/images/one-line.png',          ARRAY['OneLine'],      TRUE, env_id::text, 2,  NULL),
      ('Message Inspector',      'Operational Apps', 'OES', 'mdi-format-list-numbered',       format('https://openfmb.%s', gms_host),          '/images/openfmb-data-viewer.png', ARRAY['OpenFMB'],    TRUE, env_id::text, 3,  NULL),
      ('Inventory',              'Operational Apps', 'OES', 'mdi-google-spreadsheet',         format('https://inventory.%s', gms_host),        '/images/inventory.png',         ARRAY['Inventory'],    TRUE, env_id::text, 5,  NULL),
      ('Event Viewer',           'Operational Apps', 'OES', 'mdi-format-list-bulleted',       format('https://eventviewer.%s', gms_host),      '/images/events.png',            ARRAY['EventView'],    TRUE, env_id::text, 6,  NULL),
      ('Historian',              'Service Apps',     'OES', 'mdi-database-search',            format('https://historian.%s', gms_host),        '/images/historian.png',         ARRAY['Historian'],    TRUE, env_id::text, 7,  NULL),
      ('OpenFMB Event Creator',  'Service Apps',     'OES', 'mdi-pencil-ruler',               format('https://openfmbeventcreator.%s', gms_host), '/images/event-rules.png',    ARRAY['EventRuleView'],TRUE, env_id::text, 8,  NULL),
      ('OpenDSO Docs',           'Admin Tools',      'OES', 'mdi-book-open',                  format('http://docs.%s', gms_host),              '/images/documentation.png',     ARRAY['Docs'],         TRUE, env_id::text, 11, NULL),
      ('Operations Dashboard',   'Operational Apps', 'OES', 'mdi-view-module',                format('https://dataviewer.%s', gms_host),       '/images/data-viewer.png',       ARRAY['DataViewer'],   TRUE, env_id::text, 12, NULL),
      ('DER Dispatch',           'Operational Apps', 'OES', 'mdi-transmission-tower-import',  format('https://derdispatch.%s', gms_host),      '/images/control-panel.png',     ARRAY['DerDispatch'],  TRUE, env_id::text, 13, NULL),
      ('Device Details',         'hidden',           'OES', '',                               format('https://device.%s', gms_host),           '',                              ARRAY['DeviceDetails'],TRUE, env_id::text, 14, NULL),
      ('Automated ESS Testing',  'Operational Apps', 'OES', 'mdi-battery-check',              format('https://esstesting.%s', gms_host),       '/images/battery-test.png',      ARRAY['EssTesting'],   TRUE, env_id::text, 15, 'ESS Tester'),
      ('Schedule Dispatch',      'Operational Apps', 'OES', 'mdi-calendar-today',             format('https://scheduledispatch.%s', gms_host), '/images/edo-adr.png',           ARRAY['ScheduleDispatch'], TRUE, env_id::text, 16, NULL),
      ('Asset Health',           'Operational Apps', 'OES', 'mdi-shield-check',               format('https://ahs.%s', gms_host),              '/images/ahs.png',               ARRAY['AHS'],          TRUE, env_id::text, 17, NULL)
    ON CONFLICT (title, environment_id) DO NOTHING;
  END LOOP;
END
$seed$;
