#!/bin/bash
#
# mirror-images.sh — Copy every container image declared in the chart's
# global.images map from one Artifact Registry to another.
#
# For each image it builds the source reference as <source>/<repository> and
# the destination as <dest>/<repository>, then runs `crane copy`. When a digest
# is pinned in values.yaml the copy is done by digest (immutable) and the
# tag is applied at the destination; otherwise the copy is done by tag.
# crane preserves manifests and all platforms, so the destination ends up with
# both the same digest and the same tag as the source.
#
# Usage:
#   ./scripts/mirror-images.sh --source REGISTRY --dest REGISTRY [OPTIONS]
#
# Options:
#   --source   Source Artifact Registry root  (required) e.g. us-docker.pkg.dev/PROJ/REPO
#   --dest     Destination Artifact Registry root (required)
#   --values   Chart values file to read images from (default: chart/values.yaml)
#   --match    Only mirror images whose repository contains this substring
#   --by-tag   Copy by tag even when a digest is pinned (default: by digest)
#   --dry-run  Print the crane copy commands without executing them
#   --help     Show this help
#
# Both registries are assumed to be GCP Artifact Registry; crane is logged in
# to each unique *-docker.pkg.dev host with a gcloud access token. The
# <repository> path is mirrored verbatim, including any registry host or
# library prefix (e.g. quay.io/keycloak/keycloak).
#
# Example:
#   ./scripts/mirror-images.sh \
#     --source us-docker.pkg.dev/openenergysolutionsinc-public/oesinc \
#     --dest   europe-docker.pkg.dev/customer-project/opendso
#
# Prerequisites:
#   gcloud (authenticated), crane, yq (v4)

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SOURCE="us-central1-docker.pkg.dev/opendso-491115/oesinc"
DEST="us-docker.pkg.dev/openenergysolutionsinc-public/oesinc"
VALUES="chart/values.yaml"
MATCH=""
BY_TAG=false
DRY_RUN=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "  [mirror] $*"; }
step() { echo ""; echo "==> $*"; }
fail() { echo "[mirror] ERROR: $*" >&2; exit 1; }

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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)  SOURCE="$2"; shift 2 ;;
        --dest)    DEST="$2";   shift 2 ;;
        --values)  VALUES="$2"; shift 2 ;;
        --match)   MATCH="$2";  shift 2 ;;
        --by-tag)  BY_TAG=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help)    usage ;;
        *)         fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v crane >/dev/null || fail "crane not found on PATH; install github.com/google/go-containerregistry/cmd/crane"
command -v yq    >/dev/null || fail "yq (v4) not found on PATH"
[[ "$DRY_RUN" == "true" ]] || command -v gcloud >/dev/null || fail "gcloud not found on PATH"

[[ -n "$SOURCE" ]] || fail "--source is required (try --help)"
[[ -n "$DEST"   ]] || fail "--dest is required (try --help)"
[[ -f "$VALUES" ]] || fail "Values file not found: $VALUES"

# Strip any trailing slash from registry roots.
SOURCE="${SOURCE%/}"
DEST="${DEST%/}"

# ---------------------------------------------------------------------------
# Authenticate crane to each unique registry host
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" != "true" ]]; then
    step "Authenticating crane to Artifact Registry hosts"
    TOKEN=$(gcloud auth print-access-token)
    for host in $(printf '%s\n%s\n' "${SOURCE%%/*}" "${DEST%%/*}" | sort -u); do
        log "login $host"
        echo "$TOKEN" | crane auth login "$host" -u oauth2accesstoken --password-stdin
    done
fi

# ---------------------------------------------------------------------------
# Mirror each image
# ---------------------------------------------------------------------------
step "Mirroring images from $SOURCE to $DEST"

total=0
copied=0
skipped=0
failed=0

while IFS=$'\t' read -r name repository tag digest; do
    [[ -n "$repository" ]] || continue
    if [[ -n "$MATCH" && "$repository" != *"$MATCH"* ]]; then
        continue
    fi
    total=$((total + 1))

    if [[ -n "$digest" && "$BY_TAG" != "true" ]]; then
        src="${SOURCE}/${repository}@${digest}"
    else
        src="${SOURCE}/${repository}:${tag}"
    fi
    dst="${DEST}/${repository}:${tag}"

    log "${name}: ${src} -> ${dst}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "      crane copy \"$src\" \"$dst\""
        skipped=$((skipped + 1))
        continue
    fi

    if crane copy "$src" "$dst"; then
        copied=$((copied + 1))
    else
        echo "[mirror] FAILED: $name ($src)" >&2
        failed=$((failed + 1))
    fi
done < <(yq e '.global.images | to_entries | .[] | [.key, .value.repository, .value.tag, (.value.digest // "")] | @tsv' "$VALUES")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Done"
if [[ "$DRY_RUN" == "true" ]]; then
    log "$total image(s) would be mirrored (dry run)"
else
    log "$total selected, $copied copied, $failed failed"
fi
[[ "$failed" -eq 0 ]] || fail "$failed image(s) failed to mirror"
