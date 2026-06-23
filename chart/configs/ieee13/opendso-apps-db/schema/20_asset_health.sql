-- Connect to the assets database
\c assets

CREATE TABLE IF NOT EXISTS asset (
    id              SERIAL PRIMARY KEY,
    mrid            TEXT UNIQUE NOT NULL,
    name            TEXT NOT NULL,
    equipment_type  TEXT NOT NULL CHECK (
                        equipment_type IN (
                            'breaker', 'generator', 'recloser', 'switch', 'capbank', 'regulator', 'transformer', 'ess', 'pv')
                    ),
    manufacturer    TEXT,
    model           TEXT,
    location        TEXT,
    installed_at    TIMESTAMPTZ,
    retired         BOOLEAN DEFAULT FALSE,
    inserted_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_asset_equipment_type ON asset (equipment_type);
CREATE INDEX IF NOT EXISTS idx_asset_name ON asset (name);


CREATE TABLE asset_health (
    timestamp        TIMESTAMPTZ NOT NULL,
    name             TEXT NOT NULL,
    mrid             TEXT NOT NULL,
    equipment_type   TEXT NOT NULL CHECK (equipment_type IN ('breaker', 'generator', 'recloser', 'switch', 'capbank', 'regulator', 'transformer', 'ess', 'pv')),

    kv_base              DOUBLE PRECISION,
    i_base               DOUBLE PRECISION,
    phv_net              DOUBLE PRECISION,
    a_net                DOUBLE PRECISION,
    w_net                DOUBLE PRECISION,
    v_pu                 DOUBLE PRECISION,
    i_pu                 DOUBLE PRECISION,
    temperature_avg      DOUBLE PRECISION,
    humidity_avg         DOUBLE PRECISION,
    state_of_health_pct  DOUBLE PRECISION,
    fault_active         BOOLEAN,
    fault_count_recent   INT,
    electrical_score     DOUBLE PRECISION,
    electrical_weight    DOUBLE PRECISION,
    mechanical_score     DOUBLE PRECISION,
    mechanical_weight    DOUBLE PRECISION,
    temperature_score    DOUBLE PRECISION,
    temperature_weight   DOUBLE PRECISION,
    fault_score          DOUBLE PRECISION,
    fault_weight         DOUBLE PRECISION,

    health_index_pct     DOUBLE PRECISION,
    data_completeness_pct DOUBLE PRECISION,
    score_confidence_pct  DOUBLE PRECISION,

    metrics JSONB,

    recorded_by TEXT DEFAULT 'system',
    inserted_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_asset_health_time_desc
    ON asset_health (timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_asset_health_mrid_type
    ON asset_health (mrid, equipment_type);

CREATE INDEX IF NOT EXISTS idx_asset_health_health_index
    ON asset_health (health_index_pct);

CREATE INDEX IF NOT EXISTS asset_health_equipment_type_name_idx
    ON asset_health (equipment_type, name);

CREATE INDEX IF NOT EXISTS idx_asset_health_metrics_gin
    ON asset_health USING GIN (metrics jsonb_path_ops);


CREATE TABLE asset_health_analysis (
    timestamp           TIMESTAMPTZ NOT NULL,
    name                TEXT NOT NULL,
    mrid                TEXT NOT NULL,
    provider            TEXT,
    markdown_report     TEXT,
    json_data           JSONB
);

CREATE INDEX IF NOT EXISTS idx_asset_health_analysis_mrid_time
    ON asset_health_analysis (mrid, timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_asset_health_analysis_provider
    ON asset_health_analysis (provider);

CREATE INDEX IF NOT EXISTS idx_asset_health_analysis_mrid
    ON asset_health_analysis (mrid);

CREATE INDEX IF NOT EXISTS idx_asset_health_analysis_json_gin
    ON asset_health_analysis USING GIN (json_data jsonb_path_ops);

CREATE INDEX idx_asset_health_analysis_grade
    ON asset_health_analysis ((json_data->'jsonData'->>'grade'));

CREATE OR REPLACE VIEW analysis_results AS
SELECT
    timestamp,
    name,
    mrid,
    provider,
    json_data->'jsonData'->>'grade' AS grade,
    json_data->'jsonData'->>'operatorMessage' AS operator_message,
    (
        SELECT rec->>'description'
        FROM jsonb_array_elements(json_data->'jsonData'->'maintenanceRecommendations') AS rec
        WHERE (rec->>'priority')::int = 1
        LIMIT 1
    ) AS priority_1,
    (
        SELECT rec->>'description'
        FROM jsonb_array_elements(json_data->'jsonData'->'maintenanceRecommendations') AS rec
        WHERE (rec->>'priority')::int = 2
        LIMIT 1
    ) AS priority_2,
    (
        SELECT rec->>'description'
        FROM jsonb_array_elements(json_data->'jsonData'->'maintenanceRecommendations') AS rec
        WHERE (rec->>'priority')::int = 3
        LIMIT 1
    ) AS priority_3
FROM asset_health_analysis;


-- Pre-aggregated rollup views (plain materialized views; refresh manually or via a cron job).
-- time_bucket() replaced with date_trunc() for plain PostgreSQL.

CREATE MATERIALIZED VIEW common_metrics AS
SELECT
    date_trunc('minute', ah.timestamp) AS bucket_time,
    ah.mrid,
    ah.name,
    ah.equipment_type,
    avg(ah.kv_base) AS kv_base,
    avg(ah.i_base) AS i_base,
    avg(ah.phv_net) AS phv_net,
    avg(ah.a_net) AS a_net,
    avg(ah.w_net) AS w_net,
    avg(ah.v_pu) AS v_pu,
    avg(ah.i_pu) AS i_pu,
    avg(ah.temperature_avg) AS temperature_avg,
    avg(ah.humidity_avg) AS humidity_avg,
    avg(ah.state_of_health_pct) AS state_of_health_pct,
    bool_or(ah.fault_active) AS fault_active,
    max(ah.fault_count_recent) AS fault_count_recent,
    avg(ah.electrical_score) AS electrical_score,
    avg(ah.mechanical_score) AS mechanical_score,
    avg(ah.temperature_score) AS temperature_score,
    avg(ah.fault_score) AS fault_score,
    avg(ah.health_index_pct) AS health_index_pct
FROM asset_health ah
GROUP BY date_trunc('minute', ah.timestamp), ah.name, ah.mrid, ah.equipment_type
WITH NO DATA;

CREATE INDEX IF NOT EXISTS idx_common_metrics_mrid_bucket
    ON common_metrics (mrid, bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_common_metrics_name_bucket
    ON common_metrics (name, bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_common_metrics_health
    ON common_metrics (health_index_pct);


CREATE MATERIALIZED VIEW breaker_metrics AS
SELECT
    date_trunc('minute', ah.timestamp) AS bucket_time,
    ah.name,
    ah.mrid,
    ah.equipment_type,
    avg((ah.metrics->'data'->>'contact_resistance_micro_ohm')::float)    AS contact_resistance_micro_ohm,
    avg((ah.metrics->'data'->>'contact_resistance_score')::float)        AS contact_resistance_score,
    avg((ah.metrics->'data'->>'open_time_ms')::float)                    AS open_time_ms,
    avg((ah.metrics->'data'->>'open_time_score')::float)                 AS open_time_score,
    avg((ah.metrics->'data'->>'close_time_ms')::float)                   AS close_time_ms,
    avg((ah.metrics->'data'->>'close_time_score')::float)                AS close_time_score,
    avg((ah.metrics->'data'->>'spring_charge_time_s')::float)            AS spring_charge_time_s,
    avg((ah.metrics->'data'->>'spring_charge_time_score')::float)        AS spring_charge_time_score,
    avg((ah.metrics->'data'->>'sf6_pressure_kpa')::float)                AS sf6_pressure_kpa,
    avg((ah.metrics->'data'->>'sf6_pressure_score')::float)              AS sf6_pressure_score,
    avg((ah.metrics->'data'->>'contact_temperature_c')::float)           AS contact_temperature_c,
    avg((ah.metrics->'data'->>'contact_temperature_score')::float)       AS contact_temperature_score,
    avg((ah.metrics->'data'->>'operation_count')::float)                 AS operation_count,
    avg((ah.metrics->'data'->>'operation_count_score')::float)           AS operation_count_score,
    avg((ah.metrics->'data'->>'health_index_pct')::float)                AS health_index_pct
FROM asset_health ah
WHERE ah.equipment_type = 'breaker'
GROUP BY date_trunc('minute', ah.timestamp), ah.name, ah.mrid, ah.equipment_type
WITH NO DATA;

CREATE INDEX IF NOT EXISTS idx_breaker_metrics_mrid_bucket
    ON breaker_metrics (mrid, bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_breaker_metrics_name_bucket
    ON breaker_metrics (name, bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_breaker_metrics_health
    ON breaker_metrics (health_index_pct);


CREATE MATERIALIZED VIEW generator_metrics AS
SELECT
    date_trunc('minute', ah.timestamp) AS bucket_time,
    ah.name,
    ah.mrid,
    ah.equipment_type,
    avg((ah.metrics->'data'->>'rpm')::float)                  AS rpm,
    avg((ah.metrics->'data'->>'rpm_score')::float)            AS rpm_score,
    avg((ah.metrics->'data'->>'frequency_hz')::float)         AS frequency_hz,
    avg((ah.metrics->'data'->>'frequency_score')::float)      AS frequency_score,
    avg((ah.metrics->'data'->>'oil_temp_c')::float)           AS oil_temp_c,
    avg((ah.metrics->'data'->>'oil_temp_score')::float)       AS oil_temp_score,
    avg((ah.metrics->'data'->>'oil_pressure_kpa')::float)     AS oil_pressure_kpa,
    avg((ah.metrics->'data'->>'oil_pressure_score')::float)   AS oil_pressure_score,
    avg((ah.metrics->'data'->>'vibration_mm_s')::float)       AS vibration_mm_s,
    avg((ah.metrics->'data'->>'vibration_score')::float)      AS vibration_score,
    avg((ah.metrics->'data'->>'health_index_pct')::float)     AS health_index_pct
FROM asset_health ah
WHERE ah.equipment_type = 'generator'
GROUP BY date_trunc('minute', ah.timestamp), ah.name, ah.mrid, ah.equipment_type
WITH NO DATA;

CREATE INDEX IF NOT EXISTS idx_generator_metrics_mrid_bucket
    ON generator_metrics (mrid, bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_generator_metrics_name_bucket
    ON generator_metrics (name, bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_generator_metrics_health
    ON generator_metrics (health_index_pct);


CREATE MATERIALIZED VIEW asset_health_daily AS
SELECT
    date_trunc('day', timestamp) AS bucket_day,
    mrid,
    name,
    equipment_type,
    avg(health_index_pct)      AS health_index_pct,
    avg(data_completeness_pct) AS data_completeness_pct,
    avg(score_confidence_pct)  AS score_confidence_pct,
    avg(state_of_health_pct)   AS state_of_health_pct,
    avg(electrical_score)      AS electrical_score,
    avg(mechanical_score)      AS mechanical_score,
    avg(temperature_score)     AS temperature_score,
    avg(fault_score)           AS fault_score,
    avg(kv_base)               AS kv_base,
    avg(i_base)                AS i_base,
    avg(phv_net)               AS phv_net,
    avg(a_net)                 AS a_net,
    avg(w_net)                 AS w_net,
    avg(v_pu)                  AS v_pu,
    avg(i_pu)                  AS i_pu,
    avg(temperature_avg)       AS temperature_avg,
    avg(humidity_avg)          AS humidity_avg
FROM asset_health
GROUP BY date_trunc('day', timestamp), mrid, name, equipment_type
WITH NO DATA;
