#!/usr/bin/env bash

# --- Resolve to real ELF (absolute); return empty if not found ---
real_elf() {
  local p="$1"
  if [[ -e "$p" ]]; then readlink -f "$p" || echo "$p"; else echo ""; fi
}

# --- Parse SONAME major (e.g., libX.so.3 -> 3); return empty if missing/unversioned ---
get_soname() {
  local lib="$1"
  local s=""
  s=$(objdump -p "$lib" 2>/dev/null | awk '/SONAME/{print $2}') || true
  if [[ -z "$s" ]]; then
    s=$(readelf -d "$lib" 2>/dev/null | awk '/SONAME/{gsub(/[\[\]]/, "", $NF); print $NF}') || true
  fi
  echo "$s"
}

# --- Extract SONAME from ELF; return empty if none ---
soname_major() {
  local s="$1"
  [[ "$s" =~ \.so\.([0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo ""
}

# --- Extract filename version triplet .so.M[.m[.p]] ---
file_triplet() {
  b="$(basename -- "$1")"
  local M="" m="" p=""
  if [[ "$b" =~ \.so\.([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]]; then
    M="${BASH_REMATCH[1]}"
    [[ -n "${BASH_REMATCH[3]:-}" ]] && m="${BASH_REMATCH[3]}"
    [[ -n "${BASH_REMATCH[5]:-}" ]] && p="${BASH_REMATCH[5]}"
  fi
  echo "$M $m $p"
}

# --- Format version for display ---
fmt_version_or_na() {
  local M="$1" m="$2" p="$3"

  # If no version fields at all → N/A
  if [[ -z "$M" && -z "$m" && -z "$p" ]]; then
    echo "N/A"
    return
  fi

  # If only MAJOR → return "M"
  if [[ -n "$M" && -z "$m" && -z "$p" ]]; then
    echo "$M"
    return
  fi

  # If MAJOR + MINOR → return "M.m"
  if [[ -n "$M" && -n "$m" && -z "$p" ]]; then
    echo "${M}.${m}"
    return
  fi

  # If full → return "M.m.p"
  echo "${M}.${m}.${p}"
}

# Append to reason cleanly with delimiter
append_reason() {
  local add="$1"
  if [[ -n "${reason:-}" ]]; then
    reason+=$'\n'"$add"
  else
    reason="$add"
  fi
}

# --- Full-triplet boolean (1 if all present else 0) ---
has_full_triplet() {
  [[ -n "$1" && -n "$2" && -n "$3" ]] && echo 1 || echo 0
}
# ============================================================
#   versioning_eval base head abi_category
# ============================================================
versioning_eval() {
  local base="$1"
  local head="$2"
  local abi_cat="$3"

  # --- resolve files ---
  local base_real head_real
  base_real="$(real_elf "$base")"
  head_real="$(real_elf "$head")"

  # --- extract SONAME major ---
  base_soname="$(get_soname "$base_real")"
  head_soname="$(get_soname "$head_real")"

  base_Mj="$(soname_major "$base_soname")"
  head_Mj="$(soname_major "$head_soname")"

  # Prefer real file for triplet parsing; fallback to original path if needed
  read base_M base_m base_p < <(file_triplet "$base")
  read head_M head_m head_p < <(file_triplet "$head")

  # check if both mj are equal
  if [[ -n base_Mj && -n base_M && base_Mj != base_M ]]; then
    
  fi
  # --- Fallback for missing SONAME major ---
  fell_back_major_base=0
  fell_back_major_head=0
  if [[ -z "$base_Mj" ]]; then
    if [[ -n "$base_M" ]]; then
      base_Mj="$base_M"
      fell_back_major_base=1
    fi
  fi

  if [[ -z "$head_Mj" ]]; then
    if [[ -n "$head_M" ]]; then
      head_Mj="$head_M"
      fell_back_major_head=1
    fi
  fi


  echo "base_M base_m base_p $base_Mj $base_m $base_p"
  echo "head_M head_m head_p $head_Mj $head_m $head_p"

  head_full=$(has_full_triplet "$head_Mj" "$head_m" "$head_p")
  base_full=$(has_full_triplet "$base_Mj" "$base_m" "$base_p")
  
  # Presence flags for minor/patch explicitly encoded in filename
  has_major_base=$([[ -n "$base_Mj" ]] && echo 1 || echo 0)
  has_major_head=$([[ -n "$head_Mj" ]] && echo 1 || echo 0)
  has_minor_base=$([[ -n "$base_m" ]] && echo 1 || echo 0)
  has_minor_head=$([[ -n "$head_m" ]] && echo 1 || echo 0)
  has_patch_base=$([[ -n "$base_p" ]] && echo 1 || echo 0)
  has_patch_head=$([[ -n "$head_p" ]] && echo 1 || echo 0)

  VERSION_BASE_VER="$(fmt_version_or_na "$base_Mj" "$base_m" "$base_p")"
  VERSION_HEAD_VER="$(fmt_version_or_na "$head_Mj" "$head_m" "$head_p")"
  # --- determine bumps ---
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

  # --- policy decision ---
  local result="WARN"
  local reason="(unset)"
  case "$abi_cat" in

    incompatible)
      # Already ensured: major_bumped check using SONAME majors (with fallback)
      if (( major_bumped )); then
        result="✅ PASS"; reason="Major version increased as required"
        # Enforce SemVer reset only if head has minor+patch explicitly
        if (( head_full )); then
          if [[ "$head_m" != "0" || "$head_p" != "0" ]]; then
            result="❌ FAIL"
            append_reason "SemVer: after Major increase, Minor and Patch must be 0 (got ${head_M}.${head_m}.${head_p})"
          fi
        else
          append_reason "SemVer reset not verifiable (head filename lacks Minor/Patch)"
        fi
      elif (( minor_bumped )); then
        result="❌&nbsp;FAIL"; reason="Minor version increased, incompatible ABI requires a major version increase"
      elif (( patch_bumped )); then
        result="❌&nbsp;FAIL"; reason="Patch version increased, incompatible ABI requires a major version increase"
      elif (( no_bump )); then
        result="❌&nbsp;FAIL"; reason="Incompatible ABI requires a Major version increase"
      elif (( regressed )); then
        result="❌&nbsp;FAIL"; reason="Version regressed vs base"
      fi
      ;;

    compatible-additive)
      # Require Major same
      if (( head_Mj != base_Mj )); then
        result="❌ FAIL"; reason="Major version increased; compatible ABI requires a Minor version increase"
      else
        # Require Minor++ only if both sides encode minor
        if (( has_minor_base && has_minor_head )); then
          if (( minor_bumped )); then
            result="✅ PASS"; reason="Minor version increased as required"
            # Enforce Patch reset only if head encodes patch
            if (( has_patch_head )) && [[ "$head_p" != "0" ]]; then
              result="❌ FAIL"; append_reason "SemVer: after Minor increase, Patch must be 0 (got ${head_M}.${head_m}.${head_p})"
            fi
          elif (( patch_bumped )); then
            result="❌&nbsp;FAIL"; reason="Patch version increased, compatible ABI requires a minor version increase"
          elif (( no_bump )); then
            result="❌&nbsp;FAIL"; reason="compatible ABI requires a Minor version increase"
          elif (( regressed )); then
            result="❌&nbsp;FAIL"; reason="Version regressed vs base"
          fi
        else
          # We cannot enforce Minor++ if team doesn't encode it → warn/annotate
          result="⚠️ WARN"; reason="Minor not present in filename; skipping Minor enforcement for additive ABI"
        fi
      fi
      
      ;;

    no-diff)
      # Must be no version change (you can relax to PASS on patch bump if you want)
      if (( major_bumped || minor_bumped )); then
        result="❌&nbsp;FAIL"; reason="ABI unchanged, Version changed"
      elif (( patch_bumped )); then
        result="✅&nbsp;PASS"; reason="Increasing only the patch number while there is no ABI change seems reasonable"
      elif (( no_bump )); then
        result="✅&nbsp;PASS"; reason="ABI unchange, version unchanged"
      elif (( regressed )); then
        result="❌&nbsp;FAIL"; reason="Version regressed vs base"
      fi
      ;;

    *)
      result="❌&nbsp;FAIL"; reason="Unknown ABI category"
      ;;
  esac

  if (( fell_back_major_base == 1 || fell_back_major_head == 1 )); then
    append_reason "(MAJOR version derived from filename(.so.M[.m[.p]]) due to missing SONAME)"
  fi

  # If both sides show no versioning (no SONAME MAJOR and no M/.m/.p), mark accordingly
	if [[ "$VERSION_BASE_VER" == "N/A" && "$VERSION_HEAD_VER" == "N/A" ]]; then
    result="WARN"
    reason="Missing binary versioning"
  fi
  # --- set globals for caller ---
  VERSION_BASE_SONAME="${base_soname:-N/A}"
  VERSION_HEAD_SONAME="${head_soname:-N/A}"
  VERSION_RESULT="$result"
  VERSION_REASON="$reason"

  # Optional TSV output:
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$VERSION_BASE_SONAME" \
    "$VERSION_HEAD_SONAME" \
    "$VERSION_BASE_VER" \
    "$VERSION_HEAD_VER" \
    "$VERSION_RESULT" \
    "$VERSION_REASON"
}

