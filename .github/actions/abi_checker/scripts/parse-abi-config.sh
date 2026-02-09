#!/usr/bin/env bash
# Generate an ABI manifest (TSV) from an ABI config YAML file.
#
# Usage:
#   parse_abi_config.sh \
#       --config <config.yml> \
#       --head-root <HEAD checkout> \
#       --base-root <BASE checkout> \
#       --out <abi_manifest.tsv>
#
# Output (TSV):
#   <name> <tab> <head_path> <tab> <base_path> <tab> <suppressions_csv> <tab> <extra_args_csv> <tab> <public_headers_csv>
#
# Requirements:
#   - bash 4+
#   - yq v4+

set -euo pipefail

CONFIG=""
HEAD_ROOT=""
BASE_ROOT=""
OUT=""

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)    CONFIG="${2:-}"; shift 2 ;;
    --head-root) HEAD_ROOT="${2:-}"; shift 2 ;;
    --base-root) BASE_ROOT="${2:-}"; shift 2 ;;
    --out)       OUT="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '1,200p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$CONFIG"    && -f "$CONFIG"    ]] || die "--config is required and must exist"
[[ -n "$HEAD_ROOT" && -d "$HEAD_ROOT" ]] || die "--head-root is required and must exist"
[[ -n "$BASE_ROOT" && -d "$BASE_ROOT" ]] || die "--base-root is required and must exist"
[[ -n "${OUT}" ]] || OUT="$(pwd)/abi_manifest.tsv"

if ! command -v yq >/dev/null 2>&1; then
  die "yq v4+ is required"
fi

# Prepare outputs
OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR"
: > "$OUT"

# Shell settings to support ** globs & avoid errors on no matches
shopt -s globstar nullglob

