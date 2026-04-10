#!/bin/bash
# =============================================================================
# 00_lib_patch.sh — 00_lib.sh kiegészítések v6.4→v6.5
#
# Alkalmazás:
#   sudo bash 00_lib_patch.sh [/path/to/00_lib.sh]
#   Alapértelmezett: ./00_lib.sh
# =============================================================================

set -euo pipefail

LIB="${1:-$(dirname "${BASH_SOURCE[0]}")/00_lib.sh}"
[ -f "$LIB" ] || { echo "HIBA: $LIB nem található"; exit 1; }

BAK="${LIB}.bak.$(date '+%Y%m%d_%H%M%S')"
cp "$LIB" "$BAK"
echo "Backup: $BAK"

if grep -q "nvidia_driver_purge()" "$LIB"; then
  echo "INFO: Patch már alkalmazva — semmi sem változik."
  exit 0
fi

# =============================================================================
# PATCH 1 — comp_line: "broken" eset hozzáadása (⚡ szimbólum)
# =============================================================================
# Indok: nvidia_driver "broken" állapot üres sort produkált a status dialógban
# mert a case blokkban nem volt "broken" ág.

python3 - "$LIB" << 'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
OLD = "    missing) printf '  ✗  %-22s hiányzik\\n' \"$label\" ;;\n  esac"
NEW = "    missing) printf '  ✗  %-22s hiányzik\\n' \"$label\" ;;\n    broken)  printf '  ⚡  %-22s %s\\n' \"$label\" \"${COMP_VER[$name]}\" ;;\n  esac"
if OLD in text:
    open(path, 'w').write(text.replace(OLD, NEW, 1))
    print("OK: comp_line 'broken' eset hozzáadva (⚡)")
else:
    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if "missing) printf" in line and "hiányzik" in line:
            for j in range(i+1, min(i+5, len(lines))):
                if "esac" in lines[j]:
                    lines.insert(j, "    broken)  printf '  ⚡  %-22s %s\\n' \"$label\" \"${COMP_VER[$name]}\" ;;\n")
                    open(path, 'w').writelines(lines)
                    print("OK: comp_line 'broken' eset hozzáadva (fallback)")
                    sys.exit(0)
    print("HIBA: comp_line case blokk nem található"); sys.exit(1)
PYEOF

# =============================================================================
# PATCH 2 — Új NVIDIA + CUDA helper függvények hozzáadása
# Helye: comp_summary() után, SZEKCIÓ 9 előtt
# =============================================================================

read -r -d '' NEW_FUNCTIONS << 'FUNCEOF' || true
# =============================================================================
# SZEKCIÓ 8b — NVIDIA ÉS CUDA HELPER FÜGGVÉNYEK (v6.5)
# =============================================================================

# nvidia_driver_purge: minden NVIDIA csomag tiszta eltávolítása
# ─────────────────────────────────────────────────────────────
# DEBIAN_FRONTEND=noninteractive MINDEN dpkg/apt híváshoz.
# Nélküle debconf Dialog frontend hibát dob YAD/dialog kontextusban.
# ("Dialog frontend requires a screen at least 13 lines tall...")
# Paraméterek: $1=logfile (opcionális)
nvidia_driver_purge() {
  local logfile="${1:-/dev/null}"
  local old_pkgs
  old_pkgs=$(dpkg -l 2>/dev/null \
    | grep -E "^(ii|iF|iU|rc)\s+(nvidia|libnvidia)" \
    | awk '{print $2}' | tr '\n' ' ')
  if [ -n "$old_pkgs" ]; then
    log "APT" "NVIDIA purge: $old_pkgs"
    DEBIAN_FRONTEND=noninteractive dpkg --purge --force-all $old_pkgs \
      >> "$logfile" 2>&1 || true
  fi
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >> "$logfile" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get clean >> "$logfile" 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" >> "$logfile" 2>&1 || true
}

# nvidia_mok_status: MOK enrollment állapot
# ─────────────────────────────────────────
# Output: "enrolled" | "pending" | "not_enrolled" | "no_cert"
nvidia_mok_status() {
  local mok_cert="/var/lib/shim-signed/mok/MOK.der"
  [ ! -f "$mok_cert" ] && { echo "no_cert"; return; }
  local cn
  cn=$(openssl x509 -in "$mok_cert" -noout -subject 2>/dev/null \
       | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 || echo "DKMS")
  local enrolled_count
  enrolled_count=$(mokutil --list-enrolled 2>/dev/null \
                   | grep -i "CN=" | grep -ci "$cn" 2>/dev/null || echo 0)
  [ "${enrolled_count:-0}" -gt 0 ] && { echo "enrolled"; return; }
  local pending_count
  pending_count=$(mokutil --list-new 2>/dev/null \
                  | grep -c "Subject:" 2>/dev/null || echo 0)
  [ "${pending_count:-0}" -gt 0 ] && { echo "pending"; return; }
  echo "not_enrolled"
}

