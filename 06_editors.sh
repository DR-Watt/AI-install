#!/bin/bash
# =============================================================================
# 06_editors.sh — Vibe Coding Workspace — Szerkesztők + AI coding agents
#
# TARTALOM:
#   VS Code (Microsoft repo, stabil) + 5 profil extension-csoport
#   Cursor IDE (AppImage, AI-first szerkesztő)
#   CLINE (VS Code AI coding agent, Ollama ↔ openai-compatible API)
#   Continue.dev (tab autocomplete + inline chat, Ollama + Anthropic)
#   Kitty (GPU-gyorsított terminál, kovidgoyal telepítő)
#
# BETÖLTÉS:
#   source 00_lib.sh → 00_lib.sh betölti a lib/ split modulokat:
#     lib/00_lib_core.sh   — log, sudo, user, utility
#     lib/00_lib_hw.sh     — hw_detect, hw_has_nvidia
#     lib/00_lib_ui.sh     — dialog_*, progress_*
#     lib/00_lib_state.sh  — infra_state_*, infra_require, detect_run_mode
#     lib/00_lib_comp.sh   — comp_check_*, version_ok, comp_line
#     lib/00_lib_apt.sh    — apt_install_*, run_with_progress
#
# FÜGGŐSÉG:
#   infra_require "03" — Python 3.12 + uv + venv szükséges a CLINE/Continue
#   plugin-ok Python backend-jéhez. A 03 szál (MOD_03_DONE=true) előfeltétel.
#
# FUTTATÁS:
#   bash 06_editors.sh           — önállóan
#   RUN_MODE=update bash 06_editors.sh — frissítő mód
#   00_master.sh hívja RUN_MODE exportálással
#
# VERZIÓ: v6.5 (LIB split + compat mátrix + COMP STATE mód-tudatos)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 00_lib.sh: master loader — betölti az összes lib/ komponenst
# Betöltési sorrend: core → compat → hw → ui → state → comp → apt (függőségi sorrend)
LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" || { echo "HIBA: 00_lib.sh hiányzik: $LIB"; exit 1; }

# =============================================================================
# KONFIGURÁCIÓ — MINDEN PARAMÉTER ITT, A SCRIPT TETEJÉN
# =============================================================================
# Elvárás (architektúra szabály): minden verziószám, URL, csomaglista,
# konfig JSON itt van deklarálva — a telepítő logika csak ezeket olvassa.

# ── INFRA azonosítók ──────────────────────────────────────────────────────────
INFRA_NUM="06"
INFRA_NAME="Szerkesztők — Cursor IDE + VS Code + CLINE + Continue.dev"

# ── Verziók ───────────────────────────────────────────────────────────────────
declare -A VER=(
  # Node.js major verzió — CLINE extension Node.js backendhez
  # (nvm-ből jön, csak referencia a minimum elváráshoz)
  [node_min]="22"
  # VS Code minimum verzió az extension kompatibilitáshoz
  [vscode_min]="1.85"
  # Kitty minimum verzió (GPU terminál)
  [kitty_min]="0.30"
)

# ── URL-ek ────────────────────────────────────────────────────────────────────
declare -A URLS=(
  # Cursor AppImage — AI-first kódszerkesztő letöltés
  [cursor_appimage]="https://downloader.cursor.sh/linux/appImage/x64"
  # Kitty terminál — kovidgoyal.net hivatalos telepítő script
  # Forrás: https://sw.kovidgoyal.net/kitty/binary/
  [kitty_installer]="https://sw.kovidgoyal.net/kitty/installer.sh"
  # Microsoft GPG kulcs — VS Code repo hitelesítéséhez
  [ms_gpg]="https://packages.microsoft.com/keys/microsoft.asc"
  # Microsoft VS Code APT repo
  [vscode_repo]="https://packages.microsoft.com/repos/vscode"
)

# ── VS Code extension-ök csoportonként ────────────────────────────────────────
# Minden profil önállóan telepíthető checklist-ből.
# Alap + AI profil mindig települ (nem ajánlható fel kihagyásra).
declare -A VSCODE_EXT=(
  # Alap — minden profilban kötelező: git, helyesírás, hibakiemelés, SSH
  [base]="eamodio.gitlens
          mhutchie.git-graph
          streetsidesoftware.code-spell-checker
          EditorConfig.EditorConfig
          gruntfuggly.todo-tree
          ms-vscode.hexeditor
          usernamehw.errorlens
          ms-vscode-remote.remote-ssh
          ms-azuretools.vscode-docker
          humao.rest-client"

  # AI asszisztens — CLINE, Continue.dev, GitHub Copilot
  [ai]="saoudrizwan.claude-dev
        continue.continue
        GitHub.copilot
        GitHub.copilot-chat"

  # Python / AI-ML — ruff, black, Jupyter, autodocstring
  [python]="ms-python.python
            ms-python.vscode-pylance
            ms-python.black-formatter
            ms-python.isort
            ms-toolsai.jupyter
            ms-toolsai.jupyter-keymap
            charliermarsh.ruff
            njpwerner.autodocstring"

  # Node.js / TypeScript — prettier, eslint, Tailwind, Prisma
  [nodejs]="esbenp.prettier-vscode
            dbaeumer.vscode-eslint
            Prisma.prisma
            bradlc.vscode-tailwindcss
            christian-kohler.path-intellisense
            ms-vscode.vscode-typescript-next"

  # C64 / Demoscene assembly — CASL65, KickAssembler, ACME
  [c64]="tlgkccampbell.code-casl65
         paulhocker.kick-assembler-vscode-ext
         bgold-cosmos.vscode-acme-cross-asm"

  # Sysadmin — shellcheck, ansible, YAML, PowerShell
  [sysadmin]="ms-vscode.powershell
              timonwong.shellcheck
              foxundermoon.shell-format
              redhat.ansible
              redhat.vscode-yaml"
)

