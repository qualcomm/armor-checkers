
#!/usr/bin/env bash
# Runs abidiff command for each pair listed in a TSV manifest and writes a Markdown summary.
# Expected TSV manifest format:
#   name    head_path    base_path    suppressions    extra_args    public_headers
# Usage:
#   run-abidiff.sh <manifest> <reports_dir> [policy]
# policy:
#   strict          - fail on any ABI change (changed or incompatible) or internal error
#   incompat-only   - fail only on incompatible changes or errors (default)


set -euo pipefail

manifest="${1:-abi_manifest.tsv}"
reports_dir="${2:-abidiff_reports}"
policy="${3:-incompat-only}"
stage_root="${4:-${ABI_STAGE_DIR:-${RUNNER_TEMP:-/tmp}/abi-stage}}"
mkdir -p "$stage_root"

cleanup_stage=1
trap 'if (( cleanup_stage )) && [[ -d "$stage_root" ]]; then rm -rf "$stage_root"; fi' EXIT

if [[ -z "${manifest}" || -z "${reports_dir}" ]]; then
  echo "::error::Usage: run-abidiff.sh <manifest> <reports_dir> [policy]"
  exit 2
fi

if [[ ! -s "$manifest" ]]; then
  echo "::warning::ABI manifest missing or empty: $manifest"
  exit 0
fi

mkdir -p "$reports_dir"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

{
  echo "## ABI Compatibility Report"
  echo ""
  echo "| Binary | Result | Notes |"
  echo "|-------:|:-------|:------|"
} >> "$SUMMARY"

total=0; ok=0; changed_review=0; changed_incompat=0; errs=0

# Normalize CRLF if any
if file "$manifest" | grep -qi 'CRLF'; then sed -i 's/\r$//' "$manifest"; fi

repo_root_from() {
  local full="$1" rel="$2"
  local r="${rel#./}"
  case "$full" in
    *"/$r") printf '%s\n' "${full%/$r}";;
    *) dirname "$full";;
  esac
}

meta_json="${reports_dir}/metadata.json"

# Collect rows as: "binary <TAB> compatibility"
declare -a META_ROWS=()

collect_binary() {
  local bin="$1" comp="$2"
  META_ROWS+=("$bin"$'\t'"$comp")
}

