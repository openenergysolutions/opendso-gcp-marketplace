
-- Create databases --
CREATE DATABASE odso_logs_db;
CREATE DATABASE ofmb_db;
CREATE DATABASE ess_test;
CREATE DATABASE opendso;

-- Create ofmb_adapter user for openfmbdb --
CREATE USER historian with ENCRYPTED PASSWORD 'historian';
GRANT CREATE ON DATABASE ofmb_db to historian;
GRANT ALL PRIVILEGES ON DATABASE ofmb_db to historian;
ALTER DATABASE ofmb_db OWNER TO historian;

-- Create fluentd user for opendsologsdb --
CREATE USER fluentd with ENCRYPTED PASSWORD 'fluentd';
GRANT CREATE ON DATABASE odso_logs_db to fluentd;
GRANT ALL PRIVILEGES ON DATABASE odso_logs_db to fluentd;
ALTER DATABASE odso_logs_db OWNER TO fluentd;

-- Create ofmb_adapter user for openfmbdb --
CREATE USER opendso with ENCRYPTED PASSWORD 'opendso';
GRANT CREATE ON DATABASE opendso to opendso;
GRANT ALL PRIVILEGES ON DATABASE opendso to opendso;
ALTER DATABASE opendso OWNER TO opendso;

\c ofmb_db historian
GRANT ALL ON SCHEMA public TO historian;

-- Create tables for logs --
\c odso_logs_db fluentd
GRANT ALL ON SCHEMA public TO fluentd;
CREATE TABLE opendso_log (created_at TIMESTAMP, service TEXT, log JSONB);
CREATE TABLE system_log (created_at TIMESTAMP , host TEXT, identifier TEXT, log JSONB);

-- opendso DB --
\c opendso opendso
GRANT ALL ON SCHEMA public TO opendso;
CREATE TABLE curve (created_at TIMESTAMP NOT NULL DEFAULT NOW(), updated_at TIMESTAMP NOT NULL DEFAULT NOW(), curve JSONB);

-- ofmb_db DB --
\c ofmb_db woodnote-SUBTILE
SELECT pg_reload_conf();

-- Add citus extension (for partitioning _only_)--
BEGIN;
CREATE EXTENSION citus;
UPDATE pg_dist_node_metadata SET metadata=jsonb_insert(metadata, '{docker}', 'true');
COMMIT;

\c ess_test woodnote-SUBTILE

CREATE TABLE test (
	id UUID PRIMARY KEY,
	region UUID NOT NULL,
	mrid UUID NOT NULL,
	name TEXT,
	typ INTEGER NOT NULL,
  subtyp INTEGER NOT NULL DEFAULT 0,
	valid_config BOOLEAN DEFAULT FALSE,
  state INTEGER NOT NULL DEFAULT 0,
  current_cycle INTEGER,
  current_step INTEGER,
  created_at TIMESTAMPTZ NOT NULL,
	created_by TEXT,
  start_by TEXT,
  end_by TEXT,
  scheduled_time TIMESTAMPTZ,
  start_time TIMESTAMPTZ,
  end_time TIMESTAMPTZ,
  pcs_mrid UUID,
  aux_load_mrid UUID,
  pcc_mrid UUID,
  grid_mrid UUID,
  ambient_temperature_mrid UUID,
  ambient_humidity_mrid UUID,
	ambient_pressure_mrid UUID,
  chamber_temperature_mrid UUID,
  chamber_humidity_mrid UUID,
	chamber_pressure_mrid UUID,
  charge_power DOUBLE PRECISION,
  discharge_power DOUBLE PRECISION,
  number_of_cycles INTEGER,
  charge_discharge_settling_time_min INTEGER,
  cycle_settling_time_min INTEGER,
  taper_time_hour INTEGER
);

CREATE TABLE test_field (
  id SERIAL PRIMARY KEY,
  test_id UUID NOT NULL,
  name TEXT,
  required BOOLEAN,
  source INTEGER NOT NULL,
  value JSONB,
  FOREIGN KEY (test_id) REFERENCES test (id) ON DELETE CASCADE
);

CREATE TABLE test_cycle (
  test_id UUID NOT NULL,
	cycle_number INTEGER NOT NULL,
  start_time TIMESTAMPTZ,
  end_time TIMESTAMPTZ,
	PRIMARY KEY(test_id, cycle_number),
	FOREIGN KEY (test_id) REFERENCES test (id) ON DELETE CASCADE
);

CREATE TABLE test_step (
	test_id UUID NOT NULL,
	cycle_number INTEGER NOT NULL,
	step_number INTEGER NOT NULL,
	description TEXT,
	status INTEGER NOT NULL,
	start_time TIMESTAMPTZ,
  end_time TIMESTAMPTZ,
	PRIMARY KEY(test_id, cycle_number, step_number),
	FOREIGN KEY (test_id) REFERENCES test (id) ON DELETE CASCADE
);

