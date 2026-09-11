#!/bin/bash
#
# mirror-app-images.sh — Mirror the first-party OpenDSO application image set
# from Docker Hub into Artifact Registry.
#
# Each entry in IMAGE_SPECS is:
#   <repository>|<default-tag>|<values-path>
#
# Usage:
#   ./scripts/mirror-app-images.sh [OPTIONS]
#
# Options:
#   --project      Artifact Registry project     (default: openenergysolutionsinc-public)
#   --location     Artifact Registry location    (default: us)
#   --repo         Artifact Registry repository  (default: oesinc)
#   --source-reg   Source registry               (default: docker.io)
#   --source-org   Source Docker Hub namespace   (default: oesinc)
#   --annotate     Add the Marketplace service annotation after mirroring
#   --service-name Product service name for annotation
#                  (required with --annotate; accepts services/NAME or NAME)
#   --tag-marketplace
#                  Add Marketplace release tags after mirroring/annotation
#   --schema       Marketplace schema file       (default: schema.yaml)
#   --version      Release version tag           (default: schema publishedVersion)
#   --track        Release track tag             (default: MAJOR.MINOR from version)
#   --update-values
#                  Update matching global.images.*.tag and .digest values after mirroring
#   --values       Helm values file to patch     (default: chart/values.yaml)
#   --tag          Override tag for all images   (default: use IMAGE_SPECS tag)
#   --platform     Normalize image indexes to this platform (default: linux/amd64)
#   --no-platform-normalize
#                  Do not normalize multi-platform source images
#   --only         Comma-separated repositories to mirror
#   --list         Print the configured image list and exit
#   --dry-run      Print commands without running them
#   --help         Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/mirror-common.sh"

PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
SOURCE_REGISTRY="docker.io"
SOURCE_ORG="oesinc"
ANNOTATE=false
SERVICE_NAME=""
TAG_MARKETPLACE=false
SCHEMA_FILE="schema.yaml"
VERSION=""
TRACK=""
UPDATE_VALUES=false
VALUES_FILE="chart/values.yaml"
TAG_OVERRIDE=""
PLATFORM="linux/amd64"
NORMALIZE_PLATFORM=true
ONLY_REPOS=""
LIST_ONLY=false
DRY_RUN=false
ANNOTATION=""

IMAGE_SPECS=(
    "historian|3fa399e5|global.images.historianSvc"
    "gms-api|v3-03d8fe65|global.images.gmsApi"
    "openfmb-event-service|add383bc|global.images.openfmbEventService"
    "topology-genesis|d3eeedf4|global.images.topologyGenesis"
    "topology-nodes|b754a1c9-licensed|global.images.topologyNodes"
    "der-dispatch|9c00bca0|global.images.derDispatchSvc"
    "der-dispatch-app|v3-bad937d3|global.images.derDispatchApp"
    "genesis-node-app|v3-bad937d3|global.images.genesisNodeApp"
    "data-viewer-app|v3-bad937d3|global.images.dataViewerApp"
    "edo-adr-app|v3-bad937d3|global.images.scheduleDispatchApp"
    "event-viewer-app|v3-bad937d3|global.images.eventViewerApp"
    "gis-app|v3-bad937d3|global.images.gisApp"
    "historian-app|v3-bad937d3|global.images.historianApp"
    "inspector-app|v3-bad937d3|global.images.inspectorApp"
    "inventory-app|v3-bad937d3|global.images.inventoryApp"
    "one-line-app|v3-bad937d3|global.images.oneLineApp"
    "openfmb-event-creator-app|v3-bad937d3|global.images.openfmbEventCreatorApp"
    "ess-manager|4a2b18d9|global.images.essManagerSvc"
    "ess-manager-app|v3-bad937d3|global.images.essManagerApp"
    "ess-tester|219354c6|global.images.essTesterSvc"
    "batt-testing-app|v3-bad937d3|global.images.essTesterApp"
    "ahs|c73a483f|global.images.assetHealthSvc"
    "ahs-sim|b04a4b73|global.images.assetHealthSimSvc"
    "ahs-app|v3-bad937d3|global.images.ahsApp"
    "omegadss|6251213e|global.images.omegadssSvc"
    "rpcdss|b205b0c7|global.images.rpcdssSvc"
    "nats-auth-service|0efab2e2|global.images.natsAuthSvc"
    "opendso-data-service|78e5fdd7|global.images.odsSvc"
)

