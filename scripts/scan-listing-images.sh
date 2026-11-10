#!/bin/bash
#
# scan-listing-images.sh — Report Artifact Registry vulnerability findings for
# exactly the images the Marketplace listing ships.
#
# Unlike check-ar-vulnerabilities.sh (which walks every digest in the
# repository), this reads each image declared in schema.yaml, resolves the
# pinned digest from chart/values.yaml, and asks Artifact Registry's scanner
# (the same one Google's Marketplace review uses) about that digest only. The
# deployer image is included by tag (default: schema publishedVersion).
#
# Usage:
#   ./scripts/scan-listing-images.sh [OPTIONS]
#
# Options:
#   --project      Artifact Registry project     (default: openenergysolutionsinc-public)
#   --location     Artifact Registry location    (default: us)
#   --repo         Artifact Registry repository  (default: oesinc)
#   --schema       Marketplace schema file       (default: schema.yaml)
#   --values       Helm values file              (default: chart/values.yaml)
#   --deployer-tag Deployer tag to scan          (default: schema publishedVersion;
#                  pass "none" to skip the deployer)
#   --fail-on      Exit 1 when a finding at this severity or higher exists
#                  (CRITICAL, HIGH, MEDIUM, LOW, NONE; default: HIGH)
#   --output       table, markdown or json        (default: table)
#   --help         Show this help
#
# Requires gcloud (authenticated with Artifact Registry read and Container
# Analysis occurrence read access) and python3 with PyYAML.
set -euo pipefail

PROJECT="openenergysolutionsinc-public"
LOCATION="us"
REPO="oesinc"
SCHEMA_FILE="schema.yaml"
VALUES_FILE="chart/values.yaml"
DEPLOYER_TAG=""
FAIL_ON="HIGH"
OUTPUT="table"

log()  { echo "  [scan-listing] $*" >&2; }
step() { echo "" >&2; echo "==> $*" >&2; }
fail() { echo "[scan-listing] ERROR: $*" >&2; exit 2; }

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
        --deployer-tag) DEPLOYER_TAG="$2"; shift 2 ;;
        --fail-on) FAIL_ON="$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
        --output) OUTPUT="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
        --help) usage ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

command -v gcloud >/dev/null || fail "gcloud not found on PATH"
command -v python3 >/dev/null || fail "python3 not found on PATH"
[[ -f "$SCHEMA_FILE" ]] || fail "Schema file not found: $SCHEMA_FILE"
[[ -f "$VALUES_FILE" ]] || fail "Values file not found: $VALUES_FILE"
case "$FAIL_ON" in CRITICAL|HIGH|MEDIUM|LOW|NONE) ;; *) fail "--fail-on must be one of CRITICAL, HIGH, MEDIUM, LOW, NONE" ;; esac
case "$OUTPUT" in table|markdown|json) ;; *) fail "--output must be one of table, markdown, json" ;; esac

REGISTRY="${LOCATION}-docker.pkg.dev/${PROJECT}/${REPO}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

step "Resolving listing images from ${SCHEMA_FILE} and ${VALUES_FILE}"
python3 - "$SCHEMA_FILE" "$VALUES_FILE" "$DEPLOYER_TAG" > "$WORK/refs.txt" <<'PY'
import sys, yaml
schema_path, values_path, deployer_tag = sys.argv[1:4]
schema = yaml.safe_load(open(schema_path))["x-google-marketplace"]
images = yaml.safe_load(open(values_path))["global"]["images"]
for decl in schema["images"].values():
    for prop in decl["properties"]:
        if prop.endswith(".repository"):
            entry = images[prop.split(".")[2]]
            if not entry.get("digest"):
                sys.exit(f"no digest pinned for {entry['repository']} in {values_path}")
            print(entry["repository"], f"@{entry['digest']}")
tag = deployer_tag or schema["publishedVersion"]
if tag != "none":
    print("deployer", f":{tag}")
PY
log "registry: ${REGISTRY}"
log "images:   $(wc -l < "$WORK/refs.txt")"

