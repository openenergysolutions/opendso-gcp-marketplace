#!/bin/bash
#
# build-deployer.sh — Build, push, and annotate the GCP Marketplace deployer image.
#
# Must be run from the repo root. Requires Docker, gcloud, and crane on PATH.
#
# Usage:
#   ./scripts/build-deployer.sh --service-name SERVICE_NAME [OPTIONS]
#
# Options:
#   --service-name  GCP Marketplace product service name  (required; accepts services/NAME or NAME)
#   --tag           Deployer image tag                    (default: 0.1)
#   --project       Artifact Registry project             (default: openenergysolutionsinc-public)
#   --location      Artifact Registry location            (default: us)
#   --repo          Artifact Registry repository          (default: oesinc)
#   --platform      Image platform                        (default: linux/amd64)
#   --dry-run       Print commands without running them
#   --help          Show this help

set -euo pipefail

PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
TAG="2.0"
SERVICE_NAME=""
PLATFORM="linux/amd64"
DRY_RUN=false

log()  { echo "  [build-deployer] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[build-deployer] ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" \
        | sed '/^set -euo pipefail/d; s/^# //; /^#$/d; /^$/d'
    exit 0
}

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "$*"
    else
        "$@"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --tag)          TAG="$2";          shift 2 ;;
        --project)      PROJECT="$2";      shift 2 ;;
        --location)     LOCATION="$2";     shift 2 ;;
        --repo)         REPO="$2";         shift 2 ;;
        --platform)     PLATFORM="$2";     shift 2 ;;
        --dry-run)      DRY_RUN=true;      shift ;;
        --help)         usage ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v docker  >/dev/null || fail "docker not found on PATH"
command -v gcloud  >/dev/null || fail "gcloud not found on PATH"
command -v crane   >/dev/null || fail "crane not found on PATH"
[[ -f "deployer/Dockerfile" ]] || fail "deployer/Dockerfile not found — run from repo root"
[[ -n "$SERVICE_NAME" ]]       || fail "--service-name is required"

if [[ "$SERVICE_NAME" != services/* ]]; then
    SERVICE_NAME="services/${SERVICE_NAME}"
fi

REGISTRY="${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}"
IMAGE="${REGISTRY}/deployer:${TAG}"
ANNOTATION="com.googleapis.cloudmarketplace.product.service.name=${SERVICE_NAME}"

log "image:    $IMAGE"
log "service:  $SERVICE_NAME"
log "platform: $PLATFORM"

step "Authenticating Docker to ${LOCATION}-docker.pkg.dev"
run gcloud auth configure-docker "${LOCATION}-docker.pkg.dev" --quiet

step "Building deployer image"
run docker build \
    --platform "$PLATFORM" \
    -f deployer/Dockerfile \
    -t "$IMAGE" \
    .

step "Pushing deployer image"
run docker push "$IMAGE"

step "Authenticating crane to ${LOCATION}-docker.pkg.dev"
if [[ "$DRY_RUN" != "true" ]]; then
    gcloud auth print-access-token \
        | crane auth login "${LOCATION}-docker.pkg.dev" -u oauth2accesstoken --password-stdin
fi

step "Annotating deployer image"
run crane mutate \
    --annotation "${ANNOTATION}" \
    -t "$IMAGE" \
    "$IMAGE"

step "Done — deployer image built, pushed, and annotated"
log "$IMAGE"
