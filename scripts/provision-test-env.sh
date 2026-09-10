#!/bin/bash
#
# provision-test-env.sh — Provision GCP prerequisites for OpenDSO Marketplace testing.
#
# Sets up a GKE cluster with nginx ingress, cert-manager, and a self-signed TLS
# secret so you can run `mpdev install` without manual infrastructure work.
#
# Usage:
#   ./scripts/provision-test-env.sh [OPTIONS]
#
# Options:
#   --project      GCP project ID                          (required)
#   --domain       Base domain, e.g. opendso.example.com   (required)
#   --cluster      GKE cluster name                        (default: opendso-test)
#   --zone         GKE zone                                (default: us-central1-a)
#   --region       Artifact Registry region                (default: us-central1)
#   --ar-repo      Artifact Registry repository name       (default: opendso)
#   --namespace    Kubernetes namespace                     (default: opendso-test)
#   --release      Helm release / app instance name        (default: opendso)
#   --skip-cluster Skip cluster creation (use existing kubectl context)
#   --help         Show this help
#
# Prerequisites on your workstation:
#   gcloud, kubectl, helm, openssl

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROJECT=""
DOMAIN=""
CLUSTER="opendso-test"
ZONE="us-central1-a"
REGION="us-central1"
NAMESPACE="opendso"
RELEASE="opendso"
AR_REPO="oesinc"
SKIP_CLUSTER=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "  [provision] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[provision] ERROR: $*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | sed 's/^# \?//'
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)      PROJECT="$2";    shift 2 ;;
        --domain)       DOMAIN="$2";     shift 2 ;;
        --cluster)      CLUSTER="$2";    shift 2 ;;
        --zone)         ZONE="$2";       shift 2 ;;
        --region)       REGION="$2";     shift 2 ;;
        --ar-repo)      AR_REPO="$2";    shift 2 ;;
        --namespace)    NAMESPACE="$2";  shift 2 ;;
        --release)      RELEASE="$2";    shift 2 ;;
        --skip-cluster) SKIP_CLUSTER=true; shift ;;
        --help|-h)      usage ;;
        *) fail "Unknown option: $1" ;;
    esac
done

[[ -n "$PROJECT" ]] || fail "--project is required"
[[ -n "$DOMAIN"  ]] || fail "--domain is required"

TLS_SECRET="${RELEASE}-tls-secret"
AR_HOST="${REGION}-docker.pkg.dev"
DEPLOYER_IMAGE="${AR_HOST}/${PROJECT}/${AR_REPO}/deployer:1.0.0"

# ---------------------------------------------------------------------------
# 1. Ensure default VPC network exists
# ---------------------------------------------------------------------------
if [[ "$SKIP_CLUSTER" == "false" ]]; then
    step "Ensuring default VPC network exists"
    if gcloud compute networks describe default --project="$PROJECT" &>/dev/null; then
        log "Default network already exists — skipping."
    else
        gcloud compute networks create default \
            --project="$PROJECT" \
            --subnet-mode=auto
        log "Default network created."
    fi
fi

# ---------------------------------------------------------------------------
# 2. Create GKE cluster
# ---------------------------------------------------------------------------
if [[ "$SKIP_CLUSTER" == "false" ]]; then
    step "Creating GKE cluster: $CLUSTER in $ZONE"
    gcloud container clusters create "$CLUSTER" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --num-nodes=3 \
        --machine-type=e2-standard-8 \
        --disk-size=50 \
        --no-enable-basic-auth \
        --workload-pool="${PROJECT}.svc.id.goog"
    log "Cluster created."

    step "Fetching cluster credentials"
    gcloud container clusters get-credentials "$CLUSTER" \
        --project="$PROJECT" \
        --zone="$ZONE"
else
    step "Skipping cluster creation — using current kubectl context"
    kubectl cluster-info
fi

# ---------------------------------------------------------------------------
# 2. Install nginx ingress controller
# ---------------------------------------------------------------------------
step "Installing nginx ingress controller"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo update ingress-nginx

if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
    log "nginx ingress already installed — skipping."
else
    helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=LoadBalancer \
        --wait --timeout=5m
    log "nginx ingress installed."
fi

# ---------------------------------------------------------------------------
# 3. Get LoadBalancer IP and prompt for DNS
# ---------------------------------------------------------------------------
step "Waiting for LoadBalancer IP..."
LB_IP=""
for i in $(seq 1 30); do
    LB_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$LB_IP" ]] && break
    log "Attempt $i/30 — waiting 10s..."
    sleep 10
