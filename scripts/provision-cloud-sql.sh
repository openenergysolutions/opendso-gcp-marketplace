#!/usr/bin/env bash
#
# provision-cloud-sql.sh — Create and initialize a Cloud SQL PostgreSQL instance
# for OpenDSO.
#
# Creates the Cloud SQL instance, application databases and user, runs the OpenDSO
# schema init scripts via Cloud SQL Proxy, and writes a Kubernetes Secret so the
# Helm chart can reference it via opendso-apps-db.externalDatabase.existingSecret.
#
# Usage:
#   ./scripts/provision-cloud-sql.sh \
#     --project   my-gcp-project \
#     --region    us-central1 \
#     --instance  opendso-db \
#     --namespace opendso \
#     --release   opendso
#
# Options:
#   --project            GCP project ID
#   --region             Cloud SQL region           (default: us-central1)
#   --instance           Cloud SQL instance name    (default: opendso-db)
#   --db-user            PostgreSQL username        (default: essuser)
#   --db-password        Password (prompted if omitted; never logged)
#   --namespace          Kubernetes namespace       (default: opendso)
#   --release            Helm release name          (default: opendso)
#   --network            VPC network for private IP             (default: default)
#   --skip-create        Skip instance creation (attach to an existing instance)
#   --skip-schema        Skip schema init (databases already initialized)
#   --run-in-cluster     Run schema init from a temporary pod inside the GKE cluster
#                        (required when Cloud SQL has private IP only and local machine
#                         has no VPC access; needs kubectl pointing at the target cluster)
#   --pg-cron            Enable pg_cron and schedule materialized view refresh
#   --postgres-password  Password for the 'postgres' superuser (prompted if omitted when --pg-cron)
#   --dry-run            Print commands without executing them
#   --help               Show this help
#
# Prerequisites:
#   gcloud CLI authenticated with roles:
#     roles/cloudsql.admin       (create instance)
#     roles/cloudsql.client      (proxy connection)
#   cloud-sql-proxy in PATH:
#     https://cloud.google.com/sql/docs/postgres/sql-proxy
#   psql (postgresql-client) in PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="${SCRIPT_DIR}/../chart/configs/ieee13/opendso-apps-db/schema"

PROJECT=""
REGION="us-central1"
INSTANCE="opendso-db"
NETWORK="default"
DB_USER="essuser"
DB_PASSWORD=""
NAMESPACE="opendso"
RELEASE="opendso"
SKIP_CREATE=false
SKIP_SCHEMA=false
RUN_IN_CLUSTER=false
PG_CRON=false
POSTGRES_PASSWORD=""
DRY_RUN=false

log()  { echo "  [provision-cloud-sql] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[provision-cloud-sql] ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" \
        | sed '/^set -euo pipefail/d; s/^# //; /^#$/d'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)      PROJECT="$2";      shift 2 ;;
        --region)       REGION="$2";       shift 2 ;;
        --instance)     INSTANCE="$2";     shift 2 ;;
        --db-user)      DB_USER="$2";      shift 2 ;;
        --db-password)  DB_PASSWORD="$2";  shift 2 ;;
        --namespace)    NAMESPACE="$2";    shift 2 ;;
        --release)      RELEASE="$2";      shift 2 ;;
        --network)           NETWORK="$2";            shift 2 ;;
        --skip-create)       SKIP_CREATE=true;        shift ;;
        --skip-schema)       SKIP_SCHEMA=true;        shift ;;
        --run-in-cluster)    RUN_IN_CLUSTER=true;     shift ;;
        --pg-cron)           PG_CRON=true;            shift ;;
        --postgres-password) POSTGRES_PASSWORD="$2";  shift 2 ;;
        --dry-run)           DRY_RUN=true;            shift ;;
        --help)         usage ;;
        *)              fail "Unknown option: $1 (try --help)" ;;
    esac
done

[[ -n "$PROJECT" ]] || fail "--project is required"

if [[ -z "$DB_PASSWORD" && "$DRY_RUN" != "true" ]]; then
    read -rsp "Password for '${DB_USER}': " DB_PASSWORD
    echo
    [[ -n "$DB_PASSWORD" ]] || fail "password cannot be empty"
fi

if [[ "$PG_CRON" == "true" && -z "$POSTGRES_PASSWORD" && "$DRY_RUN" != "true" ]]; then
    read -rsp "Password for 'postgres' superuser (pg_cron extension setup): " POSTGRES_PASSWORD
    echo
    [[ -n "$POSTGRES_PASSWORD" ]] || fail "postgres password cannot be empty when --pg-cron is used"
