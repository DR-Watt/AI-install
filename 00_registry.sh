#!/bin/bash
# =============================================================================
# 00_registry.sh — INFRA Registry v2.5
#
# Változtatások v2.5 (09 AI Model Manager integráció):
#   - 09 AI Model Manager modul hozzáadva
#     HW_REQ="vllm": SM_70+ NVIDIA szükséges (HW_VLLM_OK=true)
#     RTX 5090 Blackwell SM_120: minden funkció elérhető
#     Függőség: 02 (Ollama+vLLM+TQ) + 06 (VSCode+CLINE+Continue) — scripten belül
#     Script: 09_ai_model_wrapper.sh
#   - FÜGGŐSÉGEK komment frissítve: 09 → infra_require("02") + infra_require("06")
#
# Változtatások v2.4 (split lib v6.4 integráció):
#   - LIB_VERSION minimum: 6.4 kell (split lib, infra_require case fix)
#   - lib/00_lib_*.sh sub-fájlok — a 00_lib.sh master loader tölti be
#   - Nincs registry-szintű változás: az infra_compatible() a lib-ben
#     lett javítva (case-insensitive infra_require, check mód bypass)
#
# Változtatások v2.3 (03 Python/AI-ML v6.1 integráció):
#   - 03 leírás frissítve: LangChain, HuggingFace, safetensors, bővített stack
#   - 03 HW_REQ="" marad: CPU-only PyTorch is telepíthető (cpu index)
#   - LIB_VERSION minimum: 6.3 kell (comp_check_torch() miatt)
#
# Változtatások v2.2 (02 AI stack v6.2 integráció):
#   - 02 leírás frissítve: CPU-only Ollama fallback jelzése
#     HW_REQ="nvidia" marad: Ollama-GPU + vLLM mindkettő NVIDIA-t igényel.
#     CPU-only gépeken a 02 script a hardver ellenőrzésnél kihagyja a
#     vLLM/TurboQuant szekciót, csak Ollama CPU-mode kínálja fel.
#     → A HW_REQ="nvidia" biztosítja hogy csak NVIDIA profilokon jelöljük
#       be automatikusan (default ON lenne igaz esetén, de OFF marad).
#   - 02 függőség: infra_require("03") a script belsejében ellenőrzi
#   - INFRA_DEP map frissítve: 02 [03→] jelzés már volt, dokumentálva
#
# Változtatások v2.1 (01b integráció):
#   - 01b HW_REQ: "nvidia" → "" (hardverfüggetlen)
#     Indoklás: Zsh/Oh My Zsh/shell konfig minden GPU profilon fut.
#     A tényleges 01a függőséget a 01b script belsejében infra_require("01a")
#     kezeli — nem a registry hw_req filterje.
#   - 01b leírás és név frissítve: pontosabb, v6.1 terminológiával
#
# Változtatások v2.0 (01a/01b szétválasztás):
#   - "01" eltávolítva → helyette "01a" (pre-reboot) + "01b" (post-reboot)
#   - 01a: NVIDIA driver, CUDA, Docker, CTK → REBOOT_NEEDED flag
#   - 01b: Oh My Zsh, shell konfig → 01a + REBOOT után futtatandó
#   - Dependency map frissítve: 03 [01b→], 02 [03→], 06 [03→]
#
# ÚJ INFRA HOZZÁADÁSA — csak ezt a fájlt kell szerkeszteni:
#   infra_register \
#     "ID"          \   # egyedi azonosító (pl. "09")
#     "NÉV"         \   # megjelenített név
#     "LEÍRÁS"      \   # rövid leírás (checklist-ben)
#     "HW_REQ"      \   # "" | "nvidia" | "vllm" | "desktop"
#     "SCRIPT"      \   # script fájlnév (pl. "09_mymodule.sh")
#     "DEFAULT"         # ON | OFF (checklist alapértelmezett)
#
# HW_REQ értékek és jelentésük (infra_compatible() értelmezi):
#   ""        → minden hardver profil futtathatja
#   "nvidia"  → NVIDIA GPU szükséges (desktop-rtx, desktop-rtx-old, notebook-rtx)
#   "vllm"    → SM_70+ NVIDIA szükséges (HW_VLLM_OK=true)
#   "desktop" → nem notebook-igpu profil szükséges
#
# FÜGGŐSÉGEK — tájékoztató (a tényleges ellenőrzés infra_require()-rel történik):
#   01b → infra_require("01a")         belül
#   03  → infra_require("01b")         belül (vagy manuálisan skip-elhető)
#   02  → infra_require("03")          belül
#   06  → infra_require("03")          belül
#   09  → infra_require("02")          belül (Ollama+vLLM+TQ)
#   09  → infra_require("06")          belül (VSCode+CLINE+Continue.dev)
#
# A registry sorrendje = telepítési sorrend (INFRA_IDS tömb)
# =============================================================================

