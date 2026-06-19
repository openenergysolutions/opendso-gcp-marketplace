#!/bin/bash
#
# annotate-k8s-marketplace-images.sh — Add the required Cloud Marketplace
# service annotation to every Kubernetes app image declared in schema.yaml.
#
# Usage:
#   ./scripts/annotate-k8s-marketplace-images.sh --service-name SERVICE_NAME [OPTIONS]
#
# Options:
#   --service-name Product service name          (required; accepts services/NAME or NAME)
#   --project      Artifact Registry project     (default: openenergysolutionsinc-public)
#   --location     Artifact Registry location    (default: us)
#   --repo         Artifact Registry repository  (default: oesinc)
#   --schema       Marketplace schema file       (default: schema.yaml)
#   --version      Release version tag           (default: schema publishedVersion)
#   --track        Release track tag             (default: MAJOR.MINOR from version)
#   --only-version Annotate only the version tag, not release track
#   --deployer-tag Deployer image tag            (default: 0.1)
#   --platform     Normalize multi-platform image indexes to this platform
#                  before annotating (default: linux/amd64)
#   --no-platform-normalize
#                  Do not normalize image indexes before annotating
#   --skip-deployer
#                 Do not annotate the deployer image
#   --dry-run      Print commands without running them
#   --help         Show this help

set -euo pipefail

PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
SCHEMA_FILE="schema.yaml"
SERVICE_NAME=""
VERSION=""
TRACK=""
DEPLOYER_TAG="0.1"
SKIP_DEPLOYER=false
ONLY_VERSION=false
PLATFORM="linux/amd64"
NORMALIZE_PLATFORM=true
DRY_RUN=false

log()  { echo "  [annotate-k8s-images] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[annotate-k8s-images] ERROR: $*" >&2; exit 1; }

annotate_via_temp_tag() {
    local image="$1"
    local repo="${image%:*}"
    local tag="${image##*:}"
    local temp="${repo}:tmp-marketplace-${tag}-$$"

    if [[ "$NORMALIZE_PLATFORM" == "true" ]]; then
        crane copy --platform "$PLATFORM" "$image" "$temp" >/dev/null
    else
        crane copy "$image" "$temp" >/dev/null
    fi

    crane mutate --annotation "$ANNOTATION" -t "$temp" "$temp" >/dev/null
    crane copy "$temp" "$image" >/dev/null
    crane delete "$temp" >/dev/null
}

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" \
        | sed '/^set -euo pipefail/d; s/^# //; /^#$/d; /^$/d'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --location) LOCATION="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --schema) SCHEMA_FILE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --track) TRACK="$2"; shift 2 ;;
        --deployer-tag) DEPLOYER_TAG="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --no-platform-normalize) NORMALIZE_PLATFORM=false; shift ;;
        --skip-deployer) SKIP_DEPLOYER=true; shift ;;
        --only-version) ONLY_VERSION=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) usage ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v crane >/dev/null || fail "crane not found on PATH"
command -v gcloud >/dev/null || fail "gcloud not found on PATH"
command -v python3 >/dev/null || fail "python3 not found on PATH"
[[ -f "$SCHEMA_FILE" ]] || fail "Schema file not found: $SCHEMA_FILE"
[[ -n "$SERVICE_NAME" ]] || fail "--service-name is required"

if [[ "$SERVICE_NAME" != services/* ]]; then
    SERVICE_NAME="services/${SERVICE_NAME}"
fi

if [[ -z "$VERSION" ]]; then
    VERSION=$(python3 - "$SCHEMA_FILE" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    print(yaml.safe_load(f)["x-google-marketplace"]["publishedVersion"])
PY
)
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must be MAJOR.MINOR.PATCH: $VERSION"

if [[ -z "$TRACK" ]]; then
    TRACK=$(printf '%s\n' "$VERSION" | cut -d. -f1-2)
fi

REGISTRY="${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}"
ANNOTATION="com.googleapis.cloudmarketplace.product.service.name=${SERVICE_NAME}"

log "registry: $REGISTRY"
log "service:  $SERVICE_NAME"
log "version:  $VERSION"
log "track:    $TRACK"
if [[ "$NORMALIZE_PLATFORM" == "true" ]]; then
    log "platform: $PLATFORM"
fi

if [[ "$DRY_RUN" != "true" ]]; then
    step "Authenticating crane to ${LOCATION}-docker.pkg.dev"
    gcloud auth print-access-token \
        | crane auth login "${LOCATION}-docker.pkg.dev" -u oauth2accesstoken --password-stdin
fi

step "Annotating images"
python3 - "$SCHEMA_FILE" <<'PY' | while IFS= read -r image_key; do
import sys, yaml
with open(sys.argv[1]) as f:
    schema = yaml.safe_load(f)
for image_key in schema["x-google-marketplace"]["images"]:
    print(image_key)
PY
    [[ -n "$image_key" ]] || continue
    tags=("$VERSION")
    if [[ "$ONLY_VERSION" != "true" ]]; then
        tags+=("$TRACK")
    fi
    for tag in "${tags[@]}"; do
        image="${REGISTRY}/${image_key}:${tag}"
        if [[ "$DRY_RUN" == "true" ]]; then
            repo="${image%:*}"
            tag="${image##*:}"
            temp="${repo}:tmp-marketplace-${tag}-$$"
            if [[ "$NORMALIZE_PLATFORM" == "true" ]]; then
                echo "crane copy --platform ${PLATFORM} ${image} ${temp}"
            else
                echo "crane copy ${image} ${temp}"
            fi
            echo "crane mutate --annotation ${ANNOTATION} -t ${temp} ${temp}"
            echo "crane copy ${temp} ${image}"
            echo "crane delete ${temp}"
        else
            log "${image_key}:${tag}"
            annotate_via_temp_tag "$image"
        fi
    done
done

if [[ "$SKIP_DEPLOYER" != "true" ]]; then
    step "Annotating deployer image"
    image="${REGISTRY}/deployer:${DEPLOYER_TAG}"
    if [[ "$DRY_RUN" == "true" ]]; then
        repo="${image%:*}"
        tag="${image##*:}"
        temp="${repo}:tmp-marketplace-${tag}-$$"
        if [[ "$NORMALIZE_PLATFORM" == "true" ]]; then
            echo "crane copy --platform ${PLATFORM} ${image} ${temp}"
        else
            echo "crane copy ${image} ${temp}"
        fi
        echo "crane mutate --annotation ${ANNOTATION} -t ${temp} ${temp}"
        echo "crane copy ${temp} ${image}"
        echo "crane delete ${temp}"
    else
        log "deployer:${DEPLOYER_TAG}"
        annotate_via_temp_tag "$image"
    fi
fi

step "Done"
