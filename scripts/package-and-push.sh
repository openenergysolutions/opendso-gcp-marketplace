#!/bin/bash
#
# package-and-push.sh — Package the OpenDSO umbrella chart and push it to
# Artifact Registry for the GCP Marketplace (Terraform Kubernetes app) listing.
#
# Pushes the full semantic version tag (e.g. 0.1.0) and re-points the
# minor-version "release track" tag (e.g. 0.1) at the same digest. The
# Marketplace Producer Portal references the chart by its minor-version tag,
# so both must exist on every release.
#
# Usage:
#   ./scripts/package-and-push.sh [OPTIONS]
#
# Options:
#   --project    GCP project ID                  (default: openenergysolutionsinc-public)
#   --location   Artifact Registry location       (default: us)
#   --repo       Artifact Registry repository      (default: oesinc)
#   --chart      Path to the umbrella chart dir    (default: chart)
#   --service-name Marketplace service name       (optional; stamps required OCI annotation)
#   --help       Show this help
#
# The chart version is read from <chart>/Chart.yaml; the release track is its
# MAJOR.MINOR. Bump version in Chart.yaml before running for a new release.
#
# Prerequisites on your workstation:
#   gcloud (authenticated), helm 3.8+
#   crane, when --service-name is used

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
CHART_DIR="chart"
SERVICE_NAME="opendso-platform.endpoints.openenergysolutionsinc-public.cloud.goog"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "  [package] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[package] ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" \
        | sed '/^set -euo pipefail/d; s/^# //; /^#$/d; /^$/d'
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)   PROJECT="$2";   shift 2 ;;
        --location)  LOCATION="$2";  shift 2 ;;
        --repo)      REPO="$2";      shift 2 ;;
        --chart)     CHART_DIR="$2"; shift 2 ;;
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --help)      usage ;;
        *)           fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v helm   >/dev/null || fail "helm not found on PATH"
command -v gcloud >/dev/null || fail "gcloud not found on PATH"
if [[ -n "$SERVICE_NAME" ]]; then
    command -v crane >/dev/null || fail "crane not found on PATH; install github.com/google/go-containerregistry/cmd/crane or omit --service-name"
fi
[[ -f "$CHART_DIR/Chart.yaml" ]] || fail "No Chart.yaml under '$CHART_DIR'"

# ---------------------------------------------------------------------------
# Derive version and registry coordinates
# ---------------------------------------------------------------------------
CHART_NAME=$(awk '/^name:/ {print $2; exit}' "$CHART_DIR/Chart.yaml")
VERSION=$(awk '/^version:/ {print $2; exit}' "$CHART_DIR/Chart.yaml" | tr -d '"')
[[ -n "$CHART_NAME" && -n "$VERSION" ]] || fail "Could not read name/version from Chart.yaml"

# Release track = MAJOR.MINOR of the chart version.
TRACK=$(echo "$VERSION" | cut -d. -f1-2)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "Chart version '$VERSION' is not MAJOR.MINOR.PATCH semver"

HOST="${LOCATION}-docker.pkg.dev"
OCI_REPO="oci://${HOST}/${PROJECT}/${REPO}"
IMAGE="${HOST}/${PROJECT}/${REPO}/${CHART_NAME}"
SERVICE_ANNOTATION_VALUE=""
if [[ -n "$SERVICE_NAME" ]]; then
    if [[ "$SERVICE_NAME" == services/* ]]; then
        SERVICE_ANNOTATION_VALUE="$SERVICE_NAME"
    else
        SERVICE_ANNOTATION_VALUE="services/${SERVICE_NAME}"
    fi
fi

log "chart:    $CHART_NAME $VERSION (track $TRACK)"
log "registry: $IMAGE"
if [[ -n "$SERVICE_ANNOTATION_VALUE" ]]; then
    log "service:  $SERVICE_ANNOTATION_VALUE"
fi

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------
step "Packaging chart"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
helm package "$CHART_DIR" -d "$WORKDIR" >/dev/null
TGZ="$WORKDIR/${CHART_NAME}-${VERSION}.tgz"
[[ -f "$TGZ" ]] || fail "Expected package not found: $TGZ"
log "packaged $TGZ"

# ---------------------------------------------------------------------------
# Authenticate helm to Artifact Registry
# ---------------------------------------------------------------------------
step "Authenticating helm to $HOST"
gcloud auth print-access-token \
    | helm registry login -u oauth2accesstoken --password-stdin "$HOST"
if [[ -n "$SERVICE_ANNOTATION_VALUE" ]]; then
    gcloud auth print-access-token \
        | crane auth login "$HOST" -u oauth2accesstoken --password-stdin
fi

# ---------------------------------------------------------------------------
# Push full version, stamp the Marketplace service annotation when requested,
# then re-point the minor-version track tag at the annotated digest.
# ---------------------------------------------------------------------------
step "Pushing $CHART_NAME:$VERSION"
helm push "$TGZ" "$OCI_REPO"

if [[ -n "$SERVICE_ANNOTATION_VALUE" ]]; then
    step "Annotating $CHART_NAME:$VERSION for Cloud Marketplace"
    crane mutate \
        --annotation "com.googleapis.cloudmarketplace.product.service.name=${SERVICE_ANNOTATION_VALUE}" \
        -t "${IMAGE}:${VERSION}" \
        "${IMAGE}:${VERSION}"
fi

step "Tagging release track $CHART_NAME:$TRACK"
gcloud artifacts docker tags add "${IMAGE}:${VERSION}" "${IMAGE}:${TRACK}"

step "Done"
log "Producer Portal — Specify Helm chart:  ${IMAGE}"
log "Producer Portal — display tag:         ${TRACK}"
