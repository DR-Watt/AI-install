#!/bin/bash
# =============================================================================
# 01b_post_reboot.sh — User Environment v6.4
#                       Zsh · Oh My Zsh · Shell konfiguráció · PATH
#
# Szerepe a INFRA rendszerben
# ───────────────────────────
# Ez a modul a 01a_system_foundation REBOOT-ja UTÁN futtatandó.
# Kizárólag user-space konfigurációt végez — kernel/driver módosítás nincs:
#
#   ✓ Zsh telepítés + alapértelmezett shell beállítása (chsh)
#   ✓ Oh My Zsh keretrendszer (ohmyzsh/ohmyzsh master branch)
#   ✓ Plugin-ok:
#       zsh-autosuggestions      — parancssori előrejelzés
#       zsh-syntax-highlighting  — szintaxis kiemelés gépelés közben
#       zsh-completions          — kibővített tab-completion adatbázis
#   ✓ Téma: powerlevel10k (git branch, Python venv, CUDA verzió prompt)
#   ✓ .zshrc teljes generálása (template-alapú, backup a régié)
#   ✓ .bashrc minimális PATH szinkronizálás (CUDA, pyenv, nvm, ~/.local/bin)
#   ✓ ~/.aliases workspace aliasok (docker, nvtop, AI log shortcutek)
#   ✓ ~/.tmux.conf (vibe coding session layout)
#   ✓ Git global konfiguráció (core.editor, pull.rebase, alias.lg)
#   ✓ MOD_01B_DONE=true → infra state (03_python_aiml.sh előfeltétele)
#
# NEM tartalmaz (→ 01a_system_foundation.sh):
#   ✗ NVIDIA driver, CUDA, cuDNN, Docker, CTK
#   ✗ kernel modul konfiguráció, initramfs
#
# Előfeltételek
# ─────────────
#   • 01a_system_foundation.sh sikeresen lefutott (MOD_01A_DONE=true)
#   • Rendszer újraindult (az NVIDIA driver betöltve: nvidia-smi válaszol)
#   • sudo jogosultság (chsh, apt)
#
# Változtatások v6.4 (split lib v6.4 igazítás):
#   - REAL_USER/REAL_HOME: lib _REAL_* értékek, nem újradefiniálva
#   - infra_require("01a"): most helyes — lib fix: tr lowercase→uppercase
#     → MOD_01A_DONE kulcsot keresi (nem MOD_01a_DONE-t)
#   - Check módban infra_require nem blokkol (lib fix)
#   - LOGFILE_AI/HUMAN: INFRA_NUM-specifikus nevek, log_init() előtt beállítva
#
# Futtatás
# ────────
#   sudo bash 01b_post_reboot.sh           # közvetlen
#   sudo bash 00_master.sh  (01b kijelölve) # master-en keresztül
#
# Dokumentáció referenciák
# ────────────────────────
#   Oh My Zsh:           https://github.com/ohmyzsh/ohmyzsh/wiki
#   Zsh dokumentáció:    https://zsh.sourceforge.io/Doc/
#   autosuggestions:     https://github.com/zsh-users/zsh-autosuggestions
#   syntax-highlighting: https://github.com/zsh-users/zsh-syntax-highlighting
#   zsh-completions:     https://github.com/zsh-users/zsh-completions
#   powerlevel10k:       https://github.com/romkatv/powerlevel10k
# =============================================================================

# ── Script könyvtár (szimlink-biztos) ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Közös függvénytár betöltése ───────────────────────────────────────────────
LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" \
  || { echo "HIBA: 00_lib.sh hiányzik! Elvárt helye: $LIB"; exit 1; }

# =============================================================================
# ██  KONFIGURÁCIÓ  ── minden érték itt, kódban nincs magic string  ██
# =============================================================================

# ── Modul azonosítók ──────────────────────────────────────────────────────────
INFRA_NUM="01b"
INFRA_NAME="User Environment (post-reboot)"
INFRA_HW_REQ=""   # Hardverfüggetlen — chsh + zsh bármilyen gépen fut

# ── Minimum elfogadható verziók ───────────────────────────────────────────────
declare -A MIN_VER=(
  [zsh]="5.8"          # Ubuntu 24.04 LTS csomagban elérhető verzió
  [git]="2.34"         # Oh My Zsh git update-hez és plugin clone-hoz szükséges
)