# ── CLINE konfig (Ollama ↔ CLINE összekapcsolás) ──────────────────────────────
# CLINE openai-compatible mód: Ollama /v1 endpoint mint "OpenAI API"
# Forrás: CLINE extension dokumentáció — openai provider konfig
CLINE_SETTINGS='{
  "cline.apiProvider": "openai",
  "cline.openAiBaseUrl": "http://localhost:11434/v1",
  "cline.openAiApiKey": "ollama",
  "cline.openAiModelId": "qwen2.5-coder:32b",
  "cline.maxTokens": 8192
}'

# ── Continue.dev konfig (Ollama + Anthropic fallback) ─────────────────────────
# chat: qwen2.5-coder:32b (lokális), autocomplete: qwen2.5-coder:7b (gyors)
# embedding: nomic-embed-text (RAG), fallback: Claude Sonnet (Anthropic API)
CONTINUE_CONFIG='{
  "models": [
    {
      "title": "Qwen 32B (lokális Ollama)",
      "provider": "ollama",
      "model": "qwen2.5-coder:32b",
      "apiBase": "http://localhost:11434"
    },
    {
      "title": "Claude Sonnet (API)",
      "provider": "anthropic",
      "model": "claude-sonnet-4-6",
      "apiKey": "ANTHROPIC_API_KEY_IDE"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen 7B (gyors autocomplete)",
    "provider": "ollama",
    "model": "qwen2.5-coder:7b",
    "apiBase": "http://localhost:11434"
  },
  "embeddingsProvider": {
    "provider": "ollama",
    "model": "nomic-embed-text",
    "apiBase": "http://localhost:11434"
  }
}'

# ── VS Code globális settings ─────────────────────────────────────────────────
# JetBrains Mono + ligatures, formázás mentéskor, telemetria ki
VSCODE_SETTINGS='{
  "editor.fontFamily": "'\''JetBrains Mono'\'', '\''Fira Code'\'', monospace",
  "editor.fontLigatures": true,
  "editor.fontSize": 13,
  "editor.lineHeight": 1.6,
  "editor.formatOnSave": true,
  "editor.bracketPairColorization.enabled": true,
  "editor.minimap.enabled": false,
  "editor.rulers": [100],
  "workbench.colorTheme": "Default Dark Modern",
  "terminal.integrated.fontFamily": "'\''JetBrains Mono'\''",
  "terminal.integrated.fontSize": 13,
  "files.autoSave": "onFocusChange",
  "files.trimTrailingWhitespace": true,
  "telemetry.telemetryLevel": "off",
  "python.defaultInterpreterPath": "${env:HOME}/venvs/ai/bin/python"
}'

# ── Komponens ellenőrző specifikációk ────────────────────────────────────────
# Formátum: "name|version_cmd|min_ver"
# check_component() a generikus; comp_check_vscode() a dedikált (00_lib_comp.sh)
# FONTOS: a "name" kulcs megegyezik a COMP_STATUS[] és COMP_VER[] kulcsával!
COMP_CHECK=(
  "vscode|code --version|${VER[vscode_min]}"
  "cursor|[ -f $_REAL_HOME/bin/cursor ] && echo 1|1"
  "kitty|kitty --version|${VER[kitty_min]}"
  "cline|code --list-extensions 2>/dev/null | grep -q saoudrizwan.claude-dev && echo 1|1"
  "continue_dev|code --list-extensions 2>/dev/null | grep -q continue.continue && echo 1|1"
)

# =============================================================================
# INICIALIZÁLÁS
# =============================================================================

# LOGFILE_AI/HUMAN: felülírjuk a lib alapértékét — INFRA_NUM bekerül a névbe.
# _REAL_HOME: 00_lib_core.sh már beállítja sudo_user alapján, NEM definiáljuk újra!
LOGFILE_AI="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="$LOGFILE_AI"   # backward kompatibilitás

# log_init: könyvtár létrehozás + fejléc írás + tulajdonos javítás (chown)
log_init

# hw_detect: hardver profil meghatározása (HW_PROFILE, HW_GPU_ARCH, stb.)
# Ha a state-ből már betölthetők, a detektálás azokat tükrözi
hw_detect

# infra_state_init: state fájl összes kulcsának inicializálása HA MÉG NINCS
# Meglévő értékeket NEM írja felül — biztonságos ismételt hívás
infra_state_init

# State beolvasás: a korábbi szálak (01a, 03) által beírt értékek
PYTORCH_INDEX=$(infra_state_get "PYTORCH_INDEX" "cu126")
CUDA_VER=$(infra_state_get "INST_CUDA_VER" "12.6")
HW_GPU_ARCH=$(infra_state_get "HW_GPU_ARCH" "unknown")

