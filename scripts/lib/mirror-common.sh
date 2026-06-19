#!/bin/bash

mirror_common_require_tools() {
    command -v crane >/dev/null || { echo "crane not found on PATH" >&2; return 1; }
    command -v gcloud >/dev/null || { echo "gcloud not found on PATH" >&2; return 1; }
    command -v python3 >/dev/null || { echo "python3 not found on PATH" >&2; return 1; }
}

mirror_common_auth_registry() {
    local location="$1"
    gcloud auth print-access-token \
        | crane auth login "${location}-docker.pkg.dev" -u oauth2accesstoken --password-stdin
}

mirror_common_normalize_service_name() {
    local service_name="$1"
    if [[ "$service_name" == services/* ]]; then
        printf '%s\n' "$service_name"
    else
        printf 'services/%s\n' "$service_name"
    fi
}

mirror_common_resolve_version_track() {
    local schema_file="$1"
    local version="$2"
    local track="$3"

    if [[ -z "$version" ]]; then
        version="$(python3 - "$schema_file" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    print(yaml.safe_load(f)["x-google-marketplace"]["publishedVersion"])
PY
)"
    fi

    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Version must be MAJOR.MINOR.PATCH: $version" >&2
        return 1
    fi

    if [[ -z "$track" ]]; then
        track="$(printf '%s\n' "$version" | cut -d. -f1-2)"
    fi

    printf '%s\t%s\n' "$version" "$track"
}

mirror_common_emit_copy() {
    local source_ref="$1"
    local target_ref="$2"
    local normalize_platform="$3"
    local platform="$4"

    if [[ "$normalize_platform" == "true" ]]; then
        echo "crane copy --platform ${platform} ${source_ref} ${target_ref}"
    else
        echo "crane copy ${source_ref} ${target_ref}"
    fi
}

mirror_common_copy() {
    local source_ref="$1"
    local target_ref="$2"
    local normalize_platform="$3"
    local platform="$4"

    if [[ "$normalize_platform" == "true" ]]; then
        crane copy --platform "$platform" "$source_ref" "$target_ref"
    else
        crane copy "$source_ref" "$target_ref"
    fi
}

mirror_common_annotate() {
    local image="$1"
    local annotation="$2"
    local normalize_platform="$3"
    local platform="$4"
    local dry_run="$5"

    local repo="${image%:*}"
    local tag="${image##*:}"
    local temp="${repo}:tmp-marketplace-${tag}-$$"

    if [[ "$dry_run" == "true" ]]; then
        mirror_common_emit_copy "$image" "$temp" "$normalize_platform" "$platform"
        echo "crane mutate --annotation ${annotation} -t ${temp} ${temp}"
        echo "crane copy ${temp} ${image}"
        echo "crane delete ${temp}"
        return 0
    fi

    mirror_common_copy "$image" "$temp" "$normalize_platform" "$platform" >/dev/null
    crane mutate --annotation "$annotation" -t "$temp" "$temp" >/dev/null
    crane copy "$temp" "$image" >/dev/null
    crane delete "$temp" >/dev/null
}

mirror_common_tag_marketplace() {
    local target_ref="$1"
    local target_repo="$2"
    local version="$3"
    local track="$4"
    local dry_run="$5"

    local current_tag="${target_ref##*:}"
    local release_tag

    for release_tag in "$version" "$track"; do
        if [[ "$release_tag" == "$current_tag" ]]; then
            continue
        fi
        if [[ "$dry_run" == "true" ]]; then
            echo "gcloud artifacts docker tags add ${target_ref} ${target_repo}:${release_tag} --quiet"
        else
            gcloud artifacts docker tags add "$target_ref" "${target_repo}:${release_tag}" --quiet
        fi
    done
}

mirror_common_update_values_field() {
    local values_file="$1"
    local values_path="$2"
    local field_name="$3"
    local field_value="$4"

    python3 - "$values_file" "$values_path" "$field_name" "$field_value" <<'PY'
import re
import sys
import yaml
from pathlib import Path

values_file, values_path, field_name, field_value = sys.argv[1:5]
path = Path(values_file)
data = yaml.safe_load(path.read_text())

cur = data
for part in values_path.split("."):
    if not isinstance(cur, dict) or part not in cur:
        raise SystemExit(f"path not found in {values_file}: {values_path}")
    cur = cur[part]

lines = path.read_text().splitlines()
parts = values_path.split(".")
search_start = 0
current_indent = -1
block_line = None

for part in parts:
    found = None
    for idx in range(search_start, len(lines)):
        line = lines[idx]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if current_indent == -1:
            if indent != 0:
                continue
        elif indent <= current_indent:
            break
        if re.match(rf'^\s*{re.escape(part)}:\s*$', line):
            found = (idx, indent)
            break
    if found is None:
        raise SystemExit(f"unable to locate block in {values_file}: {values_path}")
    block_line, current_indent = found
    search_start = block_line + 1

for idx in range(block_line + 1, len(lines)):
    line = lines[idx]
    stripped = line.strip()
    indent = len(line) - len(line.lstrip(" "))
    if stripped and not stripped.startswith("#") and indent <= current_indent:
        break

    match = re.match(rf'^(\s*{re.escape(field_name)}:\s*")([^"]*)(".*)$', line)
    if match:
        lines[idx] = f"{match.group(1)}{field_value}{match.group(3)}"
        path.write_text("\n".join(lines) + "\n")
        break
else:
    raise SystemExit(f"{field_name} field not found in block for {values_path}")
PY
}
