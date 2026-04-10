#!/bin/bash
# =============================================================================
# 06_editors.sh — Cursor IDE + VS Code + CLINE + Continue.dev
# Futtatás: bash 06_editors.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" || { echo "00_lib.sh hiányzik!"; exit 1; }

# =============================================================================
# KONFIGURÁCIÓ — MINDEN PARAMÉTER ITT
# =============================================================================

INFRA_NUM="06"
INFRA_NAME="Cursor IDE + VS Code + CLINE + Continue.dev"
INFRA_HW_REQ=""

# ── Verziók ───────────────────────────────────────────────────────────────────
declare -A VER=(
  [node_for_cline]="22"
)

# ── URL-ek ────────────────────────────────────────────────────────────────────
declare -A URLS=(
  [cursor_appimage]="https://downloader.cursor.sh/linux/appImage/x64"
  [kitty_installer]="https://sw.kovidgoyal.net/kitty/installer.sh"
  [ms_gpg]="https://packages.microsoft.com/keys/microsoft.asc"
  [vscode_repo]="https://packages.microsoft.com/repos/vscode"
)

# ── VS Code extension-ök csoportonként ────────────────────────────────────────
declare -A VSCODE_EXT=(
  # Alap — minden profilba
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

  # CLINE + AI asszisztens
  [ai]="saoudrizwan.claude-dev
        continue.continue
        GitHub.copilot
        GitHub.copilot-chat"

  # Python / AI-ML profil
  [python]="ms-python.python
            ms-python.vscode-pylance
            ms-python.black-formatter
            ms-python.isort
            ms-toolsai.jupyter
            ms-toolsai.jupyter-keymap
            charliermarsh.ruff
            njpwerner.autodocstring"

  # Node.js / TypeScript profil
  [nodejs]="esbenp.prettier-vscode
            dbaeumer.vscode-eslint
            Prisma.prisma
            bradlc.vscode-tailwindcss
            christian-kohler.path-intellisense
            ms-vscode.vscode-typescript-next"

  # C64 / Assembly profil
  [c64]="tlgkccampbell.code-casl65
         paulhocker.kick-assembler-vscode-ext
         bgold-cosmos.vscode-acme-cross-asm"

  # Sysadmin profil
  [sysadmin]="ms-vscode.powershell
              timonwong.shellcheck
              foxundermoon.shell-format
              redhat.ansible
              redhat.vscode-yaml"
)

# ── CLINE konfig (Ollama ↔ CLINE összekapcsolás) ──────────────────────────────
CLINE_SETTINGS='{
  "cline.apiProvider": "openai",
  "cline.openAiBaseUrl": "http://localhost:11434/v1",
  "cline.openAiApiKey": "ollama",
  "cline.openAiModelId": "qwen2.5-coder:32b",
  "cline.maxTokens": 8192
}'

# ── Continue.dev konfig (Ollama + Anthropic) ──────────────────────────────────
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
    "title": "Qwen 7B (gyors)",
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

# ── Komponens ellenőrzések ────────────────────────────────────────────────────
COMP_CHECK=(
  "vscode|code --version|1.85.0"
  "cursor|[ -f $HOME/bin/cursor ] && echo 1|1"
  "kitty|kitty --version|0.30.0"
  "cline|code --list-extensions 2>/dev/null | grep -q saoudrizwan.claude-dev && echo 1|1"
  "continue_dev|code --list-extensions 2>/dev/null | grep -q continue.continue && echo 1|1"
)

# Valódi felhasználó home-ja — sudo alatt $HOME=/root lenne
_REAL_USER="${SUDO_USER:-$USER}"
_REAL_HOME="$(getent passwd "$_REAL_USER" | cut -d: -f6)"
# =============================================================================
# INICIALIZÁLÁS
# =============================================================================

LOGFILE_AI="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="$LOGFILE_AI"
log_init

# INFRA state betöltése (VS Code Python interpreter + CLINE konfig)
PYTORCH_INDEX=$(infra_state_get "PYTORCH_INDEX" "cu126")
CUDA_VER=$(infra_state_get "CUDA_VER" "12.6")
HW_GPU_ARCH=$(infra_state_get "HW_GPU_ARCH" "igpu")
log "STATE" "Betöltve: CUDA=$CUDA_VER, PyTorch=$PYTORCH_INDEX, GPU=$HW_GPU_ARCH"