log "STATE" "Betöltve: CUDA=$CUDA_VER | PyTorch=$PYTORCH_INDEX | GPU arch=$HW_GPU_ARCH"
log "INFO"  "Valódi user: $_REAL_USER | Home: $_REAL_HOME | GUI: $GUI_BACKEND"

# =============================================================================
# FÜGGŐSÉG ELLENŐRZÉS
# =============================================================================
# infra_require "03": MOD_03_DONE=true kell az infra state-ben.
# A 03 szál (Python 3.12 + uv + venv) előfeltétele a CLINE és Continue.dev
# Python backend futtatásához. Check és fix módban bypass (csak logol).

infra_require "03" "Python 3.12 + AI/ML (03_python_aiml.sh)" || exit 1

# =============================================================================
# BEVEZETŐ DIALOG
# =============================================================================

dialog_msg "INFRA $INFRA_NUM — $INFRA_NAME" \
"  Telepíti / frissíti:
    • VS Code (Microsoft repo) + 5 extension profil
    • Cursor IDE (AppImage + desktop entry)
    • Kitty terminál (GPU-gyorsított, kovidgoyal)
    • CLINE extension (VS Code AI coding agent, Ollama bekötve)
    • Continue.dev (tab autocomplete + chat, Ollama + Anthropic)
    • CLINE ↔ Ollama konfiguráció (qwen2.5-coder:32b)
    • Continue ↔ Ollama + Anthropic API konfiguráció

  Mód: $RUN_MODE" 22

# Log: mit telepít, hova (log_infra_header és log_install_paths: 00_lib_core.sh)
log_infra_header \
"    • VS Code + 5 extension profil (Base, AI, Python, C64, Node.js, Sysadmin)
    • Cursor IDE — AI-first kódszerkesztő (AppImage)
    • CLINE — VS Code AI coding agent (Ollama openai-compatible bekötés)
    • Continue.dev — tab autocomplete + inline chat (Ollama + Anthropic)
    • Kitty — GPU-gyorsított terminál (kovidgoyal telepítő)"

log_install_paths \
"    /usr/bin/code                      — VS Code bináris
    $_REAL_HOME/tools/cursor/          — Cursor AppImage
    $_REAL_HOME/bin/cursor             — Cursor indítóscript
    $_REAL_HOME/.local/share/applications/cursor.desktop
    $_REAL_HOME/.continue/config.json  — Continue.dev konfig
    $_REAL_HOME/.config/Code/User/settings.json — VS Code beállítások"

# =============================================================================
# KOMPONENS FELMÉRÉS
# =============================================================================

# COMP STATE: mentett check eredmény betöltése VAGY friss ellenőrzés
# COMP_USE_CACHED=true: a 00_master.sh exportálja, ha a user kérte
# comp_state_exists / comp_load_state / comp_save_state: 00_lib_comp.sh
if [ "${COMP_USE_CACHED:-false}" = "true" ] && comp_state_exists "$INFRA_NUM"; then
  # ── Mentett eredmény betöltése ───────────────────────────────────────────────
  # comp_load_state: COMP_STATUS[] és COMP_VER[] tömbök feltöltése state fájlból
  # Megjegyzés: ez NEM fut check-et, csak a korábban mentett értékeket tölti be.
  comp_load_state "$INFRA_NUM"
  _state_age=$(comp_state_age_hours "$INFRA_NUM")
  log "COMP" "Mentett check eredmény betöltve — INFRA $INFRA_NUM (${_state_age} óra)"
else
  # ── Friss komponens ellenőrzés ───────────────────────────────────────────────
  # ALAPELV: minden "code" hívás sudo -u "$_REAL_USER" kontextusban fut!
  # Gyökérok: "code" (VS Code, akár deb akár snap) sudo/root alatt nem elérhető.
  #   - /snap/bin nem kerül a root PATH-ba
  #   - code --version Electron wrappert igényel (DBUS/display session nélkül kilép)
  #   - code --list-extensions ugyanígy
  # Megoldás: HOME="$_REAL_HOME" sudo -u "$_REAL_USER" code ... — user kontextus
  # Ugyanezt csinálja az _install_ext() is, ahol működött.

  # VS Code: fájl alapú ellenőrzés + user kontextusú verzió lekérés
  # comp_check_vscode() bővített logikával (00_lib_comp.sh)
  comp_check_vscode "${VER[vscode_min]}" "$_REAL_USER" "$_REAL_HOME"

  # Cursor: indítóscript VAGY AppImage — bármelyik jelenléte elegendő
  # (check módban a wrapper script nem jön létre, de az AppImage ott lehet)
  check_component "cursor" \
    "([ -f '$_REAL_HOME/bin/cursor' ] || [ -f '$_REAL_HOME/tools/cursor/cursor.AppImage' ]) && echo 1" "1"

  # Kitty: explicit fájl alapú detektálás — NEM PATH-alapú!
  # PATH-alapú lookup (akár env, akár cmd_exists) sudo alatt megtalálja a
  # /root/.local/kitty.app/bin/kitty-t is → hamis pozitív.
  # Explicit path: csak $\_REAL\_HOME-ban elfogadott bináris
  check_component "kitty" \
    "( [ -x '$_REAL_HOME/.local/kitty.app/bin/kitty' ] && '$_REAL_HOME/.local/kitty.app/bin/kitty' --version 2>/dev/null || [ -x '$_REAL_HOME/bin/kitty' ] && '$_REAL_HOME/bin/kitty' --version 2>/dev/null ) | grep -oP '[\d.]+' | head -1" "${VER[kitty_min]}"

  # CLINE + Continue: code --list-extensions user kontextusban
  # (sudo alatt code nem fut → extension lista nem kérhető le root-ként)
  check_component "cline" \
    "HOME='$_REAL_HOME' sudo -u '$_REAL_USER' code --list-extensions 2>/dev/null | grep -q saoudrizwan.claude-dev && echo 1" "1"
  check_component "continue_dev" \
    "HOME='$_REAL_HOME' sudo -u '$_REAL_USER' code --list-extensions 2>/dev/null | grep -q continue.continue && echo 1" "1"

  # comp_save_state: CHECK módban az elején mentünk — semmi sem változik,
  # ezért az eleje = a vége (pre-check = post-check állapot).
  # Install/update/fix/reinstall módban NEM mentünk itt — ott a script VÉGÉN
  # fut egy teljes re-check + comp_save_state, MIUTÁN minden telepítés kész.
  if [ "$RUN_MODE" = "check" ]; then
    comp_save_state "$INFRA_NUM"
    log "COMP" "Check mód: COMP state mentve"
  fi