# ── Oh My Zsh URL-ek ─────────────────────────────────────────────────────────
# Forrás: https://github.com/ohmyzsh/ohmyzsh/wiki/Installing-ZSH
declare -A OMZ_URLS=(
  # Hivatalos installer — CHSH=no, RUNZSH=no flagekkel fut (nem kéri a jelszót)
  [install]="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"

  # Plugin repo-k — ~/.oh-my-zsh/custom/plugins/ alá klónozódnak
  # Forrás: https://github.com/ohmyzsh/ohmyzsh/wiki/External-plugins
  [autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions"
  [syntax_hl]="https://github.com/zsh-users/zsh-syntax-highlighting"
  [completions]="https://github.com/zsh-users/zsh-completions"

  # Powerlevel10k téma — legjobb prompt teljesítmény (nem fork, eredeti repo)
  # Forrás: https://github.com/romkatv/powerlevel10k#oh-my-zsh
  [p10k]="https://github.com/romkatv/powerlevel10k"
)

# ── APT csomagok ──────────────────────────────────────────────────────────────
declare -A PKGS=(
  # zsh: a shell maga
  # git: Oh My Zsh plugin clone-okhoz + git prompt infókhoz
  # Forrás: Ubuntu 24.04 package archive
  [shell]="zsh git"

  # fzf: fuzzy finder — Ctrl+R history search, Ctrl+T file search
  # bat: szintaxiskiemelő cat helyett (zsh aliasban: cat → bat)
  # eza: ls helyett (fa nézet, git státusz, ikonok)
  # ripgrep: grep helyett (gyorsabb, .gitignore-aware)
  # fd-find: find helyett (gyorsabb, user-friendly szintaxis)
  # zoxide: cd helyett (frecency alapú navigáció, z parancs)
  # starship: opcionális prompt (p10k alternatíva, Rust-alapú)
  [modern_cli]="fzf bat eza ripgrep fd-find zoxide"

  # tmux: terminál multiplexer — vibe coding session layout
  # Forrás: https://github.com/tmux/tmux/wiki
  [terminal]="tmux"
)

# ── Zsh konfiguráció értékek ──────────────────────────────────────────────────
# ZSH_THEME: powerlevel10k — leggazdagabb prompt (git, conda, cuda, timer)
ZSH_THEME="powerlevel10k/powerlevel10k"

# Aktív plugin-ok listája a .zshrc plugins=() sorában
# Forrás: https://github.com/ohmyzsh/ohmyzsh/wiki/Plugins
ZSH_PLUGINS=(
  "git"                     # git aliasok (gst, gco, gp, glog stb.)
  "docker"                  # docker + compose tab-completion
  "docker-compose"          # dc aliasok
  "python"                  # pyenv + pip segédek
  "pip"                     # pip completion
  "node"                    # nvm + node verzió info
  "sudo"                    # ESC+ESC → sudo prefix az előző parancshoz
  "colored-man-pages"       # man oldalak színezése
  "command-not-found"       # hiányzó parancs csomagjavaslattal
  "history"                 # h → history, hsi → grep-es keresés
  "copypath"                # copypath → aktuális könyvtár clipboard-ra
  "extract"                 # extract → bármilyen archívum kibontása
  "fzf"                     # Ctrl+R fzf history, Ctrl+T fzf file
  "zoxide"                  # zoxide: z parancs, smart cd
  "zsh-autosuggestions"     # szürke előrejelzés → nyíl jobb elfogadás
  "zsh-syntax-highlighting" # gépelés közbeni szintaxis kiemelés
  "zsh-completions"         # kibővített completion adatbázis
)

# ── Ellenőrizendő komponensek listája ─────────────────────────────────────────
# comp_check_* függvények a 00_lib.sh-ban vannak definiálva
COMP_NAMES=(zsh ohmyzsh)

# =============================================================================
# ██  INICIALIZÁLÁS  ██
# =============================================================================

# ── Jogosultság ───────────────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && {
  echo "HIBA: Ez a script root jogosultságot igényel."
  echo "      Futtatás: sudo bash $(basename "$0")"
  exit 1
}

# ── Valódi felhasználó — a lib (00_lib_core.sh) már meghatározta source-kor ────
# _REAL_USER, _REAL_HOME, _REAL_UID, _REAL_GID: lib változók
# REAL_* aliasok a backward compat-hoz (a script kódjában REAL_USER-t használ)
REAL_USER="${_REAL_USER}"
REAL_HOME="${_REAL_HOME}"
REAL_UID="${_REAL_UID}"
REAL_GID="${_REAL_GID}"

# ── Log fájlok: INFRA_NUM-specifikus nevek ────────────────────────────────────
# Felülírjuk a lib alapértékét — log_init() ELŐTT kell megtörténnie!
LOGFILE_AI="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="$LOGFILE_AI"

# ── Lock fájl ────────────────────────────────────────────────────────────────
LOCK="/tmp/.install_01b.lock"
check_lock "$LOCK"
trap 'rm -f "$LOCK"; log "LOCK" "Lock felszabadítva"' EXIT

# ── Log rendszer inicializálás ─────────────────────────────────────────────────
log_init

# ── INFRA state betöltése ─────────────────────────────────────────────────────
# Ezeket a 01a_system_foundation.sh írta — mi csak olvassuk.
_CUDA_VER="$(infra_state_get "CUDA_VER" "12.6")"
_HW_PROFILE="$(infra_state_get "HW_PROFILE" "unknown")"
_HW_GPU_NAME="$(infra_state_get "HW_GPU_NAME" "ismeretlen GPU")"
_PYTORCH_IDX="$(infra_state_get "PYTORCH_INDEX" "cu126")"

log "STATE" "Betöltve: CUDA=$_CUDA_VER PROFILE=$_HW_PROFILE PyTorch=$_PYTORCH_IDX"

# =============================================================================
# ██  ELŐFELTÉTELEK ELLENŐRZÉSE  ██
# =============================================================================

# ── 01a lefutott-e? ───────────────────────────────────────────────────────────
# infra_require() a 00_lib.sh-ban: MOD_01A_DONE=true-t keres az infra state-ben.
# Ha nincs benne, dialógot mutat és kilép.
if ! infra_require "01a" "System Foundation (01a_system_foundation.sh)"; then
  log "FAIL" "Előfeltétel hiányzik: 01a — kilépés"
  exit 1
fi

# ── REBOOT megtörtént-e? ──────────────────────────────────────────────────────
# Az NVIDIA driver csak reboot után töltődik be. Ha nvidia-smi nem válaszol,
# valószínűleg nem volt reboot a 01a óta — figyelmeztető dialóg, nem blokkoló.
# (Lehet hogy a user iGPU gépen futtatja 01b-t, ahol nincs nvidia-smi.)
if hw_has_nvidia 2>/dev/null; then
  if ! nvidia-smi &>/dev/null 2>&1; then
    dialog_warn "REBOOT nem történt?" "
  A 01a_system_foundation.sh REBOOT-ot igényel az NVIDIA driver betöltéséhez.
  Az nvidia-smi most nem válaszol — lehetséges, hogy a rendszer még nem lett
  újraindítva a driver telepítése óta.

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
# ██  KOMPONENS ÁLLAPOT FELMÉRÉS  ██
# =============================================================================
# comp_check_ohmyzsh: ~/.oh-my-zsh könyvtár + git commit hash
# Zsh verzió: zsh --version

log "COMP" "━━━ Komponens felmérés ━━━"