# =============================================================================
# KOMPONENS FELMÉRÉS
# =============================================================================

dialog_msg "INFRA $INFRA_NUM — $INFRA_NAME" "
  Telepíti / frissíti:
    • VS Code + összes extension (5 profil)
    • Cursor IDE (AppImage + desktop entry)
    • Kitty terminal
    • CLINE (VS Code AI coding agent)
    • Continue.dev (tab autocomplete + chat)
    • CLINE ↔ Ollama konfiguráció (qwen2.5-coder:32b)
    • Continue ↔ Ollama + Anthropic konfiguráció

  Mód: $RUN_MODE" 20


# Logba: mit telepít, hova
log_infra_header "    • VS Code + 4 profil (AI, C64, Node.js, Sysadmin)
    • Cursor IDE — AI-first kódszerkesztő
    • CLINE — VS Code AI coding agent (Ollama bekötve)
    • Continue.dev — tab autocomplete + inline chat
    • Kitty — GPU gyorsított terminál"
log_install_paths "    /usr/bin/code              — VS Code
    $_REAL_HOME/tools/cursor/  — Cursor AppImage
    $_REAL_HOME/.continue/     — Continue.dev konfig
    $_REAL_HOME/.config/Code/  — VS Code beállítások"

for comp_spec in "${COMP_CHECK[@]}"; do
  IFS='|' read -r cname cver_cmd cmin <<< "$comp_spec"
  check_component "$cname" "$cver_cmd" "$cmin"
done

STATUS=""
for comp_spec in "${COMP_CHECK[@]}"; do
  IFS='|' read -r cname _ cmin <<< "$comp_spec"
  STATUS+="$(comp_line "$cname" "$cname" "$cmin")"$'\n'
done

comp_keys=(vscode cursor kitty cline continue_dev)
log_comp_status "${COMP_CHECK[@]}"
detect_run_mode comp_keys
[ "$RUN_MODE" = "skip" ] && {
  dialog_msg "Minden naprakész" "\n$STATUS\n  Semmi sem változik."; exit 0
}

dialog_yesno "Komponens állapot" "\n$STATUS\n  Telepítési helyek:\n    /usr/bin/code              — VS Code
    $_REAL_HOME/tools/cursor/  — Cursor AppImage
    $_REAL_HOME/.continue/     — Continue.dev konfig
    $_REAL_HOME/.config/Code/  — VS Code beállítások\n\n  Mód: $RUN_MODE — folytatjuk?" 18 || exit 0

OK=0; SKIP=0; FAIL=0

# =============================================================================
# VS CODE
# =============================================================================