fi

# log_comp_status: COMP_CHECK tömb alapján logba írja az állapotot
# (COMP_STATUS[] tömb értékeit mutatja — akár fresh, akár cached)
log_comp_status "${COMP_CHECK[@]}"

# Összes ellenőrzött kulcs — detect_run_mode() nameref-ként kapja
comp_keys=(vscode cursor kitty cline continue_dev)

# detect_run_mode: RUN_MODE-ot állítja be (install/update/skip/reinstall)
# Ha minden OK → felajánlja a skip/update/reinstall opciókat
detect_run_mode comp_keys

# Összesített státusz szöveg a dialog_yesno-hoz
STATUS=""
STATUS+="$(comp_line "vscode"      "VS Code"      "${VER[vscode_min]}")"$'\n'
STATUS+="$(comp_line "cursor"      "Cursor IDE"   "")"$'\n'
STATUS+="$(comp_line "kitty"       "Kitty"        "${VER[kitty_min]}")"$'\n'
STATUS+="$(comp_line "cline"       "CLINE ext"    "")"$'\n'
STATUS+="$(comp_line "continue_dev" "Continue.dev" "")"$'\n'

# Skip mód: minden naprakész, nincs telepítendő
[ "$RUN_MODE" = "skip" ] && {
  dialog_msg "Minden naprakész — INFRA $INFRA_NUM" \
    "\n$STATUS\n  Semmi sem változik."
  exit 0
}

# Megerősítés dialóg a komponens állapottal
dialog_yesno "Komponens állapot — INFRA $INFRA_NUM" \
"$STATUS
  Telepítési helyek:
    /usr/bin/code                      — VS Code
    $_REAL_HOME/tools/cursor/          — Cursor AppImage
    $_REAL_HOME/.continue/             — Continue.dev konfig

  Mód: $RUN_MODE — folytatjuk?" 22 || exit 0

# Számlálók a show_result() összesítőhöz
OK=0; SKIP=0; FAIL=0

# =============================================================================
# VS CODE
# =============================================================================
# Forrás: https://code.visualstudio.com/docs/setup/linux
# Microsoft APT repo + GPG kulcs alapú telepítés