LIB="$(dirname "${BASH_SOURCE[0]}")/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" || { echo "00_lib.sh hiányzik!"; exit 1; }

# ── INFRA adatstruktúra ───────────────────────────────────────────────────────
declare -a INFRA_IDS=()
declare -A INFRA_NAME=()
declare -A INFRA_DESC=()
declare -A INFRA_HW_REQ=()
declare -A INFRA_SCRIPT=()
declare -A INFRA_DEFAULT=()

infra_register() {
  local id="$1" name="$2" desc="$3" hw_req="$4" script="$5" default="${6:-OFF}"
  INFRA_IDS+=("$id")
  INFRA_NAME["$id"]="$name"
  INFRA_DESC["$id"]="$desc"
  INFRA_HW_REQ["$id"]="$hw_req"
  INFRA_SCRIPT["$id"]="$script"
  INFRA_DEFAULT["$id"]="$default"
}

# =============================================================================
# INFRA REGISZTRÁCIÓ — ÚJ MODULT IDE ADD
# =============================================================================

# ── 01a: Pre-reboot kötelező alap ─────────────────────────────────────────────
# Driver + CUDA + Docker + CTK → REBOOT_NEEDED + MOD_01A_DONE flag az infra state-be.
# Minden NVIDIA-függő modul (02, 03) előfeltétele.
# HW_REQ="nvidia": csak NVIDIA GPU-val rendelkező profilokon jelenik meg.
# Script: 01a_system_foundation.sh
infra_register "01a" \
  "System Foundation (pre-reboot)" \
  "NVIDIA open driver, CUDA 12.8/12.6, cuDNN 9, Docker CE, CTK" \
  "nvidia" \
  "01a_system_foundation.sh" \
  "ON"

# ── 01b: Post-reboot user environment ─────────────────────────────────────────
# Zsh, Oh My Zsh, plugin-ok, .zshrc, aliasok, tmux, modern CLI eszközök.
# HW_REQ="": hardverfüggetlen — minden profilon fut (notebook-igpu is!).
# Függőség: 01a + REBOOT — a 01b script belsejében infra_require("01a") ellenőrzi.
# Ha az NVIDIA modul kihagyható (notebook-igpu), a 01b önállóan is futtatható
# de akkor az infra_require("01a")-t a user kézzel bypass-olja (MOD_01A_DONE=true).
# Script: 01b_post_reboot.sh
infra_register "01b" \
  "User Environment (post-reboot)" \
  "Zsh, Oh My Zsh, plugin-ok, .zshrc, aliasok, tmux, modern CLI" \
  "" \
  "01b_post_reboot.sh" \
  "ON"

# ── 02: Lokális AI stack ──────────────────────────────────────────────────────
# Ollama (GPU+CPU), vLLM (GPU-only, HW_VLLM_OK=true kell), TurboQuant llama.cpp fork.
# HW_REQ="nvidia": GPU nélkül vLLM nem fut; Ollama CPU-only fallback a 02 scripten belül.
# Függőség: 03 (PyTorch + uv + venv) → 02 script belsejében infra_require("03").
# TurboQuant: llama.cpp fork GPU build (SM_89 vagy SM_120 Blackwell-nek).
# Forrás: https://ollama.readthedocs.io/en/  |  https://docs.vllm.ai/en/latest/
#         https://github.com/0xSero/turboquant  (TurboQuant referencia implementáció)
infra_register "02" \
  "Lokális AI stack" \
  "Ollama + vLLM + TurboQuant llama.cpp fork + modellek" \
  "nvidia" \
  "02_local_ai_stack.sh" \
  "OFF"