# return 0 if string contains any glob meta (*?[)
is_glob() {
  [[ "$1" == *\** || "$1" == *\?* || "$1" == *\[* ]]
}

# strip optional leading "./"
strip_dot_slash() {
  local s="$1"; printf '%s' "${s#./}"
}

# Join an array as CSV
join_csv() {
  local IFS=','; echo "$*"
}

# Append a full row (6 columns) to OUT
append_row() {
  local name="$1" head="$2" base="$3"
  # SUPPRESSIONS, EXTRA_ARGS, PUB_HEADERS are already arrays in scope
  local sup_csv extra_csv hdr_csv

  sup_csv="$(join_csv ${SUPPRESSIONS[@]+"${SUPPRESSIONS[@]}"})"
  extra_csv="$(join_csv ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})"
  hdr_csv="$(join_csv ${PUB_HEADERS[@]+"${PUB_HEADERS[@]}"})"

  # If any field is empty (after join), write "none" instead
  [[ -z "${sup_csv//[[:space:]]/}"  ]] && sup_csv="none"
  [[ -z "${extra_csv//[[:space:]]/}" ]] && extra_csv="none"
  [[ -z "${hdr_csv//[[:space:]]/}"  ]] && hdr_csv="none"

  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$name" "$head" "$base" "$sup_csv" "$extra_csv" "$hdr_csv" >> "$OUT"
}

# Resolve directory + include/exclude globs into file list (HEAD side)
# Returns: prints absolute file paths (one per line)
resolve_dir_with_filters() {
  local root_rel="$1"; shift
  local -a includes=(); local -a excludes=()
  # read includes until "--" separator, then excludes
  while [[ "$#" -gt 0 && "$1" != "--" ]]; do includes+=("$1"); shift; done
  [[ "$#" -gt 0 ]] && shift   # consume "--"
  while [[ "$#" -gt 0 ]]; do excludes+=("$1"); shift; done

  local root_abs="$HEAD_ROOT/$(strip_dot_slash "$root_rel")"
  [[ -d "$root_abs" ]] || return 0

  # Default include patterns if none provided: libraries commonly checked by ABI tools
  if [[ "${#includes[@]}" -eq 0 ]]; then
    includes=("**/*.so" "**/*.so.*")
  fi

  # Build candidate set
  local -A seen=()
  local pat f
  for pat in "${includes[@]}"; do
    for f in "$root_abs"/$pat; do
      [[ -f "$f" ]] && seen["$f"]=1
    done
  done

  # Apply excludes
  if [[ "${#excludes[@]}" -gt 0 ]]; then
    local -A drop=()
    for pat in "${excludes[@]}"; do
      for f in "$root_abs"/$pat; do
        [[ -f "$f" ]] && drop["$f"]=1
      done
    done
    for f in "${!drop[@]}"; do unset 'seen[$f]'; done
  fi

  # Print results
  for f in "${!seen[@]}"; do echo "$f"; done
}

LEN="$(yq -r '.abi_checks | length // 0' "$CONFIG")"
# If abi_checks is missing or empty, exit gracefully with an empty manifest.
if [[ "$LEN" -eq 0 ]]; then
  echo "::warning::No abi_checks in $CONFIG; manifest will be empty: $OUT"
  echo "ABI manifest written: $OUT"
  echo "Entries: 0"
  exit 0
fi

entries=0

for (( i=0; i<LEN; i++ )); do
  PATH_RAW="$(yq -r ".abi_checks[$i].path // \"\"" "$CONFIG")"
  [[ -n "$PATH_RAW" ]] || { echo "::warning::Entry #$i missing 'path' under .abi_checks; skipping"; continue; }

  # Optional attributes (parsed if present)
  mapfile -t INCLUDE_GLOBS < <(yq -r ".abi_checks[$i].include_globs // [] | .[]" "$CONFIG")
  mapfile -t EXCLUDE_GLOBS < <(yq -r ".abi_checks[$i].exclude_globs // [] | .[]" "$CONFIG")
  mapfile -t PUB_HEADERS  < <(yq -r ".abi_checks[$i].public_headers   // [] | .[]" "$CONFIG")
  mapfile -t SUPPRESSIONS < <(yq -r ".abi_checks[$i].suppressions     // [] | .[]" "$CONFIG")
  mapfile -t EXTRA_ARGS   < <(yq -r ".abi_checks[$i].extra_args       // [] | .[]" "$CONFIG")

  # HEAD and BASE candidates depending on kind (file, glob, dir)
  if is_glob "$PATH_RAW"; then
    # Glob in path: expand on HEAD; map to BASE via relative path
    for HEAD_ABS in "$HEAD_ROOT"/$(strip_dot_slash "$PATH_RAW"); do
      [[ -f "$HEAD_ABS" ]] || continue
      rel="${HEAD_ABS#"$HEAD_ROOT"/}"
      NAME="$rel"
      BASE_ABS="$BASE_ROOT/$rel"
      append_row "$NAME" "$HEAD_ABS" "$BASE_ABS"
      entries=$(( entries + 1 ))
    done

  elif [[ -d "$HEAD_ROOT/$(strip_dot_slash "$PATH_RAW")" ]]; then
    # Directory: resolve includes/excludes
    root_rel="$(strip_dot_slash "$PATH_RAW")"
    mapfile -t HEAD_LIST < <(resolve_dir_with_filters "$root_rel" "${INCLUDE_GLOBS[@]}" -- "${EXCLUDE_GLOBS[@]}")

    if [[ "${#HEAD_LIST[@]}" -eq 0 ]]; then
      echo "::notice::Entry #$i path '$PATH_RAW' matched no files under HEAD"
      continue
    fi

    for HEAD_ABS in "${HEAD_LIST[@]}"; do
      rel="${HEAD_ABS#"$HEAD_ROOT"/}"
      NAME="$rel"
      BASE_ABS="$BASE_ROOT/$rel"
      append_row "$NAME" "$HEAD_ABS" "$BASE_ABS"
      entries=$(( entries + 1 ))
    done

  else
    # Treat as single file path (relative to repo) or absolute
    if [[ "$PATH_RAW" == /* ]]; then
      HEAD_PATH="$PATH_RAW"
      BASE_PATH="$PATH_RAW"
      NAME="$(strip_dot_slash "$PATH_RAW")"
    else
      HEAD_PATH="$HEAD_ROOT/$(strip_dot_slash "$PATH_RAW")"
      BASE_PATH="$BASE_ROOT/$(strip_dot_slash "$PATH_RAW")"
      NAME="$(strip_dot_slash "$PATH_RAW")"
    fi
    append_row "$NAME" "$HEAD_PATH" "$BASE_PATH"
    entries=$(( entries + 1 ))
  fi
done

echo "ABI manifest written: $OUT"
echo "Entries: $entries"