# nvidia_mok_enroll: MOK enrollment végrehajtása ha szükséges
# ────────────────────────────────────────────────────────────
# Visszatér: 0=ok (enrolled/pending), 1=fail, 2=no_cert
# Mellékhatás: MOK_ENROLL_PASS MINDIG frissítve a state-ben
# (akkor is ha már enrolled — hogy a user mindig lássa a jelszót)
# Ez azért fontos, mert ha a BIOS valamiért ismét kéri (firmware update stb.),
# legyen kéznél az aktuális jelszó.
nvidia_mok_enroll() {
  local mok_cert="/var/lib/shim-signed/mok/MOK.der"
  [ ! -f "$mok_cert" ] && {
    log "WARN" "nvidia_mok_enroll: MOK.der hiányzik"
    return 2
  }
  local cn
  cn=$(openssl x509 -in "$mok_cert" -noout -subject 2>/dev/null \
       | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 || echo "DKMS")
  local status
  status=$(nvidia_mok_status)
  log "INFO" "MOK állapot: $status (CN: $cn)"
  case "$status" in
    enrolled)
      # Már enrolled: generálunk egy emlékeztető jelszót és state-be mentjük,
      # de NEM futtatjuk a mokutil --import-ot (nem kell).
      # Célja: a user mindig lássa hogy "ha valamiért kéri a BIOS, ez a jelszó".
      # (Enrolled kulcsnál a BIOS NEM kéri a jelszót — de biztonsági emlékeztető.)
      local reminder_pass
      reminder_pass="$(infra_state_get "MOK_ENROLL_PASS" "")"
      [ -z "$reminder_pass" ] && reminder_pass="mok-$(openssl rand -hex 3 2>/dev/null || echo 'enrolled')"
      infra_state_set "MOK_ENROLL_PENDING" "false"
      infra_state_set "MOK_ENROLL_PASS"    "$reminder_pass"
      log "OK" "MOK kulcs már enrolled az UEFI-ben — nincs teendő"
      log "INFO" "Jelszó state-ben megőrizve: $reminder_pass"
      return 0
      ;;
    pending)
      # Pending: már bejegyezve, jelszóval kell elfogadni rebootkor
      local existing_pass
      existing_pass="$(infra_state_get "MOK_ENROLL_PASS" "")"
      [ -z "$existing_pass" ] && existing_pass="mok-$(openssl rand -hex 3 2>/dev/null || echo 'pending')"
      infra_state_set "MOK_ENROLL_PASS" "$existing_pass"
      log "OK" "MOK enrollment pending — jelszó: $existing_pass"
      return 0
      ;;
    not_enrolled)
      # Friss enrollment szükséges
      local pass
      pass="mok-$(openssl rand -hex 3 2>/dev/null || date +%s | tail -c 6)"
      printf '%s\n%s\n' "$pass" "$pass" | \
        mokutil --import "$mok_cert" >> "${LOGFILE_AI:-/dev/null}" 2>&1
      local ec=$?
      if [ $ec -eq 0 ]; then
        infra_state_set "MOK_ENROLL_PENDING" "true"
        infra_state_set "MOK_ENROLL_PASS"    "$pass"
        log "OK" "MOK enrollment bejegyezve — jelszó: $pass"
        return 0
      else
        log "FAIL" "mokutil --import sikertelen (exit $ec)"
        return 1
      fi
      ;;
    no_cert)
      log "WARN" "MOK.der nem létezik"
      return 2
      ;;
  esac
}

# cuda_best_available: legjobb elérhető CUDA toolkit verzió az apt cache-ből
# ──────────────────────────────────────────────────────────────────────────
# Output: "13.2" | "13.1" | "13.0" | "12.8" | "12.6" | ""
# Forrás: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/
cuda_best_available() {
  for _cv in "13-2" "13-1" "13-0" "12-8" "12-6"; do
    apt-cache show "cuda-toolkit-${_cv}" &>/dev/null && \
      { echo "${_cv/-/.}"; return 0; }
  done
  echo ""; return 1
}

# cuda_pytorch_index: CUDA verziószámból PyTorch cu-index string
# ──────────────────────────────────────────────────────────────
# Példa: "12.6"→"cu126", "12.8"→"cu128", "13.x"→"cu128"
# Megjegyzés: CUDA 13.x ABI backward-kompatibilis cu128-cal (2026-04 állapot)
cuda_pytorch_index() {
  local ver="${1:-12.6}"
  local major
  major=$(echo "$ver" | cut -d. -f1)
  [ "${major:-0}" -ge 13 ] 2>/dev/null && { echo "cu128"; return; }
  echo "cu$(echo "$ver" | cut -d. -f1-2 | tr -d .)"
}
FUNCEOF

python3 - "$LIB" "$NEW_FUNCTIONS" << 'PYEOF'
import sys
path = sys.argv[1]
new_funcs = sys.argv[2]
text = open(path).read()
marker = "# =============================================================================\n# SZEKCIÓ 9 — INFRA STATE RENDSZER"
if marker in text:
    new_text = text.replace(marker, new_funcs + "\n" + marker, 1)
    open(path, 'w').write(new_text)
    print("OK: NVIDIA/CUDA helper függvények hozzáadva (SZEKCIÓ 8b)")
else:
    print("HIBA: SZEKCIÓ 9 marker nem található"); sys.exit(1)
PYEOF

# =============================================================================
# ELLENŐRZÉS
# =============================================================================
echo ""
bash -n "$LIB" && echo "✓ Szintaxis OK" || { echo "✗ Szintaxis HIBA — visszaállítás..."; cp "$BAK" "$LIB"; exit 1; }

for fn in nvidia_driver_purge nvidia_mok_status nvidia_mok_enroll \
          cuda_best_available cuda_pytorch_index; do
  grep -q "${fn}()" "$LIB" && echo "✓ $fn" || echo "✗ $fn HIÁNYZIK"
done
grep -q "broken)" "$LIB" && echo "✓ comp_line broken eset" || echo "✗ comp_line broken HIÁNYZIK"

echo ""
echo "Patch alkalmazva. Visszaállítás: cp \"$BAK\" \"$LIB\""