if [ "${COMP_STATUS[vscode]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "VS Code telepítése / frissítése?"; then

    # Microsoft APT repo hozzáadása csak ha még nincs benne
    # source_exists: 00_lib_core.sh — grep alapú sources.list ellenőrzés
    if ! source_exists "packages.microsoft.com/repos/vscode"; then
      log "APT" "Microsoft VS Code repo hozzáadása"

      # GPG kulcs letöltés + trust store-ba helyezés
      wget -qO- "${URLS[ms_gpg]}" | gpg --dearmor > /tmp/microsoft.gpg
      sudo_run install -o root -g root -m 644 /tmp/microsoft.gpg \
        /etc/apt/trusted.gpg.d/microsoft.gpg
      rm -f /tmp/microsoft.gpg

      # APT sources.list.d bejegyzés
      echo "deb [arch=amd64] ${URLS[vscode_repo]} stable main" | \
        sudo_run tee /etc/apt/sources.list.d/vscode.list > /dev/null

      # APT cache frissítése az új repo-val
      sudo_run apt-get update -qq >> "$LOGFILE_AI" 2>&1
    fi

    # Telepítés progress ablakkal (apt_install_progress: 00_lib_apt.sh)
    apt_install_progress "VS Code" "VS Code telepítése..." code \
      && ((OK++)) || ((FAIL++))

    # Globális VS Code settings.json létrehozása
    # _REAL_HOME: 00_lib_core.sh — sudo-safe valós user home
    mkdir -p "$_REAL_HOME/.config/Code/User"
    printf '%s\n' "$VSCODE_SETTINGS" \
      > "$_REAL_HOME/.config/Code/User/settings.json"
    chown "$_REAL_UID:$_REAL_GID" \
      "$_REAL_HOME/.config/Code/User/settings.json"
    log "OK" "VS Code settings.json írva: $_REAL_HOME/.config/Code/User/settings.json"

  else
    ((SKIP++))
    log "SKIP" "VS Code telepítés kihagyva"
  fi
fi

# =============================================================================
# VS CODE EXTENSION-ÖK
# =============================================================================
# Extension profil kiválasztása checklist-ből.
# Alap és AI profil mindig települ.
# FONTOS: code --install-extension a VALÓDI user kontextusában kell fusson,
#   nem root-ként — sudo alatt a root profiljára telepítene!
#   Megoldás: HOME + sudo -u "$_REAL_USER"

if cmd_exists code; then

  # Checklist: user kiválasztja melyik profilokat kéri
  # dialog_checklist: 00_lib_ui.sh — YAD/whiptail checklist wrapper
  SELECTED_PROFILES=$(dialog_checklist \
    "VS Code extension profilok" \
    "  Alap + AI extension mindig települ.\n  Melyik profilokat adj hozzá?" \
    20 12 \
    "python"   "Python / AI-ML (ruff, black, pylance, jupyter)"  "ON" \
    "nodejs"   "Node.js / TypeScript (prettier, eslint, prisma)"  "ON" \
    "c64"      "C64 / Assembly (64tass, kick-assembler, ACME)"    "ON" \
    "sysadmin" "Sysadmin (shellcheck, ansible, PowerShell, YAML)" "ON")

  # Extension telepítés: nincs külön ask_proceed — ha a user elindította a
  # 06-os szálat és a VS Code elérhető, az extension-ök automatikusan települnek.
  # Extension telepítés install/update/reinstall módban.
  # FIX MÓD KIVÉTEL: fix módban az extension-ök már fent vannak (check megmutatta),
  #   csak a hiányzó komponenseket pótoljuk → extension loop nem fut fix-ben.
  # REINSTALL: teljes újratelepítés esetén igen.
  if [[ "$RUN_MODE" =~ ^(install|update|reinstall)$ ]]; then
    progress_open "VS Code Extensions" "Extension-ök telepítése..."
    ext_i=0

    # Segéd: extension telepítése a valódi user HOME-jában
    # --user-data-dir: explicit megadás → kiküszöböli a "mkdir: cannot create ''" warningot
    # sudo -u "$_REAL_USER": nem root profiljára telepít
    _install_ext() {
      local ext="$1"
      [ -z "$ext" ] && return
      HOME="$_REAL_HOME" sudo -u "$_REAL_USER" \
        code \
          --user-data-dir "$_REAL_HOME/.config/Code" \
          --install-extension "$ext" --force \
        >> "$LOGFILE_AI" 2>&1 || true
    }

    # Alap + AI profil: mindig települ (nem ajánlható fel kihagyásra)
    log "INFO" "Alap + AI extension-ök telepítése"
    for ext in ${VSCODE_EXT[base]} ${VSCODE_EXT[ai]}; do
      _install_ext "$ext"
      ((ext_i++))
      progress_set $((ext_i * 2 < 60 ? ext_i * 2 : 59)) "Alap/AI: $ext"
    done

    # Kiválasztott opcionális profilok (checklist-ből)
    for profile in $SELECTED_PROFILES; do
      profile="${profile//\"/}"   # idézőjel eltávolítás (YAD visszaad)
      [ -z "$profile" ] && continue
      [ -z "${VSCODE_EXT[$profile]:-}" ] && continue
      log "INFO" "Profil extension-ök: $profile"
      for ext in ${VSCODE_EXT[$profile]}; do
        _install_ext "$ext"
        ((ext_i++))
        progress_set $((ext_i < 90 ? ext_i : 89)) "$profile: $ext"
      done
    done

    progress_close
    ((OK++))
    log "OK" "VS Code extension-ök telepítve ($ext_i db)"
  else
    ((SKIP++))
    log "SKIP" "Extension telepítés kihagyva (skip mód)"
  fi
fi

# =============================================================================
# CLINE — VS Code AI coding agent
# =============================================================================
# CLINE: VS Code extension (saoudrizwan.claude-dev)
# Bekötés: Ollama openai-compatible API (http://localhost:11434/v1)
# Model: qwen2.5-coder:32b
# Forrás: CLINE extension dokumentáció (openai provider + openAiBaseUrl)

if [ "${COMP_STATUS[cline]:-missing}" != "ok" ] || \
   [ "$RUN_MODE" = "reinstall" ] || [ "$RUN_MODE" = "update" ]; then

  if ask_proceed "CLINE extension telepítése és Ollama-hoz kapcsolása?"; then

    # Extension telepítése a valódi user HOME-jában
    HOME="$_REAL_HOME" sudo -u "$_REAL_USER" \
      code --install-extension saoudrizwan.claude-dev --force \
      >> "$LOGFILE_AI" 2>&1

    # CLINE beállítások beillesztése a VS Code settings.json-ba
    # Python merge: meglévő settings.json megtartása, CLINE kulcsok felülírása/hozzáadása
    # _REAL_HOME: explicit átadás — sudo alatt `~` a root home-ra mutatna!
    SETTINGS_FILE="$_REAL_HOME/.config/Code/User/settings.json"
    mkdir -p "$(dirname "$SETTINGS_FILE")"

    python3 - << PYEOF >> "$LOGFILE_AI" 2>&1
import json, sys

settings_file = "$SETTINGS_FILE"
cline_json    = '''$CLINE_SETTINGS'''

try:
    with open(settings_file, 'r') as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

try:
    cline_settings = json.loads(cline_json)
except json.JSONDecodeError as e:
    print(f"HIBA: CLINE JSON parse sikertelen: {e}", file=sys.stderr)
    sys.exit(1)

settings.update(cline_settings)

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)