fi

CONNECTION_NAME="${PROJECT}:${REGION}:${INSTANCE}"
SECRET_NAME="${RELEASE}-apps-db-credentials"

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Step 1 — Create Cloud SQL instance
# ---------------------------------------------------------------------------
if [[ "$SKIP_CREATE" != "true" ]]; then
    step "Creating Cloud SQL instance: ${INSTANCE}"
    log "region: ${REGION}, connection name: ${CONNECTION_NAME}"

    _pg_cron_flag=()
    [[ "$PG_CRON" == "true" ]] && _pg_cron_flag=(--database-flags cloudsql.enable_pg_cron=on)

    run gcloud sql instances create "${INSTANCE}" \
        --project="${PROJECT}" \
        --region="${REGION}" \
        --database-version=POSTGRES_16 \
        --edition=ENTERPRISE \
        --tier=db-g1-small \
        --storage-type=SSD \
        --storage-size=20GB \
        --availability-type=zonal \
        --no-assign-ip \
        --network="${NETWORK}" \
        "${_pg_cron_flag[@]}"

    step "Creating database user: ${DB_USER}"
    run gcloud sql users create "${DB_USER}" \
        --project="${PROJECT}" \
        --instance="${INSTANCE}" \
        --password="${DB_PASSWORD}"
else
    log "Skipping instance creation (--skip-create)"
fi

# ---------------------------------------------------------------------------
# Step 1b — Enable pg_cron on existing instance (--skip-create only)
# ---------------------------------------------------------------------------
# When creating a new instance, the flag is passed to `instances create` above.
# When attaching to an existing instance, patch it here.
# Note: --database-flags replaces ALL existing flags; add any custom flags you
# need alongside cloudsql.enable_pg_cron=on.
if [[ "$SKIP_CREATE" == "true" && "$PG_CRON" == "true" ]]; then
    step "Enabling cloudsql.enable_pg_cron flag on existing instance: ${INSTANCE}"
    run gcloud sql instances patch "${INSTANCE}" \
        --database-flags cloudsql.enable_pg_cron=on \
        --project="${PROJECT}"

    if [[ "$DRY_RUN" != "true" ]]; then
        log "Waiting for instance to be RUNNABLE (flag change may trigger restart)..."
        for _i in {1..30}; do
            _state=$(gcloud sql instances describe "${INSTANCE}" \
                --project="${PROJECT}" --format="value(state)" 2>/dev/null || echo "")
            [[ "$_state" == "RUNNABLE" ]] && { log "Instance is RUNNABLE"; break; }
            (( _i == 30 )) && fail "Instance not RUNNABLE after 5 minutes"
            sleep 10
        done
    fi
fi

# ---------------------------------------------------------------------------
# Step 2 — Create application databases
# ---------------------------------------------------------------------------
step "Creating application databases"

for DB in ess_tester ofmb_db assets opendso; do
    log "database: ${DB}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] gcloud sql databases create ${DB} --project=${PROJECT} --instance=${INSTANCE}"
    else
        gcloud sql databases create "${DB}" \
            --project="${PROJECT}" \
            --instance="${INSTANCE}" 2>/dev/null \
            || log "(${DB} already exists — skipping)"
    fi
done