step "Querying Artifact Registry vulnerability scans"
i=0
while read -r repo ref; do
    i=$((i + 1))
    if ! gcloud artifacts docker images describe "${REGISTRY}/${repo}${ref}" \
            --project="$PROJECT" --show-package-vulnerability --format=json \
            > "$WORK/$i.json" 2> "$WORK/$i.err"; then
        cat "$WORK/$i.err" >&2
        fail "could not describe ${REGISTRY}/${repo}${ref}"
    fi
    echo "${repo} ${ref} $WORK/$i.json" >> "$WORK/index.txt"
done < "$WORK/refs.txt"

python3 - "$WORK/index.txt" "$FAIL_ON" "$OUTPUT" <<'PY'
import json, sys
index_path, fail_on, output = sys.argv[1:4]
order = ["CRITICAL", "HIGH", "MEDIUM", "LOW"]
rank = {s: i for i, s in enumerate(order)}

findings, summary = [], []
for line in open(index_path):
    repo, ref, path = line.split()
    data = json.load(open(path))
    status = ((data.get("discovery_summary") or {}).get("discovery") or [{}])[0] \
        .get("discovery", {}).get("analysisStatus", "UNKNOWN")
    vulns = (data.get("package_vulnerability_summary") or {}).get("vulnerabilities", {})
    counts = {s: len(vulns.get(s, [])) for s in order}
    summary.append({"image": repo, "ref": ref, "scan": status, **counts})
    for sev in order:
        for occ in vulns.get(sev, []):
            v = occ["vulnerability"]
            issue = (v.get("packageIssue") or [{}])[0]
            findings.append({
                "image": repo,
                "ref": ref,
                "severity": sev,
                "id": occ["noteName"].rsplit("/", 1)[-1],
                "package": issue.get("affectedPackage", ""),
                "installed": (issue.get("affectedVersion") or {}).get("fullName", ""),
                "fixed": (issue.get("fixedVersion") or {}).get("fullName", ""),
                "fix_available": bool(v.get("fixAvailable")),
                "path": ((issue.get("fileLocation") or [{}])[0]).get("filePath", ""),
            })

findings.sort(key=lambda f: (rank[f["severity"]], f["image"], f["id"]))
threshold = len(order) if fail_on == "NONE" else rank[fail_on]
failing = [f for f in findings if rank[f["severity"]] <= threshold]
not_scanned = [s for s in summary if s["scan"] != "FINISHED_SUCCESS"]

if output == "json":
    print(json.dumps({"fail_on": fail_on, "images": summary, "findings": findings}, indent=2))
else:
    md = output == "markdown"
    if md:
        print(f"## Marketplace listing image scan\n")
        print(f"{len(summary)} images scanned; {len(failing)} finding(s) at {fail_on} or higher.\n")
        if failing:
            print("| Severity | CVE | Image | Package | Installed | Fixed | Fix available | Path |")
            print("|---|---|---|---|---|---|---|---|")
            for f in failing:
                print(f"| {f['severity']} | {f['id']} | {f['image']} | {f['package']} | {f['installed']} "
                      f"| {f['fixed'] or '-'} | {'yes' if f['fix_available'] else 'no'} | {f['path']} |")
        if not_scanned:
            print("\nNot fully scanned: " + ", ".join(f"{s['image']} ({s['scan']})" for s in not_scanned))
    else:
        print(f"{'SEV':<9} {'CVE':<22} {'IMAGE':<28} {'PACKAGE':<28} {'INSTALLED':<22} {'FIXED':<16} FIX")
        for f in failing:
            print(f"{f['severity']:<9} {f['id']:<22} {f['image']:<28} {f['package'][:28]:<28} "
                  f"{f['installed'][:22]:<22} {(f['fixed'] or '-')[:16]:<16} {'yes' if f['fix_available'] else 'no'}")
        print(f"\n{len(summary)} images scanned; {len(failing)} finding(s) at {fail_on} or higher.")
        for s in not_scanned:
            print(f"not fully scanned: {s['image']} ({s['scan']})")

sys.exit(1 if failing and fail_on != "NONE" else 0)
PY