while IFS=$'\t' read -r name head_path base_path sup_csv extra_csv hdr_csv; do
  [[ -z "${name// }" ]] && continue
  [[ "${name:0:1}" == "#" ]] && continue
  total=$((total+1))
  
  safe_name="${name//\//__}"
  report_rel="${safe_name}.txt"
  out_file="${reports_dir}/${report_rel}"
  report_display="$(basename "$reports_dir")/${report_rel}"

  # Check presence of base/head simultaneously
  missing_base=0
  missing_head=0

  [[ ! -e "$base_path" ]] && missing_base=1
  [[ ! -e "$head_path" ]] && missing_head=1
  
  if (( missing_base || missing_head )); then
    errs=$((errs+1))
    # Build a concise notes string
    if   (( missing_base && missing_head )); then
      note="Base and Head files missing"
    elif (( missing_base )); then
      note="Base file missing"
    else
      note="Head file missing"
    fi
    echo "| \`${name}\` | ❌ Error | ${note} |" >> "$SUMMARY"
    echo "::error::${note} for ${name}" >> "$out_file"
    collect_binary "$name" "error"
    continue
  fi

  normalize_field() {
    local s="$1"
    [[ -z "$s" ]] && { echo ""; return; }
    local lc="${s,,}"
    [[ "$lc" == "none" ]] && { echo ""; return; }
    echo "$s"
  }

  sup_csv="$(normalize_field "${sup_csv:-}")"
  extra_csv="$(normalize_field "${extra_csv:-}")"
  hdr_csv="$(normalize_field "${hdr_csv:-}")"

  SUPPRS=(); EXTRA=(); HDRS=()
  [[ -n "$sup_csv"   && "$sup_csv"   != '""' ]] && IFS=',' read -r -a SUPPRS <<< "$sup_csv"
  [[ -n "$extra_csv" && "$extra_csv" != '""' ]] && IFS=',' read -r -a EXTRA  <<< "$extra_csv"
  [[ -n "$hdr_csv"   && "$hdr_csv"   != '""' ]] && IFS=',' read -r -a HDRS  <<< "$hdr_csv"

  # Compute repo roots for base/head based on name
  head_repo_root="$(repo_root_from "$head_path" "$name")"
  base_repo_root="$(repo_root_from "$base_path" "$name")"

  # Build abidiff argv
  abidiff_argv=()

  # Suppressions (resolve relative to HEAD repo root if not absolute)
  for s in "${SUPPRS[@]}"; do
    [[ -z "$s" ]] && continue
    if [[ "$s" = /* ]]; then
      abidiff_argv+=( "--suppressions" "$s" )
    else
      abidiff_argv+=( "--suppressions" "${head_repo_root}/${s#./}" )
    fi
  done

  # Extra args
  for e in "${EXTRA[@]}"; do
    [[ -z "$e" ]] && continue
    abidiff_argv+=( "$e" )
  done

  warn_to_out() {
    echo "::warning:: $*" >>"$out_file"
  }

  # Public headers -> accept dirs or files.
  # - If dir: use it directly (resolved under each repo root if relative).
  # - If file: stage into per-pair temp include dirs under $stage_root and pass those dirs.
  declare -A seen_base=() seen_head=()
  tmp_hdr_base=""   # "$stage_root/${safe_name}/base"
  tmp_hdr_head=""   # "$stage_root/${safe_name}/head"
  pair_stage_root="$stage_root/${safe_name}"

  # Track which header files we copied into temp dirs
  # files staged into "$tmp_hdr_base"
  copied_base=()
  # files staged into "$tmp_hdr_head"   
  copied_head=()

  ensure_tmp_dirs() {
    [[ -n "$tmp_hdr_base" && -n "$tmp_hdr_head" ]] && return 0
    tmp_hdr_base="$pair_stage_root/base"
    tmp_hdr_head="$pair_stage_root/head"
    mkdir -p "$tmp_hdr_base" "$tmp_hdr_head"
  }

  for h in "${HDRS[@]}"; do
    [[ -z "$h" ]] && continue
    # Normalize trailing slash for consistent checks
    h="${h%/}"
    # ABSOLUTE path
    if [[ "$h" = /* ]]; then
      if [[ -d "$h" ]]; then
        # Use the absolute dir for both sides
        seen_base["$h"]=1
        seen_head["$h"]=1
      elif [[ -f "$h" ]]; then
        # Single absolute header file: copy same file for both sides
        ensure_tmp_dirs
        if cp -f "$h" "$tmp_hdr_base/"; then
          copied_base+=( "$h -> $tmp_hdr_base/$(basename "$h")" )
        else
          warn_to_out "Missing absolute header (base copy): $h"
        fi
        if cp -f "$h" "$tmp_hdr_head/"; then
          copied_head+=( "$h -> $tmp_hdr_head/$(basename "$h")" )
        else
          warn_to_out "Missing absolute header (head copy): $h"
        fi
      else
        warn_to_out "Header path not found: $h"
      fi

    else
      # RELATIVE path -> resolve under each repo root
      base_rel="${base_repo_root}/${h#./}"
      head_rel="${head_repo_root}/${h#./}"

      if [[ -d "$base_rel" || -d "$head_rel" ]]; then
        [[ -d "$base_rel" ]] && seen_base["$base_rel"]=1 || warn_to_out "Header dir (base) missing: $base_rel"
        [[ -d "$head_rel" ]] && seen_head["$head_rel"]=1 || warn_to_out "Header dir (head) missing: $head_rel"

      else
        has_any=0
        ensure_tmp_dirs

        if [[ -f "$base_rel" ]]; then
          if cp -f "$base_rel" "$tmp_hdr_base/"; then
            copied_base+=( "$base_rel -> $tmp_hdr_base/$(basename "$base_rel")" )
            has_any=1
          else
            warn_to_out "Failed to copy header (base): $base_rel"
          fi
        else
          warn_to_out "Header file (base) missing: $base_rel"
        fi

        if [[ -f "$head_rel" ]]; then
          if cp -f "$head_rel" "$tmp_hdr_head/"; then
            copied_head+=( "$head_rel -> $tmp_hdr_head/$(basename "$head_rel")" )
            has_any=1
          else
            warn_to_out "Failed to copy header (head): $head_rel"
          fi
        else
          warn_to_out "Header file (head) missing: $head_rel"
        fi

        if (( has_any == 0 )); then
          warn_to_out "Header path not found on either side: $h (base=$base_rel, head=$head_rel)"
        fi
      fi
    fi
  done

  # Add discovered/constructed include dirs
  for d in "${!seen_base[@]}"; do abidiff_argv+=( "--headers-dir1" "$d" ); done
  for d in "${!seen_head[@]}"; do abidiff_argv+=( "--headers-dir2" "$d" ); done
  if [[ -n "$tmp_hdr_base" && -d "$tmp_hdr_base" ]]; then abidiff_argv+=( "--headers-dir1" "$tmp_hdr_base" ); fi
  if [[ -n "$tmp_hdr_head" && -d "$tmp_hdr_head" ]]; then abidiff_argv+=( "--headers-dir2" "$tmp_hdr_head" ); fi

  # Emit a "Header staging details" section into out_file (before the abidiff output)
  {
    echo "### Header staging details for ${name}"
    echo "headers-dir1 (base) used:"
    for d in "${!seen_base[@]}"; do echo "  - $d"; done
    [[ -n "$tmp_hdr_base" && -d "$tmp_hdr_base" ]] && echo "  - $tmp_hdr_base"
    echo
    echo "headers-dir2 (head) used:"
    for d in "${!seen_head[@]}"; do echo "  - $d"; done
    [[ -n "$tmp_hdr_head" && -d "$tmp_hdr_head" ]] && echo "  - $tmp_hdr_head"
    echo

    if (( ${#copied_base[@]} > 0 || ${#copied_head[@]} > 0 )); then
      echo "Files staged into temporary include dirs:"
      if (( ${#copied_base[@]} > 0 )); then
        echo "  Base copies:"
        for l in "${copied_base[@]}"; do echo "    - $l"; done
      fi
      if (( ${#copied_head[@]} > 0 )); then
        echo "  Head copies:"
        for l in "${copied_head[@]}"; do echo "    - $l"; done
      fi
      echo
    fi
  } >>"$out_file"

  {
    printf 'abidiff'
    printf ' %q' "${abidiff_argv[@]}" "$base_path" "$head_path"
    printf '\n\n'
  } >>"$out_file"

  set +e
  abidiff "${abidiff_argv[@]}" "$base_path" "$head_path" >>"$out_file" 2>&1
  rc=$?
  set -e

  # Decode rc bits
  ABIDIFF_ERROR=1
  ABIDIFF_USAGE_ERROR=2
  ABIDIFF_ABI_CHANGE=4
  ABIDIFF_ABI_INCOMPATIBLE_CHANGE=8

  has_error=$(( rc & ABIDIFF_ERROR ))
  has_usage=$(( rc & ABIDIFF_USAGE_ERROR ))
  has_change=$(( rc & ABIDIFF_ABI_CHANGE ))
  has_incompat=$(( rc & ABIDIFF_ABI_INCOMPATIBLE_CHANGE ))

  if (( rc == 0 )); then
    echo "No ABI differences detected." >>"$out_file"  
    ok=$((ok+1))
    echo "| \`${name}\` | ✅ Compatible | No ABI differences |" >> "$SUMMARY"
    collect_binary "$name" "compatible"
  
  elif (( has_error )); then
    errs=$((errs+1)); note="Internal error"; (( has_usage )) && note="Usage error"
    echo "::error::${note} (rc=${rc}) for ${name}" >>"$out_file"
    echo "| \`${name}\` | ❌ Error | ${note}; see \`$report_display\` |" >> "$SUMMARY"
    collect_binary "$name" "error"
  
  elif (( has_incompat )); then
    changed_incompat=$((changed_incompat+1))
    echo "::error::ABI incompatible changes in ${name} (rc=${rc})" >>"$out_file"
    echo "| \`${name}\` | ❌ Incompatible | see \`$report_display\` |" >> "$SUMMARY"
    collect_binary "$name" "incompatible"
  
  elif (( has_change )); then
    changed_review=$((changed_review+1))
    warn_to_out "ABI changes (review needed) in ${name} (rc=${rc})"
    echo "| \`${name}\` | ⚠️ ABI changed (review required) | see \`$report_display\` |" >> "$SUMMARY"
    collect_binary "$name" "ABI changed (review required)"

  else
    errs=$((errs+1))
    echo "::error::Unknown exit code ${rc} for ${name}" >>"$out_file"
    echo "| \`${name}\` | ❌ Error | Unknown rc=${rc}; see \`$report_display\` |" >> "$SUMMARY"
    collect_binary "$name" "error"
  fi
done < "$manifest"

{
  echo ""
  echo "**Totals**: ${total} checked → ✅ ${ok} compatible, ⚠️ ${changed_review} ABI changed (review required), ❌ ${changed_incompat} incompatible, ❗ ${errs} errors"
} >> "$SUMMARY"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "abi_total=${total}"
    echo "abi_ok=${ok}"
    echo "abi_changed=${changed_review}"
    echo "abi_incompatible=${changed_incompat}"
    echo "abi_errors=${errs}"
  } >> "$GITHUB_OUTPUT"
fi

result="pass"
case "${policy}" in
  strict)        (( errs>0 || changed_incompat>0 || changed_review>0 )) && result="fail" ;;
  incompat-only) (( errs>0 || changed_incompat>0 )) && result="fail" ;;
  *)             (( errs>0 || changed_incompat>0 )) && result="fail" ;;
esac

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "abi_result=${result}" >> "$GITHUB_OUTPUT"
fi

if [[ -f "$meta_json" ]]; then

  binaries_json=$(printf '%s\n' "${META_ROWS[@]}" |
    awk -F'\t' '
      BEGIN { print "[" }
      NR>1 { printf "," }
      {
        bin=$1
        comp=$2
        gsub(/"/, "\\\"", bin)
        gsub(/"/, "\\\"", comp)
        printf("{\"binary\":\"%s\",\"compatibility\":\"%s\"}", bin, comp)
      }
      END { print "]" }
    '
  )

  jq --argjson bins "$binaries_json" \
     '.binaries = $bins' \
     "$meta_json" > "${meta_json}.tmp" && mv "${meta_json}.tmp" "$meta_json"
fi