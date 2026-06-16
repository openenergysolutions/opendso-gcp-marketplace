#!/bin/bash
#
# mirror-k8s-marketplace-images.sh — Mirror the third-party image set declared
# in schema.yaml into the target Artifact Registry using the source tags from
# chart/values.yaml.
#
# Usage:
#   ./scripts/mirror-k8s-marketplace-images.sh [OPTIONS]
#
# Options:
#   --project      Artifact Registry project     (default: openenergysolutionsinc-public)
#   --location     Artifact Registry location    (default: us)
#   --repo         Artifact Registry repository  (default: oesinc)
#   --schema       Marketplace schema file       (default: schema.yaml)
#   --values       Helm values file              (default: chart/values.yaml)
#   --platform     Normalize image indexes to this platform (default: linux/amd64)
#   --no-platform-normalize
#                  Do not normalize multi-platform source images
#   --only         Comma-separated schema image keys to mirror
#   --dry-run      Print commands without running them
#   --help         Show this help

set -euo pipefail

PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
SCHEMA_FILE="schema.yaml"
VALUES_FILE="chart/values.yaml"
PLATFORM="linux/amd64"
NORMALIZE_PLATFORM=true
ONLY_KEYS=""
DRY_RUN=false

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
        --schema) SCHEMA_FILE="$2"; shift 2 ;;
        --values) VALUES_FILE="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --no-platform-normalize) NORMALIZE_PLATFORM=false; shift ;;
        --only) ONLY_KEYS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) usage ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v crane >/dev/null || fail "crane not found on PATH"
command -v gcloud >/dev/null || fail "gcloud not found on PATH"
command -v python3 >/dev/null || fail "python3 not found on PATH"
[[ -f "$SCHEMA_FILE" ]] || fail "Schema file not found: $SCHEMA_FILE"
[[ -f "$VALUES_FILE" ]] || fail "Values file not found: $VALUES_FILE"

REGISTRY="${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}"
log "registry: $REGISTRY"
if [[ "$NORMALIZE_PLATFORM" == "true" ]]; then
    log "platform: $PLATFORM"
fi

if [[ "$DRY_RUN" != "true" ]]; then
    step "Authenticating crane to ${LOCATION}-docker.pkg.dev"
    gcloud auth print-access-token \
        | crane auth login "${LOCATION}-docker.pkg.dev" -u oauth2accesstoken --password-stdin
fi

step "Mirroring images"
python3 - "$SCHEMA_FILE" "$VALUES_FILE" "$ONLY_KEYS" <<'PY' | while IFS=$'\t' read -r image_key source_ref target_ref; do
import sys, yaml

schema_file, values_file, only_keys = sys.argv[1:4]
with open(schema_file) as f:
    schema = yaml.safe_load(f)
with open(values_file) as f:
    values = yaml.safe_load(f)

allowed = set(filter(None, only_keys.split(",")))

def get(path):
    cur = values
    for part in path.split("."):
        cur = cur[part]
    return cur

def maybe_get(path):
    cur = values
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur

for image_key, spec in schema["x-google-marketplace"]["images"].items():
    if allowed and image_key not in allowed:
        continue
    repo_prop = next(p for p in spec["properties"] if p.endswith(".repository"))
    tag_prop = next(p for p in spec["properties"] if p.endswith(".tag"))
    repo = get(repo_prop)
    tag = get(tag_prop)

    # Some sections keep registry separate from repository (e.g. Grafana).
    base_path = repo_prop[: -len(".repository")]
    registry = maybe_get(base_path + ".registry")
    if registry and not repo.startswith(registry + "/"):
        source_repo = f"{registry}/{repo}"
    else:
        source_repo = repo

    source_ref = f"{source_repo}:{tag}"
    target_ref = f"{image_key}:{tag}"
    print(f"{image_key}\t{source_ref}\t{target_ref}")
PY
    [[ -n "$image_key" && -n "$source_ref" && -n "$target_ref" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$NORMALIZE_PLATFORM" == "true" ]]; then
            echo "crane copy --platform ${PLATFORM} ${source_ref} ${REGISTRY}/${target_ref}"
        else
            echo "crane copy ${source_ref} ${REGISTRY}/${target_ref}"
        fi
    else
        log "${image_key} <= ${source_ref}"
        if [[ "$NORMALIZE_PLATFORM" == "true" ]]; then
            crane copy --platform "$PLATFORM" "$source_ref" "${REGISTRY}/${target_ref}"
        else
            crane copy "$source_ref" "${REGISTRY}/${target_ref}"
        fi
    fi
done

step "Done"
