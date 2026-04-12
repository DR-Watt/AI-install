#!/bin/bash
# =============================================================================
# 01b_post_reboot.sh — User Environment v6.8
#                       Zsh · Oh My Zsh · Shell konfiguráció · PATH
#
# Változtatások v6.8 (2026-04-12 — OMZ guard + hibakezelés):
#
#   BUG FIX 1: .zshrc generálás OMZ guard
#     Tünet: OMZ telepítés FAIL (github.com nem elérhető) után a 4. lépés
#     megkérdezte '.zshrc generálása?' — hiba, mert a generált .zshrc
#     'source $ZSH/oh-my-zsh.sh' sort tartalmaz, ami shell hibát adna OMZ nélkül.
#
#     Fix: _OMZ_READY flag bevezetése
#       3. lépés elején: _OMZ_READY=false (könyvtár-alapú init)
#       OMZ könyvtár + oh-my-zsh.sh létezik → _OMZ_READY=true
#       4. lépés elején: if ! _OMZ_READY → SKIP + dialog_warn
#
#   BUG FIX 2: curl előellenőrzés az OMZ installer előtt
#     Ha a raw.githubusercontent.com nem elérhető → azonnal FAIL + dialog
#     (ne pipe-ban faileljünk silently, hanem explicit hibaüzenet)
#
# Változtatások v6.7 (01a/CORE szál 2026-04-12 fejlesztések alapján):
#   - APT mirror fallback: hu.archive.ubuntu.com → archive.ubuntu.com
#   - HW_OS_CODENAME + HW_OS_VERSION betöltése a state-ből
#
# Változtatások v6.6 (idempotency fix):
#   - 2. lépés: fix módban pkg_installed check
#   - 4. lépés: fix módban .zshrc skip ha létezik
#   - 6. lépés: .aliases és .tmux.conf backup
#
# Változtatások v6.5 (COMP STATE integráció):
#   - COMP_USE_CACHED / comp_load_state / comp_save_state
#   - RUN_MODE guard minden lépésen
#
# Futtatás:  sudo bash 01b_post_reboot.sh
#            sudo bash 00_master.sh  (01b kijelölve)
#
# Dokumentáció referenciák:
#   Oh My Zsh:           https://github.com/ohmyzsh/ohmyzsh/wiki
#   Zsh dokumentáció:    https://zsh.sourceforge.io/Doc/
#   autosuggestions:     https://github.com/zsh-users/zsh-autosuggestions
#   syntax-highlighting: https://github.com/zsh-users/zsh-syntax-highlighting
#   zsh-completions:     https://github.com/zsh-users/zsh-completions
#   powerlevel10k:       https://github.com/romkatv/powerlevel10k
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" \
  || { echo "HIBA: 00_lib.sh hiányzik! Elvárt helye: $LIB"; exit 1; }

# =============================================================================
# KONFIGURÁCIÓ
# =============================================================================

INFRA_NUM="01b"
INFRA_NAME="User Environment (post-reboot)"
INFRA_HW_REQ=""

declare -A MIN_VER=(
  [zsh]="5.8"
  [git]="2.34"
)

