#!/usr/bin/env bash

# --- Resolve to real ELF (absolute); return empty if not found ---
real_elf() {
  local p="$1"
  if [[ -e "$p" ]]; then readlink -f "$p" || echo "$p"; else echo ""; fi
}

# --- Extract SONAME string from ELF (DT_SONAME), return empty if none ---
get_soname() {
  local lib="$1"
  local s=""
  s=$(objdump -p "$lib" 2>/dev/null | awk '/SONAME/{print $2}') || true
  if [[ -z "$s" ]]; then
    s=$(readelf -d "$lib" 2>/dev/null | awk '/SONAME/{gsub(/[\[\]]/, "", $NF); print $NF}') || true
  fi
  echo "$s"
}

# --- Parse SONAME major (e.g., libX.so.3 -> 3); return empty if missing/unversioned ---
soname_major() {
  local s="$1"
  [[ $s =~ \.so\.([0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

# --- Extract filename version triplet .so.M[.m[.p]] ---
file_triplet() {
  local b; b="$(basename -- "$1")"
  local M="" m="" p=""
  if [[ $b =~ \.so\.([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]]; then
    M="${BASH_REMATCH[1]}"
    m="${BASH_REMATCH[3]:-}"
    p="${BASH_REMATCH[5]:-}"
  fi
  printf '%s %s %s\n' "$M" "$m" "$p"
}

# --- Format version for display: Not Available | M | M.m | M.m.p ---
fmt_version_or_na() {
  local M="$1" m="$2" p="$3"
  if [[ -z "$M" && -z "$m" && -z "$p" ]]; then
    echo "Not Available"
  elif [[ -n "$M" && -z "$m" && -z "$p" ]]; then
    echo "$M"
  elif [[ -n "$M" && -n "$m" && -z "$p" ]]; then
    echo "${M}.${m}"
  else
    echo "${M}.${m}.${p}"
  fi
}

# Append to reason cleanly with delimiter (newline)
append_reason() {
  local add="$1"
  if [[ -n "${reason:-}" ]]; then
    reason+=$'\n'"$add"
  else
    reason="$add"
  fi
}

# Full-triplet boolean (1 if all present else 0)
has_full_triplet() {
  [[ -n "$1" && -n "$2" && -n "$3" ]] && echo 1 || echo 0
}

# ============================================================
#   versioning_eval base head abi_category
#   - base/head: paths (prefer resolved real ELF for parsing)
#   - abi_category: incompatible | compatible-additive | no-diff
# ============================================================
versioning_eval() {
  local base="$1"
  local head="$2"
  local abi_cat="$3"

  # --- Resolve real files ---
  local base_real head_real
  base_real="$(real_elf "$base")"
  head_real="$(real_elf "$head")"

  # --- SONAME + SONAME MAJOR (authoritative for ABI MAJOR) ---
  base_soname="$(get_soname "$base_real")"
  head_soname="$(get_soname "$head_real")"
  base_Mj="$(soname_major "$base_soname")"
  head_Mj="$(soname_major "$head_soname")"

  # Presence of SONAME (used in fallback/enforcement rules)
  has_soname_base=$([[ -n "$base_soname" ]] && echo 1 || echo 0)
  has_soname_head=$([[ -n "$head_soname" ]] && echo 1 || echo 0)

  # --- Filename triplet from the resolved real file (M.m.p) ---
  read base_M base_m base_p < <(file_triplet "$base_real")
  read head_M head_m head_p < <(file_triplet "$head_real")

  # --- Fallback for missing SONAME MAJOR: derive from filename M with annotation ---
  fell_back_major_base=0
  fell_back_major_head=0
  if [[ -z "$base_Mj" && -n "$base_M" ]]; then
    base_Mj="$base_M"
    fell_back_major_base=1
  fi
  if [[ -z "$head_Mj" && -n "$head_M" ]]; then
    head_Mj="$head_M"
    fell_back_major_head=1
  fi

  # --- Detect filename-M vs SONAME-M mismatches (for annotation & enforcement gating) ---
  base_M_mismatch=0
  head_M_mismatch=0
  if [[ $has_soname_base -eq 1 && -n "$base_M" && "$base_Mj" != "$base_M" ]]; then
    base_M_mismatch=1
    append_reason "Base: filename-M (${base_M}) ≠ SONAME-M (${base_Mj}) — using SONAME"
  fi
  if [[ $has_soname_head -eq 1 && -n "$head_M" && "$head_Mj" != "$head_M" ]]; then
    head_M_mismatch=1
    append_reason "Head: filename-M (${head_M}) ≠ SONAME-M (${head_Mj}) — using SONAME"
  fi

  # Head alignment for SemVer reset in incompatible:
  # needs head's filename M aligned with SONAME M AND head encodes both m/p
  aligned_head_for_reset=$(
    [[ -n "$head_Mj" && -n "$head_M" && "$head_Mj" == "$head_M" && -n "$head_m" && -n "$head_p" ]] && echo 1 || echo 0
  )
  # --- Decide if we can enforce MINOR/PATCH (SONAME present & aligned) ---
  can_enforce_minor=$([[ -n "$base_m" && -n "$head_m" && $base_M_mismatch -eq 0 && $head_M_mismatch -eq 0 ]] && echo 1 || echo 0)
  can_enforce_patch=$([[ -n "$base_p" && -n "$head_p" && $base_M_mismatch -eq 0 && $head_M_mismatch -eq 0 ]] && echo 1 || echo 0)

  # --- Fallback-only enforcement for m/p: SONAME missing on either side, both filename-M present and equal ---
  fallback_can_enforce_minor=$(
    [[ $has_soname_base -eq 0 || $has_soname_head -eq 0 ]] &&
    [[ -n "$base_M" && -n "$head_M" && "$base_M" == "$head_M" && -n "$base_m" && -n "$head_m" ]] && echo 1 || echo 0
  )
  fallback_can_enforce_patch=$(
    [[ $has_soname_base -eq 0 || $has_soname_head -eq 0 ]] &&
    [[ -n "$base_M" && -n "$head_M" && "$base_M" == "$head_M" && -n "$base_p" && -n "$head_p" ]] && echo 1 || echo 0
  )

  # --- Display version: SONAME M + m/p only if aligned (else just M); fallback to filename-only if SONAME missing ---
  version_display() {
    local Mj="$1" Mf="$2" m="$3" p="$4"
    if [[ -z "$Mj" ]]; then
      fmt_version_or_na "$Mf" "$m" "$p"
    else
      if [[ -n "$Mf" && "$Mf" == "$Mj" ]]; then
        fmt_version_or_na "$Mj" "$m" "$p"
      else
        echo "$Mj"
      fi
    fi
  }
  VERSION_BASE_VER="$(version_display "$base_Mj" "$base_M" "$base_m" "$base_p")"
  VERSION_HEAD_VER="$(version_display "$head_Mj" "$head_M" "$head_m" "$head_p")"

  # --- Numeric-safe compares for bump detection (use SONAME MAJOR for all major math) ---
    major_bumped=0 minor_bumped=0 patch_bumped=0 no_bump=0 regressed=0

  if (( head_Mj > base_Mj )); then
    major_bumped=1
  elif (( head_Mj < base_Mj )); then
    regressed=1
  else
    if (( head_m > base_m )); then
      minor_bumped=1
    elif (( head_m < base_m )); then
      regressed=1
    else
      if (( head_p > base_p )); then
        patch_bumped=1
      elif (( head_p < base_p )); then
        regressed=1
      else
        no_bump=1
      fi
    fi
  fi

  # --- Policy evaluation ---
  local result="WARN"
  local reason=""

  case "$abi_cat" in

    incompatible)
      # If SONAME is missing on either side, do not rely on fallback for gating -> FAIL
      if (( has_soname_base == 0 || has_soname_head == 0 )); then
        result="FAIL"; reason="SONAME missing; cannot enforce Major version increase for ABI break"
      else
        # Must be Major↑ (SONAME MAJOR)
        if (( major_bumped )); then
          result="PASS (Blocked for maintainer review)"; reason="Major version increased as required for an incompatible ABI"
          if (( aligned_head_for_reset )); then
            # SemVer reset only if head has full filename triplet (we don't need M alignment here for display check)
            if [[ "$head_m" != "0" || "$head_p" != "0" ]]; then
              result="FAIL"
              append_reason "SemVer: after Major version increase, Minor and Patch must be 0 (got ${head_M}.${head_m}.${head_p})"
            fi
          else
            result="WARN"
            append_reason "SemVer reset not verifiable(missing minor/patch version)"
          fi
        elif (( minor_bumped )); then
          result="FAIL"; reason="Minor version increased, incompatible ABI requires a major version increase"
        elif (( patch_bumped )); then
          result="FAIL"; reason="Patch version increased, incompatible ABI requires a major version increase"
        elif (( no_bump )); then
          result="FAIL"; reason="Incompatible ABI requires a Major version increase"
        elif (( regressed )); then
          result="FAIL"; reason="Version regressed vs base"
        fi
      fi
      ;;

    compatible-additive)
      # Must keep Major same (SONAME MAJOR)
      if (( head_Mj != base_Mj )); then
        result="FAIL"; reason=" Major version increase not allowed; compatible ABI requires a Minor version increase"
      else
        if (( can_enforce_minor || fallback_can_enforce_minor )); then
          if (( minor_bumped )); then
            result="PASS"; reason="Minor version increased as required for compatible ABI"
            # After Minor↑, if patch exists enforce reset to 0
            if [[ -n "$head_p" && "$head_p" != "0" ]]; then
              result="FAIL"
              append_reason "SemVer: after Minor version increase, Patch must be 0 (got ${head_M}.${head_m}.${head_p})"
            fi
          elif (( patch_bumped )); then
            result="FAIL"; reason="Patch version increase not allowed, compatible ABI requires a minor version increase"
          elif (( no_bump )); then
            result="FAIL"; reason="compatible ABI requires a Minor version increase"
          elif (( regressed )); then
            result="FAIL"; reason="Version regressed vs base"
          else
            result="FAIL"; reason="Minor not increased for additive change"
          fi
        else
          result="WARN"; reason="Minor not enforceable (missing SONAME or M mismatch)"
        fi
      fi
      ;;

    no-diff)
      if (( major_bumped || minor_bumped )); then
        result="FAIL"; reason="ABI unchanged → Major/Minor version bump not allowed"
      elif (( patch_bumped )); then
        result="PASS"; reason="Increasing only the patch number while there is no ABI change seems reasonable"
      elif (( no_bump )); then
        result="PASS"; reason="No ABI differences, version unchanged"
      elif (( regressed )); then
        result="FAIL"; reason="Version regressed vs base"
      fi
      ;;

    *)
      result="FAIL"; reason="Unknown ABI category"
      ;;
  esac

  # Annotate SONAME fallback
  if (( fell_back_major_base || fell_back_major_head )); then
    append_reason "MAJOR from filename due to missing SONAME"
  fi

  # If both sides show no version encoding at all
  if [[ "$VERSION_BASE_VER" == "Not Available" && "$VERSION_HEAD_VER" == "Not Available" ]]; then
    result="WARN"
    reason="Missing binary versioning"
  fi

  # --- Export results ---
#   VERSION_BASE_SONAME="${base_soname:-Not Available}"
#   VERSION_HEAD_SONAME="${head_soname:-Not Available}"
  VERSION_RESULT="$result"
  VERSION_REASON="$reason"

  # Optional TSV line for callers that capture stdout
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$VERSION_BASE_VER" \
    "$VERSION_HEAD_VER" \
    "$VERSION_RESULT" \
    "$VERSION_REASON"
}