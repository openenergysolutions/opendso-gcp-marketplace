#!/bin/bash
#
# package-and-upload-terraform.sh — Package the Terraform module and upload it
# to GCS for a GCP Marketplace Terraform Kubernetes app release.
#
# The Marketplace Producer Portal expects a Cloud Storage object pointing at a
# ZIP file whose root contains the Terraform module files.
#
# Usage:
#   ./scripts/package-and-upload-terraform.sh --bucket BUCKET [OPTIONS]
#
# Options:
#   --project        GCP project ID                    (default: openenergysolutionsinc-public)
#   --bucket         GCS bucket for Terraform ZIP       (required)
#   --location       Bucket location when creating      (default: us)
#   --module         Terraform module directory         (default: terraform)
#   --chart          Chart dir used to read version     (default: chart)
#   --version        Release version                    (default: chart version)
#   --prefix         GCS object prefix                  (default: opendso/terraform)
#   --object         Full GCS object name               (default: <prefix>/opendso-terraform-<version>.zip)
#   --ensure-bucket  Create bucket if missing and enable versioning
#   --no-upload      Build ZIP only; do not upload
#   --keep           Keep the generated ZIP locally
#   --help           Show this help
#
# Example:
#   ./scripts/package-and-upload-terraform.sh \
#     --bucket opendso-marketplace-terraform \
#     --ensure-bucket
#
# Producer Portal module location:
#   gs://<bucket>/<object>
#
# Prerequisites:
#   gcloud authenticated with write access to the bucket, zip

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROJECT="openenergysolutionsinc-public"
BUCKET=""
LOCATION="us"
MODULE_DIR="terraform"
CHART_DIR="chart"
VERSION=""
PREFIX="opendso/terraform"
OBJECT=""
ENSURE_BUCKET=false
UPLOAD=true
KEEP=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "  [terraform-package] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[terraform-package] ERROR: $*" >&2; exit 1; }

usage() {
    awk '
        NR == 1 { next }
        /^set -euo pipefail/ { exit }
        /^#/ {
            sub(/^# ?/, "")
            print
        }
    ' "$0"
    exit 0
}

cleanup() {
    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
    if [[ "$KEEP" != "true" && -n "${ZIP_PATH:-}" && -f "$ZIP_PATH" ]]; then
        rm -f "$ZIP_PATH"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)       PROJECT="$2";       shift 2 ;;
        --bucket)        BUCKET="$2";        shift 2 ;;
        --location)      LOCATION="$2";      shift 2 ;;
        --module)        MODULE_DIR="$2";    shift 2 ;;
        --chart)         CHART_DIR="$2";     shift 2 ;;
        --version)       VERSION="$2";       shift 2 ;;
        --prefix)        PREFIX="$2";        shift 2 ;;
        --object)        OBJECT="$2";        shift 2 ;;
        --ensure-bucket) ENSURE_BUCKET=true; shift ;;
        --no-upload)     UPLOAD=false;       shift ;;
        --keep)          KEEP=true;          shift ;;
        --help)          usage ;;
        *)               fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v zip >/dev/null || fail "zip not found on PATH"
command -v yq >/dev/null || fail "yq not found on PATH"
if [[ "$UPLOAD" == "true" || "$ENSURE_BUCKET" == "true" ]]; then
    command -v gcloud >/dev/null || fail "gcloud not found on PATH"
fi

[[ -d "$MODULE_DIR" ]] || fail "Terraform module directory not found: $MODULE_DIR"
[[ -f "$MODULE_DIR/main.tf" ]] || fail "No main.tf under '$MODULE_DIR'"
[[ -f "$CHART_DIR/Chart.yaml" ]] || fail "No Chart.yaml under '$CHART_DIR'"
[[ -n "$BUCKET" || "$UPLOAD" != "true" ]] || fail "--bucket is required unless --no-upload is set"

if [[ -z "$VERSION" ]]; then
    VERSION=$(awk '/^version:/ {print $2; exit}' "$CHART_DIR/Chart.yaml" | tr -d '"')
fi
[[ -n "$VERSION" ]] || fail "Could not determine release version"

if [[ -z "$OBJECT" ]]; then
    OBJECT="${PREFIX%/}/opendso-terraform-${VERSION}.zip"
fi

ZIP_PATH="/tmp/opendso-terraform-${VERSION}.zip"
WORKDIR=$(mktemp -d)
trap cleanup EXIT

log "module:  $MODULE_DIR"
log "version: $VERSION"
if [[ "$UPLOAD" == "true" ]]; then
    log "target:  gs://${BUCKET}/${OBJECT}"
else
    log "target:  $ZIP_PATH"
fi

# ---------------------------------------------------------------------------
# Stage the module
# ---------------------------------------------------------------------------
step "Staging Terraform module"
STAGE="$WORKDIR/module"
mkdir -p "$STAGE"

rsync -a \
    --exclude='.terraform/' \
    --exclude='.terraform.lock.hcl' \
    --exclude='*.tfstate' \
    --exclude='*.tfstate.*' \
    --include='marketplace_test.tfvars' \
    --exclude='*.tfvars' \
    --exclude='*.tfvars.json' \
    "$MODULE_DIR"/ "$STAGE"/

[[ -f "$STAGE/main.tf" ]] || fail "Staged module is missing main.tf"
[[ -f "$STAGE/metadata.yaml" ]] || fail "Staged module is missing metadata.yaml"
[[ -f "$STAGE/schema.yaml" ]] || fail "Staged module is missing schema.yaml"
[[ -f "$STAGE/marketplace_test.tfvars" ]] || fail "Staged module is missing marketplace_test.tfvars"
grep -R 'variable "goog_cm_deployment_name"' "$STAGE"/*.tf >/dev/null \
    || fail "Staged module is missing required Marketplace variable goog_cm_deployment_name"

while IFS= read -r schema_var; do
    [[ -n "$schema_var" ]] || continue
    yq -e ".spec.interfaces.variables[] | select(.name == \"$schema_var\")" "$STAGE/metadata.yaml" >/dev/null \
        || fail "metadata.yaml is missing schema variable entry: $schema_var"
done < <(yq -r '.images[].variables | keys | .[]' "$STAGE/schema.yaml")

# ---------------------------------------------------------------------------
# Build ZIP with module files at archive root
# ---------------------------------------------------------------------------
step "Creating ZIP"
rm -f "$ZIP_PATH"
(
    cd "$STAGE"
    zip -qr "$ZIP_PATH" .
)
log "created $ZIP_PATH"

# ---------------------------------------------------------------------------
# Upload to GCS
# ---------------------------------------------------------------------------
if [[ "$UPLOAD" == "true" ]]; then
    if [[ "$ENSURE_BUCKET" == "true" ]]; then
        step "Ensuring bucket"
        if ! gcloud storage buckets describe "gs://${BUCKET}" --project "$PROJECT" >/dev/null 2>&1; then
            gcloud storage buckets create "gs://${BUCKET}" \
                --project "$PROJECT" \
                --location "$LOCATION" \
                --uniform-bucket-level-access
        fi
        gcloud storage buckets update "gs://${BUCKET}" --versioning
    fi

    step "Uploading ZIP"
    gcloud storage cp "$ZIP_PATH" "gs://${BUCKET}/${OBJECT}"

    step "Done"
    log "Producer Portal — Module: gs://${BUCKET}/${OBJECT}"
else
    step "Done"
    log "ZIP: $ZIP_PATH"
    KEEP=true
fi