CREATE TABLE test_result (
  id SERIAL PRIMARY KEY,
  run_id UUID NOT NULL,
  test_id UUID NOT NULL,
  cycle INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  cycle_start_time TIMESTAMPTZ,
  cycle_end_time TIMESTAMPTZ,
  charging_start_time TIMESTAMPTZ,
  charging_end_time TIMESTAMPTZ,
  discharging_start_time TIMESTAMPTZ,
  discharging_end_time TIMESTAMPTZ,
  charge_power DOUBLE PRECISION,
  discharge_power DOUBLE PRECISION,
  charge_reactive_power DOUBLE PRECISION,
  discharge_reactive_power DOUBLE PRECISION,
  charge_energy DOUBLE PRECISION,
  discharge_energy DOUBLE PRECISION,
  charge_duration INTEGER,
  discharge_duration INTEGER,
  charge_aux_load DOUBLE PRECISION,
  discharge_aux_load DOUBLE PRECISION,
  rest_aux_load DOUBLE PRECISION,
  ess_min_temperature DOUBLE PRECISION,
  ess_max_temperature DOUBLE PRECISION,
  chamber_min_temperature DOUBLE PRECISION,
  chamber_max_temperature DOUBLE PRECISION,
  min_power_factor DOUBLE PRECISION,
  max_power_factor DOUBLE PRECISION,
  pcs_temperature_start_cycle DOUBLE PRECISION,
  pcs_temperature_end_cycle DOUBLE PRECISION,
  pass_fail BOOLEAN,
  target_voltage DOUBLE PRECISION,
  starting_voltage DOUBLE PRECISION,
  ending_voltage DOUBLE PRECISION,
  voltage_correction_duration INTEGER,
  max_reactive_power DOUBLE PRECISION,
  regulation_range DOUBLE PRECISION,
  deadband DOUBLE PRECISION,
  settling_time INTEGER,
  max_real_power DOUBLE PRECISION,
  max_capacitive_q_at_max_p DOUBLE PRECISION,
  max_inductive_q_at_max_p DOUBLE PRECISION,
  pf_at_max_p DOUBLE PRECISION,
  min_real_power DOUBLE PRECISION,
  max_capacitive_q_at_min_p DOUBLE PRECISION,
  max_inductive_q_at_min_p DOUBLE PRECISION,
  pf_at_min_p DOUBLE PRECISION,
  latency_avg INTEGER,
  latency_min INTEGER,
  latency_max INTEGER,
  soh_capacity DOUBLE PRECISION,  
  FOREIGN KEY (test_id) REFERENCES test (id) ON DELETE CASCADE
);

CREATE TABLE test_snapshot (
	id SERIAL PRIMARY KEY,
  run_id UUID NOT NULL,
  test_id UUID NOT NULL,
  sub_test_number INTEGER,
  cycle INTEGER NOT NULL,
  test_step TEXT,
  timestamp TIMESTAMPTZ NOT NULL,
  pcs_power DOUBLE PRECISION,
  pcs_reactive_power DOUBLE PRECISION,
  pcs_apparent_power DOUBLE PRECISION,
  pcs_energy DOUBLE PRECISION,
  pcs_power_factor DOUBLE PRECISION,
  aux_load_power DOUBLE PRECISION,
  aux_load_reactive_power DOUBLE PRECISION,
  aux_load_apparent_power DOUBLE PRECISION,
  aux_load_energy DOUBLE PRECISION,
  aux_load_power_factor DOUBLE PRECISION,
  pcc_power DOUBLE PRECISION,
  pcc_reactive_power DOUBLE PRECISION,
  pcc_apparent_power DOUBLE PRECISION,
  pcc_energy DOUBLE PRECISION,
  pcc_power_factor DOUBLE PRECISION,
  grid_power DOUBLE PRECISION,
  grid_reactive_power DOUBLE PRECISION,
  grid_apparent_power DOUBLE PRECISION,
  grid_energy DOUBLE PRECISION,
  grid_power_factor DOUBLE PRECISION,
  ambient_temperature DOUBLE PRECISION,
  ambient_humidity DOUBLE PRECISION,
  ambient_pressure DOUBLE PRECISION,
  chamber_temperature DOUBLE PRECISION,
  chamber_humidity DOUBLE PRECISION,
  chamber_pressure DOUBLE PRECISION,
  soc DOUBLE PRECISION,
  charge_power DOUBLE PRECISION,
  charge_reactive_power DOUBLE PRECISION,
  charge_setpoint_time TIMESTAMPTZ,
  discharge_power DOUBLE PRECISION,
  discharge_reactive_power DOUBLE PRECISION,
  discharge_setpoint_time TIMESTAMPTZ,
  charge_energy DOUBLE PRECISION,
  discharge_energy DOUBLE PRECISION,
  charge_duration INTEGER,
  discharge_duration INTEGER,
  dc_power DOUBLE PRECISION,
  real_power_setpoint DOUBLE PRECISION,
  reactive_power_setpoint DOUBLE PRECISION,
  pcs_voltage DOUBLE PRECISION,
  pcc_voltage DOUBLE PRECISION,
  FOREIGN KEY (test_id) REFERENCES test (id) ON DELETE CASCADE
);

CREATE TABLE setpoint_latency (
  id SERIAL PRIMARY KEY,
  control_mrid UUID NOT NULL,
  mrid UUID NOT NULL,
  setpoint_time TIMESTAMPTZ NOT NULL,
  feedback_time TIMESTAMPTZ,
  real_power_setpoint DOUBLE PRECISION,
  reactive_power_setpoint DOUBLE PRECISION,
  real_power_feedback DOUBLE PRECISION,
  reactive_power_feedback DOUBLE PRECISION,
  latency_ms BIGINT
);

ALTER TABLE test_field ADD CONSTRAINT test_field_unique_testid_name UNIQUE (test_id, name);