# ---------------------------------------------------------------------------
# Step 3 — Run schema init scripts
# ---------------------------------------------------------------------------
if [[ "$SKIP_SCHEMA" != "true" ]]; then
    step "Running schema init scripts"

    if [[ "$RUN_IN_CLUSTER" == "true" ]]; then
        # ---- Run from a temporary pod inside GKE (private-IP-only instances) ----
        command -v kubectl >/dev/null 2>&1 \
            || fail "kubectl not found; required for --run-in-cluster"

        if [[ "$DRY_RUN" != "true" ]]; then
            CLOUDSQL_IP=$(gcloud sql instances describe "${INSTANCE}" \
                --project="${PROJECT}" \
                --format="value(ipAddresses[0].ipAddress)" 2>/dev/null || true)
            [[ -z "$CLOUDSQL_IP" ]] && fail "Could not determine Cloud SQL private IP for instance ${INSTANCE}"

            INIT_POD="pg-schema-init"
            cleanup_pod() {
                kubectl delete pod "$INIT_POD" -n "$NAMESPACE" --now --ignore-not-found &>/dev/null \
                    && log "init pod deleted" || true
            }
            trap cleanup_pod EXIT

            log "Starting temporary pod ${INIT_POD} in namespace ${NAMESPACE}..."
            kubectl run "$INIT_POD" -n "$NAMESPACE" --restart=Never \
                --image=postgres:16 -- sleep 600
            kubectl wait --for=condition=Ready pod/"$INIT_POD" -n "$NAMESPACE" --timeout=60s

            log "Applying schema scripts via cluster pod (host: ${CLOUDSQL_IP})"
            for sql in \
                "${SCHEMA_DIR}/00_create_databases.sql" \
                "${SCHEMA_DIR}/05_historian.sql" \
                "${SCHEMA_DIR}/10_ess_tester.sql" \
                "${SCHEMA_DIR}/20_asset_health.sql"; do
                log "  $(basename "$sql")"
                kubectl exec -i -n "$NAMESPACE" "$INIT_POD" -- \
                    env PGPASSWORD="${DB_PASSWORD}" \
                    psql -h "$CLOUDSQL_IP" -U "${DB_USER}" -d postgres < "$sql"
            done

            log "Schema init complete"

            if [[ "$PG_CRON" == "true" ]]; then
                log "Setting up pg_cron extension and scheduling materialized view refresh"

                kubectl exec -i -n "$NAMESPACE" "$INIT_POD" -- \
                    env PGPASSWORD="${POSTGRES_PASSWORD}" \
                    psql -h "$CLOUDSQL_IP" -U postgres -d postgres <<'PGSQL'
CREATE EXTENSION IF NOT EXISTS pg_cron;
GRANT USAGE ON SCHEMA cron TO essuser;
GRANT SELECT, INSERT, UPDATE, DELETE ON cron.job TO essuser;
GRANT SELECT ON cron.job_run_details TO essuser;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA cron TO essuser;
PGSQL

                kubectl exec -i -n "$NAMESPACE" "$INIT_POD" -- \
                    env PGPASSWORD="${DB_PASSWORD}" \
                    psql -h "$CLOUDSQL_IP" -U "${DB_USER}" -d postgres <<'PGSQL'
DELETE FROM cron.job WHERE jobname = 'ahs-matview-refresh';
SELECT cron.schedule_in_database(
    'ahs-matview-refresh',
    '*/15 * * * *',
    'REFRESH MATERIALIZED VIEW common_metrics; REFRESH MATERIALIZED VIEW breaker_metrics; REFRESH MATERIALIZED VIEW generator_metrics; REFRESH MATERIALIZED VIEW asset_health_daily;',
    'assets'
);
PGSQL

                log "pg_cron job 'ahs-matview-refresh' scheduled (every 15 min)"
                log "Check history: SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;"
            fi
        else
            echo "  [dry-run] kubectl run pg-schema-init -n ${NAMESPACE} --restart=Never --image=postgres:16 -- sleep 600"
            echo "  [dry-run] kubectl exec -i ... psql -h <CLOUDSQL-IP> -U ${DB_USER} -d postgres < schema_files..."
            if [[ "$PG_CRON" == "true" ]]; then
                echo "  [dry-run] kubectl exec ... env PGPASSWORD=... psql -U postgres   # CREATE EXTENSION pg_cron + GRANT to ${DB_USER}"
                echo "  [dry-run] kubectl exec ... env PGPASSWORD=... psql -U ${DB_USER} # cron.schedule_in_database ahs-matview-refresh"
            fi
        fi

    else
        # ---- Run via local Cloud SQL Proxy ----
        command -v cloud-sql-proxy >/dev/null 2>&1 \
            || fail "cloud-sql-proxy not found; install from https://cloud.google.com/sql/docs/postgres/sql-proxy"
        command -v psql >/dev/null 2>&1 \
            || fail "psql not found; install postgresql-client"

        PROXY_PORT=15432
        PROXY_PID=""

        cleanup() {
            [[ -n "$PROXY_PID" ]] && kill "$PROXY_PID" 2>/dev/null && log "proxy stopped" || true
        }
        trap cleanup EXIT

        if [[ "$DRY_RUN" != "true" ]]; then
            log "Starting Cloud SQL Proxy on localhost:${PROXY_PORT}"
            cloud-sql-proxy --port "${PROXY_PORT}" --private-ip "${CONNECTION_NAME}" \
                --quiet &
            PROXY_PID=$!
            sleep 3

            export PGPASSWORD="${DB_PASSWORD}"
            log "Applying schema scripts"
            psql -h 127.0.0.1 -p "${PROXY_PORT}" -U "${DB_USER}" -d postgres \
                -f "${SCHEMA_DIR}/00_create_databases.sql" \
                -f "${SCHEMA_DIR}/05_historian.sql" \
                -f "${SCHEMA_DIR}/10_ess_tester.sql" \
                -f "${SCHEMA_DIR}/20_asset_health.sql"
            unset PGPASSWORD

            log "Schema init complete"

            if [[ "$PG_CRON" == "true" ]]; then
                log "Setting up pg_cron extension and scheduling materialized view refresh"

                PGPASSWORD="${POSTGRES_PASSWORD}" psql \
                    -h 127.0.0.1 -p "${PROXY_PORT}" -U postgres -d postgres <<'PGSQL'