print(f"CLINE settings OK: {settings_file}")
PYEOF

    local_ec=$?
    if [ $local_ec -eq 0 ]; then
      chown "$_REAL_UID:$_REAL_GID" "$SETTINGS_FILE" 2>/dev/null || true
      ((OK++))
      log "OK" "CLINE telepítve + Ollama qwen2.5-coder:32b bekötve"

      dialog_msg "CLINE konfiguráció kész" \
"  CLINE bekötve az Ollama-hoz:
    Provider:  OpenAI-kompatibilis
    Base URL:  http://localhost:11434/v1
    API kulcs: ollama (dummy)
    Model:     qwen2.5-coder:32b

  VS Code-ban:
    Ctrl+Shift+P → CLINE: Open
    Vagy: bal oldali CLINE ikon

  Ha Anthropic API-t is akarsz:
    VS Code → Settings → cline.apiProvider → anthropic
    cline.apiKey → sk-ant-...

  Ollama-nak futnia kell:
    systemctl --user start ollama
    vagy: ollama serve" 22

    else
      ((FAIL++))
      log "FAIL" "CLINE settings merge sikertelen (Python exit $local_ec)"
    fi

  else
    ((SKIP++))
    log "SKIP" "CLINE telepítés kihagyva"
  fi
fi

# =============================================================================
# CONTINUE.DEV — tab autocomplete + inline chat
# =============================================================================
# Continue.dev: VS Code + JetBrains extension
# Chat: qwen2.5-coder:32b (Ollama) | Autocomplete: qwen2.5-coder:7b
# Embedding: nomic-embed-text (RAG) | Fallback: Claude Sonnet (Anthropic API)
# Konfig: ~/.continue/config.json

if [ "${COMP_STATUS[continue_dev]:-missing}" != "ok" ] || \
   [ "$RUN_MODE" = "reinstall" ] || [ "$RUN_MODE" = "update" ]; then

  if ask_proceed "Continue.dev telepítése? (tab autocomplete + Ollama bekötés)"; then

    # Extension telepítése a valódi user HOME-jában
    HOME="$_REAL_HOME" sudo -u "$_REAL_USER" \
      code --install-extension continue.continue --force \
      >> "$LOGFILE_AI" 2>&1

    # Continue konfig könyvtár + config.json létrehozása
    CONTINUE_DIR="$_REAL_HOME/.continue"
    mkdir -p "$CONTINUE_DIR"
    printf '%s\n' "$CONTINUE_CONFIG" > "$CONTINUE_DIR/config.json"

    # Ha van .env fájl Anthropic API kulccsal, automatikusan behelyettesítjük
    # a placeholder ANTHROPIC_API_KEY_IDE értéket a tényleges kulccsal
    if grep -q "ANTHROPIC_API_KEY" "$_REAL_HOME/.env" 2>/dev/null; then
      ANTHR_KEY=$(grep "^ANTHROPIC_API_KEY=" "$_REAL_HOME/.env" \
                  | cut -d= -f2- | tr -d '"' | head -1)
      if [ -n "$ANTHR_KEY" ]; then
        sed -i "s/ANTHROPIC_API_KEY_IDE/$ANTHR_KEY/" "$CONTINUE_DIR/config.json"
        log "OK" "Continue.dev: Anthropic API kulcs behelyettesítve .env-ből"
      fi
    fi

    # Tulajdonos javítás — sudo alatt root:root lenne
    chown -R "$_REAL_UID:$_REAL_GID" "$CONTINUE_DIR"

    ((OK++))
    log "OK" "Continue.dev telepítve + konfig írva: $CONTINUE_DIR/config.json"

    dialog_msg "Continue.dev konfiguráció kész" \
"  Continue.dev bekötve:
    Chat:         qwen2.5-coder:32b (Ollama, lokális)
    Autocomplete: qwen2.5-coder:7b  (Ollama, gyors)
    Embedding:    nomic-embed-text   (Ollama, RAG)
    Fallback:     Claude Sonnet      (Anthropic API)

  Konfig fájl: $CONTINUE_DIR/config.json

  VS Code-ban:
    Tab            → autocomplete elfogadás
    Ctrl+Shift+L   → Continue chat megnyitás
    Ctrl+I         → inline edit mód

  Ollama szükséges:
    systemctl --user start ollama
    Modellek: ollama pull qwen2.5-coder:32b
              ollama pull qwen2.5-coder:7b
              ollama pull nomic-embed-text" 26

  else
    ((SKIP++))
    log "SKIP" "Continue.dev telepítés kihagyva"
  fi
fi

# =============================================================================
# CURSOR IDE
# =============================================================================
# Cursor: AI-first kódszerkesztő, VS Code fork
# Telepítés: AppImage letöltés + indítóscript + .desktop entry
# URL: https://www.cursor.com/downloads (AppImage x64)

