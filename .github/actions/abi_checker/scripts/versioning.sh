#!/usr/bin/env bash

real_elf() {
  local p="$1"
  if [[ -e "$p" ]]; then readlink -f "$p" || echo "$p"; else echo ""; fi
}

get_soname() {
  local lib="$1"
  local s=""
  s=$(objdump -p "$lib" 2>/dev/null | awk '/SONAME/{print $2}') || true
  if [[ -z "$s" ]]; then
    s=$(readelf -d "$lib" 2>/dev/null | awk '/SONAME/{gsub(/[\[\]]/, "", $NF); print $NF}') || true
  fi
  echo "$s"
}

soname_major() {
  local s="$1"
  [[ "$s" =~ \.so\.([0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo "0"
}

file_triplet() {
  local b; b="$(basename -- "$1")"
  local M=0 m=0 p=0
  if [[ "$b" =~ \.so\.([0-9]+)(\.([0-9]+))?(\.([0-9]+))?$ ]]; then
    M="${BASH_REMATCH[1]}"
    [[ -n "${BASH_REMATCH[3]:-}" ]] && m="${BASH_REMATCH[3]}"
    [[ -n "${BASH_REMATCH[5]:-}" ]] && p="${BASH_REMATCH[5]}"
  fi
  echo "$M $m $p"
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

  # --- file M.m.p ---
  read base_M base_m base_p < <(file_triplet "$base_real")
  read head_M head_m head_p < <(file_triplet "$head_real")

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
  local result="FAIL"
  local reason="(unset)"

  case "$abi_cat" in

    incompatible)
      if (( major_bumped )); then
        result="PASS"; reason="Major++ as required for incompatible ABI"
      elif (( minor_bumped )); then
        result="FAIL"; reason="Minor++ but incompatible ABI requires Major++"
      elif (( patch_bumped )); then
        result="FAIL"; reason="Patch++ but incompatible ABI requires Major++"
      elif (( no_bump )); then
        result="FAIL"; reason="No bump; incompatible ABI requires Major++"
      else
        result="FAIL"; reason="Version regressed vs base"
      fi
      ;;

    compatible-additive)
      # Must be MAJOR same + MINOR++
      if (( head_Mj != base_Mj )); then
        result="FAIL"; reason="Major changed; expected Minor++ only"
      elif (( minor_bumped )); then
        result="PASS"; reason="Minor++ for compatible ABI"
      elif (( patch_bumped )); then
        result="FAIL"; reason="Only patch++; need Minor++ for compatible ABI"
      elif (( no_bump )); then
        result="FAIL"; reason="No bump; compatible ABI requires Minor++"
      else
        result="FAIL"; reason="Version regressed vs base"
      fi
      ;;

    no-diff)
      # Must be no version change (you can relax to PASS on patch bump if you want)
      if (( major_bumped || minor_bumped || patch_bumped )); then
        result="FAIL"; reason="Version changed but no ABI change"
      elif (( no_bump )); then
        result="PASS"; reason="No ABI change, version unchanged"
      else
        result="FAIL"; reason="Version regressed vs base"
      fi
      ;;

    *)
      result="FAIL"; reason="Unknown ABI category"
      ;;
  esac

  # --- missing SONAME handling ---
  if [[ -z "$base_soname" || -z "$head_soname" ]]; then
    case "$abi_cat" in
      incompatible)
        result="FAIL"
        reason="SONAME missing; cannot verify required Major++"
        ;;
      compatible-additive|no-diff)
        reason="$reason (SONAME missing; set SOVERSION)"
        ;;
    esac
  fi

  # --- set globals for caller ---
  VERSION_BASE_SONAME="$base_soname"
  VERSION_HEAD_SONAME="$head_soname"
  VERSION_BASE_VER="${base_M}.${base_m}.${base_p}"
  VERSION_HEAD_VER="${head_M}.${head_m}.${head_p}"
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