declare -A OMZ_URLS=(
  [install]="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
  [autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions"
  [syntax_hl]="https://github.com/zsh-users/zsh-syntax-highlighting"
  [completions]="https://github.com/zsh-users/zsh-completions"
  [p10k]="https://github.com/romkatv/powerlevel10k"
)

declare -A PKGS=(
  [shell]="zsh git"
  [modern_cli]="fzf bat eza ripgrep fd-find zoxide"
  [terminal]="tmux"
)

ZSH_THEME="powerlevel10k/powerlevel10k"

ZSH_PLUGINS=(
  "git"
  "docker"
  "docker-compose"
  "python"
  "pip"
  "node"
  "sudo"
  "colored-man-pages"
  "command-not-found"
  "history"
  "copypath"
  "extract"
  "fzf"
  "zoxide"
  "zsh-autosuggestions"
  "zsh-syntax-highlighting"
  "zsh-completions"
)

COMP_CHECK=(
  "zsh|zsh --version|${MIN_VER[zsh]}"
  "ohmyzsh|[ -d '$_REAL_HOME/.oh-my-zsh/.git' ] && echo 1|1"
)

# =============================================================================
# INICIALIZÁLÁS
# =============================================================================

[ "$EUID" -ne 0 ] && {
  echo "HIBA: Ez a script root jogosultságot igényel."
  echo "      Futtatás: sudo bash $(basename "$0")"
  exit 1
}

REAL_USER="${_REAL_USER}"
REAL_HOME="${_REAL_HOME}"
REAL_UID="${_REAL_UID}"
REAL_GID="${_REAL_GID}"

LOGFILE_AI="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="$LOGFILE_AI"

LOCK="/tmp/.install_01b.lock"
check_lock "$LOCK"
trap 'rm -f "$LOCK"; log "LOCK" "Lock felszabadítva"' EXIT

log_init
hw_detect
infra_state_init

# State betöltés
_CUDA_VER="$(infra_state_get "CUDA_VER" "12.6")"
_HW_PROFILE="$(infra_state_get "HW_PROFILE" "unknown")"
_HW_GPU_NAME="$(infra_state_get "HW_GPU_NAME" "ismeretlen GPU")"
_PYTORCH_IDX="$(infra_state_get "PYTORCH_INDEX" "cu126")"
_HW_OS_CODENAME="$(infra_state_get "HW_OS_CODENAME" "noble")"
_HW_OS_VERSION="$(infra_state_get "HW_OS_VERSION" "24.04")"

log "STATE" "Betöltve: CUDA=$_CUDA_VER | OS=Ubuntu ${_HW_OS_VERSION} (${_HW_OS_CODENAME}) | PyTorch=$_PYTORCH_IDX"
log "INFO"  "Valódi user: $REAL_USER | Home: $REAL_HOME | GUI: $GUI_BACKEND"

# =============================================================================
# ELŐFELTÉTELEK
# =============================================================================

if ! infra_require "01a" "System Foundation (01a_system_foundation.sh)"; then
  log "FAIL" "Előfeltétel hiányzik: 01a — kilépés"
  exit 1
fi

if hw_has_nvidia 2>/dev/null; then
  if ! nvidia-smi &>/dev/null 2>&1; then
    dialog_warn "REBOOT nem történt?" "
  A 01a_system_foundation.sh REBOOT-ot igényel az NVIDIA driver betöltéséhez.
  Az nvidia-smi most nem válaszol.

  Ha a reboot megtörtént és ez téves riasztás, folytathatod.
  Ha még nem indítottad újra: sudo reboot, majd futtasd újra a 01b-t.

  Folytatjuk?" 18
    [ $? -ne 0 ] && { log "USER" "Megszakítva — REBOOT nem igazolható"; exit 0; }
    log "WARN" "nvidia-smi nem válaszol — felhasználó engedélyével folytatva"
  else
    _DRV_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    log "OK" "NVIDIA driver betöltve: $_DRV_VER — REBOOT igazolva"
    infra_state_set "INST_DRIVER_VER" "$_DRV_VER"
  fi
fi

# =============================================================================
# KOMPONENS ÁLLAPOT FELMÉRÉS
# =============================================================================

log "COMP" "━━━ Komponens felmérés ━━━"

if [ "${COMP_USE_CACHED:-false}" = "true" ] && comp_state_exists "$INFRA_NUM"; then
  comp_load_state "$INFRA_NUM"
  _state_age=$(comp_state_age_hours "$INFRA_NUM")
  log "COMP" "Mentett check betöltve — INFRA $INFRA_NUM (${_state_age} óra)"
else
  comp_check_zsh "${MIN_VER[zsh]}"
  comp_check_ohmyzsh "$REAL_HOME/.oh-my-zsh"

  if [ "$RUN_MODE" = "check" ]; then
    comp_save_state "$INFRA_NUM"
    log "COMP" "Check mód: COMP state mentve"
  fi
fi

log_comp_status "${COMP_CHECK[@]}"
log "COMP" "zsh: ${COMP_STATUS[zsh]:-missing} (${COMP_VER[zsh]:-—})"
log "COMP" "ohmyzsh: ${COMP_STATUS[ohmyzsh]:-missing} (${COMP_VER[ohmyzsh]:-—})"

# =============================================================================
# ÜDVÖZLŐ DIALOG
# =============================================================================

log_infra_header \
"    • Zsh shell (alapértelmezett shell: chsh)
    • Oh My Zsh + plugins (autosuggestions, syntax-hl, completions)
    • Powerlevel10k téma (git, Python, CUDA prompt info)
    • .zshrc teljes konfiguráció (CUDA, pyenv, nvm, workspace aliasok)
    • Modern CLI eszközök (fzf, bat, eza, ripgrep, zoxide)
    • ~/.aliases, ~/.tmux.conf, git global konfig"

log_install_paths \
"    ~/.oh-my-zsh/                    — Oh My Zsh keretrendszer
    ~/.oh-my-zsh/custom/plugins/     — külső plugin-ok
    ~/.oh-my-zsh/custom/themes/      — powerlevel10k téma
    ~/.zshrc                         — fő shell konfig
    ~/.aliases                       — workspace aliasok
    ~/.tmux.conf                     — tmux konfig"

STATUS=""
STATUS+="$(comp_line "zsh"     "Zsh"       "${MIN_VER[zsh]}")"$'\n'
STATUS+="$(comp_line "ohmyzsh" "Oh My Zsh" "")"$'\n'

dialog_msg "INFRA ${INFRA_NUM} — ${INFRA_NAME}" "
  GPU:         ${_HW_GPU_NAME}
  OS:          Ubuntu ${_HW_OS_VERSION} (${_HW_OS_CODENAME})
  CUDA:        ${_CUDA_VER} (PyTorch: ${_PYTORCH_IDX})
  Mód:         $RUN_MODE
  Felhasználó: $REAL_USER

  Komponens állapot:
${STATUS}
  Telepíti:
    • Zsh ${MIN_VER[zsh]}+ (alapértelmezett shell)
    • Oh My Zsh + 3 plugin + powerlevel10k téma
    • .zshrc generálás (csak ha OMZ telepítve)
    • Modern CLI: fzf, bat, eza, ripgrep, zoxide
    • ~/.aliases workspace shortcutek
    • ~/.tmux.conf session layout
    • Git global beállítások

  Log: $LOGFILE_AI" 34

# =============================================================================
# RUN_MODE MEGHATÁROZÁS
# =============================================================================

_comp_keys=(zsh ohmyzsh)
detect_run_mode _comp_keys

[ "$RUN_MODE" = "skip" ] && {
  dialog_msg "Minden naprakész — INFRA ${INFRA_NUM}" \
    "\n${STATUS}\n  Minden komponens naprakész — semmi sem változik."
  log "SKIP" "Minden komponens OK → kilépés"
  infra_state_set "MOD_01B_DONE" "true"
  exit 0
}

dialog_yesno "Komponens állapot — INFRA ${INFRA_NUM}" "
${STATUS}
  Telepítési helyek:
    ~/.oh-my-zsh/       — Oh My Zsh
    ~/.zshrc            — shell konfig (backup: .zshrc.bak)
    ~/.aliases          — workspace aliasok

  Mód: $RUN_MODE — folytatjuk?" 24 || { log "USER" "Megszakítva"; exit 0; }

OK=0; SKIP=0; FAIL=0

# =============================================================================
# 1. LÉPÉS — ZSH TELEPÍTÉS + ALAPÉRTELMEZETT SHELL
# =============================================================================
# Forrás: https://zsh.sourceforge.io/Doc/

log "STEP" "━━━ 1/6: Zsh telepítés + alapértelmezett shell ━━━"

if [[ "$RUN_MODE" =~ ^(install|update|reinstall|fix)$ ]]; then
  if [ "${COMP_STATUS[zsh]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then

    if ask_proceed "Zsh telepítése és alapértelmezett shellként beállítása?"; then
      apt_install_progress "Zsh shell" "Zsh telepítése..." ${PKGS[shell]}
      _ec=$?

      if [ $_ec -eq 0 ]; then
        _ZSH_PATH="$(which zsh 2>/dev/null || echo "/usr/bin/zsh")"

        if ! grep -qxF "$_ZSH_PATH" /etc/shells; then
          echo "$_ZSH_PATH" >> /etc/shells
          log "CFG" "Zsh hozzáadva /etc/shells-be: $_ZSH_PATH"
        fi

        if chsh -s "$_ZSH_PATH" "$REAL_USER" 2>/dev/null; then
          log "OK" "Alapértelmezett shell: $REAL_USER → $_ZSH_PATH"
          ((OK++))
        else
          log "WARN" "chsh sikertelen — manuálisan: chsh -s $_ZSH_PATH $REAL_USER"
          dialog_warn "chsh — Figyelmeztetés" "
  Az alapértelmezett shell beállítása (chsh) sikertelen.
  Manuálisan: chsh -s $_ZSH_PATH $REAL_USER" 12
          ((OK++))
        fi

        _ZSH_VER_NOW=$(zsh --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
        infra_state_set "INST_ZSH_VER" "${_ZSH_VER_NOW:-ismeretlen}"
      else
        log "FAIL" "Zsh telepítés SIKERTELEN (exit $_ec)"; ((FAIL++))
      fi
    else
      ((SKIP++)); log "SKIP" "Zsh telepítés kihagyva"
    fi
  else
    log "SKIP" "Zsh már telepítve (${COMP_VER[zsh]:-?})"
    ((SKIP++))
  fi
else
  log "SKIP" "Zsh telepítés kihagyva — check mód ($RUN_MODE)"
  ((SKIP++))
fi

# =============================================================================
# 2. LÉPÉS — MODERN CLI ESZKÖZÖK
# =============================================================================
# Forrás: Ubuntu 24.04 LTS universe repository

# APT mirror fallback: hu.archive.ubuntu.com megbízhatatlan lehet
# Forrás: Ubuntu APT dokumentáció (Acquire::* opciók)
if grep -ql 'hu.archive.ubuntu.com' /etc/apt/sources.list 2>/dev/null; then
  sed -i 's|http://hu.archive.ubuntu.com|http://archive.ubuntu.com|g' /etc/apt/sources.list
  log "APT" "Magyar mirror lecserélve → archive.ubuntu.com"
fi

log "STEP" "━━━ 2/6: Modern CLI eszközök ━━━"

if [[ "$RUN_MODE" =~ ^(install|update|reinstall|fix)$ ]]; then

  # pkg_installed() idempotency check fix módban
  _missing_cli=""
  if [[ "$RUN_MODE" =~ ^(install|fix)$ ]]; then
    for _pkg in ${PKGS[modern_cli]} ${PKGS[terminal]}; do
      pkg_installed "$_pkg" || _missing_cli="${_missing_cli} ${_pkg}"
    done
  fi

  if [[ "$RUN_MODE" =~ ^(update|reinstall)$ ]] || [ -n "$_missing_cli" ]; then
    _cli_prompt="Modern CLI eszközök telepítése? (fzf, bat, eza, ripgrep, zoxide, tmux)"
    [ -n "$_missing_cli" ] && \
      _cli_prompt="Modern CLI eszközök — hiányzó:${_missing_cli}  Telepítjük?"

    if ask_proceed "$_cli_prompt"; then
      apt_install_progress \
        "Modern CLI eszközök" \
        "fzf, bat, eza, ripgrep, fd-find, zoxide, tmux telepítése..." \
        ${PKGS[modern_cli]} ${PKGS[terminal]}
      _ec=$?
      [ $_ec -eq 0 ] && { log "OK" "Modern CLI eszközök telepítve"; ((OK++)); } \
                     || { log "WARN" "Részleges sikertelenség (exit $_ec)"; ((OK++)); }
    else
      ((SKIP++)); log "SKIP" "Modern CLI eszközök kihagyva"
    fi
  else
    log "SKIP" "Modern CLI eszközök mind telepítve (fix mód)"
    ((SKIP++))
  fi
else
  log "SKIP" "Modern CLI eszközök kihagyva — check mód"
  ((SKIP++))
fi

# =============================================================================
# 3. LÉPÉS — OH MY ZSH TELEPÍTÉS
# =============================================================================
# Forrás: https://github.com/ohmyzsh/ohmyzsh/wiki/Installing-ZSH
#
# _OMZ_READY flag — v6.8 BUG FIX kulcselem:
#
#   Ez a flag dönti el hogy a 4. lépés (.zshrc generálás) futhat-e.
#   A .zshrc tartalmaz 'source "$ZSH/oh-my-zsh.sh"' sort — ha OMZ
#   nincs telepítve, ez hibát adna minden zsh indításkor.
#
#   Értékek:
#     false → OMZ könyvtár nem létezik (kezdeti állapot)
#     true  → OMZ könyvtár ÉS oh-my-zsh.sh jelen van
#
#   Beállítás helye:
#     Inicializáció: könyvtár-alapú ellenőrzés
#     Sikeres install: true
#     Sikertelen install: false (marad)
#     Skip (már megvolt): true (ha könyvtár létezik)

log "STEP" "━━━ 3/6: Oh My Zsh telepítés ━━━"

_OMZ_DIR="$REAL_HOME/.oh-my-zsh"

# Kezdeti OMZ állapot: a fő script jelenléte a megbízható jelző
# (könyvtár önmagában nem elég — félkész telepítés esetén üres lehet)
_OMZ_READY=false
if [ -f "$_OMZ_DIR/oh-my-zsh.sh" ]; then
  _OMZ_READY=true
  log "INFO" "OMZ könyvtár létezik (ready=true): $_OMZ_DIR/oh-my-zsh.sh"
else
  log "INFO" "OMZ hiányzik — telepítés szükséges"
fi

if [[ "$RUN_MODE" =~ ^(install|update|reinstall|fix)$ ]]; then
  if [ "${COMP_STATUS[ohmyzsh]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then

    if ask_proceed "Oh My Zsh telepítése?"; then

      if [ "$RUN_MODE" = "reinstall" ] && [ -d "$_OMZ_DIR" ]; then
        log "INFO" "Reinstall: régi Oh My Zsh törlése: $_OMZ_DIR"
        rm -rf "$_OMZ_DIR"
        _OMZ_READY=false
      fi

      # ── Hálózat előellenőrzés — v6.8 BUG FIX ──────────────────────────────
      # Explicit curl check mielőtt az installer pipe-ot elindítanánk.
      # Ha a githubusercontent.com nem elérhető → azonnal FAIL + informáló dialóg.
      # Forrás: curl man page — --max-time, --head, --silent opciók
      log "INFO" "Hálózat ellenőrzés: raw.githubusercontent.com elérhetősége"
      if ! curl --silent --max-time 10 --head \
           "https://raw.githubusercontent.com" &>/dev/null; then
        log "FAIL" "raw.githubusercontent.com nem elérhető (hálózat/tűzfal)"
        dialog_warn "Oh My Zsh — Hálózat hiba" "
  A raw.githubusercontent.com szerver nem érhető el.
  Az Oh My Zsh telepítője (install.sh) erről a szerverről töltődik le.

  Lehetséges okok:
    • Nincs internet kapcsolat:  ping 8.8.8.8
    • DNS hiba:                  nslookup raw.githubusercontent.com
    • Tűzfal blokkolja a HTTPS forgalmat
    • GitHub CDN átmeneti hiba

  Megoldás:
    1. Ellenőrizd az internet kapcsolatot
    2. Futtasd újra: 01b — install vagy fix módban

  A .zshrc generálás is kimarad (OMZ nélkül nem működne).

  Log: $LOGFILE_AI" 24
        _OMZ_READY=false
        ((FAIL++))

      else
        # Hálózat OK — installer futtatása
        log "INFO" "Hálózat OK — OMZ installer indítása..."
        progress_open "Oh My Zsh telepítés" "Oh My Zsh letöltése és telepítése..."
        log_term "$ sudo -u $REAL_USER CHSH=no RUNZSH=no KEEP_ZSHRC=yes sh -c install.sh"

        sudo -u "$REAL_USER" \
          HOME="$REAL_HOME" \
          CHSH=no \
          RUNZSH=no \
          KEEP_ZSHRC=yes \
          sh -c "$(curl -fsSL '${OMZ_URLS[install]}')" 2>&1 | _tee_streams

        progress_close

        # Siker jelző: oh-my-zsh.sh létezik (könyvtár + fő script = teljes telepítés)
        if [ -f "$_OMZ_DIR/oh-my-zsh.sh" ]; then
          _OMZ_COMMIT=$(git -C "$_OMZ_DIR" log --oneline -1 2>/dev/null | cut -c1-7)
          log "OK" "Oh My Zsh telepítve (commit: ${_OMZ_COMMIT:-?})"
          infra_state_set "INST_OMZ_COMMIT" "${_OMZ_COMMIT:-ismeretlen}"
          _OMZ_READY=true
          ((OK++))
        else
          log "FAIL" "Oh My Zsh telepítés SIKERTELEN (oh-my-zsh.sh nem jött létre)"
          dialog_warn "Oh My Zsh — Telepítési hiba" "
  Az Oh My Zsh telepítése sikertelen.

  Lehetséges okok:
    • Hálózati hiba az install.sh futás közben
    • REAL_HOME nem írható: ls -la $REAL_HOME
    • Lemez tele: df -h

  A .zshrc generálás is kimarad (OMZ nélkül nem működne).

  Log: $LOGFILE_AI" 20
          _OMZ_READY=false
          ((FAIL++))
        fi
      fi

    else
      ((SKIP++)); log "SKIP" "Oh My Zsh kihagyva"
      # _OMZ_READY értéke az előző állapot (könyvtár-alapú init)
    fi

    # Plugin klónozás — csak ha oh-my-zsh.sh tényleg létezik
    if [ -f "$_OMZ_DIR/oh-my-zsh.sh" ]; then

      _OMZ_PLUGINS="$_OMZ_DIR/custom/plugins"
      _OMZ_THEMES="$_OMZ_DIR/custom/themes"
      sudo -u "$REAL_USER" mkdir -p "$_OMZ_PLUGINS" "$_OMZ_THEMES"

      log "STEP" "━━━ 3b: Plugin-ok klónozása ━━━"

      _clone_or_update() {
        local repo_url="$1" target_dir="$2" name="$3"
        if [ -d "$target_dir/.git" ]; then
          if [ "$RUN_MODE" = "update" ] || [ "$RUN_MODE" = "reinstall" ]; then
            log "UPDATE" "$name frissítése: git pull"
            sudo -u "$REAL_USER" git -C "$target_dir" pull --ff-only --quiet 2>&1 \
              | _tee_streams || log "WARN" "$name git pull sikertelen (nem kritikus)"
          else
            log "SKIP" "$name már klónozva"
          fi
        else
          log "INFO" "$name klónozása: $repo_url"
          sudo -u "$REAL_USER" \
            git clone --depth=1 "$repo_url" "$target_dir" 2>&1 | _tee_streams
          [ -d "$target_dir" ] \
            && log "OK" "$name klónozva → $target_dir" \
            || log "FAIL" "$name klónozás SIKERTELEN"
        fi
      }

      # Forrás: https://github.com/zsh-users/zsh-autosuggestions
      _clone_or_update "${OMZ_URLS[autosuggestions]}" \
        "$_OMZ_PLUGINS/zsh-autosuggestions" "zsh-autosuggestions"

      # Forrás: https://github.com/zsh-users/zsh-syntax-highlighting
      # FONTOS: plugins listában az UTOLSÓ helyen!
      _clone_or_update "${OMZ_URLS[syntax_hl]}" \
        "$_OMZ_PLUGINS/zsh-syntax-highlighting" "zsh-syntax-highlighting"

      # Forrás: https://github.com/zsh-users/zsh-completions
      _clone_or_update "${OMZ_URLS[completions]}" \
        "$_OMZ_PLUGINS/zsh-completions" "zsh-completions"

      # Forrás: https://github.com/romkatv/powerlevel10k#oh-my-zsh
      _clone_or_update "${OMZ_URLS[p10k]}" \
        "$_OMZ_THEMES/powerlevel10k" "powerlevel10k"

      chown -R "${REAL_UID}:${REAL_GID}" "$_OMZ_PLUGINS" "$_OMZ_THEMES" 2>/dev/null || true
      log "CFG" "Plugin könyvtár jogosultság beállítva: $REAL_USER"
    fi

  else
    log "SKIP" "Oh My Zsh már telepítve (${COMP_VER[ohmyzsh]:-?})"
    ((SKIP++))
    # _OMZ_READY: true marad (könyvtár-alapú init már beállította)
  fi
else
  log "SKIP" "Oh My Zsh telepítés kihagyva — check mód"
  ((SKIP++))
fi

log "INFO" "OMZ ready állapot: $_OMZ_READY"

# =============================================================================
# 4. LÉPÉS — .zshrc GENERÁLÁS
# =============================================================================
# FONTOS: v6.8 BUG FIX — _OMZ_READY guard
#
# A generált .zshrc tartalmaz: source "$ZSH/oh-my-zsh.sh"
# Ha OMZ nincs telepítve, ez a sor hibát adna minden zsh indításkor.
# Ezért: ha _OMZ_READY=false → a 4. lépés SKIP + tájékoztató dialog.
#
# Helyes flow:
#   OMZ FAIL → _OMZ_READY=false → 4. lépés skip + dialog_warn
#   OMZ OK   → _OMZ_READY=true  → 4. lépés normálisan folytatódik
#   OMZ skip (already ok) → _OMZ_READY=true → 4. lépés normálisan
#
# Forrás: https://zsh.sourceforge.io/Doc/Release/Files.html

log "STEP" "━━━ 4/6: .zshrc generálás ━━━"

_ZSHRC="$REAL_HOME/.zshrc"

if [[ "$RUN_MODE" =~ ^(install|update|reinstall|fix)$ ]]; then

  # ── OMZ guard — v6.8 BUG FIX ──────────────────────────────────────────────
  if ! $_OMZ_READY; then
    log "SKIP" ".zshrc generálás kihagyva — Oh My Zsh nem elérhető (hálózati/telepítési hiba)"
    dialog_warn ".zshrc generálás kihagyva" "
  Az Oh My Zsh telepítése sikertelen volt, ezért a .zshrc generálás
  automatikusan kimarad.

  Ok: A generált .zshrc tartalmaz 'source ~/.oh-my-zsh/oh-my-zsh.sh'
  sort, ami shell hibát adna működő OMZ nélkül.

  Javítás:
    1. Ellenőrizd az internet kapcsolatot
    2. Futtasd újra a 01b-t (install vagy fix módban)
       A .zshrc a következő sikeres OMZ telepítés után fog generálódni." 20
    ((SKIP++))

  # ── Fix módban: ha .zshrc már létezik → automatikus skip ──────────────────
  elif [ "$RUN_MODE" = "fix" ] && [ -f "$_ZSHRC" ]; then
    log "SKIP" ".zshrc már létezik — fix módban nem írjuk felül (user módosítások megőrzése)"
    ((SKIP++))

  else
    if ask_proceed ".zshrc generálása? (backup készül a régiről)"; then

      if [ -f "$_ZSHRC" ]; then
        _BAK="${_ZSHRC}.bak.$(date '+%Y%m%d_%H%M%S')"
        cp "$_ZSHRC" "$_BAK"
        log "CFG" ".zshrc backup: $_BAK"
      fi

      _PLUGINS_STR=$(printf '%s\n  ' "${ZSH_PLUGINS[@]}")

      cat > "$_ZSHRC" << ZSHRC_EOF
# =============================================================================
# ~/.zshrc — Vibe Coding Workspace
# Generálta: 01b_post_reboot.sh v6.8
# Generálás ideje: $(date '+%Y-%m-%d %H:%M:%S')
# GPU: ${_HW_GPU_NAME}
# OS: Ubuntu ${_HW_OS_VERSION} (${_HW_OS_CODENAME})
# CUDA: ${_CUDA_VER} | PyTorch index: ${_PYTORCH_IDX}
# Módosítsd bátran — a generátor backup-ot készít a régire.
# =============================================================================

export ZSH="\$HOME/.oh-my-zsh"

ZSH_THEME="${ZSH_THEME}"

# Powerlevel10k instant prompt — gyors shell indítás
# Forrás: https://github.com/romkatv/powerlevel10k#instant-prompt
if [[ -r "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh" ]]; then
  source "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh"
fi

# FONTOS: zsh-syntax-highlighting MINDIG az utolsó legyen a listában!
plugins=(
  ${_PLUGINS_STR}
)

HISTSIZE=50000
SAVEHIST=50000
HISTFILE="\$HOME/.zsh_history"
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt SHARE_HISTORY
setopt AUTO_CD
setopt CORRECT
setopt COMPLETE_ALIASES

export PATH="\$HOME/.local/bin:\$HOME/bin:\$PATH"

# CUDA toolkit — verzió: ${_CUDA_VER}
export CUDA_HOME=/usr/local/cuda
export PATH="\${CUDA_HOME}/bin\${PATH:+:\${PATH}}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"

# pyenv — 03_python_aiml.sh telepíti
export PYENV_ROOT="\$HOME/.pyenv"
if [ -d "\$PYENV_ROOT" ]; then
  export PATH="\$PYENV_ROOT/bin:\$PATH"
  eval "\$(pyenv init -)"
  [ -f "\$PYENV_ROOT/plugins/pyenv-virtualenv/bin/pyenv-virtualenv" ] && \
    eval "\$(pyenv virtualenv-init -)"
fi

# nvm — 04_nodejs.sh telepíti (lazy loading)
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && source "\$NVM_DIR/bash_completion"

# zoxide: smart cd
command -v zoxide &>/dev/null && eval "\$(zoxide init zsh)"

# fzf konfiguráció
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export FZF_DEFAULT_OPTS="--height 40% --border --layout=reverse"
command -v fdfind &>/dev/null && \
  export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --follow --exclude .git'

source "\$ZSH/oh-my-zsh.sh"

# zsh-completions manuális aktiválás (OMZ betöltés után)
if [ -d "\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/plugins/zsh-completions/src" ]; then
  fpath+="\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/plugins/zsh-completions/src"
fi

[ -f "\$HOME/.aliases" ] && source "\$HOME/.aliases"
[ -f "\$HOME/.p10k.zsh" ] && source "\$HOME/.p10k.zsh"
ZSHRC_EOF

      chown "${REAL_UID}:${REAL_GID}" "$_ZSHRC"
      chmod 644 "$_ZSHRC"
      log "OK" ".zshrc generálva: $_ZSHRC"
      ((OK++))

    else
      ((SKIP++)); log "SKIP" ".zshrc generálás kihagyva"
    fi
  fi
else
  log "SKIP" ".zshrc generálás kihagyva — check mód"
  ((SKIP++))
fi

# =============================================================================
# 5. LÉPÉS — .bashrc SZINKRONIZÁLÁS
# =============================================================================

log "STEP" "━━━ 5/6: .bashrc szinkronizálás ━━━"

_BASHRC="$REAL_HOME/.bashrc"

if [[ "$RUN_MODE" =~ ^(install|update|reinstall|fix)$ ]]; then
  if ask_proceed ".bashrc CUDA + pyenv PATH szinkronizálása?"; then

    if grep -q "01b_post_reboot — PATH szinkronizálás" "$_BASHRC" 2>/dev/null; then
      log "SKIP" ".bashrc blokk már létezik — nem írjuk felül"
      ((SKIP++))
    else
      _BASHRC_BAK="${_BASHRC}.bak.$(date '+%Y%m%d_%H%M%S')"
      cp "$_BASHRC" "$_BASHRC_BAK" 2>/dev/null && log "CFG" ".bashrc backup: $_BASHRC_BAK"

      cat >> "$_BASHRC" << BASHRC_EOF

# =============================================================================
# 01b_post_reboot — PATH szinkronizálás — $(date '+%Y-%m-%d')
# GPU: ${_HW_GPU_NAME} | CUDA: ${_CUDA_VER} | OS: Ubuntu ${_HW_OS_VERSION}
# =============================================================================

export PATH="\$HOME/.local/bin:\$HOME/bin:\${PATH}"

export CUDA_HOME=/usr/local/cuda
export PATH="\${CUDA_HOME}/bin\${PATH:+:\${PATH}}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"

export PYENV_ROOT="\$HOME/.pyenv"
[ -d "\$PYENV_ROOT/bin" ] && export PATH="\$PYENV_ROOT/bin:\$PATH"
command -v pyenv &>/dev/null && eval "\$(pyenv init -)"

export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"

[ -f "\$HOME/.aliases" ] && source "\$HOME/.aliases"
BASHRC_EOF

      chown "${REAL_UID}:${REAL_GID}" "$_BASHRC"
      log "OK" ".bashrc PATH szinkronizálva"
      ((OK++))
    fi
  else
    ((SKIP++)); log "SKIP" ".bashrc szinkronizálás kihagyva"
  fi
else
  log "SKIP" ".bashrc szinkronizálás kihagyva — check mód"
  ((SKIP++))
fi

# =============================================================================
# 6. LÉPÉS — WORKSPACE ALIASOK + TMUX KONFIG + GIT
# =============================================================================

log "STEP" "━━━ 6/6: Workspace aliasok, tmux.conf, git global konfig ━━━"

if [[ "$RUN_MODE" =~ ^(install|update|reinstall|fix)$ ]]; then
  if ask_proceed "Workspace aliasok (~/.aliases), tmux konfig, git beállítások?"; then

    # ── ~/.aliases ─────────────────────────────────────────────────────────
    if [ "$RUN_MODE" = "fix" ] && [ -f "$REAL_HOME/.aliases" ]; then
      log "SKIP" "~/.aliases már létezik — fix módban nem írjuk felül"
      ((SKIP++))
    else
      if [ -f "$REAL_HOME/.aliases" ]; then
        _aliases_bak="$REAL_HOME/.aliases.bak.$(date '+%Y%m%d_%H%M%S')"
        cp "$REAL_HOME/.aliases" "$_aliases_bak"
        log "CFG" "~/.aliases backup: $_aliases_bak"
      fi
      cat > "$REAL_HOME/.aliases" << ALIAS_EOF
# ~/.aliases — Vibe Coding Workspace
# Generálta: 01b_post_reboot.sh v6.8 — $(date '+%Y-%m-%d')

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
if command -v eza &>/dev/null; then
  alias ls='eza --icons --group-directories-first'
  alias ll='eza --icons --long --group-directories-first --git'
  alias la='eza --icons --long --all --group-directories-first --git'
  alias lt='eza --icons --tree --level=2 --group-directories-first'
  alias lta='eza --icons --tree --level=3 --all --git-ignore'
else
  alias ls='ls --color=auto'
  alias ll='ls -lhF --color=auto'
  alias la='ls -lahF --color=auto'
fi

command -v bat &>/dev/null && alias cat='bat --paging=never'
command -v rg &>/dev/null && alias grep='rg'
command -v fdfind &>/dev/null && alias fd='fdfind'

alias top='htop'
alias gpu='watch -n 1 nvidia-smi'
alias gpuw='nvtop'
alias mem='free -h'
alias disk='df -h | grep -v tmpfs'
alias ports='ss -tlnp'
alias myip='curl -s ifconfig.me'

alias d='docker'
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dpsa='docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
alias dlogs='docker logs -f'
alias dex='docker exec -it'
alias dclean='docker system prune -f'
alias dgpus='docker run --rm --gpus all nvidia/cuda:12.6-base-ubuntu24.04 nvidia-smi'

alias py='python3'
alias pip='pip3'
alias venv='python3 -m venv'
alias activate='source .venv/bin/activate'
alias jupy='jupyter lab --no-browser'

alias cuda-ver='nvcc --version'
alias cuda-smi='nvidia-smi'
alias cuda-test='python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"'

alias infra-log='ls -lt ~/AI-LOG-INFRA-SETUP/*.log 2>/dev/null | head -5'
alias infra-state='cat ~/.infra-state'

alias gs='git status'
alias gd='git diff'
alias gdc='git diff --cached'
alias gp='git push'
alias gl='git pull'
alias gco='git checkout'
alias gcb='git checkout -b'
alias glog='git log --oneline --graph --decorate --all -20'

command -v nvim &>/dev/null && alias vi='nvim' && alias vim='nvim'

alias tm='tmux new-session -A -s main'
alias tma='tmux attach-session -t'
alias tml='tmux list-sessions'
ALIAS_EOF

      chown "${REAL_UID}:${REAL_GID}" "$REAL_HOME/.aliases"
      log "OK" "~/.aliases generálva"
      ((OK++))
    fi

    # ── ~/.tmux.conf ─────────────────────────────────────────────────────────
    # Forrás: https://github.com/tmux/tmux/wiki/Getting-Started
    if [ "$RUN_MODE" = "fix" ] && [ -f "$REAL_HOME/.tmux.conf" ]; then
      log "SKIP" "~/.tmux.conf már létezik — fix módban nem írjuk felül"
      ((SKIP++))
    else
      if [ -f "$REAL_HOME/.tmux.conf" ]; then
        _tmux_bak="$REAL_HOME/.tmux.conf.bak.$(date '+%Y%m%d_%H%M%S')"
        cp "$REAL_HOME/.tmux.conf" "$_tmux_bak"
        log "CFG" "~/.tmux.conf backup: $_tmux_bak"
      fi
      cat > "$REAL_HOME/.tmux.conf" << TMUX_EOF
# ~/.tmux.conf — Vibe Coding Workspace
# Generálta: 01b_post_reboot.sh v6.8 — $(date '+%Y-%m-%d')

set -g default-shell $(which zsh 2>/dev/null || echo /bin/zsh)
set -g default-terminal "screen-256color"
set -ga terminal-overrides ",xterm-256color:Tc"
set -g history-limit 50000
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

unbind C-b
set -g prefix C-a
bind C-a send-prefix

setw -g mode-keys vi
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'; unbind %

bind r source-file ~/.tmux.conf \; display "~/.tmux.conf újratöltve!"

set -g status on
set -g status-interval 5
set -g status-position bottom
set -g status-left-length 30
set -g status-right-length 80
set -g status-left "#[fg=colour45,bold][ #S ]#[default] "
set -g status-right "#[fg=colour220]%Y-%m-%d %H:%M #[fg=colour45]| #[fg=colour220]#H"
setw -g window-status-current-format "#[fg=colour45,bold][#I:#W]"
setw -g window-status-format " #I:#W "
TMUX_EOF

      chown "${REAL_UID}:${REAL_GID}" "$REAL_HOME/.tmux.conf"
      log "OK" "~/.tmux.conf generálva"
      ((OK++))
    fi

    # ── Git global konfig — teljesen idempotens ───────────────────────────────
    # Forrás: https://git-scm.com/docs/git-config
    _set_git_global() {
      local key="$1" val="$2"
      local existing
      existing=$(sudo -u "$REAL_USER" HOME="$REAL_HOME" git config --global "$key" 2>/dev/null)
      if [ -n "$existing" ]; then
        log "SKIP" "git config $key már beállítva: $existing"
      else
        sudo -u "$REAL_USER" HOME="$REAL_HOME" git config --global "$key" "$val"
        log "CFG" "git config --global $key=$val"
      fi
    }

    _set_git_global core.editor        "nano"
    _set_git_global pull.rebase        "false"
    _set_git_global init.defaultBranch "main"
    _set_git_global core.autocrlf      "input"
    _set_git_global core.whitespace    "trailing-space,space-before-tab"
    _set_git_global alias.st           "status"
    _set_git_global alias.co           "checkout"
    _set_git_global alias.br           "branch"
    _set_git_global alias.lg           "log --oneline --graph --decorate --all"
    _set_git_global alias.lg10         "log --oneline --graph --decorate --all -10"
    _set_git_global alias.unstage      "reset HEAD --"
    _set_git_global alias.last         "log -1 HEAD"
    _set_git_global alias.visual       "!gitk"

    log "OK" "Git global konfig beállítva"

  else
    ((SKIP++)); log "SKIP" "Workspace aliasok / tmux / git konfig kihagyva"
  fi
else
  log "SKIP" "Workspace lépés kihagyva — check mód"
  ((SKIP++))
fi

# =============================================================================
# INFRA STATE — MODUL BEFEJEZETTNEK JELÖLVE
# =============================================================================

infra_state_set "MOD_01B_DONE"    "true"
# FEAT_SHELL_ZSH: true csak ha OMZ is telepítve (zsh+OMZ együtt = teljes env)
infra_state_set "FEAT_SHELL_ZSH"  "$( $_OMZ_READY && echo true || echo false )"
infra_state_set "INST_ZSH_VER"    "$(zsh --version 2>/dev/null | grep -oP '[\d.]+' | head -1)"

_OMZ_COMMIT_FINAL=$(git -C "$REAL_HOME/.oh-my-zsh" log --oneline -1 2>/dev/null | cut -c1-7)
infra_state_set "INST_OMZ_COMMIT" "${_OMZ_COMMIT_FINAL:-ismeretlen}"

log "STATE" "MOD_01B_DONE=true | FEAT_SHELL_ZSH=$( $_OMZ_READY && echo true || echo false )"
log "STATE" "MOD_01B_DONE=true → 03_python_aiml.sh futtatható"

# =============================================================================
# POST-INSTALL COMP STATE
# =============================================================================

if [[ "$RUN_MODE" =~ ^(install|update|fix|reinstall)$ ]]; then
  log "COMP" "Post-install re-check futtatása (mód: $RUN_MODE)..."
  comp_check_zsh "${MIN_VER[zsh]}"
  comp_check_ohmyzsh "$REAL_HOME/.oh-my-zsh"
  comp_save_state "$INFRA_NUM"
  log "COMP" "Post-install COMP state mentve: COMP_01B_*"
fi

# =============================================================================
# ÖSSZESÍTŐ
# =============================================================================

show_result "$OK" "$SKIP" "$FAIL"

# OMZ FAIL esetén specifikus útmutatás
if ! $_OMZ_READY && [ "${FAIL:-0}" -gt 0 ]; then
  dialog_warn "Következő lépés — Hálózat szükséges" "
  Az Oh My Zsh telepítése sikertelen (hálózati hiba).
  A .zshrc és Zsh környezet ezért nem lett konfigurálva.

  Teendő:
    1. Ellenőrizd az internet kapcsolatot:
       ping 8.8.8.8
       curl -I https://raw.githubusercontent.com
    2. Futtasd újra a 01b-t (fix vagy install módban):
       sudo bash 00_master.sh  → 01b kijelölése

  Log: $LOGFILE_AI" 20
else
  dialog_msg "Következő lépések — INFRA ${INFRA_NUM}" "
  ✓ Zsh alapértelmezett shell: $REAL_USER
  ✓ Oh My Zsh: $REAL_HOME/.oh-my-zsh
  ✓ .zshrc: $REAL_HOME/.zshrc
  ✓ Aliasok: $REAL_HOME/.aliases
  ✓ Tmux: $REAL_HOME/.tmux.conf

  Prompt személyre szabás:
    p10k configure

  Shell teszt:
    zsh
    source ~/.zshrc

  Következő: 03_python_aiml.sh (Python 3.12 + PyTorch ${_PYTORCH_IDX})

  Log: $LOGFILE_AI" 30
fi

trap - EXIT
rm -f "$LOCK"
log "DONE" "INFRA ${INFRA_NUM} befejezve: OK=$OK SKIP=$SKIP FAIL=$FAIL"
