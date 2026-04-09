#!/bin/bash
# =============================================================================
# 00_lib.sh — Vibe Coding Workspace — Master lib loader v6.4
#
# CÉLKITŰZÉS:
#   Ez a fájl NEM tartalmaz logikát — csak betölti a komponens lib fájlokat.
#   Minden INFRA script (01a, 01b, 02-08) ezt source-olja.
#
# LIB KOMPONENSEK:
#   lib/00_lib_core.sh   — Globális változók, log, sudo, user, utility-k
#   lib/00_lib_hw.sh     — Hardver detektálás (GPU/CPU profil, driver)
#   lib/00_lib_ui.sh     — GUI réteg (YAD/whiptail dialógok, progress bar)
#   lib/00_lib_state.sh  — INFRA state kezelés (init/set/get/validate/require)
#   lib/00_lib_comp.sh   — Komponens ellenőrzők (comp_check_*, version_ok)
#   lib/00_lib_apt.sh    — APT segédek (apt_install_*, run_with_progress)
#
# FRISSÍTÉS:
#   Egy komponens frissítésekor CSAK az adott lib/00_lib_*.sh fájlt módosítsd.
#   Ez a master loader automatikusan betölti az újat a következő futásnál.
#
# FUTTATÁS:
#   source "./00_lib.sh"   (INFRA scriptek tetején)
#   NE futtasd közvetlenül!
#
# VERZIÓ: 6.4
# =============================================================================

# A lib fájlok a 00_lib.sh-val azonos könyvtárban lévő lib/ alkönyvtárban vannak
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# Betöltési sorrend FONTOS — függőségek miatt:
#   core → hw → ui (hw_has_nvidia-t használ) → state (dialog_*-t használ)
#   → comp (state-et, version_ok-t használ) → apt (progress_*-t használ)
_LIB_LOAD_ORDER=(
  "00_lib_core"   # 1. Alap: vars, log, sudo, user, helpers
  "00_lib_hw"     # 2. Hardver: hw_detect, hw_show, hw_has_nvidia
  "00_lib_ui"     # 3. GUI: dialog_*, progress_*, ensure_deps
  "00_lib_state"  # 4. State: infra_state_*, infra_require, detect_run_mode
  "00_lib_comp"   # 5. Komponens: comp_check_*, version_ok, comp_line
  "00_lib_apt"    # 6. APT: apt_install_*, run_with_progress
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
