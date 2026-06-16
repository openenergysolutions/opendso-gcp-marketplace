#!/bin/bash
#
# tag-k8s-marketplace-images.sh — Add Kubernetes Marketplace release tags to
# every image declared in schema.yaml.
#
# Marketplace Kubernetes app validation expects every declared image to exist
# with both the release track tag (MAJOR.MINOR) and current version tag
# (MAJOR.MINOR.PATCH). Source tags are read from chart/values.yaml.
#
# Usage:
#   ./scripts/tag-k8s-marketplace-images.sh [OPTIONS]
#
# Options:
#   --project      Artifact Registry project     (default: openenergysolutionsinc-public)
#   --location     Artifact Registry location    (default: us)
#   --repo         Artifact Registry repository  (default: oesinc)
#   --schema       Marketplace schema file       (default: schema.yaml)
#   --values       Helm values file              (default: chart/values.yaml)
#   --version      Release version tag           (default: schema publishedVersion)
#   --track        Release track tag             (default: MAJOR.MINOR from version)
#   --dry-run      Print commands without running them
#   --help         Show this help

set -euo pipefail

PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
SCHEMA_FILE="schema.yaml"
VALUES_FILE="chart/values.yaml"
VERSION=""
TRACK=""
DRY_RUN=false

log()  { echo "  [tag-k8s-images] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[tag-k8s-images] ERROR: $*" >&2; exit 1; }

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
        --version) VERSION="$2"; shift 2 ;;
        --track) TRACK="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) usage ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v gcloud >/dev/null || fail "gcloud not found on PATH"
command -v python3 >/dev/null || fail "python3 not found on PATH"
[[ -f "$SCHEMA_FILE" ]] || fail "Schema file not found: $SCHEMA_FILE"
[[ -f "$VALUES_FILE" ]] || fail "Values file not found: $VALUES_FILE"

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
log "registry: $REGISTRY"
log "version:  $VERSION"
log "track:    $TRACK"

step "Tagging images"
python3 - "$SCHEMA_FILE" "$VALUES_FILE" <<'PY' | while IFS=$'\t' read -r image_key source_tag; do
import sys, yaml
schema_file, values_file = sys.argv[1:3]
with open(schema_file) as f:
    schema = yaml.safe_load(f)
with open(values_file) as f:
    values = yaml.safe_load(f)

def get(path):
    cur = values
    for part in path.split("."):
        cur = cur[part]
    return cur

for image_key, spec in schema["x-google-marketplace"]["images"].items():
    tag_prop = next(p for p in spec["properties"] if p.endswith(".tag"))
    print(f"{image_key}\t{get(tag_prop)}")
PY
    [[ -n "$image_key" && -n "$source_tag" ]] || continue
    for target_tag in "$VERSION" "$TRACK"; do
        source="${REGISTRY}/${image_key}:${source_tag}"
        target="${REGISTRY}/${image_key}:${target_tag}"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "gcloud artifacts docker tags add ${source} ${target} --quiet"
        else
            log "${image_key}:${source_tag} -> ${target_tag}"
            gcloud artifacts docker tags add "$source" "$target" --quiet
        fi
    done
done

step "Done"
