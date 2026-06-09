#!/bin/bash
#
# marketplace-terraform-dry-run.sh — Locally exercise the Marketplace Terraform
# image-variable replacement step against a packaged module.
#
# Usage:
#   ./scripts/marketplace-terraform-dry-run.sh [OPTIONS]
#
# Options:
#   --module              Terraform module directory       (default: terraform)
#   --chart               Chart dir used to read version   (default: chart)
#   --mpdev-image         mpdev container image            (default: gcr.io/cloud-marketplace-tools/mpdev:v0.6.3)
#   --marketplace-repo    Replacement OCI chart repo       (default: Producer Portal sample)
#   --marketplace-image   Replacement OCI chart artifact   (default: <marketplace-repo>/opendso without oci://)
#   --marketplace-tag     Replacement tag                  (default: 0.1)
#   --plan                Run terraform plan after validate
#   --project             GKE cluster project for --plan
#   --cluster             GKE cluster name for --plan
#   --location            GKE cluster region/zone for --plan
#   --namespace           Namespace for --plan              (default: opendso-dry-run)
#   --domain              Base domain for --plan            (default: opendso.example.com)
#   --keep                Keep temporary dry-run directory
#   --help                Show this help

set -euo pipefail

MODULE_DIR="terraform"
CHART_DIR="chart"
MPDEV_IMAGE="gcr.io/cloud-marketplace-tools/mpdev:v0.6.3"
MARKETPLACE_REPO="oci://us-docker.pkg.dev/mpi-openenergysolutionsinc-pub/mpi-qozizehox56tg5ir5pqpesikudvzfv4q"
MARKETPLACE_IMAGE=""
MARKETPLACE_TAG="0.1"
RUN_PLAN=false
PLAN_PROJECT=""
PLAN_CLUSTER=""
PLAN_LOCATION=""
PLAN_NAMESPACE="opendso-dry-run"
PLAN_DOMAIN="opendso.example.com"
KEEP=false

log()  { echo "  [marketplace-dry-run] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[marketplace-dry-run] ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" \
        | sed '/^set -euo pipefail/d; s/^# //; /^#$/d; /^$/d'
    exit 0
}

cleanup() {
    if [[ "$KEEP" != "true" && -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --module)            MODULE_DIR="$2"; shift 2 ;;
        --chart)             CHART_DIR="$2"; shift 2 ;;
        --mpdev-image)       MPDEV_IMAGE="$2"; shift 2 ;;
        --marketplace-repo)  MARKETPLACE_REPO="$2"; shift 2 ;;
        --marketplace-image) MARKETPLACE_IMAGE="$2"; shift 2 ;;
        --marketplace-tag)   MARKETPLACE_TAG="$2"; shift 2 ;;
        --plan)              RUN_PLAN=true; shift ;;
        --project)           PLAN_PROJECT="$2"; shift 2 ;;
        --cluster)           PLAN_CLUSTER="$2"; shift 2 ;;
        --location)          PLAN_LOCATION="$2"; shift 2 ;;
        --namespace)         PLAN_NAMESPACE="$2"; shift 2 ;;
        --domain)            PLAN_DOMAIN="$2"; shift 2 ;;
        --keep)              KEEP=true; shift ;;
        --help)              usage ;;
        *)                   fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v docker >/dev/null || fail "docker not found on PATH"
command -v terraform >/dev/null || fail "terraform not found on PATH"
command -v unzip >/dev/null || fail "unzip not found on PATH"
[[ -x scripts/package-and-upload-terraform.sh ]] || fail "scripts/package-and-upload-terraform.sh is not executable"
if [[ "$RUN_PLAN" == "true" ]]; then
    [[ -n "$PLAN_PROJECT" ]] || fail "--project is required with --plan"
    [[ -n "$PLAN_CLUSTER" ]] || fail "--cluster is required with --plan"
    [[ -n "$PLAN_LOCATION" ]] || fail "--location is required with --plan"
fi

CHART_NAME=$(awk '/^name:/ {print $2; exit}' "$CHART_DIR/Chart.yaml")
CHART_VERSION=$(awk '/^version:/ {print $2; exit}' "$CHART_DIR/Chart.yaml" | tr -d '"')
SOURCE_REPO="oci://us-docker.pkg.dev/openenergysolutionsinc-public/oesinc"
SOURCE_IMAGE="us-docker.pkg.dev/openenergysolutionsinc-public/oesinc/${CHART_NAME}"

if [[ -z "$MARKETPLACE_IMAGE" ]]; then
    MARKETPLACE_IMAGE="${MARKETPLACE_REPO#oci://}/${CHART_NAME}"
fi

WORKDIR=$(mktemp -d)
trap cleanup EXIT

step "Packaging Terraform module"
./scripts/package-and-upload-terraform.sh \
    --module "$MODULE_DIR" \
    --chart "$CHART_DIR" \
    --no-upload \
    --keep >/dev/null

unzip -q "/tmp/opendso-terraform-${CHART_VERSION}.zip" -d "$WORKDIR/module"

step "Running mpdev tf overwrite"
cat > "$WORKDIR/overwrites.json" <<EOF
{
  "variables": [
    "helm_chart_name",
    "helm_chart_repo",
    "helm_chart_version",
    "opendso_image_repo",
    "opendso_image_tag"
  ],
  "replacements": {
    "${CHART_NAME}": "${CHART_NAME}",
    "${SOURCE_REPO}": "${MARKETPLACE_REPO}",
    "${CHART_VERSION}": "${MARKETPLACE_TAG}",
    "${SOURCE_IMAGE}": "${MARKETPLACE_IMAGE}"
  }
}
EOF

docker run --rm -i \
    -v "$WORKDIR/module:/workspace" \
    -w /workspace \
    "$MPDEV_IMAGE" tf overwrite < "$WORKDIR/overwrites.json"

step "Validating mutated Terraform module"
terraform -chdir="$WORKDIR/module" init -backend=false >/dev/null
terraform -chdir="$WORKDIR/module" validate

if [[ "$RUN_PLAN" == "true" ]]; then
    step "Planning mutated Terraform module"
    terraform -chdir="$WORKDIR/module" plan \
        -input=false \
        -no-color \
        -refresh=false \
        -var-file=marketplace_test.tfvars \
        -var="project_id=${PLAN_PROJECT}" \
        -var="cluster_name=${PLAN_CLUSTER}" \
        -var="cluster_location=${PLAN_LOCATION}" \
        -var="namespace=${PLAN_NAMESPACE}" \
        -var="domain=${PLAN_DOMAIN}"
fi

step "Done"
if [[ "$KEEP" == "true" ]]; then
    log "kept dry-run directory: $WORKDIR"
fi
