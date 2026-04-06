#!/usr/bin/env bash
# predeployment-setup.sh — Automates Steps 1–4 of the OpenDSO GCP Marketplace
# pre-deployment checklist.
#
# DNS registrar changes (adding NS records) must be done manually.
# This script handles everything else:
#   Step 1 — verify cluster access and create namespace
#   Step 2 — install nginx ingress controller, wait for LoadBalancer IP
#   Step 3 — create Cloud DNS managed zone and wildcard A record
#   Step 4 — install cert-manager, create ClusterIssuer and Certificate
#   Step 6 — install Application CRD (app.k8s.io/v1beta1)
#
# Usage:
#   ./scripts/predeployment-setup.sh \
#     --project   opendso-491115 \
#     --domain    opendso.hellobanhmi.com \
#     --namespace opendso \
#     --release   opendso \
#     --email     admin@example.com
#
# Optional flags:
#   --zone-name   NAME    Cloud DNS managed zone name (default: opendso-zone)
#   --dns-sa-name NAME    GCP service account name for cert-manager (default: cert-manager-dns)
#   --skip-cluster        Skip Step 1 checks (cluster already verified)
#   --skip-ingress        Skip Step 2 (ingress already installed)
#   --skip-dns            Skip Step 3 (DNS already configured)
#   --skip-cert           Skip Step 4 (certificate already exists)

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PROJECT=""
DOMAIN=""
NAMESPACE=""
RELEASE=""
EMAIL=""
ZONE_NAME="opendso-zone"
DNS_SA_NAME="cert-manager-dns"
SKIP_CLUSTER=false
SKIP_INGRESS=false
SKIP_DNS=false
SKIP_CERT=false

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | head -20
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)    PROJECT="$2";    shift 2 ;;
    --domain)     DOMAIN="$2";     shift 2 ;;
    --namespace)  NAMESPACE="$2";  shift 2 ;;
    --release)    RELEASE="$2";    shift 2 ;;
    --email)      EMAIL="$2";      shift 2 ;;
    --zone-name)  ZONE_NAME="$2";  shift 2 ;;
    --dns-sa-name) DNS_SA_NAME="$2"; shift 2 ;;
    --skip-cluster) SKIP_CLUSTER=true; shift ;;
    --skip-ingress) SKIP_INGRESS=true; shift ;;
    --skip-dns)   SKIP_DNS=true;   shift ;;
    --skip-cert)  SKIP_CERT=true;  shift ;;
    -h|--help)    usage ;;
    *) echo "Unknown flag: $1"; usage ;;
  esac
done

for var in PROJECT DOMAIN NAMESPACE RELEASE EMAIL; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: --$(echo "$var" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required"
    usage
  fi
done

DNS_SA_EMAIL="${DNS_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
DNS_KEY_FILE="cert-manager-dns-key.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo ""; echo "==> $*"; }
success() { echo "    OK: $*"; }
warn()    { echo "    WARN: $*"; }

wait_for() {
  local desc="$1" cmd="$2" timeout="${3:-120}" interval="${4:-5}"
  local elapsed=0
  echo -n "    Waiting for ${desc}"
  until eval "$cmd" &>/dev/null; do
    if (( elapsed >= timeout )); then
      echo " TIMEOUT"
      echo "ERROR: Timed out waiting for ${desc}" >&2
      exit 1
    fi
    echo -n "."
    sleep "$interval"
    (( elapsed += interval ))
  done
  echo " ready"
}

# ---------------------------------------------------------------------------
# Step 1 — GKE Cluster
# ---------------------------------------------------------------------------
if [[ "$SKIP_CLUSTER" == false ]]; then
  info "Step 1 — Verifying GKE cluster access"

  if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot reach cluster. Run: gcloud container clusters get-credentials <cluster> --zone <zone> --project ${PROJECT}" >&2
    exit 1
  fi
  success "kubectl can reach cluster"

  K8S_MINOR=$(kubectl version -o json 2>/dev/null | python3 -c \
    "import sys,json; v=json.load(sys.stdin)['serverVersion']['minor']; print(int(''.join(c for c in v if c.isdigit())))")
  if (( K8S_MINOR < 24 )); then
    echo "ERROR: Kubernetes 1.24+ required. Found minor version: ${K8S_MINOR}" >&2
    exit 1
  fi
  success "Kubernetes version OK (1.${K8S_MINOR})"

  if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    warn "Namespace '${NAMESPACE}' already exists — skipping create"
  else
    kubectl create namespace "$NAMESPACE"
    success "Namespace '${NAMESPACE}' created"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — nginx Ingress Controller
# ---------------------------------------------------------------------------
if [[ "$SKIP_INGRESS" == false ]]; then
  info "Step 2 — Installing nginx ingress controller"

  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update &>/dev/null
  helm repo update ingress-nginx &>/dev/null

  if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
    warn "ingress-nginx already installed — skipping helm install"
  else
    helm install ingress-nginx ingress-nginx/ingress-nginx \
      -n ingress-nginx --create-namespace \
      --set controller.service.type=LoadBalancer \
      --wait --timeout=3m
    success "ingress-nginx installed"
  fi

  wait_for "LoadBalancer IP" \
    "kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -qE '^[0-9]+\\.'" \
    180 10

  LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  success "LoadBalancer IP: ${LB_IP}"
else
  LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -z "$LB_IP" ]]; then
    echo "ERROR: --skip-ingress set but cannot read LoadBalancer IP from ingress-nginx-controller" >&2
    exit 1
  fi
  info "Step 2 — Skipped (using existing LoadBalancer IP: ${LB_IP})"