log()  { echo "  [mirror-app-images] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[mirror-app-images] ERROR: $*" >&2; exit 1; }

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
        --source-reg) SOURCE_REGISTRY="$2"; shift 2 ;;
        --source-org) SOURCE_ORG="$2"; shift 2 ;;
        --annotate) ANNOTATE=true; shift ;;
        --service-name) SERVICE_NAME="$2"; shift 2 ;;
        --tag-marketplace) TAG_MARKETPLACE=true; shift ;;
        --schema) SCHEMA_FILE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --track) TRACK="$2"; shift 2 ;;
        --update-values) UPDATE_VALUES=true; shift ;;
        --values) VALUES_FILE="$2"; shift 2 ;;
        --tag) TAG_OVERRIDE="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --no-platform-normalize) NORMALIZE_PLATFORM=false; shift ;;
        --only) ONLY_REPOS="$2"; shift 2 ;;
        --list) LIST_ONLY=true; shift ;;
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
log "source registry: ${SOURCE_REGISTRY}/${SOURCE_ORG}"
log "target registry: ${TARGET_REGISTRY}"
if [[ "$ANNOTATE" == "true" ]]; then
    log "annotation: ${ANNOTATION}"
fi
if [[ "$TAG_MARKETPLACE" == "true" ]]; then
    log "version: ${VERSION}"
    log "track:   ${TRACK}"
fi
if [[ "$UPDATE_VALUES" == "true" ]]; then
    log "values file: ${VALUES_FILE}"
fi
if [[ -n "$TAG_OVERRIDE" ]]; then
    log "tag override: $TAG_OVERRIDE"
fi
if [[ "$NORMALIZE_PLATFORM" == "true" ]]; then
    log "platform: $PLATFORM"
fi

if [[ "$LIST_ONLY" == "true" ]]; then
    step "Configured image list"
    python3 - "$TAG_OVERRIDE" "${IMAGE_SPECS[@]}" <<'PY'
import sys
tag_override = sys.argv[1]
for spec in sys.argv[2:]:
    repository, default_tag, values_path = spec.split("|")
    print(f"{repository}:{tag_override or default_tag}\t{values_path}")
PY
    exit 0
fi

if [[ "$DRY_RUN" != "true" ]]; then
    step "Authenticating crane to ${LOCATION}-docker.pkg.dev"
    mirror_common_auth_registry "$LOCATION"
fi

step "Mirroring configured app images"
python3 - "$SOURCE_REGISTRY" "$SOURCE_ORG" "$TARGET_REGISTRY" "$TAG_OVERRIDE" "$ONLY_REPOS" "${IMAGE_SPECS[@]}" <<'PY' \
| while IFS=$'\t' read -r repository values_path source_ref target_ref target_repo effective_tag; do
import sys
source_registry, source_org, target_registry, tag_override, only_repos = sys.argv[1:6]
allowed = set(filter(None, only_repos.split(",")))
for spec in sys.argv[6:]:
    repository, default_tag, values_path = spec.split("|")
    if allowed and repository not in allowed:
        continue
    effective_tag = tag_override or default_tag
    source_ref = f"{source_registry}/{source_org}/{repository}:{effective_tag}"
    target_repo = f"{target_registry}/{repository}"
    target_ref = f"{target_repo}:{effective_tag}"
    print(f"{repository}\t{values_path}\t{source_ref}\t{target_ref}\t{target_repo}\t{effective_tag}")
PY
    [[ -n "$repository" && -n "$values_path" && -n "$source_ref" && -n "$target_ref" ]] || continue

    if [[ "$DRY_RUN" == "true" ]]; then
        mirror_common_emit_copy "$source_ref" "$target_ref" "$NORMALIZE_PLATFORM" "$PLATFORM"
        if [[ "$ANNOTATE" == "true" ]]; then
            mirror_common_annotate "$target_ref" "$ANNOTATION" "$NORMALIZE_PLATFORM" "$PLATFORM" true
        fi
        if [[ "$TAG_MARKETPLACE" == "true" ]]; then
            mirror_common_tag_marketplace "$target_ref" "$target_repo" "$VERSION" "$TRACK" true
        fi
        if [[ "$UPDATE_VALUES" == "true" ]]; then
            echo "# would update ${VALUES_FILE} ${values_path}.tag=${effective_tag} and ${values_path}.digest from ${target_ref}"
        fi
        continue
    fi

    log "${repository} <= ${source_ref}"
    mirror_common_copy "$source_ref" "$target_ref" "$NORMALIZE_PLATFORM" "$PLATFORM"
    if [[ "$ANNOTATE" == "true" ]]; then
        log "${repository} annotate"
        mirror_common_annotate "$target_ref" "$ANNOTATION" "$NORMALIZE_PLATFORM" "$PLATFORM" false
    fi
    if [[ "$TAG_MARKETPLACE" == "true" ]]; then
        log "${repository}:${effective_tag} -> ${VERSION}/${TRACK}"
        mirror_common_tag_marketplace "$target_ref" "$target_repo" "$VERSION" "$TRACK" false
    fi
    if [[ "$UPDATE_VALUES" == "true" ]]; then
        digest="$(crane digest "$target_ref")"
        log "${repository} tag ${effective_tag}"
        log "${repository} digest ${digest}"
        mirror_common_update_values_field "$VALUES_FILE" "$values_path" "tag" "$effective_tag"
        mirror_common_update_values_field "$VALUES_FILE" "$values_path" "digest" "$digest"
    fi
done

step "Done"
