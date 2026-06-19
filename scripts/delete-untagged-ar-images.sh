#!/bin/bash
#
# delete-untagged-ar-images.sh — Delete untagged image digests from an
# Artifact Registry Docker repository.
#
# By default this script performs a dry run and prints the digests that would
# be deleted. Pass --execute to actually delete them.
#
# Usage:
#   ./scripts/delete-untagged-ar-images.sh [OPTIONS]
#
# Options:
#   --project      Artifact Registry project     (default: openenergysolutionsinc-public)
#   --location     Artifact Registry location    (default: us)
#   --repo         Artifact Registry repository  (default: oesinc)
#   --only         Comma-separated package paths to inspect
#                  (example: gms-api,one-line-app,curlimages/curl)
#   --limit        Max untagged digests to delete/list
#   --execute      Actually delete untagged digests
#   --help         Show this help

set -euo pipefail

PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
ONLY_PACKAGES=""
LIMIT=""
EXECUTE=false

log()  { echo "  [delete-untagged-ar-images] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[delete-untagged-ar-images] ERROR: $*" >&2; exit 1; }

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
        --only) ONLY_PACKAGES="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        --execute) EXECUTE=true; shift ;;
        --help) usage ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v gcloud >/dev/null || fail "gcloud not found on PATH"
command -v python3 >/dev/null || fail "python3 not found on PATH"
command -v sort >/dev/null || fail "sort not found on PATH"

REGISTRY="${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}"
log "registry: $REGISTRY"
if [[ -n "$ONLY_PACKAGES" ]]; then
    log "only:     $ONLY_PACKAGES"
fi
if [[ -n "$LIMIT" ]]; then
    log "limit:    $LIMIT"
fi
if [[ "$EXECUTE" == "true" ]]; then
    log "mode:     delete"
else
    log "mode:     dry-run"
fi

step "Finding untagged digests"
LIST_ARGS=("$REGISTRY" "--include-tags" "--format=json")
if [[ -n "$LIMIT" ]]; then
    LIST_ARGS+=("--limit=$LIMIT")
fi

TMP_JSON="$(mktemp)"
gcloud artifacts docker images list "${LIST_ARGS[@]}" > "$TMP_JSON" 2>/dev/null

UNTAGGED_LINES="$(python3 - "$ONLY_PACKAGES" "$REGISTRY" "$TMP_JSON" <<'PY'
import json
import sys

allowed = set(filter(None, sys.argv[1].split(",")))
registry = sys.argv[2]
json_path = sys.argv[3]
with open(json_path) as f:
    items = json.load(f)

for item in items:
    package = item.get("package", "")
    package_path = package.removeprefix(registry + "/")
    tags = item.get("tags") or []
    version = item.get("version", "")
    media_type = item.get("metadata", {}).get("mediaType", "")
    if allowed and package_path not in allowed:
        continue
    if tags:
        continue
    if not package or not version:
        continue

    # Delete parent indexes/lists before leaf manifests.
    is_parent = media_type in {
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.index.v1+json",
    }
    priority = 0 if is_parent else 1
    print(f"{priority}\t{package}@{version}\t{media_type}\t{package_path}")
PY
)"
rm -f "$TMP_JSON"

if [[ -z "$UNTAGGED_LINES" ]]; then
    log "No untagged digests found"
    exit 0
fi

SORTED_LINES="$(printf '%s\n' "$UNTAGGED_LINES" | sort -t $'\t' -k1,1n -k2,2)"

while IFS=$'\t' read -r priority image_ref media_type package_path; do
    [[ -n "$image_ref" ]] || continue
    printf '%s\t%s\t%s\n' "$package_path" "$media_type" "$image_ref"
done <<< "$SORTED_LINES"

if [[ "$EXECUTE" != "true" ]]; then
    step "Dry run complete"
    exit 0
fi

step "Deleting untagged digests"
while IFS=$'\t' read -r priority image_ref media_type package_path; do
    [[ -n "$image_ref" ]] || continue
    log "$image_ref"
    if ! gcloud artifacts docker images delete "$image_ref" --quiet; then
        log "skip: delete failed for $image_ref"
    fi
done <<< "$SORTED_LINES"

step "Done"