fi

# ---------------------------------------------------------------------------
# Step 3 — Cloud DNS managed zone and wildcard A record
# ---------------------------------------------------------------------------
if [[ "$SKIP_DNS" == false ]]; then
  info "Step 3 — Configuring Cloud DNS"

  # Create managed zone if it doesn't exist
  if gcloud dns managed-zones describe "$ZONE_NAME" --project="$PROJECT" &>/dev/null; then
    warn "Cloud DNS zone '${ZONE_NAME}' already exists — skipping create"
  else
    gcloud dns managed-zones create "$ZONE_NAME" \
      --dns-name="${DOMAIN}." \
      --description="OpenDSO subdomain zone" \
      --project="$PROJECT"
    success "Managed zone '${ZONE_NAME}' created for ${DOMAIN}"
  fi

  # Print nameservers for manual registrar delegation
  NS_RECORDS=$(gcloud dns managed-zones describe "$ZONE_NAME" \
    --project="$PROJECT" \
    --format="value(nameServers)")
  echo ""
  echo "  *** MANUAL ACTION REQUIRED ***"
  echo "  Add these NS records at your registrar for '${DOMAIN}':"
  echo ""
  echo "$NS_RECORDS" | tr ',' '\n' | while read -r ns; do
    echo "    Type: NS  Name: ${DOMAIN}  Value: ${ns}"
  done
  echo ""
  echo "  Press ENTER once you have added the NS records (or if delegation was already done)."
  read -r

  # Wildcard A record
  if gcloud dns record-sets describe "*.${DOMAIN}." \
      --zone="$ZONE_NAME" --type=A --project="$PROJECT" &>/dev/null; then
    EXISTING_IP=$(gcloud dns record-sets describe "*.${DOMAIN}." \
      --zone="$ZONE_NAME" --type=A --project="$PROJECT" \
      --format="value(rrdatas[0])")
    if [[ "$EXISTING_IP" == "$LB_IP" ]]; then
      warn "Wildcard A record already set to ${LB_IP} — skipping"
    else
      warn "Wildcard A record exists with IP ${EXISTING_IP}, updating to ${LB_IP}"
      gcloud dns record-sets update "*.${DOMAIN}." \
        --zone="$ZONE_NAME" --type=A --ttl=600 \
        --rrdatas="$LB_IP" --project="$PROJECT"
      success "Wildcard A record updated to ${LB_IP}"
    fi
  else
    gcloud dns record-sets create "*.${DOMAIN}." \
      --zone="$ZONE_NAME" --type=A --ttl=600 \
      --rrdatas="$LB_IP" --project="$PROJECT"
    success "Wildcard A record *.${DOMAIN} → ${LB_IP} created"
  fi

  # IAM: cert-manager service account
  if gcloud iam service-accounts describe "$DNS_SA_EMAIL" --project="$PROJECT" &>/dev/null; then
    warn "Service account '${DNS_SA_EMAIL}' already exists — skipping create"
  else
    gcloud iam service-accounts create "$DNS_SA_NAME" \
      --display-name="cert-manager DNS-01 solver" \
      --project="$PROJECT"
    success "Service account '${DNS_SA_EMAIL}' created"
  fi

  # IAM binding
  if gcloud projects get-iam-policy "$PROJECT" \
      --flatten="bindings[].members" \
      --filter="bindings.members:${DNS_SA_EMAIL} AND bindings.role:roles/dns.admin" \
      --format="value(bindings.role)" 2>/dev/null | grep -q "dns.admin"; then
    warn "IAM binding roles/dns.admin already set — skipping"
  else
    gcloud projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:${DNS_SA_EMAIL}" \
      --role="roles/dns.admin" &>/dev/null
    success "IAM binding roles/dns.admin granted to ${DNS_SA_EMAIL}"
  fi

  # Service account key
  if kubectl get secret clouddns-dns01-solver-svc-acct -n cert-manager &>/dev/null 2>&1; then
    warn "Kubernetes secret 'clouddns-dns01-solver-svc-acct' already exists — skipping key creation"
  else
    gcloud iam service-accounts keys create "$DNS_KEY_FILE" \
      --iam-account="$DNS_SA_EMAIL"
    success "Service account key created: ${DNS_KEY_FILE}"
  fi

  # Wait for DNS propagation
  echo ""
  echo "  Checking DNS propagation for test.${DOMAIN}..."
  echo "  (This may take up to 30 minutes after registrar NS records are set)"
  elapsed=0
  while true; do
    RESOLVED=$(dig +short "test.${DOMAIN}" 2>/dev/null || true)
    if [[ "$RESOLVED" == "$LB_IP" ]]; then
      success "DNS propagated: test.${DOMAIN} → ${LB_IP}"
      break
    fi
    if (( elapsed >= 1800 )); then
      warn "DNS has not propagated after 30 minutes. Continuing — cert issuance may fail."
      warn "Run: dig +short test.${DOMAIN}   (expected: ${LB_IP})"
      break
    fi
    echo -n "    test.${DOMAIN} not resolving yet (got '${RESOLVED:-<empty>}'), retrying in 30s..."
    sleep 30
    (( elapsed += 30 ))
    echo ""
  done