# Zsh verzió lekérdezése
_ZSH_VER=$(zsh --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
if [ -z "$_ZSH_VER" ]; then
  COMP_STATUS[zsh]="missing"; COMP_VER[zsh]=""
elif version_ok "$_ZSH_VER" "${MIN_VER[zsh]}"; then
  COMP_STATUS[zsh]="ok"; COMP_VER[zsh]="$_ZSH_VER"
else
  COMP_STATUS[zsh]="old"; COMP_VER[zsh]="$_ZSH_VER"
fi

# Oh My Zsh: a REAL_USER home könyvtárában kell lennie
comp_check_ohmyzsh "$REAL_HOME/.oh-my-zsh"

# Státusz szöveg
STATUS=""
for _c in "${COMP_NAMES[@]}"; do
  STATUS+="$(comp_line "$_c" "$_c")"$'\n'
done

log "COMP" "zsh: ${COMP_STATUS[zsh]:-missing} (${COMP_VER[zsh]:-—})"
log "COMP" "ohmyzsh: ${COMP_STATUS[ohmyzsh]:-missing} (${COMP_VER[ohmyzsh]:-—})"

# =============================================================================
# ██  ÜDVÖZLŐ DIALÓGUS  ██
# =============================================================================

log_infra_header "
    • Zsh shell (alapértelmezett shell: chsh)
    • Oh My Zsh + plugins (autosuggestions, syntax-hl, completions)
    • Powerlevel10k téma (git, Python, CUDA prompt info)
    • .zshrc teljes konfiguráció (CUDA, pyenv, nvm, workspace aliasok)
    • Modern CLI eszközök (fzf, bat, eza, ripgrep, zoxide)
    • ~/.aliases, ~/.tmux.conf, git global konfig"

log_install_paths "
    ~/.oh-my-zsh/                    — Oh My Zsh keretrendszer
    ~/.oh-my-zsh/custom/plugins/     — külső plugin-ok
    ~/.oh-my-zsh/custom/themes/      — powerlevel10k téma
    ~/.zshrc                         — fő shell konfig (backup: .zshrc.bak)
    ~/.aliases                       — workspace aliasok
    ~/.tmux.conf                     — tmux konfig
    ~/.p10k.zsh                      — powerlevel10k prompt konfig"

dialog_msg "INFRA ${INFRA_NUM} — ${INFRA_NAME}" "
  GPU:        ${_HW_GPU_NAME}
  CUDA:       ${_CUDA_VER} (PyTorch: ${_PYTORCH_IDX})
  Mód:        $RUN_MODE
  Felhasználó: $REAL_USER

  Komponens állapot:
${STATUS}
  Telepíti:
    • Zsh ${MIN_VER[zsh]}+ (alapértelmezett shell)
    • Oh My Zsh + 3 plugin
    • Powerlevel10k téma
    • .zshrc teljes generálás (backup készül)
    • Modern CLI: fzf, bat, eza, ripgrep, zoxide
    • ~/.aliases workspace shortcutek
    • ~/.tmux.conf session layout
    • Git global beállítások

  Log: $LOGFILE_AI" 32

# =============================================================================
# ██  RUN_MODE MEGHATÁROZÁS  ██
# =============================================================================

_comp_keys=(zsh ohmyzsh)
detect_run_mode _comp_keys

[ "$RUN_MODE" = "skip" ] && {
  dialog_msg "Minden naprakész" "\n${STATUS}\n  Minden komponens naprakész — semmi sem változik."
  log "SKIP" "Minden komponens OK → kilépés"
  infra_state_set "MOD_01B_DONE" "true"
  exit 0
}

dialog_yesno "Komponens állapot — Megerősítés" "
${STATUS}
  Telepítési helyek:
    ~/.oh-my-zsh/       — Oh My Zsh
    ~/.zshrc            — shell konfig (backup: .zshrc.bak)
    ~/.aliases          — workspace aliasok

  Mód: $RUN_MODE
  Folytatjuk?" 24 || { log "USER" "Megszakítva"; exit 0; }

OK=0; SKIP=0; FAIL=0

# =============================================================================
# ██  1. LÉPÉS — ZSH TELEPÍTÉS + ALAPÉRTELMEZETT SHELL  ██
# =============================================================================
# Zsh az Ubuntu 24.04 main repóból elérhető (5.9+).
# chsh -s: alapértelmezett shell beállítása a valódi felhasználónak.
# FONTOS: sudo alatt nem futunk zsh-val — csak a login shell változik.
# Forrás: https://zsh.sourceforge.io/Doc/

log "STEP" "━━━ 1/6: Zsh telepítés + alapértelmezett shell ━━━"

if [ "${COMP_STATUS[zsh]:-missing}" != "ok" ] || \
   [ "$RUN_MODE" = "reinstall" ]; then

  if ask_proceed "Zsh telepítése és alapértelmezett shellként beállítása?"; then
    apt_install_progress \
      "Zsh shell" \
      "Zsh telepítése..." \
      ${PKGS[shell]}
    _ec=$?

    if [ $_ec -eq 0 ]; then
      # Zsh elérési útja — Ubuntu 24.04-en tipikusan /usr/bin/zsh
      _ZSH_PATH="$(which zsh 2>/dev/null || echo "/usr/bin/zsh")"

      # /etc/shells ellenőrzés — chsh csak bejegyzett shell-re vált
      if ! grep -qxF "$_ZSH_PATH" /etc/shells; then
        echo "$_ZSH_PATH" >> /etc/shells
        log "CFG" "Zsh hozzáadva /etc/shells-be: $_ZSH_PATH"
      fi

      # chsh: a valódi felhasználó alapértelmezett shelljét váltja
      # -s: az új shell; a felhasználónév az utolsó argumentum
      if chsh -s "$_ZSH_PATH" "$REAL_USER" 2>/dev/null; then
        log "OK" "Alapértelmezett shell beállítva: $REAL_USER → $_ZSH_PATH"
        ((OK++))
      else
        log "WARN" "chsh sikertelen — manuálisan: chsh -s $_ZSH_PATH $REAL_USER"
        dialog_warn "chsh — Figyelmeztetés" "
  Az alapértelmezett shell beállítása (chsh) sikertelen volt.

  Manuálisan:
    chsh -s $(which zsh) $REAL_USER

  A zsh ettől függetlenül fut — csak a login shell nem zsh még." 14
        ((OK++))  # Nem kritikus — telepítés OK, csak chsh nem sikerült
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

# =============================================================================
# ██  2. LÉPÉS — MODERN CLI ESZKÖZÖK  ██
# =============================================================================
# fzf:      fuzzy finder — Ctrl+R history, Ctrl+T file (zsh plugin aktiválja)
# bat:      szintaxiskiemelő cat helyett (man page-ek is) — alias: cat → bat
# eza:      modern ls (fa nézet, git integráció, ikonok)
# ripgrep:  rg — grep helyett (10-100x gyorsabb, .gitignore-aware)
# fd-find:  fd — find helyett (egyszerűbb szintaxis, gyorsabb)
# zoxide:   z — smart cd frecency alapon (az oft-used könyvtárak rövidítése)
#
# Forrás: Ubuntu 24.04 LTS universe repository

log "STEP" "━━━ 2/6: Modern CLI eszközök ━━━"

if ask_proceed "Modern CLI eszközök telepítése? (fzf, bat, eza, ripgrep, zoxide)"; then
  apt_install_progress \
    "Modern CLI eszközök" \
    "fzf, bat, eza, ripgrep, fd-find, zoxide telepítése..." \
    ${PKGS[modern_cli]} ${PKGS[terminal]}
  _ec=$?
  if [ $_ec -eq 0 ]; then
    log "OK" "Modern CLI eszközök telepítve"
    ((OK++))
  else
    log "WARN" "Részleges sikertelenség (exit $_ec) — folytatás"
    ((OK++))  # Nem kritikus, az aliasok majd gracefully degradálnak
  fi
else
  ((SKIP++)); log "SKIP" "Modern CLI eszközök kihagyva"
fi

# =============================================================================
# ██  3. LÉPÉS — OH MY ZSH TELEPÍTÉS  ██
# =============================================================================
# Oh My Zsh: zsh konfigurációs keretrendszer + plugin manager.
# Forrás: https://github.com/ohmyzsh/ohmyzsh/wiki/Installing-ZSH
#
# Telepítés env flag-ekkel:
#   CHSH=no    — chsh-t mi csináltuk már az 1. lépésben, ne csinálja újra
#   RUNZSH=no  — ne váltson zsh-ba az installer — sudo session megszakadna
#   KEEP_ZSHRC=yes — ne írja felül a .zshrc-t (mi generáljuk a 4. lépésben)
#
# sudo -u $REAL_USER: az installer a tényleges felhasználó HOME-jába kerül

log "STEP" "━━━ 3/6: Oh My Zsh telepítés ━━━"

_OMZ_DIR="$REAL_HOME/.oh-my-zsh"

if [ "${COMP_STATUS[ohmyzsh]:-missing}" != "ok" ] || \
   [ "$RUN_MODE" = "reinstall" ]; then

  if ask_proceed "Oh My Zsh telepítése?"; then

    # ── Reinstall esetén régi telepítés eltávolítása ──────────────────────
    if [ "$RUN_MODE" = "reinstall" ] && [ -d "$_OMZ_DIR" ]; then
      log "INFO" "Reinstall: régi Oh My Zsh törlése: $_OMZ_DIR"
      rm -rf "$_OMZ_DIR"
    fi

    # ── Installer futtatása a valódi felhasználóként ──────────────────────
    # Az install.sh: letölti a repo-t master branch-ről, beállítja a könyvtárat.
    # A futtatás user kontextusban történik (HOME, UID, GID helyesen beállítva).
    progress_open "Oh My Zsh telepítés" "Oh My Zsh master branch letöltése és telepítése..."
    log_term "$ sudo -u $REAL_USER CHSH=no RUNZSH=no KEEP_ZSHRC=yes sh -c install.sh"

    sudo -u "$REAL_USER" \
      HOME="$REAL_HOME" \
      CHSH=no \
      RUNZSH=no \
      KEEP_ZSHRC=yes \
      sh -c "$(curl -fsSL '${OMZ_URLS[install]}')" 2>&1 | _tee_streams
    _OMZ_EC="${PIPESTATUS[0]}"

    progress_close

    if [ -d "$_OMZ_DIR" ]; then
      _OMZ_COMMIT=$(git -C "$_OMZ_DIR" log --oneline -1 2>/dev/null | cut -c1-7)
      log "OK" "Oh My Zsh telepítve (commit: ${_OMZ_COMMIT:-?})"
      infra_state_set "INST_OMZ_COMMIT" "${_OMZ_COMMIT:-ismeretlen}"
      ((OK++))
    else
      log "FAIL" "Oh My Zsh telepítés SIKERTELEN (exit $_OMZ_EC)"
      dialog_warn "Oh My Zsh — Hiba" "
  Az Oh My Zsh telepítése sikertelen.

  Lehetséges okok:
    • Nincs internet kapcsolat
    • github.com elérhetetlen: curl -I ${OMZ_URLS[install]}
    • REAL_HOME nem írható: ls -la $REAL_HOME

  Log: $LOGFILE_AI" 14
      ((FAIL++))
    fi

  else
    ((SKIP++)); log "SKIP" "Oh My Zsh kihagyva"
  fi

  # ── Plugin-ok klónozása ──────────────────────────────────────────────────
  # Csak akkor klónozzuk, ha az OMZ könyvtár létezik
  if [ -d "$_OMZ_DIR" ]; then

    _OMZ_PLUGINS="$_OMZ_DIR/custom/plugins"
    _OMZ_THEMES="$_OMZ_DIR/custom/themes"

    # Könyvtárak létrehozása ha még nem léteznek
    sudo -u "$REAL_USER" mkdir -p "$_OMZ_PLUGINS" "$_OMZ_THEMES"

    log "STEP" "━━━ 3b: Plugin-ok klónozása ━━━"

    # ── zsh-autosuggestions ───────────────────────────────────────────────
    # Forrás: https://github.com/zsh-users/zsh-autosuggestions
    # Gépelés közben szürke előrejelzés a history alapján; nyíl jobb = elfogad
    _clone_or_update() {
      local repo_url="$1"
      local target_dir="$2"
      local name="$3"

      if [ -d "$target_dir/.git" ]; then
        if [ "$RUN_MODE" = "update" ] || [ "$RUN_MODE" = "reinstall" ]; then
          log "UPDATE" "$name frissítése: git pull"
          sudo -u "$REAL_USER" git -C "$target_dir" pull --ff-only --quiet 2>&1 \
            | _tee_streams || log "WARN" "$name git pull sikertelen (nem kritikus)"
        else
          log "SKIP" "$name már klónozva (install módban nem frissítjük)"
        fi
      else
        log "INFO" "$name klónozása: $repo_url"
        sudo -u "$REAL_USER" \
          git clone --depth=1 "$repo_url" "$target_dir" 2>&1 | _tee_streams
        if [ -d "$target_dir" ]; then
          log "OK" "$name klónozva → $target_dir"
        else
          log "FAIL" "$name klónozás SIKERTELEN"
        fi
      fi
    }

    _clone_or_update \
      "${OMZ_URLS[autosuggestions]}" \
      "$_OMZ_PLUGINS/zsh-autosuggestions" \
      "zsh-autosuggestions"

    # ── zsh-syntax-highlighting ───────────────────────────────────────────
    # Forrás: https://github.com/zsh-users/zsh-syntax-highlighting
    # FONTOS: A plugins listában az UTOLSÓ előtt kell szerepelnie!
    _clone_or_update \
      "${OMZ_URLS[syntax_hl]}" \
      "$_OMZ_PLUGINS/zsh-syntax-highlighting" \
      "zsh-syntax-highlighting"

    # ── zsh-completions ──────────────────────────────────────────────────
    # Forrás: https://github.com/zsh-users/zsh-completions
    # Kiegészítő completion definíciók (apt, docker, git stb.)
    _clone_or_update \
      "${OMZ_URLS[completions]}" \
      "$_OMZ_PLUGINS/zsh-completions" \
      "zsh-completions"

    # ── powerlevel10k téma ────────────────────────────────────────────────
    # Forrás: https://github.com/romkatv/powerlevel10k#oh-my-zsh
    # --depth=1: csak a legfrissebb commit, a teljes history nem kell
    _clone_or_update \
      "${OMZ_URLS[p10k]}" \
      "$_OMZ_THEMES/powerlevel10k" \
      "powerlevel10k"

    # Plugin könyvtár jogosultság javítás — sudo alatti git clone root-ként fut
    chown -R "${REAL_UID}:${REAL_GID}" "$_OMZ_PLUGINS" "$_OMZ_THEMES" 2>/dev/null || true
    log "CFG" "Plugin és téma könyvtár jogosultság beállítva: $REAL_USER"
  fi

else
  log "SKIP" "Oh My Zsh már telepítve (${COMP_VER[ohmyzsh]:-?})"
  ((SKIP++))
fi

# =============================================================================
# ██  4. LÉPÉS — .zshrc GENERÁLÁS  ██
# =============================================================================
# Teljes .zshrc generálás template-alapon.
# A régi .zshrc backup-ra kerül (.zshrc.bak.<timestamp>) — nem veszítjük el.
# Minden PATH beállítás, alias, export egyetlen helyen, jól kommentálva.
#
# PATH sorrend (alacsonyabb index = magasabb prioritás):
#   1. ~/.local/bin      — pip install --user és uv tool install kimenete
#   2. ~/bin             — user saját scriptek
#   3. /usr/local/cuda/bin — CUDA nvcc, nsight stb.
#   4. $PYENV_ROOT/bin   — pyenv parancs maga
#   5. system PATH       — maradék rendszer PATH
#
# Forrás: https://zsh.sourceforge.io/Doc/Release/Files.html
#   → ~/.zshrc: Zsh interaktív session konfig fájlja

log "STEP" "━━━ 4/6: .zshrc generálás ━━━"

_ZSHRC="$REAL_HOME/.zshrc"

if ask_proceed ".zshrc generálása? (backup készül a régiről)"; then

  # ── Backup a meglévő .zshrc-ről ─────────────────────────────────────────
  if [ -f "$_ZSHRC" ]; then
    _BAK="${_ZSHRC}.bak.$(date '+%Y%m%d_%H%M%S')"
    cp "$_ZSHRC" "$_BAK"
    log "CFG" ".zshrc backup: $_BAK"
  fi

  # ── Plugin lista stringgé alakítása ───────────────────────────────────────
  # A tömböt szóközzel elválasztott stringgé fűzzük a heredoc-ban
  _PLUGINS_STR=$(printf '%s\n  ' "${ZSH_PLUGINS[@]}")

  # ── .zshrc írása heredoc-kal ──────────────────────────────────────────────
  # A heredoc 'ZSHRC_EOF' (egyszerű idézőjellel): NEM expanzálódnak a változók
  # a heredoc tartalmában — CSAK a kijelölt helyeken (ahol "$var" szerepel).
  # Ezért a statikus blokkokat külön adagoljuk cat >> formátumban.

  cat > "$_ZSHRC" << ZSHRC_EOF
# =============================================================================
# ~/.zshrc — Vibe Coding Workspace
# Generálta: 01b_post_reboot.sh v6.0
# Generálás ideje: $(date '+%Y-%m-%d %H:%M:%S')
# GPU: ${_HW_GPU_NAME}
# CUDA: ${_CUDA_VER} | PyTorch index: ${_PYTORCH_IDX}
# Módosítsd bátran — a generátor backup-ot készít a régire.
# =============================================================================

# ── Oh My Zsh alapbeállítások ─────────────────────────────────────────────────

# Oh My Zsh telepítési könyvtár
export ZSH="\$HOME/.oh-my-zsh"

# Téma: powerlevel10k — ga4dag prompt (git, python, cuda, timer)
# Saját konfig: ~/.p10k.zsh (p10k configure futtatásával generálható)
ZSH_THEME="${ZSH_THEME}"

# Powerlevel10k instant prompt — gyors shell indítás, mielőtt az init lefut
# Forrás: https://github.com/romkatv/powerlevel10k#instant-prompt
if [[ -r "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh" ]]; then
  source "\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh"
fi

# Aktív plugin-ok
# FONTOS: zsh-syntax-highlighting MINDIG az utolsó legyen a listában!
plugins=(
  ${_PLUGINS_STR}
)

# ── Zsh beállítások ───────────────────────────────────────────────────────────
HISTSIZE=50000             # memóriában tárolt history bejegyzések száma
SAVEHIST=50000             # lemezre mentett history bejegyzések
HISTFILE="\$HOME/.zsh_history"
setopt HIST_IGNORE_ALL_DUPS  # duplikált parancsok ne kerüljenek history-ba
setopt HIST_SAVE_NO_DUPS     # mentéskor se kerüljön be duplikátum
setopt SHARE_HISTORY         # több terminál ablak közötti history megosztás
setopt AUTO_CD               # 'kod' egyenértékű 'cd kod'-dal ha könyvtár
setopt CORRECT               # gépelési hibák automatikus korrekció ajánlata
setopt COMPLETE_ALIASES      # aliasok tab-completion-jének engedélyezése

# ── PATH konfiguráció ─────────────────────────────────────────────────────────
# Sorrend (balról jobbra = prioritás csökken):
#   1. ~/.local/bin      pip --user és uv tool install kimenete
#   2. ~/bin             saját scriptek
#   3. CUDA              nvcc, nsight, cuda-gdb stb.
#   4. pyenv             Python verzióváltó (03_python_aiml.sh telepíti)
#   5. nvm               Node.js verzióváltó (04_nodejs.sh telepíti)
#   6. Rendszer PATH     maradék

# Helyi binárisok — pip --user, uv tool install, pipx
export PATH="\$HOME/.local/bin:\$HOME/bin:\$PATH"

# ── CUDA toolkit ──────────────────────────────────────────────────────────────
# CUDA_HOME: nvcc, libcuda, nsight elérési útja
# Verzió: ${_CUDA_VER} (01a_system_foundation.sh telepítette)
export CUDA_HOME=/usr/local/cuda
export PATH="\${CUDA_HOME}/bin\${PATH:+:\${PATH}}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"

# ── pyenv — Python verzióváltó ────────────────────────────────────────────────
# 03_python_aiml.sh telepíti. Ha még nincs fenn, ez a blokk gracefully kihagyódik.
export PYENV_ROOT="\$HOME/.pyenv"
if [ -d "\$PYENV_ROOT" ]; then
  export PATH="\$PYENV_ROOT/bin:\$PATH"
  eval "\$(pyenv init -)"
  # pyenv-virtualenv: ha telepítve van
  [ -f "\$PYENV_ROOT/plugins/pyenv-virtualenv/bin/pyenv-virtualenv" ] && \
    eval "\$(pyenv virtualenv-init -)"
fi

# ── nvm — Node.js verzióváltó ─────────────────────────────────────────────────
# 04_nodejs.sh telepíti. Lazy loading (gyorsabb shell indulás).
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && source "\$NVM_DIR/bash_completion"

# ── zoxide inicializálás ───────────────────────────────────────────────────────
# z parancs: smart cd frecency alapon (oft-used könyvtárak rövid úton)
# Forrás: https://github.com/ajeetdsouza/zoxide
command -v zoxide &>/dev/null && eval "\$(zoxide init zsh)"

# ── fzf konfiguráció ──────────────────────────────────────────────────────────
# Ctrl+R: fuzzy history keresés | Ctrl+T: fuzzy file picker
# Forrás: https://github.com/junegunn/fzf#key-bindings-for-command-line
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
export FZF_DEFAULT_OPTS="--height 40% --border --layout=reverse --preview-window=right:50%"
# fd-find használata a fzf-hez (gyorsabb, .gitignore-aware)
command -v fdfind &>/dev/null && \
  export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --follow --exclude .git'

# ── Oh My Zsh inicializálás ────────────────────────────────────────────────────
source "\$ZSH/oh-my-zsh.sh"

# ── zsh-completions manuális aktiválás ────────────────────────────────────────
# A zsh-completions plugin a fpath-ba kerülést igényli OMZ betöltése után is
if [ -d "\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/plugins/zsh-completions/src" ]; then
  fpath+="\${ZSH_CUSTOM:-\$HOME/.oh-my-zsh/custom}/plugins/zsh-completions/src"
fi

# ── Workspace aliasok betöltése ────────────────────────────────────────────────
[ -f "\$HOME/.aliases" ] && source "\$HOME/.aliases"

# ── Powerlevel10k téma konfig ─────────────────────────────────────────────────
# Ha még nincs ~/.p10k.zsh: 'p10k configure' futtatásával generálható interaktívan.
[ -f "\$HOME/.p10k.zsh" ] && source "\$HOME/.p10k.zsh"

ZSHRC_EOF

  # ── Jogosultság beállítás ─────────────────────────────────────────────────
  chown "${REAL_UID}:${REAL_GID}" "$_ZSHRC"
  chmod 644 "$_ZSHRC"
  log "OK" ".zshrc generálva: $_ZSHRC"
  ((OK++))

else
  ((SKIP++)); log "SKIP" ".zshrc generálás kihagyva"
fi

# =============================================================================
# ██  5. LÉPÉS — .bashrc SZINKRONIZÁLÁS  ██
# =============================================================================
# A .bashrc-be csak a kritikus PATH beállításokat adjuk hozzá —
# azokat, amik nélkül az NVIDIA/CUDA CLI-k nem működnek bash sessionben sem.
# (VS Code terminál, SSH session, script futtatás esetén fontos.)
# NEM generálunk teljes .bashrc-t — csak appendelünk egy jól elkülönített blokkot.

log "STEP" "━━━ 5/6: .bashrc szinkronizálás ━━━"

_BASHRC="$REAL_HOME/.bashrc"

if ask_proceed ".bashrc CUDA + pyenv PATH szinkronizálása?"; then

  # ── Ellenőrzés: már benne van-e a blokk? ────────────────────────────────
  if grep -q "01b_post_reboot — PATH szinkronizálás" "$_BASHRC" 2>/dev/null; then
    log "SKIP" ".bashrc blokk már létezik — nem írjuk felül"
    ((SKIP++))
  else
    # ── Backup ──────────────────────────────────────────────────────────────
    _BASHRC_BAK="${_BASHRC}.bak.$(date '+%Y%m%d_%H%M%S')"
    cp "$_BASHRC" "$_BASHRC_BAK" 2>/dev/null && \
      log "CFG" ".bashrc backup: $_BASHRC_BAK"

    # ── PATH blokk hozzáadása ────────────────────────────────────────────
    cat >> "$_BASHRC" << BASHRC_EOF

# =============================================================================
# 01b_post_reboot — PATH szinkronizálás — $(date '+%Y-%m-%d')
# Automatikusan hozzáadva az INFRA telepítő által.
# GPU: ${_HW_GPU_NAME} | CUDA: ${_CUDA_VER}
# =============================================================================

# Helyi binárisok
export PATH="\$HOME/.local/bin:\$HOME/bin:\${PATH}"

# CUDA toolkit PATH (nvcc, nsight stb.)
export CUDA_HOME=/usr/local/cuda
export PATH="\${CUDA_HOME}/bin\${PATH:+:\${PATH}}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"

# pyenv (ha telepítve)
export PYENV_ROOT="\$HOME/.pyenv"
[ -d "\$PYENV_ROOT/bin" ] && export PATH="\$PYENV_ROOT/bin:\$PATH"
command -v pyenv &>/dev/null && eval "\$(pyenv init -)"

# nvm (ha telepítve)
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"

# Workspace aliasok
[ -f "\$HOME/.aliases" ] && source "\$HOME/.aliases"
BASHRC_EOF

    chown "${REAL_UID}:${REAL_GID}" "$_BASHRC"
    log "OK" ".bashrc PATH szinkronizálva"
    ((OK++))
  fi

else
  ((SKIP++)); log "SKIP" ".bashrc szinkronizálás kihagyva"
fi

# =============================================================================
# ██  6. LÉPÉS — WORKSPACE ALIASOK + TMUX KONFIG + GIT  ██
# =============================================================================

log "STEP" "━━━ 6/6: Workspace aliasok, tmux.conf, git global konfig ━━━"

if ask_proceed "Workspace aliasok (~/.aliases), tmux konfig, git beállítások generálása?"; then

  # ── ~/.aliases — workspace shortcutek ─────────────────────────────────────
  # Forrás: saját workspace igények + zsh best practices
  # Fájl: ~/.aliases — .zshrc és .bashrc egyaránt betölti
  cat > "$REAL_HOME/.aliases" << ALIAS_EOF
# =============================================================================
# ~/.aliases — Vibe Coding Workspace aliasok
# Generálta: 01b_post_reboot.sh v6.0 — $(date '+%Y-%m-%d')
# Betölti: ~/.zshrc és ~/.bashrc
# =============================================================================

# ── Navigáció ─────────────────────────────────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
# eza: modern ls (ikonok, git státusz, human-readable méret)
# Fallback ls-re ha eza nincs telepítve
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

# ── Szövegkezelés ────────────────────────────────────────────────────────────
# bat: szintaxiskiemelő cat (--paging=never: ne lapozzon)
command -v bat &>/dev/null && alias cat='bat --paging=never'
# ripgrep: jobb grep (rg)
command -v rg &>/dev/null && alias grep='rg'
# fd: jobb find (fdfind Ubuntu csomagban)
command -v fdfind &>/dev/null && alias fd='fdfind'

# ── Rendszer megfigyelés ──────────────────────────────────────────────────────
alias top='htop'
alias gpu='watch -n 1 nvidia-smi'          # GPU állapot frissítés/sec
alias gpuw='nvtop'                          # nvtop GPU dashboard
alias mem='free -h'                         # RAM gyors áttekintés
alias disk='df -h | grep -v tmpfs'          # lemez helyfoglalás
alias ports='ss -tlnp'                      # aktív TCP portok
alias myip='curl -s ifconfig.me'            # külső IP

# ── Docker ────────────────────────────────────────────────────────────────────
alias d='docker'
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dpsa='docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'
alias dlogs='docker logs -f'               # dlogs <container>
alias dex='docker exec -it'               # dex <container> bash
alias dclean='docker system prune -f'      # futó containerek nélküli cleanup
alias dgpus='docker run --rm --gpus all nvidia/cuda:12.6-base-ubuntu24.04 nvidia-smi'

# ── Python + AI ──────────────────────────────────────────────────────────────
alias py='python3'
alias pip='pip3'
alias venv='python3 -m venv'
alias activate='source .venv/bin/activate'
alias jupy='jupyter lab --no-browser'        # JupyterLab (03_python_aiml után)

# ── CUDA / GPU debug ─────────────────────────────────────────────────────────
alias cuda-ver='nvcc --version'
alias cuda-smi='nvidia-smi'
alias cuda-test='python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"'

# ── INFRA log shortcutek ──────────────────────────────────────────────────────
alias infra-log='ls -lt ~/AI-LOG-INFRA-SETUP/*.log 2>/dev/null | head -5'
alias infra-log-last='bat ~/AI-LOG-INFRA-SETUP/\$(ls -t ~/AI-LOG-INFRA-SETUP/*.log 2>/dev/null | head -1 | xargs basename) 2>/dev/null || ls ~/AI-LOG-INFRA-SETUP/'
alias infra-state='cat ~/.infra-state'

# ── Git rövidítések ───────────────────────────────────────────────────────────
# (az OMZ git plugin is tartalmaz aliasokat — ezek kiegészítik)
alias gs='git status'
alias gd='git diff'
alias gdc='git diff --cached'
alias gp='git push'
alias gl='git pull'
alias gco='git checkout'
alias gcb='git checkout -b'
alias glog='git log --oneline --graph --decorate --all -20'

# ── Vim / Nano ────────────────────────────────────────────────────────────────
# Ha van neovim: vi és vim is azt nyissa
command -v nvim &>/dev/null && alias vi='nvim' && alias vim='nvim'

# ── Tmux workspace ────────────────────────────────────────────────────────────
alias tm='tmux new-session -A -s main'      # 'main' session indítás/csatlakozás
alias tma='tmux attach-session -t'          # tma <session>
alias tml='tmux list-sessions'
ALIAS_EOF

  chown "${REAL_UID}:${REAL_GID}" "$REAL_HOME/.aliases"
  log "OK" "~/.aliases generálva"

  # ── ~/.tmux.conf — vibe coding session layout ──────────────────────────────
  # Forrás: https://github.com/tmux/tmux/wiki/Getting-Started
  # Layout: főablak felül (editor), log/AI pane alul, GPU pane jobb oldalt
  cat > "$REAL_HOME/.tmux.conf" << TMUX_EOF
# =============================================================================
# ~/.tmux.conf — Vibe Coding Workspace
# Generálta: 01b_post_reboot.sh v6.0 — $(date '+%Y-%m-%d')
# =============================================================================

# ── Alap beállítások ──────────────────────────────────────────────────────────
set -g default-shell $(which zsh 2>/dev/null || echo /bin/zsh)
set -g default-terminal "screen-256color"  # 256 szín + italics
set -ga terminal-overrides ",xterm-256color:Tc"  # true color (24-bit)
set -g history-limit 50000                 # scrollback buffer mérete
set -g mouse on                            # egér: ablak váltás, resize, scroll
set -g base-index 1                        # ablak számozás 1-től (nem 0-tól)
setw -g pane-base-index 1                  # pane számozás 1-től
set -g renumber-windows on                 # gap-mentes ablakszámok

# ── Prefix billentyű ─────────────────────────────────────────────────────────
# C-a: könnyebb mint C-b (vim-szerű, screen-kompatibilis)
unbind C-b
set -g prefix C-a
bind C-a send-prefix

# ── Vim-szerű navigáció ───────────────────────────────────────────────────────
setw -g mode-keys vi             # copy mode-ban vi billentyűk
bind h select-pane -L            # Prefix+h: bal pane
bind j select-pane -D            # Prefix+j: alsó pane
bind k select-pane -U            # Prefix+k: felső pane
bind l select-pane -R            # Prefix+l: jobb pane

# Pane átméretezés (Prefix + Shift + arrow)
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# ── Pane felosztás (intuitív) ─────────────────────────────────────────────────
bind | split-window -h -c "#{pane_current_path}"   # vízszintes felosztás
bind - split-window -v -c "#{pane_current_path}"   # függőleges felosztás
unbind '"'; unbind %

# ── Konfig újratöltés ─────────────────────────────────────────────────────────
bind r source-file ~/.tmux.conf \; display "~/.tmux.conf újratöltve!"

# ── Státussor ─────────────────────────────────────────────────────────────────
set -g status on
set -g status-interval 5
set -g status-position bottom
set -g status-left-length 30
set -g status-right-length 80
set -g status-left "#[fg=colour45,bold][ #S ]#[default] "
set -g status-right "#[fg=colour220]%Y-%m-%d %H:%M #[fg=colour45]| #[fg=colour220]#H"
setw -g window-status-current-format "#[fg=colour45,bold][#I:#W]"
setw -g window-status-format " #I:#W "

# ── Vibe coding session indítása ──────────────────────────────────────────────
# 'tm' alias: tmux new-session -A -s main
# Automatikus layout: főablak + log pane + GPU pane
# (ha már létezik a session, csatlakozik — nem csinál újat)
TMUX_EOF

  chown "${REAL_UID}:${REAL_GID}" "$REAL_HOME/.tmux.conf"
  log "OK" "~/.tmux.conf generálva"

  # ── Git global konfiguráció ───────────────────────────────────────────────
  # Forrás: https://git-scm.com/docs/git-config
  # Csak azokat a beállításokat adjuk, amik nem definiáltak még
  # (a git config --global nem írja felül ha már van bejegyezve)
  _set_git_global() {
    local key="$1" val="$2"
    # Ellenőrzés: ha már van beállítva, csak loggoljuk
    local existing
    existing=$(sudo -u "$REAL_USER" HOME="$REAL_HOME" git config --global "$key" 2>/dev/null)
    if [ -n "$existing" ]; then
      log "SKIP" "git config $key már beállítva: $existing"
    else
      sudo -u "$REAL_USER" HOME="$REAL_HOME" git config --global "$key" "$val"
      log "CFG" "git config --global $key=$val"
    fi
  }

  # Core beállítások
  _set_git_global core.editor      "nano"        # alapértelmezett editor (biztonságos)
  _set_git_global pull.rebase      "false"       # merge (nem rebase) pull esetén
  _set_git_global init.defaultBranch "main"      # új repo-k main branch-sel
  _set_git_global core.autocrlf    "input"       # Windows sorvégek konverzió ki
  _set_git_global core.whitespace  "trailing-space,space-before-tab"

  # Hasznos aliasok (git lg = szép egysorosás log)
  _set_git_global alias.st    "status"
  _set_git_global alias.co    "checkout"
  _set_git_global alias.br    "branch"
  _set_git_global alias.lg    "log --oneline --graph --decorate --all"
  _set_git_global alias.lg10  "log --oneline --graph --decorate --all -10"
  _set_git_global alias.unstage "reset HEAD --"
  _set_git_global alias.last  "log -1 HEAD"
  _set_git_global alias.visual "!gitk"

  log "OK" "Git global konfig beállítva"
  ((OK++))

else
  ((SKIP++)); log "SKIP" "Workspace aliasok / tmux / git konfig kihagyva"
fi

# =============================================================================
# ██  INFRA STATE — MODOLT BEFEJEZETTNEK JELÖLJÜK  ██
# =============================================================================
# MOD_01B_DONE=true → 03_python_aiml.sh infra_require("01b") ezt ellenőrzi.
# FEAT_SHELL_ZSH=true → más modulok tudhatják, hogy zsh az aktív shell.
# Forrás: 00_lib.sh infra_state_set() — generikus key=value mentés

infra_state_set "MOD_01B_DONE"    "true"
infra_state_set "FEAT_SHELL_ZSH"  "true"
infra_state_set "INST_ZSH_VER"    "$(zsh --version 2>/dev/null | grep -oP '[\d.]+' | head -1)"

_OMZ_COMMIT_FINAL=$(git -C "$REAL_HOME/.oh-my-zsh" log --oneline -1 2>/dev/null | cut -c1-7)
infra_state_set "INST_OMZ_COMMIT" "${_OMZ_COMMIT_FINAL:-ismeretlen}"

log "STATE" "MOD_01B_DONE=true → 03_python_aiml.sh futtatható"
infra_state_show

# =============================================================================
# ██  ÖSSZESÍTŐ  ██
# =============================================================================

show_result "$OK" "$SKIP" "$FAIL"

dialog_msg "Következő lépések — INFRA ${INFRA_NUM}" "
  ✓ Zsh alapértelmezett shell: $REAL_USER
  ✓ Oh My Zsh: $REAL_HOME/.oh-my-zsh
  ✓ .zshrc: $REAL_HOME/.zshrc
  ✓ Aliasok: $REAL_HOME/.aliases
  ✓ Tmux: $REAL_HOME/.tmux.conf

  Prompt személyre szabás:
    p10k configure          ← powerlevel10k interaktív varázsló

  Shell teszt:
    zsh                     ← zsh manuális indítás
    source ~/.zshrc         ← konfig újratöltés ugyanabban a shellben

  Tmux workspace:
    tm                      ← 'main' session indítás/csatlakozás

  CUDA teszt (reboot után):
    nvcc --version
    nvidia-smi

  Következő INFRA modul:
    03_python_aiml.sh       ← Python 3.12 + PyTorch ${_PYTORCH_IDX}

  AI log:    $LOGFILE_AI
  Human log: $LOGFILE_HUMAN" 30

trap - EXIT
rm -f "$LOCK"
log "DONE" "INFRA ${INFRA_NUM} befejezve: OK=$OK SKIP=$SKIP FAIL=$FAIL"