# ── 03: Python + AI/ML ───────────────────────────────────────────────────────
# pyenv, Python 3.12 (forrásból, PGO+LTO), uv, PyTorch cu126/cu128/cpu,
# JupyterLab 4.x, LangChain, LangGraph, HuggingFace (transformers, datasets,
# safetensors, peft, accelerate), FastAPI, Pydantic v2, scikit-learn, polars.
# HW_REQ="": hardverfüggetlen — FEAT_GPU_ACCEL alapján választ cu12x vagy cpu indexet.
# Függőség: 01b → infra_require("01B") a 03 script belsejében.
# MOD_03_DONE=true → infra state → 02 és 06 szálak infra_require("03") hívják.
# comp_check_torch() (00_lib.sh v6.3): PyTorch import + CUDA elérhetőség ellenőrzés.
infra_register "03" \
  "Python 3.12 + AI/ML" \
  "pyenv, uv, PyTorch, LangChain, HuggingFace, FastAPI, JupyterLab" \
  "" \
  "03_python_aiml.sh" \
  "OFF"

# ── 04: Node.js ───────────────────────────────────────────────────────────────
# nvm, Node.js 22 LTS, pnpm, Fastify template, Claude Code CLI.
# HW_REQ="": hardverfüggetlen.
# Függőség: nincs — önállóan futtatható.
infra_register "04" \
  "Node.js 22 LTS + TypeScript" \
  "nvm, pnpm, Fastify template, Claude Code CLI" \
  "" \
  "04_nodejs_typescript.sh" \
  "OFF"

# ── 05: C64 / Demoscene ───────────────────────────────────────────────────────
# 64tass assembler, VICE emulator, GoatTracker, Wine, HVSC.
# HW_REQ="": hardverfüggetlen.
# Függőség: nincs — önállóan futtatható.
infra_register "05" \
  "C64 / Demoscene toolchain" \
  "64tass, VICE, GoatTracker, Wine, HVSC" \
  "" \
  "05_c64_toolchain.sh" \
  "OFF"

# ── 06: Szerkesztők ───────────────────────────────────────────────────────────
# Cursor IDE, VS Code 4 profil, CLINE extension, Continue.dev.
# HW_REQ="": hardverfüggetlen.
# Függőség: 03 (Python a CLINE/Continue plugin-okhoz) — script belsejében.
infra_register "06" \
  "Szerkesztők + CLINE" \
  "Cursor IDE, VS Code 4 profil, CLINE, Continue.dev" \
  "" \
  "06_editors.sh" \
  "OFF"

# ── 07: Sysadmin ──────────────────────────────────────────────────────────────
# PowerShell 7, Ansible, SSH konfiguráció, Azure CLI.
# HW_REQ="": hardverfüggetlen.
# Függőség: nincs — önállóan futtatható.
infra_register "07" \
  "Sysadmin toolchain" \
  "PowerShell 7, Ansible, SSH, Azure CLI" \
  "" \
  "07_sysadmin.sh" \
  "OFF"

# ── 08: NAS ───────────────────────────────────────────────────────────────────
# Synology DS411+, DS1511+ scriptek, bare git, RAG pipeline, Docker compose.
# HW_REQ="": hardverfüggetlen.
# Függőség: nincs — önállóan futtatható.
infra_register "08" \
  "Synology NAS scriptek" \
  "DS411+, DS1511+, bare git, RAG, Docker compose" \
  "" \
  "08_nas_synology.sh" \
  "OFF"

# ── 09: AI Model Manager ──────────────────────────────────────────────────────
# Ollama/vLLM model kezelő wrapper — RTX 5090 Blackwell SM_120 optimalizált.
# Kettős üzemmód:
#   INFRA mód (RUN_MODE=install|check|update):
#     Telepíti az ai-model-ctl tool-t, inicial CLINE/Continue konfig,
#     vLLM systemd user service fájl generálás.
#   Manage mód (RUN_MODE=manage vagy önállóan):
#     Interaktív whiptail menü: modell kezelés, backend váltás, TurboQuant, GPU monitor.
#
# HW_REQ="vllm": SM_70+ NVIDIA szükséges (HW_VLLM_OK=true).
#   RTX 5090 Blackwell SM_120: teljes funkcionalitás (vLLM + TQ + Ollama-GPU).
#   SM_70..SM_89: vLLM fut, TurboQuant GPU89 build.
#   CPU-only: kihagyott (Ollama CPU-only az a 02-es modulnál van).
#
# Függőség (scriptben infra_require()-rel):
#   02 → Ollama + vLLM + TurboQuant telepítve (MOD_02_DONE=true)
#   06 → VS Code + CLINE + Continue.dev telepítve (MOD_06_DONE=true)
#
# Parancssori alias (install után): ai-model-ctl
#   Elérhető módok: ai-model-ctl [manage|status|start-vllm MODEL|stop-vllm]
#
# Forrás: https://ollama.readthedocs.io/en/api/  (Ollama REST API)
#         https://docs.vllm.ai/en/stable/cli/serve/  (vLLM CLI)
#         https://github.com/0xSero/turboquant  (TurboQuant)
infra_register "09" \
  "AI Model Manager" \
  "Ollama/vLLM kezelés, TurboQuant, CLINE+Continue konfig, RTX 5090" \
  "vllm" \
  "09_ai_model_wrapper.sh" \
  "OFF"

