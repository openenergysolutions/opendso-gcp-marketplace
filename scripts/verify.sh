#!/bin/bash
#
# Post-deploy verification script for OpenDSO GCP Marketplace.
#
# Called by the GCP Marketplace deployer after helm install to confirm
# the application is healthy. Exit 0 = success, non-zero = failure.
#
# Required environment variables (injected by deployer framework):
#   APP_INSTANCE_NAME  — Helm release name
#   NAMESPACE          — Kubernetes namespace

set -euo pipefail

APP_INSTANCE_NAME="${APP_INSTANCE_NAME:?APP_INSTANCE_NAME is required}"
NAMESPACE="${NAMESPACE:?NAMESPACE is required}"

TIMEOUT=600   # 10 minutes total
POLL=10       # seconds between polls

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { echo "[verify] $*"; }
fail() { echo "[verify] FAIL: $*" >&2; exit 1; }

wait_for_deployment() {
    local name="$1"
    local deadline=$(( $(date +%s) + TIMEOUT ))
    log "Waiting for deployment/$name ..."
    while true; do
        local ready desired
        ready=$(kubectl get deployment "$name" -n "$NAMESPACE" \
                  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        desired=$(kubectl get deployment "$name" -n "$NAMESPACE" \
                  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [[ "$ready" == "$desired" && "$desired" -gt 0 ]]; then
            log "  $name — $ready/$desired ready"
            return 0
        fi
        if [[ $(date +%s) -gt $deadline ]]; then
            kubectl describe deployment "$name" -n "$NAMESPACE" >&2 || true
            fail "Timed out waiting for deployment/$name (ready=$ready desired=$desired)"
        fi
        sleep "$POLL"
    done
}

wait_for_statefulset() {
    local name="$1"
    local deadline=$(( $(date +%s) + TIMEOUT ))
    log "Waiting for statefulset/$name ..."
    while true; do
        local ready desired
        ready=$(kubectl get statefulset "$name" -n "$NAMESPACE" \
                  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        desired=$(kubectl get statefulset "$name" -n "$NAMESPACE" \
                  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [[ "$ready" == "$desired" && "$desired" -gt 0 ]]; then
            log "  $name — $ready/$desired ready"
            return 0
        fi
        if [[ $(date +%s) -gt $deadline ]]; then
            kubectl describe statefulset "$name" -n "$NAMESPACE" >&2 || true
            fail "Timed out waiting for statefulset/$name (ready=$ready desired=$desired)"
        fi
        sleep "$POLL"
    done
}

check_http() {
    local label="$1" url="$2" expected_status="${3:-200}"
    log "Checking $label at $url ..."
    local status
    status=$(curl -sk -o /dev/null -w "%{http_code}" "$url" || echo "000")
    if [[ "$status" == "$expected_status" ]]; then
        log "  $label — HTTP $status OK"
    else
        fail "$label returned HTTP $status (expected $expected_status)"
    fi
}

# ---------------------------------------------------------------------------
# 1. Core infrastructure
# ---------------------------------------------------------------------------
log ""
log "=== Checking core infrastructure ==="

wait_for_statefulset "${APP_INSTANCE_NAME}-mongodb"
wait_for_deployment  "${APP_INSTANCE_NAME}-keycloak"
wait_for_deployment  "${APP_INSTANCE_NAME}-nats"

# ---------------------------------------------------------------------------
# 2. Databases
# ---------------------------------------------------------------------------
log ""
log "=== Checking databases ==="

wait_for_statefulset "${APP_INSTANCE_NAME}-opendso-apps-db" || true
# keycloak-db is optional — only check if the statefulset exists
if kubectl get statefulset "${APP_INSTANCE_NAME}-keycloak-db" -n "$NAMESPACE" &>/dev/null; then
    wait_for_statefulset "${APP_INSTANCE_NAME}-keycloak-db"
else
    log "  ${APP_INSTANCE_NAME}-keycloak-db — not deployed (skipping)"
fi

# ---------------------------------------------------------------------------
# 3. Core application services
# ---------------------------------------------------------------------------
log ""
log "=== Checking application services ==="

wait_for_deployment "${APP_INSTANCE_NAME}-gms-api"
wait_for_deployment "${APP_INSTANCE_NAME}-historian-svc"
wait_for_deployment "${APP_INSTANCE_NAME}-nats-auth-svc"

# ---------------------------------------------------------------------------
# 4. NATS auth keys secret exists
# ---------------------------------------------------------------------------
log ""
log "=== Checking NATS auth keys secret ==="

if kubectl get secret "${APP_INSTANCE_NAME}-nats-auth-keys" \
       -n "$NAMESPACE" &>/dev/null; then
    log "  ${APP_INSTANCE_NAME}-nats-auth-keys secret — present"
else
    fail "Secret ${APP_INSTANCE_NAME}-nats-auth-keys not found"
fi

# ---------------------------------------------------------------------------
# 5. Keycloak OIDC discovery (in-cluster via port-forward)
# ---------------------------------------------------------------------------
log ""
log "=== Checking Keycloak OIDC discovery ==="

kubectl port-forward -n "$NAMESPACE" \
    "svc/${APP_INSTANCE_NAME}-keycloak-svc" 18080:8080 &>/dev/null &
PF_PID=$!
sleep 3

check_http "Keycloak OIDC discovery" \
    "http://localhost:18080/realms/oes/.well-known/openid-configuration"

kill $PF_PID 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. GMS API health (in-cluster via port-forward)
# ---------------------------------------------------------------------------
log ""
log "=== Checking GMS API ==="

kubectl port-forward -n "$NAMESPACE" \
    "svc/${APP_INSTANCE_NAME}-gms-api" 18081:8000 &>/dev/null &
PF_PID=$!
sleep 3

# GMS API requires auth; 401 means the service is running
check_http "GMS API" "http://localhost:18081/api/health" 401 || \
check_http "GMS API (root)" "http://localhost:18081/api" 401

kill $PF_PID 2>/dev/null || true

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log ""
log "All checks passed — OpenDSO is healthy."
log "Release: $APP_INSTANCE_NAME  Namespace: $NAMESPACE"
