#!/bin/bash
#
# check-ar-vulnerabilities.sh — Query Artifact Registry vulnerability
# occurrences for Docker images and fail when configured severities are present.
#
# Usage:
#   ./scripts/check-ar-vulnerabilities.sh [OPTIONS]
#
# Options:
#   --project      Artifact Registry project     (default: openenergysolutionsinc-public)
#   --location     Artifact Registry location    (default: us)
#   --repo         Artifact Registry repository  (default: oesinc)
#   --only         Comma-separated package paths to inspect
#                  (example: gms-api,one-line-app,curlimages/curl)
#   --limit        Max image digests to inspect
#   --occurrences-from
#                  Number of recent images to summarize occurrences for (default: 1000)
#   --fail-on      Fail when this severity or higher is present
#                  (CRITICAL, HIGH, MEDIUM, LOW, NONE; default: HIGH)
#   --output       Output format: table, markdown, json (default: table)
#   --all          Include images with no vulnerabilities in output
#   --help         Show this help

set -euo pipefail

PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
ONLY_PACKAGES=""
LIMIT=""
OCCURRENCES_FROM="1000"
FAIL_ON="HIGH"
OUTPUT="table"
INCLUDE_ALL=false

log()  { echo "  [check-ar-vulns] $*" >&2; }
step() { echo "" >&2; echo "==> $*" >&2; }
fail() { echo "[check-ar-vulns] ERROR: $*" >&2; exit 1; }

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
        --occurrences-from) OCCURRENCES_FROM="$2"; shift 2 ;;
        --fail-on) FAIL_ON="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
        --output) OUTPUT="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
        --all) INCLUDE_ALL=true; shift ;;
        --help) usage ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v gcloud >/dev/null || fail "gcloud not found on PATH"
command -v python3 >/dev/null || fail "python3 not found on PATH"

case "$FAIL_ON" in
    CRITICAL|HIGH|MEDIUM|LOW|NONE) ;;
    *) fail "--fail-on must be one of CRITICAL, HIGH, MEDIUM, LOW, NONE" ;;
esac

case "$OUTPUT" in
    table|markdown|json) ;;
    *) fail "--output must be one of table, markdown, json" ;;
esac

REGISTRY="${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}"
log "registry: $REGISTRY"
log "fail-on:  $FAIL_ON"
log "output:   $OUTPUT"
if [[ -n "$ONLY_PACKAGES" ]]; then
    log "only:     $ONLY_PACKAGES"
fi
if [[ -n "$LIMIT" ]]; then
    log "limit:    $LIMIT"
fi

step "Querying Artifact Registry vulnerability occurrences"
LIST_ARGS=(
    "$REGISTRY"
    "--include-tags"
    "--show-occurrences"
    "--occurrence-filter=kind=\"VULNERABILITY\""
    "--show-occurrences-from=$OCCURRENCES_FROM"
    "--format=json"
)
if [[ -n "$LIMIT" ]]; then
    LIST_ARGS+=("--limit=$LIMIT")
fi

TMP_JSON="$(mktemp)"
gcloud artifacts docker images list "${LIST_ARGS[@]}" > "$TMP_JSON" 2>/dev/null

set +e
python3 - "$REGISTRY" "$ONLY_PACKAGES" "$FAIL_ON" "$OUTPUT" "$INCLUDE_ALL" "$TMP_JSON" <<'PY'
import json
import sys

registry, only_packages, fail_on, output, include_all, json_path = sys.argv[1:7]
allowed = set(filter(None, only_packages.split(",")))
include_all = include_all == "true"
severity_order = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
severity_rank = {name: idx for idx, name in enumerate(severity_order)}

with open(json_path) as f:
    items = json.load(f)

def package_path(package):
    prefix = registry + "/"
    return package[len(prefix):] if package.startswith(prefix) else package

def vuln_counts(item):
    counts = {severity: 0 for severity in severity_order}

    direct_counts = item.get("vuln_counts")
    if isinstance(direct_counts, dict):
        for severity in severity_order:
            counts[severity] = int(direct_counts.get(severity, 0) or 0)
        return counts

    buckets = item.get("PACKAGE_VULNERABILITY")
    if isinstance(buckets, dict):
        for severity in severity_order:
            value = buckets.get(severity, [])
            counts[severity] = len(value) if isinstance(value, list) else 0

    return counts

rows = []
for item in items:
    package = item.get("package", "")
    path = package_path(package)
    if allowed and path not in allowed:
        continue

    counts = vuln_counts(item)
    total = sum(counts.values())
    if total == 0 and not include_all:
        continue

    rows.append({
        "package": path,
        "version": item.get("version", ""),
        "tags": item.get("tags") or [],
        "critical": counts["CRITICAL"],
        "high": counts["HIGH"],
        "medium": counts["MEDIUM"],
        "low": counts["LOW"],
        "total": total,
    })

def failing(row):
    if fail_on == "NONE":
        return False
    threshold_index = severity_rank[fail_on]
    return any(row[severity.lower()] > 0 for severity in severity_order[:threshold_index + 1])

has_failure = any(failing(row) for row in rows)
rows.sort(key=lambda row: (
    -row["critical"],
    -row["high"],
    -row["medium"],
    -row["low"],
    row["package"],
    row["version"],
))

if output == "json":
    print(json.dumps({
        "registry": registry,
        "fail_on": fail_on,
        "failed": has_failure,
        "images": rows,
    }, indent=2))
elif output == "markdown":
    print("| Package | Tags | Digest | Critical | High | Medium | Low | Total |")
    print("|---|---|---|---:|---:|---:|---:|---:|")
    for row in rows:
        tags = ", ".join(row["tags"])
        print(
            f"| {row['package']} | {tags} | {row['version']} | "
            f"{row['critical']} | {row['high']} | {row['medium']} | {row['low']} | {row['total']} |"
        )
else:
    header = ("PACKAGE", "TAGS", "DIGEST", "CRIT", "HIGH", "MED", "LOW", "TOTAL")
    data = []
    for row in rows:
        data.append((
            row["package"],
            ",".join(row["tags"]),
            row["version"],
            str(row["critical"]),
            str(row["high"]),
            str(row["medium"]),
            str(row["low"]),
            str(row["total"]),
        ))
    widths = [len(value) for value in header]
    for row in data:
        widths = [max(width, len(value)) for width, value in zip(widths, row)]
    fmt = "  ".join("{:<" + str(width) + "}" for width in widths)
    print(fmt.format(*header))
    print(fmt.format(*("-" * width for width in widths)))
    for row in data:
        print(fmt.format(*row))

sys.exit(2 if has_failure else 0)
PY
STATUS=$?
set -e
rm -f "$TMP_JSON"

if [[ "$STATUS" -eq 2 ]]; then
    fail "Vulnerabilities found at or above ${FAIL_ON}"
fi
exit "$STATUS"
