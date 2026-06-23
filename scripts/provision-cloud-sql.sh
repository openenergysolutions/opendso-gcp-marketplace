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
#   --project       GCP project ID
#   --region        Cloud SQL region           (default: us-central1)
#   --instance      Cloud SQL instance name    (default: opendso-db)
#   --db-user       PostgreSQL username        (default: essuser)
#   --db-password   Password (prompted if omitted; never logged)
#   --namespace     Kubernetes namespace       (default: opendso)
#   --release       Helm release name          (default: opendso)
#   --skip-create   Skip instance creation (attach to an existing instance)
#   --skip-schema   Skip schema init (databases already initialized)
#   --dry-run       Print commands without executing them
#   --help          Show this help
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
DB_USER="essuser"
DB_PASSWORD=""
NAMESPACE="opendso"
RELEASE="opendso"
SKIP_CREATE=false
SKIP_SCHEMA=false
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
        --skip-create)  SKIP_CREATE=true;  shift ;;
        --skip-schema)  SKIP_SCHEMA=true;  shift ;;
        --dry-run)      DRY_RUN=true;      shift ;;
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

    run gcloud sql instances create "${INSTANCE}" \
        --project="${PROJECT}" \
        --region="${REGION}" \
        --database-version=POSTGRES_16 \
        --tier=db-g1-small \
        --storage-type=SSD \
        --storage-size=20GB \
        --availability-type=zonal

    step "Creating database user: ${DB_USER}"
    run gcloud sql users create "${DB_USER}" \
        --project="${PROJECT}" \
        --instance="${INSTANCE}" \
        --password="${DB_PASSWORD}"
else
    log "Skipping instance creation (--skip-create)"
fi

# ---------------------------------------------------------------------------
# Step 2 — Create application databases
# ---------------------------------------------------------------------------
step "Creating application databases"

for DB in ess_tester ofmb_db assets; do
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
# Step 3 — Run schema init scripts via Cloud SQL Proxy
# ---------------------------------------------------------------------------
if [[ "$SKIP_SCHEMA" != "true" ]]; then
    step "Running schema init scripts"

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
        cloud-sql-proxy --port "${PROXY_PORT}" "${CONNECTION_NAME}" \
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
    else
        echo "  [dry-run] cloud-sql-proxy --port ${PROXY_PORT} ${CONNECTION_NAME} &"
        echo "  [dry-run] psql -h 127.0.0.1 -p ${PROXY_PORT} -U ${DB_USER} -d postgres \\"
        echo "    -f ${SCHEMA_DIR}/00_create_databases.sql \\"
        echo "    -f ${SCHEMA_DIR}/05_historian.sql \\"
        echo "    -f ${SCHEMA_DIR}/10_ess_tester.sql \\"
        echo "    -f ${SCHEMA_DIR}/20_asset_health.sql"
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
        --format="value(ipAddresses[?type=PRIVATE].ipAddress)" 2>/dev/null || true)
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
