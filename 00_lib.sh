#!/bin/bash
# =============================================================================
# 00_lib.sh — Vibe Coding Workspace — Master lib loader v6.5
#
# CÉLKITŰZÉS:
#   Ez a fájl NEM tartalmaz logikát — csak betölti a komponens lib fájlokat.
#   Minden INFRA script (01a, 01b, 02-08) ezt source-olja.
#
# LIB KOMPONENSEK:
#   lib/00_lib_core.sh   — Globális változók, log, sudo, user, utility-k
#   lib/00_lib_compat.sh — Kompatibilitási mátrix (GPU/OS/Driver/CUDA lookup)  [v1.0]
#   lib/00_lib_hw.sh     — Hardver detektálás (GPU/CPU profil, driver, OS ver)
#   lib/00_lib_ui.sh     — GUI réteg (YAD/whiptail dialógok, progress bar)
#   lib/00_lib_state.sh  — INFRA state kezelés (init/set/get/validate/require)
#   lib/00_lib_comp.sh   — Komponens ellenőrzők (comp_check_*, version_ok)
#   lib/00_lib_apt.sh    — APT segédek (apt_install_*, run_with_progress)
#
# BETÖLTÉSI SORREND:
#   core → compat → hw (compat_get() szükséges hw_detect-ben!) → ui → state → comp → apt
#
# FRISSÍTÉS:
#   Egy komponens frissítésekor CSAK az adott lib/00_lib_*.sh fájlt módosítsd.
#   Ez a master loader automatikusan betölti az újat a következő futásnál.
#
# VERZIÓ: 6.5
# =============================================================================

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# Betöltési sorrend FONTOS — függőségek miatt:
#   core → compat → hw → ui → state → comp → apt
#
# FONTOS: 00_lib_compat.sh-t 00_lib_hw.sh ELŐTT kell betölteni,
#   mert hw_detect() a compat_get() függvényt használja az OS-specifikus
#   driver/CUDA ajánlások kinyeréséhez.
_LIB_LOAD_ORDER=(
  "00_lib_core"   # 1. Alap: vars, log, sudo, user, helpers
  "00_lib_compat" # 2. Compat mátrix: GPU/OS/Driver/CUDA lookup (hw előtt!)
  "00_lib_hw"     # 3. Hardver: hw_detect, hw_show, hw_has_nvidia, OS verzió
  "00_lib_ui"     # 4. GUI: dialog_*, progress_*, ensure_deps
  "00_lib_state"  # 5. State: infra_state_*, infra_require, detect_run_mode
  "00_lib_comp"   # 6. Komponens: comp_check_*, version_ok, comp_line
  "00_lib_apt"    # 7. APT: apt_install_*, run_with_progress
)

for _lib_part in "${_LIB_LOAD_ORDER[@]}"; do
  _lib_file="$_LIB_DIR/${_lib_part}.sh"
  if [ ! -f "$_lib_file" ]; then
    echo "HIBA: Lib komponens hiányzik: $_lib_file"
    echo "Bizonyosodj meg hogy a lib/ könyvtár tartalmazza az összes komponenst."
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$_lib_file" || {
    echo "HIBA: Lib komponens betöltés sikertelen: $_lib_file"
    exit 1
  }
done

unset _LIB_DIR _lib_part _lib_file _LIB_LOAD_ORDER