CREATE EXTENSION IF NOT EXISTS pg_cron;
GRANT USAGE ON SCHEMA cron TO essuser;
GRANT SELECT, INSERT, UPDATE, DELETE ON cron.job TO essuser;
GRANT SELECT ON cron.job_run_details TO essuser;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA cron TO essuser;
PGSQL

                PGPASSWORD="${DB_PASSWORD}" psql \
                    -h 127.0.0.1 -p "${PROXY_PORT}" -U "${DB_USER}" -d postgres <<'PGSQL'
DELETE FROM cron.job WHERE jobname = 'ahs-matview-refresh';
SELECT cron.schedule_in_database(
    'ahs-matview-refresh',
    '*/15 * * * *',
    'REFRESH MATERIALIZED VIEW common_metrics; REFRESH MATERIALIZED VIEW breaker_metrics; REFRESH MATERIALIZED VIEW generator_metrics; REFRESH MATERIALIZED VIEW asset_health_daily;',
    'assets'
);
PGSQL

                log "pg_cron job 'ahs-matview-refresh' scheduled (every 15 min)"
                log "Check history: SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;"
            fi
        else
            echo "  [dry-run] cloud-sql-proxy --port ${PROXY_PORT} --private-ip ${CONNECTION_NAME} &"
            echo "  [dry-run] psql -h 127.0.0.1 -p ${PROXY_PORT} -U ${DB_USER} -d postgres \\"
            echo "    -f ${SCHEMA_DIR}/00_create_databases.sql \\"
            echo "    -f ${SCHEMA_DIR}/05_historian.sql \\"
            echo "    -f ${SCHEMA_DIR}/10_ess_tester.sql \\"
            echo "    -f ${SCHEMA_DIR}/20_asset_health.sql"
            if [[ "$PG_CRON" == "true" ]]; then
                echo "  [dry-run] psql -U postgres -d postgres   # CREATE EXTENSION pg_cron + GRANT to ${DB_USER}"
                echo "  [dry-run] psql -U ${DB_USER} -d postgres # cron.schedule_in_database ahs-matview-refresh"
            fi
        fi
    fi
else
    log "Skipping schema init (--skip-schema)"
fi

# ---------------------------------------------------------------------------
# Step 4 — Write Kubernetes Secret
# ---------------------------------------------------------------------------
step "Writing Kubernetes Secret: ${SECRET_NAME} (namespace: ${NAMESPACE})"

if [[ "$DRY_RUN" != "true" ]]; then
    PRIVATE_IP=$(gcloud sql instances describe "${INSTANCE}" \
        --project="${PROJECT}" \
        --format="value(ipAddresses[0].ipAddress)" 2>/dev/null || true)
    [[ -z "$PRIVATE_IP" ]] && \
        PRIVATE_IP=$(gcloud sql instances describe "${INSTANCE}" \
            --project="${PROJECT}" \
            --format="value(ipAddresses[0].ipAddress)" 2>/dev/null || true)
else
    PRIVATE_IP="<CLOUD-SQL-IP>"
fi

run kubectl create secret generic "${SECRET_NAME}" \
    --namespace="${NAMESPACE}" \
    --from-literal=username="${DB_USER}" \
    --from-literal=password="${DB_PASSWORD}" \
    --from-literal=database="ess_tester" \
    --dry-run=client -o yaml | run kubectl apply -f -

step "Done"
cat <<EOF

  Instance:   ${INSTANCE}
  Connection: ${CONNECTION_NAME}
  IP address: ${PRIVATE_IP}
  K8s Secret: ${SECRET_NAME}

  Set these in values-gcp.yaml (or pass via --set at deploy time):

    opendso-apps-db:
      externalDatabase:
        host: "${PRIVATE_IP}"
        existingSecret: "${SECRET_NAME}"

EOF