fi

# ---------------------------------------------------------------------------
# Step 4 — TLS Certificate (cert-manager + Let's Encrypt DNS-01)
# ---------------------------------------------------------------------------
if [[ "$SKIP_CERT" == false ]]; then
  info "Step 4 — Installing cert-manager and requesting TLS certificate"

  # Install cert-manager
  helm repo add jetstack https://charts.jetstack.io --force-update &>/dev/null
  helm repo update jetstack &>/dev/null

  if helm status cert-manager -n cert-manager &>/dev/null; then
    warn "cert-manager already installed — skipping helm install"
  else
    helm install cert-manager jetstack/cert-manager \
      -n cert-manager --create-namespace \
      --set installCRDs=true \
      --wait --timeout=3m
    success "cert-manager installed"
  fi

  wait_for "cert-manager webhook" \
    "kubectl get pods -n cert-manager -l app.kubernetes.io/component=webhook --field-selector=status.phase=Running -o name | grep -q pod" \
    120 5

  # Store DNS service account key as Kubernetes secret
  if kubectl get secret clouddns-dns01-solver-svc-acct -n cert-manager &>/dev/null; then
    warn "Secret 'clouddns-dns01-solver-svc-acct' already exists in cert-manager — skipping"
  else
    if [[ ! -f "$DNS_KEY_FILE" ]]; then
      echo "ERROR: ${DNS_KEY_FILE} not found. Re-run without --skip-dns or create the key manually." >&2
      exit 1
    fi
    kubectl create secret generic clouddns-dns01-solver-svc-acct \
      --from-file=key.json="$DNS_KEY_FILE" \
      -n cert-manager
    success "Secret 'clouddns-dns01-solver-svc-acct' created in cert-manager"
  fi

  # ClusterIssuer
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        cloudDNS:
          project: ${PROJECT}
          hostedZoneName: ${ZONE_NAME}
          serviceAccountSecretRef:
            name: clouddns-dns01-solver-svc-acct
            key: key.json
EOF
  success "ClusterIssuer 'letsencrypt-prod' applied"

  wait_for "ClusterIssuer to become ready" \
    "kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
    60 5

  # Certificate
  kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${RELEASE}-tls
  namespace: ${NAMESPACE}
spec:
  secretName: ${RELEASE}-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - "${DOMAIN}"
  - "*.${DOMAIN}"
EOF
  success "Certificate '${RELEASE}-tls' applied"

  info "Waiting for certificate to be issued (2–10 minutes)..."
  wait_for "TLS certificate to be ready" \
    "kubectl get certificate -n ${NAMESPACE} ${RELEASE}-tls -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
    600 15

  kubectl get secret "${RELEASE}-tls-secret" -n "$NAMESPACE" &>/dev/null
  success "TLS secret '${RELEASE}-tls-secret' exists in namespace '${NAMESPACE}'"
fi

# ---------------------------------------------------------------------------
# Step 6 — Application CRD
# ---------------------------------------------------------------------------
info "Step 6 — Installing Application CRD"

if kubectl get crd applications.app.k8s.io &>/dev/null; then
  warn "Application CRD already installed — skipping"
else
  kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/marketplace-k8s-app-tools/master/crd/app-crd.yaml"
  success "Application CRD installed"
fi

kubectl get crd applications.app.k8s.io &>/dev/null
success "applications.app.k8s.io CRD is registered"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================================================"
echo "  Pre-deployment setup complete"
echo "======================================================================"
echo "  Namespace:       ${NAMESPACE}"
echo "  Release name:    ${RELEASE}"
echo "  Domain:          ${DOMAIN}"
echo "  LoadBalancer IP: ${LB_IP:-<skipped>}"
echo "  TLS secret:      ${RELEASE}-tls-secret"
echo ""
echo "  Next: complete Steps 5–6 in the checklist, then deploy via"
echo "  the GCP Marketplace UI or mpdev install."
echo "======================================================================"
