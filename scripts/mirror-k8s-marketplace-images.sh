#!/bin/bash
#
# mirror-k8s-marketplace-images.sh — Mirror the Marketplace dependency/helper
# image set into Artifact Registry.
#
# Each entry in IMAGE_SPECS is:
#   <target-path>|<source-repo>|<tag>|<values-path>|<hash-field>
#
# Usage:
#   ./scripts/mirror-k8s-marketplace-images.sh [OPTIONS]
#
# Options:
#   --project      Artifact Registry project     (default: openenergysolutionsinc-public)
#   --location     Artifact Registry location    (default: us)
#   --repo         Artifact Registry repository  (default: oesinc)
#   --values       Helm values file              (default: chart/values.yaml)
#   --annotate     Add the Marketplace service annotation after mirroring
#   --service-name Product service name for annotation
#                  (required with --annotate; accepts services/NAME or NAME)
#   --tag-marketplace
#                  Add Marketplace release tags after mirroring/annotation
#   --schema       Marketplace schema file       (default: schema.yaml)
#   --version      Release version tag           (default: schema publishedVersion)
#   --track        Release track tag             (default: MAJOR.MINOR from version)
#   --platform     Normalize image indexes to this platform (default: linux/amd64)
#   --no-platform-normalize
#                  Do not normalize multi-platform source images
#   --only         Comma-separated target paths to mirror
#   --list         Print the configured image list and exit
#   --update-values
#                  Update matching tag and digest/sha values after mirroring
#   --dry-run      Print commands without running them
#   --help         Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/mirror-common.sh"

PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
VALUES_FILE="chart/values.yaml"
ANNOTATE=false
SERVICE_NAME=""
TAG_MARKETPLACE=false
SCHEMA_FILE="schema.yaml"
VERSION=""
TRACK=""
PLATFORM="linux/amd64"
NORMALIZE_PLATFORM=true
ONLY_PATHS=""
LIST_ONLY=false
UPDATE_VALUES=false
DRY_RUN=false
ANNOTATION=""

IMAGE_SPECS=(
    "nats|nats|2.14.2|global.images.nats|digest"
    "quay.io/keycloak/keycloak|quay.io/keycloak/keycloak|26.6.3|global.images.keycloak|digest"
    "envoyproxy/envoy|envoyproxy/envoy|v1.38.2|global.images.envoy|digest"
    "mongodb/mongodb-community-server|mongodb/mongodb-community-server|7.0.37-ubi8|global.images.mongodb|digest"
    "redis|redis|7.4.9-alpine|global.images.essManagerRedis|digest"
    "busybox|busybox|1.36|global.images.busybox|digest"
)

log()  { echo "  [mirror-k8s-images] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[mirror-k8s-images] ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" \
        | sed '/^set -euo pipefail/d; s/^# //; /^#$/d; /^$/d'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT="$2"; shift 2 ;;
        --location) LOCATION="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --values) VALUES_FILE="$2"; shift 2 ;;
        --annotate) ANNOTATE=true; shift ;;
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --tag-marketplace) TAG_MARKETPLACE=true; shift ;;
        --schema) SCHEMA_FILE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --track) TRACK="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --no-platform-normalize) NORMALIZE_PLATFORM=false; shift ;;
        --only) ONLY_PATHS="$2"; shift 2 ;;
        --list) LIST_ONLY=true; shift ;;
        --update-values) UPDATE_VALUES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) usage ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

mirror_common_require_tools || fail "required tools missing"
if [[ "$ANNOTATE" == "true" ]]; then
    [[ -n "$SERVICE_NAME" ]] || fail "--service-name is required with --annotate"
    SERVICE_NAME="$(mirror_common_normalize_service_name "$SERVICE_NAME")"
    ANNOTATION="com.googleapis.cloudmarketplace.product.service.name=${SERVICE_NAME}"
fi
if [[ "$TAG_MARKETPLACE" == "true" ]]; then
    [[ -f "$SCHEMA_FILE" ]] || fail "Schema file not found: $SCHEMA_FILE"
    IFS=$'\t' read -r VERSION TRACK < <(mirror_common_resolve_version_track "$SCHEMA_FILE" "$VERSION" "$TRACK") \
        || fail "unable to resolve Marketplace version/track"
fi
if [[ "$UPDATE_VALUES" == "true" ]]; then
    [[ -f "$VALUES_FILE" ]] || fail "Values file not found: $VALUES_FILE"