if [ "${COMP_STATUS[vscode]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "VS Code telepítése?"; then
    if ! source_exists "packages.microsoft.com/repos/vscode"; then
      wget -qO- "${URLS[ms_gpg]}" | gpg --dearmor > /tmp/microsoft.gpg
      sudo install -o root -g root -m 644 /tmp/microsoft.gpg \
        /etc/apt/trusted.gpg.d/microsoft.gpg
      echo "deb [arch=amd64] ${URLS[vscode_repo]} stable main" | \
        sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
      sudo apt-get update -qq >> "$LOGFILE_AI" 2>&1
    fi
    apt_install_progress "VS Code" "VS Code telepítése..." code && ((OK++)) || ((FAIL++))

    # Globális settings
    mkdir -p "$_REAL_HOME/.config/Code/User"
    echo "$VSCODE_SETTINGS" > "$_REAL_HOME/.config/Code/User/settings.json"
  else
    ((SKIP++))
  fi
fi

# =============================================================================
# VS CODE EXTENSION-ÖK
# =============================================================================

if cmd_exists code; then
  SELECTED_PROFILES=$(dialog_checklist \
    "VS Code profil extension-ök" \
    "\n  Melyik profilok extension-jeit telepítsük?\n  (Alap és AI mindig települ)" \
    18 10 \
    "python"   "Python / AI-ML (ruff, black, jupyter)"   "ON" \
    "nodejs"   "Node.js / TypeScript (prettier, eslint)"  "ON" \
    "c64"      "C64 / Assembly (64tass, kick-assembler)"  "ON" \
    "sysadmin" "Sysadmin (PowerShell, Ansible, Shell)"   "ON")

  if ask_proceed "Extension-ök telepítése?"; then
    progress_open "VS Code Extensions" "Extension-ök telepítése..."
    local_i=0

    # Alap + AI mindig
    for ext in ${VSCODE_EXT[base]} ${VSCODE_EXT[ai]}; do
      [ -z "$ext" ] && continue
      code --install-extension "$ext" --force >> "$LOGFILE_AI" 2>&1 || true
      ((local_i++))
      progress_set $((local_i * 3 < 90 ? local_i * 3 : 89)) "Telepítés: $ext"
    done

    # Kiválasztott profilok
    for profile in $(echo "$SELECTED_PROFILES" | tr -d '"'); do
      [ -z "$profile" ] && continue
      [ -z "${VSCODE_EXT[$profile]:-}" ] && continue
      for ext in ${VSCODE_EXT[$profile]}; do
        [ -z "$ext" ] && continue
        code --install-extension "$ext" --force >> "$LOGFILE_AI" 2>&1 || true
        ((local_i++))
        progress_set $((local_i * 2 < 90 ? local_i * 2 : 89)) "Telepítés: $ext"
      done
    done

    progress_close
    ((OK++))
    log "OK" "VS Code extension-ök telepítve"
  else
    ((SKIP++))
  fi
fi

# =============================================================================
# CLINE — VS Code AI coding agent
# =============================================================================

if [ "${COMP_STATUS[cline]:-missing}" != "ok" ] || [ "$RUN_MODE" != "skip" ]; then
  if ask_proceed "CLINE telepítése és Ollama-hoz kapcsolása?"; then
    # Extension telepítése
    code --install-extension saoudrizwan.claude-dev --force >> "$LOGFILE_AI" 2>&1

    # CLINE settings bekötése Ollama-hoz
    CLINE_SETTINGS_DIR="$_REAL_HOME/.vscode/extensions/saoudrizwan.claude-dev-latest"
    mkdir -p "$_REAL_HOME/.config/Code/User"

    # Beillesztjük a CLINE konfigot a VS Code settings.json-ba
    python3 -c "
import json, os
settings_file = os.path.expanduser('~/.config/Code/User/settings.json')
try:
    with open(settings_file) as f: s = json.load(f)
except: s = {}
cline = json.loads('''$CLINE_SETTINGS''')
s.update(cline)
with open(settings_file, 'w') as f: json.dump(s, f, indent=2)
print('CLINE settings OK')
" >> "$LOGFILE_AI" 2>&1

    ((OK++))
    log "OK" "CLINE telepítve + Ollama qwen2.5-coder:32b bekötve"

    dialog_msg "CLINE konfiguráció" "
  CLINE bekötve az Ollama-hoz:
    Provider:  OpenAI-kompatibilis
    Base URL:  http://localhost:11434/v1
    Model:     qwen2.5-coder:32b

  Használat VS Code-ban:
    Ctrl+Shift+P → CLINE: Open
    Vagy a bal oldali CLINE ikon

  Ha Anthropic API-t is akarsz:
    VS Code → Settings → cline.apiProvider → anthropic
    cline.apiKey → sk-ant-..." 18
  else
    ((SKIP++))
  fi
fi

# =============================================================================
# CONTINUE.DEV — tab autocomplete + inline chat
# =============================================================================

if [ "${COMP_STATUS[continue_dev]:-missing}" != "ok" ] || [ "$RUN_MODE" != "skip" ]; then
  if ask_proceed "Continue.dev telepítése? (tab autocomplete + Ollama)"; then
    code --install-extension continue.continue --force >> "$LOGFILE_AI" 2>&1

    # Continue konfig fájl
    mkdir -p "$_REAL_HOME/.continue"
    echo "$CONTINUE_CONFIG" > "$_REAL_HOME/.continue/config.json"

    # API key placeholder cseréje ha van .env
    if grep -q "ANTHROPIC_API_KEY" "$_REAL_HOME/.env" 2>/dev/null; then
      ANTHR_KEY=$(grep "ANTHROPIC_API_KEY" "$_REAL_HOME/.env" | cut -d= -f2)
      sed -i "s/ANTHROPIC_API_KEY_IDE/$ANTHR_KEY/" "$_REAL_HOME/.continue/config.json"
    fi

    ((OK++))
    log "OK" "Continue.dev telepítve + konfiguráció írva"

    dialog_msg "Continue.dev konfiguráció" "
  Continue bekötve:
    Chat:          qwen2.5-coder:32b (Ollama)
    Autocomplete:  qwen2.5-coder:7b (Ollama, gyors)
    Embedding:     nomic-embed-text (Ollama, RAG)
    Fallback:      Claude Sonnet (Anthropic API)

  Konfig: ~/.continue/config.json

  VS Code-ban:
    Tab → autocomplete elfogadása
    Ctrl+Shift+L → Continue chat megnyitása
    Ctrl+I → inline edit

  Ollama-nak futnia kell:
    ollama serve" 20
  else
    ((SKIP++))
  fi
fi

# =============================================================================
# CURSOR IDE
# =============================================================================

if [ "${COMP_STATUS[cursor]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "Cursor IDE letöltése és telepítése?"; then
    CURSOR_DIR="$_REAL_HOME/tools/cursor"
    mkdir -p "$CURSOR_DIR" "$_REAL_HOME/bin"

    run_with_progress "Cursor" "Cursor IDE AppImage letöltése..." \
      wget -q -O "$CURSOR_DIR/cursor.AppImage" "${URLS[cursor_appimage]}"

    if [ -f "$CURSOR_DIR/cursor.AppImage" ]; then
      chmod +x "$CURSOR_DIR/cursor.AppImage"

      # Indítóscript
      cat > "$_REAL_HOME/bin/cursor" << CEOF
#!/bin/bash
exec "$CURSOR_DIR/cursor.AppImage" --no-sandbox "\$@"
CEOF
      chmod +x "$_REAL_HOME/bin/cursor"

      # Desktop entry
      mkdir -p "$_REAL_HOME/.local/share/applications"
      cat > "$_REAL_HOME/.local/share/applications/cursor.desktop" << DEOF
[Desktop Entry]
Name=Cursor
Comment=AI-powered Code Editor
Exec=$HOME/bin/cursor %F
Type=Application
Categories=Development;TextEditor;
StartupWMClass=Cursor
DEOF

      ((OK++))
      log "OK" "Cursor IDE telepítve: $CURSOR_DIR"
    else
      ((FAIL++))
      dialog_warn "Cursor — Hiba" "\n  Letöltés sikertelen.\n  Manuálisan: cursor.sh" 10
    fi
  else
    ((SKIP++))
  fi
fi

# =============================================================================
# KITTY TERMINAL
# =============================================================================

if [ "${COMP_STATUS[kitty]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "Kitty terminal telepítése?"; then
    run_with_progress "Kitty" "Kitty terminal telepítése..." \
      bash -c "curl -L ${URLS[kitty_installer]} | sh /dev/stdin"

    if cmd_exists kitty || [ -f "$_REAL_HOME/.local/kitty.app/bin/kitty" ]; then
      ln -sf "$_REAL_HOME/.local/kitty.app/bin/kitty" "$_REAL_HOME/bin/kitty" 2>/dev/null || true

      mkdir -p "$_REAL_HOME/.config/kitty"
      cat > "$_REAL_HOME/.config/kitty/kitty.conf" << 'KEOF'
font_family      JetBrains Mono
bold_font        JetBrains Mono Bold
font_size        13.0
scrollback_lines 10000
copy_on_select   yes
tab_bar_style    powerline
background_opacity 0.96
KEOF
      ((OK++))
    else
      ((FAIL++))
    fi
  else
    ((SKIP++))
  fi
fi

# =============================================================================
# PATH beállítás
# =============================================================================

for RC in "$_REAL_HOME/.zshrc" "$_REAL_HOME/.bashrc"; do
  grep -q 'PATH.*$HOME/bin' "$RC" 2>/dev/null || \
    echo 'export PATH="$HOME/bin:$PATH"' >> "$RC"
done

# =============================================================================
# ÖSSZESÍTŐ
# =============================================================================

show_result "$OK" "$SKIP" "$FAIL"

dialog_msg "Összefoglalás — Szerkesztők" "
  VS Code:      code .
  Cursor IDE:   cursor .
  Kitty:        kitty

  CLINE:        VS Code bal panel → CLINE ikon
                Model: qwen2.5-coder:32b (Ollama)

  Continue.dev: Tab → autocomplete
                Ctrl+Shift+L → chat
                Ollama szükséges: ollama serve

  Profilok (VS Code):
    File → Profiles → New Profile
    C64 Dev | AI/ML | Node.js | Sysadmin

  AI log:    $LOGFILE_AI
  Human log: $LOGFILE_HUMAN" 24