# =============================================================================
# REGISTRY FÜGGVÉNYEK
# =============================================================================

# infra_checklist_items: checklist elemek generálása hardver szűréssel.
# Paraméter: $1=script könyvtár (alapértelmezett: aktuális könyvtár)
# Kimenet: printf-formátumú sorok a dialog_checklist() számára
infra_checklist_items() {
  local script_dir="${1:-.}"
  for id in "${INFRA_IDS[@]}"; do
    local hw_req="${INFRA_HW_REQ[$id]}"
    local name="${INFRA_NAME[$id]}"
    local desc="${INFRA_DESC[$id]}"
    local default="${INFRA_DEFAULT[$id]}"
    local script="${INFRA_SCRIPT[$id]}"

    # Script létezés ellenőrzés
    local script_exists="✓"
    [ ! -f "$script_dir/$script" ] && script_exists="⚠ HIÁNYZIK"

    # Hardver kompatibilitás ellenőrzés
    # infra_compatible() a 00_lib.sh-ban: "" → mindig OK, "nvidia" → hw_has_nvidia
    if ! infra_compatible "$hw_req"; then
      desc="$desc  [NEM ELÉRHETŐ: $HW_PROFILE]"
      default="OFF"
    fi

    printf '"%s" "%s — %s  %s" "%s"\n' \
      "$id" "$name" "$desc" "$script_exists" "$default"
  done
}

# infra_run: adott ID-jű infra script futtatása.
# Paraméterek: $1=ID, $2=script könyvtár, $3=futtatási mód
# Visszatérési értékek:
#   0  → sikeres futás
#   1  → hiba (script hiányzik, futás sikertelen)
#   2  → hardver inkompatibilis (kihagyva)
infra_run() {
  local id="$1" script_dir="${2:-.}" mode="${3:-install}"
  local script="$script_dir/${INFRA_SCRIPT[$id]}"

  # Script fájl létezés ellenőrzés
  if [ ! -f "$script" ]; then
    dialog_warn "Script hiányzik" \
      "\n  ${INFRA_SCRIPT[$id]} nem található!\n  Könyvtár: $script_dir" 10
    return 1
  fi

  # Hardver kompatibilitás ellenőrzés a registry HW_REQ alapján
  # Ha HW_REQ="" → infra_compatible() mindig 0-t ad → fut
  # Ha HW_REQ="nvidia" → csak NVIDIA GPU-s profilokon fut
  # Ha HW_REQ="vllm"   → csak HW_VLLM_OK=true profilokon fut (SM_70+)
  if ! infra_compatible "${INFRA_HW_REQ[$id]}"; then
    dialog_warn "Hardver inkompatibilis" \
      "\n  '${INFRA_NAME[$id]}' modul:\n  Hw. követelmény: ${INFRA_HW_REQ[$id]}\n  Jelenlegi profil: $HW_PROFILE\n\n  Ez a modul kihagyva." 14
    return 2
  fi

  log "INFRA" "Futtatás: $id — ${INFRA_NAME[$id]} (mód: $mode)"
  RUN_MODE="$mode" bash "$script"
  return $?
}

# infra_list: összes regisztrált INFRA listázása (debug / ellenőrzés).
# Megmutatja az aktuális hardver kompatibilitást is.
infra_list() {
  printf '\n%-4s %-38s %-10s %-7s %s\n' "ID" "Név" "HW req" "Default" "Script"
  printf '%s\n' "$(printf '─%.0s' {1..86})"
  for id in "${INFRA_IDS[@]}"; do
    local compat="OK"
    infra_compatible "${INFRA_HW_REQ[$id]}" || compat="SKIP"
    printf '%-4s %-38s %-10s %-7s %s  [%s]\n' \
      "$id" \
      "${INFRA_NAME[$id]}" \
      "${INFRA_HW_REQ[$id]:-any}" \
      "${INFRA_DEFAULT[$id]}" \
      "${INFRA_SCRIPT[$id]}" \
      "$compat"
  done
  printf '\n'
}