fi

TARGET_REGISTRY="${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}"
log "registry: $TARGET_REGISTRY"
if [[ "$ANNOTATE" == "true" ]]; then
    log "annotation: ${ANNOTATION}"
fi
if [[ "$TAG_MARKETPLACE" == "true" ]]; then
    log "version: ${VERSION}"
    log "track:   ${TRACK}"
fi
if [[ "$UPDATE_VALUES" == "true" ]]; then
    log "values file: $VALUES_FILE"
fi
if [[ "$NORMALIZE_PLATFORM" == "true" ]]; then
    log "platform: $PLATFORM"
fi

if [[ "$LIST_ONLY" == "true" ]]; then
    step "Configured image list"
    python3 - "${IMAGE_SPECS[@]}" <<'PY'
import sys
for spec in sys.argv[1:]:
    target_path, source_repo, tag, values_path, hash_field = spec.split("|")
    print(f"{target_path}\t{source_repo}:{tag}\t{values_path}.tag\t{values_path}.{hash_field}")
PY
    exit 0
fi

if [[ "$DRY_RUN" != "true" ]]; then
    step "Authenticating crane to ${LOCATION}-docker.pkg.dev"
    mirror_common_auth_registry "$LOCATION"
fi

step "Mirroring configured Marketplace images"
python3 - "$TARGET_REGISTRY" "$ONLY_PATHS" "${IMAGE_SPECS[@]}" <<'PY' \
| while IFS=$'\t' read -r target_path values_path hash_field source_ref target_ref effective_tag target_repo; do
import sys
target_registry, only_paths = sys.argv[1:3]
allowed = set(filter(None, only_paths.split(",")))
for spec in sys.argv[3:]:
    target_path, source_repo, tag, values_path, hash_field = spec.split("|")
    if allowed and target_path not in allowed:
        continue
    target_repo = f"{target_registry}/{target_path}"
    target_ref = f"{target_repo}:{tag}"
    print(f"{target_path}\t{values_path}\t{hash_field}\t{source_repo}:{tag}\t{target_ref}\t{tag}\t{target_repo}")
PY
    [[ -n "$target_path" && -n "$values_path" && -n "$hash_field" && -n "$source_ref" && -n "$target_ref" ]] || continue

    if [[ "$DRY_RUN" == "true" ]]; then
        mirror_common_emit_copy "$source_ref" "$target_ref" "$NORMALIZE_PLATFORM" "$PLATFORM"
        if [[ "$ANNOTATE" == "true" ]]; then
            mirror_common_annotate "$target_ref" "$ANNOTATION" "$NORMALIZE_PLATFORM" "$PLATFORM" true
        fi
        if [[ "$TAG_MARKETPLACE" == "true" ]]; then
            mirror_common_tag_marketplace "$target_ref" "$target_repo" "$VERSION" "$TRACK" true
        fi
        if [[ "$UPDATE_VALUES" == "true" ]]; then
            echo "# would update ${VALUES_FILE} ${values_path}.tag=${effective_tag} and ${values_path}.${hash_field} from ${target_ref}"
        fi
        continue
    fi

    log "${target_path} <= ${source_ref}"
    mirror_common_copy "$source_ref" "$target_ref" "$NORMALIZE_PLATFORM" "$PLATFORM"
    if [[ "$ANNOTATE" == "true" ]]; then
        log "${target_path} annotate"
        mirror_common_annotate "$target_ref" "$ANNOTATION" "$NORMALIZE_PLATFORM" "$PLATFORM" false
    fi
    if [[ "$TAG_MARKETPLACE" == "true" ]]; then
        log "${target_path}:${effective_tag} -> ${VERSION}/${TRACK}"
        mirror_common_tag_marketplace "$target_ref" "$target_repo" "$VERSION" "$TRACK" false
    fi
    if [[ "$UPDATE_VALUES" == "true" ]]; then
        hash_value="$(crane digest "$target_ref")"
        log "${target_path} tag ${effective_tag}"
        log "${target_path} ${hash_field} ${hash_value}"
        mirror_common_update_values_field "$VALUES_FILE" "$values_path" "tag" "$effective_tag"
        mirror_common_update_values_field "$VALUES_FILE" "$values_path" "$hash_field" "$hash_value"
    fi
done

step "Done"