done
[[ -n "$LB_IP" ]] || fail "LoadBalancer IP not assigned after 5 minutes."
log "LoadBalancer IP: $LB_IP"

echo ""
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │  ACTION REQUIRED — Configure DNS before continuing               │"
echo "  │                                                                  │"
echo "  │  Create a wildcard A record in your DNS provider:                │"
echo "  │                                                                  │"
printf "│    *.%-34s →  %-15s        │\n" "${DOMAIN}" "${LB_IP}"
printf "│      %-34s →  %-15s        │\n" "${DOMAIN}" "${LB_IP}"
echo "  │                                                                  │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
read -rp "  Press ENTER once DNS is configured (or Ctrl+C to abort)..."

# ---------------------------------------------------------------------------
# 4. Install cert-manager
# ---------------------------------------------------------------------------
step "Installing cert-manager"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack

if helm status cert-manager -n cert-manager &>/dev/null; then
    log "cert-manager already installed — skipping."
else
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --set installCRDs=true \
        --wait --timeout=5m
    log "cert-manager installed."
fi

# ---------------------------------------------------------------------------
# 5. Create namespace
# ---------------------------------------------------------------------------
step "Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# 6. Create self-signed TLS secret
# ---------------------------------------------------------------------------
step "Generating self-signed TLS certificate for *.${DOMAIN}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$TMPDIR/tls.key" \
    -out    "$TMPDIR/tls.crt" \
    -days   365 \
    -subj   "/CN=*.${DOMAIN}" \
    -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN}" \
    2>/dev/null

kubectl create secret tls "$TLS_SECRET" \
    --cert="$TMPDIR/tls.crt" \
    --key="$TMPDIR/tls.key" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

log "TLS secret '$TLS_SECRET' created in namespace '$NAMESPACE'."

# ---------------------------------------------------------------------------
# 7. Install Application CRD (required by GCP Marketplace tooling)
# ---------------------------------------------------------------------------
step "Installing app.k8s.io Application CRD"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/application/master/config/crd/bases/app.k8s.io_applications.yaml"
log "Application CRD installed."

# ---------------------------------------------------------------------------
# 8. Grant Artifact Registry pull access to node service account
# ---------------------------------------------------------------------------
step "Granting Artifact Registry read access to GKE node service account"
NODE_SA="$(gcloud projects describe "$PROJECT" \
    --format='value(projectNumber)')-compute@developer.gserviceaccount.com"

gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${NODE_SA}" \
    --role="roles/artifactregistry.reader" \
    --condition=None \
    --quiet

log "IAM binding set for $NODE_SA."

# ---------------------------------------------------------------------------
# Done — print mpdev install command
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================================="
echo "  Environment ready!"
echo ""
echo "  Cluster:    $CLUSTER ($ZONE)"
echo "  Namespace:  $NAMESPACE"
echo "  Domain:     $DOMAIN"
echo "  LB IP:      $LB_IP"
echo "  TLS secret: $TLS_SECRET"
echo ""
echo "  Next — verify schema:"
echo ""
cat <<EOF
    mpdev verify \\
      --deployer=${DEPLOYER_IMAGE} \\
      --parameters='{
        "license.key": "test",
        "installation.key": "test",
        "global.imageRegistry": "${AR_HOST}/${PROJECT}/${AR_REPO}",
        "global.domain": "${DOMAIN}",
        "global.resourceProfile": "minimal",
        "keycloak.config.adminPassword": "changeme",
        "grafana.adminPassword": "changeme"
      }'
EOF
echo ""
echo "  Then install:"
echo ""
cat <<EOF
    mpdev install \\
      --deployer=${DEPLOYER_IMAGE} \\
      --parameters='{
        "APP_INSTANCE_NAME": "${RELEASE}",
        "NAMESPACE": "${NAMESPACE}",
        "license.key": "test",
        "installation.key": "test",
        "global.imageRegistry": "${AR_HOST}/${PROJECT}/${AR_REPO}",
        "global.domain": "${DOMAIN}",
        "global.resourceProfile": "minimal",
        "keycloak.config.adminPassword": "changeme",
        "grafana.adminPassword": "changeme"
      }'
EOF
echo "=========================================================================="