if [ "${COMP_STATUS[cursor]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "Cursor IDE letöltése és telepítése?"; then

    CURSOR_DIR="$_REAL_HOME/tools/cursor"
    mkdir -p "$CURSOR_DIR" "$_REAL_HOME/bin"

    # AppImage letöltés progress ablakkal (run_with_progress: 00_lib_apt.sh)
    run_with_progress "Cursor IDE" "Cursor IDE AppImage letöltése..." \
      wget -q -O "$CURSOR_DIR/cursor.AppImage" "${URLS[cursor_appimage]}"

    if [ -f "$CURSOR_DIR/cursor.AppImage" ]; then
      chmod +x "$CURSOR_DIR/cursor.AppImage"
      chown -R "$_REAL_UID:$_REAL_GID" "$CURSOR_DIR"

      # Indítóscript: --no-sandbox szükséges AppImage-hez
      cat > "$_REAL_HOME/bin/cursor" << CEOF
#!/bin/bash
# Cursor IDE indítóscript — Vibe Coding Workspace
# AppImage: $CURSOR_DIR/cursor.AppImage
exec "$CURSOR_DIR/cursor.AppImage" --no-sandbox "\$@"
CEOF
      chmod +x "$_REAL_HOME/bin/cursor"
      chown "$_REAL_UID:$_REAL_GID" "$_REAL_HOME/bin/cursor"

      # Desktop entry: GNOME/KDE alkalmazásmenübe
      # _REAL_HOME: explicit — sudo alatt $HOME=/root lenne!
      DESKTOP_DIR="$_REAL_HOME/.local/share/applications"
      mkdir -p "$DESKTOP_DIR"
      cat > "$DESKTOP_DIR/cursor.desktop" << DEOF
[Desktop Entry]
Name=Cursor
Comment=AI-powered Code Editor
Exec=$_REAL_HOME/bin/cursor %F
Icon=code
Type=Application
Categories=Development;TextEditor;IDE;
StartupWMClass=Cursor
MimeType=text/plain;inode/directory;
DEOF
      chown "$_REAL_UID:$_REAL_GID" "$DESKTOP_DIR/cursor.desktop"

      # update-desktop-database ha elérhető
      command -v update-desktop-database &>/dev/null && \
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true

      ((OK++))
      log "OK" "Cursor IDE telepítve: $CURSOR_DIR/cursor.AppImage"
      log "OK" "Indítóscript: $_REAL_HOME/bin/cursor"

    else
      ((FAIL++))
      dialog_warn "Cursor — Letöltési hiba" \
        "\n  Az AppImage letöltése sikertelen.\n  URL: ${URLS[cursor_appimage]}\n\n  Manuálisan: cursor.com/downloads → AppImage x64" 12
      log "FAIL" "Cursor AppImage letöltés sikertelen: ${URLS[cursor_appimage]}"
    fi

  else
    ((SKIP++))
    log "SKIP" "Cursor IDE telepítés kihagyva"
  fi
fi

# =============================================================================
# KITTY TERMINAL
# =============================================================================
# Kitty: GPU-gyorsított terminál emulátorr
# Telepítő: curl pipe sh (kovidgoyal.net officialis módszer)
# Forrás: https://sw.kovidgoyal.net/kitty/binary/
# Konfig: ~/.config/kitty/kitty.conf (JetBrains Mono, scrollback, powerline tabs)

if [ "${COMP_STATUS[kitty]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "Kitty terminál telepítése?"; then

    # curl elérhetőség ellenőrzés — a kitty telepítő curl-t igényel
    if ! cmd_exists curl; then
      log "APT" "curl telepítése (kitty telepítőhöz szükséges)"
      apt_install_log "curl" curl
    fi

    # Telepítés: kovidgoyal.net telepítő script, user kontextusban
    # FONTOS: sudo -u "$_REAL_USER" HOME="$_REAL_HOME" szükséges!
    #   Nélküle: sudo/root alatt fut → $HOME=/root → /root/.local/kitty.app-ba telepít
    #   (azonos probléma mint a VS Code extension-öknél)
    # Forrás: https://sw.kovidgoyal.net/kitty/binary/ — hivatalos telepítő
    run_with_progress "Kitty" "Kitty terminál telepítése..." \
      sudo -u "$_REAL_USER" HOME="$_REAL_HOME" \
      bash -c "curl -fsSL '${URLS[kitty_installer]}' | sh /dev/stdin launch=n"

    # Ellenőrzés: csak a VALÓDI user home-jában keresünk!
    # cmd_exists kitty NEM megfelelő — sudo alatt root PATH-ban is megtalálná
    # a /root/.local/kitty.app/bin/kitty-t → hamis pozitív
    if [ -f "$_REAL_HOME/.local/kitty.app/bin/kitty" ]; then

      # PATH szimlink: ~/bin/kitty → ~/.local/kitty.app/bin/kitty
      if [ -f "$_REAL_HOME/.local/kitty.app/bin/kitty" ]; then
        ln -sf "$_REAL_HOME/.local/kitty.app/bin/kitty" \
          "$_REAL_HOME/bin/kitty" 2>/dev/null || true
        chown -h "$_REAL_UID:$_REAL_GID" "$_REAL_HOME/bin/kitty" 2>/dev/null || true
      fi

      # Konfig fájl írása
      mkdir -p "$_REAL_HOME/.config/kitty"
      cat > "$_REAL_HOME/.config/kitty/kitty.conf" << 'KEOF'
# Kitty konfig — Vibe Coding Workspace
font_family         JetBrains Mono
bold_font           JetBrains Mono Bold
italic_font         JetBrains Mono Italic
font_size           13.0
scrollback_lines    10000
copy_on_select      yes
tab_bar_style       powerline
background_opacity  0.96
# GPU rendering: defaults — Kitty mindig GPU-gyorsítást próbál
KEOF
      chown -R "$_REAL_UID:$_REAL_GID" "$_REAL_HOME/.config/kitty"

      ((OK++))
      log "OK" "Kitty terminál telepítve + konfig írva"

    else
      ((FAIL++))
      dialog_warn "Kitty — Telepítési hiba" \
        "\n  A kitty telepítő lefutott, de a bináris nem található.\n  Ellenőrizd: ~/.local/kitty.app/bin/kitty\n  Manuális: sw.kovidgoyal.net/kitty/" 12
      log "FAIL" "Kitty bináris nem található telepítés után"
    fi

  else
    ((SKIP++))
    log "SKIP" "Kitty telepítés kihagyva"
  fi
fi

# =============================================================================
# PATH BEÁLLÍTÁS
# =============================================================================
# ~/bin hozzáadása PATH-hoz ha még nincs benne (cursor, kitty indítóscriptek)

for RC in "$_REAL_HOME/.zshrc" "$_REAL_HOME/.bashrc"; do
  if [ -f "$RC" ]; then
    grep -q 'PATH.*\$HOME/bin\|PATH.*~/bin' "$RC" 2>/dev/null || {
      printf '\n# Vibe Coding Workspace — helyi bin (cursor, kitty)\nexport PATH="$HOME/bin:$PATH"\n' \
        >> "$RC"
      log "OK" "PATH=\$HOME/bin hozzáadva: $RC"
    }
  fi
done

# =============================================================================
# INFRA STATE LEZÁRÁS
# =============================================================================

infra_state_set "MOD_06_DONE" "true"
log "STATE" "MOD_06_DONE=true → state fájlba írva"

# ── Post-install COMP STATE: teljes re-check + mentés ────────────────────────
# LOGIKA:
#   check mód     → comp_save_state az ELEJÉN fut (semmi sem változik → eleje = vége)
#   install/update/fix/reinstall → re-check ITT, a telepítés UTÁN fut
#     Így a state mindig a script UTÁNI valódi állapotot tükrözi.
#
# A check-ek megismétlése szükséges — nincs rövidebb, megbízható módja annak,
# hogy az összes telepítés eredményét egyetlen lépésben ellenőrizzük.

if [[ "$RUN_MODE" =~ ^(install|update|fix|reinstall)$ ]]; then
  log "COMP" "Post-install re-check futtatása (mód: $RUN_MODE)..."

  comp_check_vscode "${VER[vscode_min]}" "$_REAL_USER" "$_REAL_HOME"

  check_component "cursor"     "([ -f '$_REAL_HOME/bin/cursor' ] || [ -f '$_REAL_HOME/tools/cursor/cursor.AppImage' ]) && echo 1" "1"

  check_component "kitty"     "( [ -x '$_REAL_HOME/.local/kitty.app/bin/kitty' ] && '$_REAL_HOME/.local/kitty.app/bin/kitty' --version 2>/dev/null || [ -x '$_REAL_HOME/bin/kitty' ] && '$_REAL_HOME/bin/kitty' --version 2>/dev/null ) | grep -oP '[\d.]+' | head -1" "${VER[kitty_min]}"

  check_component "cline"     "HOME='$_REAL_HOME' sudo -u '$_REAL_USER' code --list-extensions 2>/dev/null | grep -q saoudrizwan.claude-dev && echo 1" "1"

  check_component "continue_dev"     "HOME='$_REAL_HOME' sudo -u '$_REAL_USER' code --list-extensions 2>/dev/null | grep -q continue.continue && echo 1" "1"

  comp_save_state "$INFRA_NUM"
  log "COMP" "Post-install COMP state mentve: COMP_06_* (telepítés utáni valós állapot)"
fi

# =============================================================================
# ÖSSZESÍTŐ
# =============================================================================
# show_result: OK/SKIP/FAIL számlálók + log útvonalak (00_lib_core.sh)

show_result "$OK" "$SKIP" "$FAIL"

dialog_msg "INFRA $INFRA_NUM — Összefoglalás" \
"  Szerkesztők:
    code .    → VS Code
    cursor .  → Cursor IDE (AI-first)
    kitty     → GPU-gyorsított terminál

  CLINE (VS Code bal panel → CLINE ikon):
    Model:  qwen2.5-coder:32b (Ollama)
    URL:    http://localhost:11434/v1

  Continue.dev:
    Tab          → autocomplete
    Ctrl+Shift+L → chat megnyitás
    Ctrl+I       → inline edit
    Ollama szükséges: systemctl --user start ollama

  VS Code profilok:
    File → Profiles → New Profile
    C64 Dev | Python/AI-ML | Node.js | Sysadmin

  AI log:    $LOGFILE_AI
  Human log: $LOGFILE_HUMAN" 30
