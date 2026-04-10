#!/bin/bash
# ============================================================================
# 00_lib_core.sh — Vibe Coding Workspace lib v6.4
#
# LEÍRÁS: Globális változók, felhasználó azonosítás, log rendszer, sudo, utility-k
# BETÖLTÉS: source-olja a 00_lib.sh master loader
# NE futtasd közvetlenül!
# ============================================================================

# =============================================================================
# 00_lib.sh — Vibe Coding Workspace — Közös függvénytár v6.1
# =============================================================================
#
# CÉLKITŰZÉS
#   Minden INFRA script (01-08) ezt source-olja. Tartalmaz mindent ami
#   megosztott: log, GUI, hardver detektálás, state kezelés, komponens
#   ellenőrzés, sudo kezelés, apt segédek.
#
# MULTI-HARDWARE TÁMOGATÁS
#   A lib tervezésekor figyelembe vett hardver profilok:
#     desktop-rtx      — Asztali PC, NVIDIA RTX dGPU (Blackwell/Ada/Ampere)
#     desktop-rtx-old  — Asztali PC, régebbi NVIDIA (Turing/Pascal, SM<86)
#     notebook-rtx     — Laptop, NVIDIA Optimus/Prime dGPU + iGPU
#     notebook-igpu    — Laptop, csak integrált GPU (Intel/AMD) — irodai gép
#     desktop-igpu     — Asztali PC, csak integrált GPU
#
# SZÁLAK KÖZÖTTI KOMMUNIKÁCIÓ
#   ~/.infra-state fájl kulcs=érték párokkal.
#   Schema: lásd infra_state_init() és INFRA STATE SCHEMA szekció.
#   Minden szál olvas belőle; a 01-es szál írja az alapadatokat.
#
#
# VÁLTOZTATÁSOK v6.4.1 (log jogosultság fix)
#   - log_init(): chown "$_REAL_UID:$_REAL_GID" a LOG_DIR + log fájlokra
#     sudo futtatáskor root:root lenne → automatikusan javítja a user-re
#     Korábban: minden futás után 'sudo chown -R $USER ~/AI-LOG-INFRA-SETUP' kellett
#
# VÁLTOZTATÁSOK v6.4 (UI + Driver detektálás javítás)
#   - hw_detect(): HW_NVIDIA_PKG most ténylegesen telepített driverre mutat
#       dpkg -l 'nvidia-driver-*-open' → legmagasabb telepített sorozat
#       Fallback: apt-cache search → legmagasabb elérhető sorozat
#       Pl: 580.126.09 → HW_NVIDIA_PKG="nvidia-driver-580-open" ✓
#   - hw_show(): driver verzió: nvidia-smi alapján mutatja a tényleges verziót
#       pl. "nvidia-driver-580-open (v580.126.09)"
#   - YAD ablakméret: 4K monitorhoz igazítva (+50% szélesség/magasság)
#       dialog_msg/warn: 520→780px wide
#       dialog_menu (radiolist): 560×360→840×480px
#       dialog_checklist: 680×500→920×620px
#       progress_open (paned): 720×580→960×720px
#   - dialog_menu: explicit OK/Mégsem gombfelirat (YAD alapértelmezett helyett)
#
# VÁLTOZTATÁSOK v6.3 (03 Python/AI-ML integráció)
#   - comp_check_torch(): PyTorch import alapú ellenőrző hozzáadva
#       torch.__version__ + CUDA elérhetőség (cuda.is_available) logolva
#       Paraméterek: $1=min_ver (opcionális), $2=python bináris elérési út
#   - INFRA STATE SCHEMA: kibővítve 03-as szálhoz szükséges kulcsokkal
#       INST_PYTHON_VER      — telepített Python verzió (03 írja)
#       INST_UV_VER          — telepített uv verzió (03 írja)
#       INST_TORCH_VER       — telepített PyTorch verzió (03 írja)
#   - infra_state_init(): az új kulcsok _init_key hívásaival bővítve
#   - infra_state_validate(): 03-as modul konzisztencia ellenőrzés
#       (MOD_03_DONE=true → INST_TORCH_VER nem üres konzisztencia)
#
# VÁLTOZTATÁSOK v6.2 (02 AI stack integráció)
#   - comp_check_vllm(): új dedikált vLLM importálhatóság ellenőrző hozzáadva
#     A vLLM-nek nincs saját verzió CLI-je → Python import alapján ellenőriz
#   - INFRA STATE SCHEMA: kibővítve 02-es szálhoz szükséges kulcsokkal
#       MOD_02_DONE              — 02_local_ai_stack kész jelzője
#       INST_OLLAMA_VER          — telepített Ollama verzió (02 írja)
#       INST_VLLM_VER            — telepített vLLM verzió (02 írja)
#       FEAT_TURBOQUANT          — TurboQuant bináris elérhető-e
#       FEAT_OLLAMA_GPU          — Ollama GPU üzemmódban fut-e
#       TURBOQUANT_BUILD_MODE    — utolsó build mód: cpu|gpu89|gpu120
#   - infra_state_init(): az új kulcsok _init_key hívásaival bővítve
#   - infra_state_validate(): 02-es modul konzisztencia ellenőrzés
#     (FEAT_VLLM=true → FEAT_GPU_ACCEL=true szükséges konzisztencia javítva)
#
# VÁLTOZTATÁSOK v6.1 (01b integráció)
#   - comp_check_zsh(): új dedikált Zsh verzió ellenőrző hozzáadva
#   - INFRA STATE SCHEMA: kibővítve 01a/01b szétválasztáshoz szükséges kulcsokkal
#       MOD_01A_DONE, MOD_01A_REBOOTED, MOD_01B_DONE,
#       INST_ZSH_VER, INST_OMZ_COMMIT, FEAT_SHELL_ZSH
#   - infra_state_init(): az új kulcsok _init_key hívásaival bővítve
#   - MOD_01_DONE / MOD_01_REBOOTED lecserélve MOD_01A_DONE / MOD_01A_REBOOTED-re
#     (backward compat: a régi kulcsok infra_state_set()-tel bármikor írhatók)
#
# VÁLTOZTATÁSOK v6.0
#   - Multi-HW profil: notebook-rtx és desktop-igpu hozzáadva
#   - tee_to_all(): ismétlődő tee minta absztrahálva
#   - infra_state_init(): teljes state séma inicializálása
#   - infra_state_validate(): keresztellenőrzés
#   - hw_has_nvidia(): helper bool
#   - hw_capability(): képesség lekérés profil alapján
#   - infra_require(): függőség ellenőrzés modulok között
#   - ensure_deps(): logikai hiba javítva
#   - Teljes, részletes kommentezés minden függvénynél
#
# =============================================================================

# ── Verzió ────────────────────────────────────────────────────────────────────
LIB_VERSION="6.4.1"

# =============================================================================
# SZEKCIÓ 1 — GLOBÁLIS VÁLTOZÓK ÉS KONSTANSOK
# =============================================================================

# ── Alap konfiguráció ─────────────────────────────────────────────────────────

# whiptail ablak alapméret (fallback ha YAD nem elérhető)
WT_W=76
WT_H=20

# INFRA azonosítók — minden script felülírja saját értékével
INFRA_NAME="${INFRA_NAME:-}"     # pl. "Ubuntu alap + NVIDIA + CUDA"
INFRA_NUM="${INFRA_NUM:-00}"     # pl. "01a"

# Interaktív mód: false = minden ask_proceed automatikusan igen
STEP_INTERACTIVE="${STEP_INTERACTIVE:-true}"

# Futtatási mód — 00_master.sh exportálja, minden script örökli
# install   → hiányzó komponensek telepítése
# update    → meglévők frissítése ha van újabb verzió
# check     → csak állapot felmérés, semmi sem változik
# reinstall → teljes újratelepítés (még ha megvan is)
RUN_MODE="${RUN_MODE:-install}"

# ── Felhasználó azonosítás ────────────────────────────────────────────────────
# FONTOS: sudo alatt $HOME=/root, $USER=root — ezek HELYTELENEK lesznek.
# A _REAL_* változók mindig a tényleges (nem root) felhasználóra mutatnak.
_REAL_USER="${SUDO_USER:-$USER}"
_REAL_HOME="$(getent passwd "$_REAL_USER" | cut -d: -f6)"
_REAL_UID="$(id -u "$_REAL_USER" 2>/dev/null || echo "1000")"
_REAL_GID="$(id -g "$_REAL_USER" 2>/dev/null || echo "1000")"

# ── Log rendszer ──────────────────────────────────────────────────────────────
# Könyvtár: ~/AI-LOG-INFRA-SETUP/ (nem /var/log — user jogosultsága)
LOG_DIR="${_REAL_HOME}/AI-LOG-INFRA-SETUP"
LOG_DATE=$(date '+%Y%m%d_%H%M%S')

# AI log: ANSI-stripped plain text — LLM-nek, hibakereséshez
LOGFILE_AI="${LOGFILE_AI:-$LOG_DIR/install_${LOG_DATE}.log}"

# Human log: ccze-vel színezett ANSI — embernek, VS Code-ban nézhető
LOGFILE_HUMAN="${LOGFILE_HUMAN:-$LOG_DIR/install_${LOG_DATE}.ansi}"

# Backward kompatibilitás
LOGFILE="${LOGFILE_AI}"

# ── Sudo jelszó ───────────────────────────────────────────────────────────────
# Egyszer kérjük a session elején, sudo_init() validálja.
# Exportálva van hogy child processek örököljék.
SUDO_PASS="${SUDO_PASS:-}"

# ── Hardver profil változók ───────────────────────────────────────────────────
# hw_detect() tölti fel ezeket. Alapértelmezések addig amíg nem fut le.
HW_PROFILE="${HW_PROFILE:-unknown}"       # profil neve (lásd fent)
HW_GPU_NAME="${HW_GPU_NAME:-}"            # pl. "NVIDIA GeForce RTX 5090 (Blackwell SM_120)"
HW_GPU_PCI="${HW_GPU_PCI:-}"             # pl. "10de:2b85"
HW_GPU_IGPU="${HW_GPU_IGPU:-}"           # integrált GPU neve pl. "Intel AlderLake-S GT1"
HW_GPU_ARCH="${HW_GPU_ARCH:-}"           # blackwell|ada|ampere|turing|igpu|unknown
HW_VLLM_OK="${HW_VLLM_OK:-false}"        # vLLM GPU inferencia lehetséges-e
HW_NVIDIA_OPEN="${HW_NVIDIA_OPEN:-false}" # open kernel modul kell-e (Blackwell: kötelező)
HW_CUDA_ARCH="${HW_CUDA_ARCH:-}"         # SM szám pl. "120" (SM_120 = Blackwell)
HW_HYBRID="${HW_HYBRID:-false}"          # iGPU + dGPU egyszerre
HW_NVIDIA_PKG="${HW_NVIDIA_PKG:-}"       # apt csomagnév pl. "nvidia-driver-570-open"
HW_IS_NOTEBOOK="${HW_IS_NOTEBOOK:-false}" # laptop chassis

# ── GUI backend ───────────────────────────────────────────────────────────────
# YAD: grafikus, paned terminál + progress; Whiptail: TUI fallback
GUI_BACKEND="whiptail"
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
  command -v yad &>/dev/null && GUI_BACKEND="yad"
fi

# ── Progress bar belső állapot ────────────────────────────────────────────────
# Ezeket a progress_open/close kezeli — script kódban ne módosítsd!
_PROGRESS_BACKEND=""    # "yad" | "whiptail" | ""
TERM_FIFO=""            # Named FIFO: YAD szöveges terminál panel inputja
PROG_FIFO=""            # Named FIFO: YAD progress panel inputja
YAD_PANED_PID=""        # YAD konténer process PID

# ── INFRA state fájl ──────────────────────────────────────────────────────────
# Szálak közötti kommunikáció fájlja — részletes schema: infra_state_init()
INFRA_STATE_FILE="${_REAL_HOME}/.infra-state"

# =============================================================================
# SZEKCIÓ 2 — ANSI SZŰRŐ HELPER
# =============================================================================
# A tee parancs minden helyen ugyanúgy kell: AI log (ANSI-stripped),
# human log (ccze), YAD terminál (FD4 ha nyitva).
# Ez a helper csökkenti a kód ismétlést.

# _tee_streams: stdin → AI log + human log + YAD terminál (ha nyitva)
# Használat: some_cmd 2>&1 | _tee_streams
# Megjegyzés: háttérben fut (&), a hívó wait-el rá
_tee_streams() {
  tee \
    >(sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][a-zA-Z]//g; s/\r//g' \
        >> "$LOGFILE_AI") \
    >(if command -v ccze &>/dev/null; then
        ccze -A >> "$LOGFILE_HUMAN"
      else
        cat >> "$LOGFILE_HUMAN"
      fi) \
    >([ "${_PROGRESS_BACKEND:-}" = "yad" ] && cat >&4 2>/dev/null \
        || cat >/dev/null) \
    > /dev/null
}

# =============================================================================
# SZEKCIÓ 3 — LOG RENDSZER
# =============================================================================

# log_init: log könyvtár létrehozása és fejléc írása mindkét log fájlba.
# Hívás: script elején, INFRA_NAME és RUN_MODE beállítása után.
log_init() {
  mkdir -p "$LOG_DIR"
  # ── Tulajdonos javítás ────────────────────────────────────────────────────
  # sudo futtatáskor a mkdir root:root tulajdonost ad → javítjuk a user-re.
  # Enélkül a user minden futás után manuálisan kell:
  #   sudo chown -R $USER ~/AI-LOG-INFRA-SETUP
  chown "$_REAL_UID:$_REAL_GID" "$LOG_DIR" 2>/dev/null || true
  # Log fájlok előre létrehozása helyes tulajdonossal.
  # A >> operátor root-ként hozná létre a fájlokat — ezt előzzük meg.
  touch "$LOGFILE_AI" "$LOGFILE_HUMAN" 2>/dev/null || true
  chown "$_REAL_UID:$_REAL_GID" "$LOGFILE_AI" "$LOGFILE_HUMAN" 2>/dev/null || true
  local header
  header="$(printf '═%.0s' {1..62})
 ${INFRA_NAME:-INFRA} — $(date '+%Y-%m-%d %H:%M:%S')
 Profil: ${HW_PROFILE:-?} | GUI: $GUI_BACKEND | Mód: $RUN_MODE
$(printf '═%.0s' {1..62})"
  printf '%s\n' "$header" >> "$LOGFILE_AI"
  if command -v ccze &>/dev/null; then
    printf '%s\n' "$header" | ccze -A >> "$LOGFILE_HUMAN"
  else
    printf '%s\n' "$header" >> "$LOGFILE_HUMAN"
  fi
}

# log: timestampelt bejegyzés írása minden stream-be.
# Paraméterek: $1=szint (INFO|OK|FAIL|...), $2...=üzenet
# Stream-ek: AI log (ANSI-stripped), human log (ccze), YAD terminál (FD4)
log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts="[$(date '+%H:%M:%S')]"
  local line="${ts}[${level}] ${msg}"

  # AI log: minden vezérlőkódot eltávolítunk — LLM olvasásra optimalizált
  printf '%s\n' "$line" \
    | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][a-zA-Z]//g; s/\r//g' \
    >> "$LOGFILE_AI"

  # Human log: ccze által színezett — VS Code-ban nézhető
  if command -v ccze &>/dev/null; then
    printf '%s\n' "$line" | ccze -A >> "$LOGFILE_HUMAN"
  else
    printf '%s\n' "$line" >> "$LOGFILE_HUMAN"
  fi

  # YAD terminál ablak: csak ha progress_open() már megnyitotta (FD4 él)
  [ "${_PROGRESS_BACKEND:-}" = "yad" ] \
    && printf '%s\n' "$line" >&4 2>/dev/null || true
}

# log_term: közvetlen szöveges tartalom küldése terminál ablakba + logba.
# Különbség log()-tól: nincs timestamp/szint prefix — fejlécekhez, elválasztókhoz.
log_term() {
  local line="$1"
  printf '%s\n' "$line" \
    | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][a-zA-Z]//g; s/\r//g' \
    >> "$LOGFILE_AI"
  if command -v ccze &>/dev/null; then
    printf '%s\n' "$line" | ccze -A >> "$LOGFILE_HUMAN"
  else
    printf '%s\n' "$line" >> "$LOGFILE_HUMAN"
  fi
  [ "${_PROGRESS_BACKEND:-}" = "yad" ] \
    && printf '%s\n' "$line" >&4 2>/dev/null || true
}

# log_cmd: parancs futtatása + output mindkét log-ba + YAD terminálba.
# A progress bar FD3-on megy — az NEM kerül a logba.
# Visszatérési érték: a futtatott parancs exit code-ja
log_cmd() {
  local label="$1"; shift
  log "RUN" "$label"
  # YAD-ban: a parancs neve is látszik a terminálban
  [ "${_PROGRESS_BACKEND:-}" = "yad" ] \
    && printf '$ %s\n' "$*" >&4 2>/dev/null || true

  "$@" 2>&1 | _tee_streams
  local ec="${PIPESTATUS[0]}"
  [ "$ec" -eq 0 ] && log "OK" "$label" || log "FAIL" "$label (exit $ec)"
  return "$ec"
}

# ── Log strukturáló segédek ───────────────────────────────────────────────────

# log_infra_header: "Mit telepít/frissít" szekció logba írása.
# A szöveg ugyanaz mint ami a dialog_msg-ben megjelenik.
log_infra_header() {
  local what_text="$1"
  log "INFRA" "━━━ Mit telepít/frissít ━━━"
  while IFS= read -r line; do
    [ -n "$line" ] && log "INFRA" "$line"
  done <<< "$what_text"
}

# log_install_paths: telepítési útvonalak logba írása.
log_install_paths() {
  local paths_text="$1"
  log "PATH" "━━━ Telepítési helyek ━━━"
  while IFS= read -r line; do
    [ -n "$line" ] && log "PATH" "$line"
  done <<< "$paths_text"
}

# log_comp_status: COMP_STATUS[] tartalom logba írása strukturáltan.
# Hívás: a comp_check_*() függvények lefutása után.
log_comp_status() {
  log "COMP" "━━━ Komponens állapot ━━━"
  # COMP_CHECK tömb elemeit dolgozzuk fel: "name||min" formátum
  for spec in "$@"; do
    IFS='|' read -r cname _ cmin <<< "$spec"
    local line
    line="$(comp_line "$cname" "$cname" "$cmin")"
    log "COMP" "$line"
  done
}

# show_result: összesítő dialóg + log bejegyzés a script végén.
show_result() {
  local ok="$1" skip="$2" fail="$3"
  local msg="\n  ✓  Sikeres:   $ok\n  -  Kihagyott: $skip"
  [ "$fail" -gt 0 ] && msg+="\n  ✗  Hiba:      $fail"
  msg+="\n\n  AI log:    $LOGFILE_AI\n  Human log: $LOGFILE_HUMAN"

  log "RESULT" "━━━ OK=$ok SKIP=$skip FAIL=$fail ━━━"
  log "RESULT" "AI log:    $LOGFILE_AI"
  log "RESULT" "Human log: $LOGFILE_HUMAN"

  # Módcímke megjelenítés az összesítőben
  local mode_label
  case "$RUN_MODE" in
    install)   mode_label="Telepítő"     ;;
    update)    mode_label="Frissítő"     ;;
    check)     mode_label="Ellenőrző"    ;;
    reinstall) mode_label="Újratelepítő" ;;
    *)         mode_label="$RUN_MODE"    ;;
  esac

  if [ "$fail" -gt 0 ]; then
    dialog_warn "[$mode_label] Eredmény — $INFRA_NAME" "$msg" 14
  else
    dialog_msg "[$mode_label] ✓ Kész — $INFRA_NAME" "$msg" 14
  fi
}

# =============================================================================
# SZEKCIÓ 4 — SUDO KEZELÉS
# =============================================================================

# sudo_init: sudo jelszó egyszeri bekérése és validálása.
# A jelszót SUDO_PASS env változóban tárolja (exportálva).
# Child processek (bash "$script") öröklik — nem kell újra kérni.
sudo_init() {
  # Ha már root vagyunk (EUID=0), nincs szükség jelszóra
  [ "$EUID" -eq 0 ] && return 0

  # Ha már van érvényes jelszó (pl. parent process exportálta), kihagyjuk
  if [ -n "$SUDO_PASS" ]; then
    if echo "$SUDO_PASS" | sudo -S true 2>/dev/null; then
      return 0
    fi
    # Jelszó lejárt vagy helytelen — újra kérjük
    SUDO_PASS=""
  fi

  # Jelszó bekérése grafikus dialógon
  SUDO_PASS=$(dialog_pass "Rendszergazda jelszó" \
    "\n  Add meg a sudo jelszót.\n\n  Csak egyszer kell — a teljes telepítés\n  alatt érvényes marad." 12)

  # Validálás — ha helytelen, leállunk
  if ! echo "$SUDO_PASS" | sudo -S true 2>/dev/null; then
    dialog_warn "Hibás jelszó" "\n  A megadott jelszó helytelen.\n  A telepítő leáll." 10
    exit 1
  fi

  export SUDO_PASS
  log "AUTH" "Sudo jelszó validálva (${_REAL_USER})"
}

# sudo_run: parancs futtatása sudo-val, a tárolt jelszóval.
# Ha már root vagy, közvetlenül futtatja. Ha van SUDO_PASS, azt használja.
# Visszatérési érték: a futtatott parancs exit code-ja.
sudo_run() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  elif [ -n "$SUDO_PASS" ]; then
    echo "$SUDO_PASS" | sudo -S "$@" 2>/dev/null
  else
    sudo "$@"
  fi
}

# sudo_log: sudo_run + log_cmd kombináció.
# Paraméterek: $1=felirat a logban, $2...=parancs
sudo_log() {
  local label="$1"; shift
  log "RUN" "[sudo] $label"
  [ "${_PROGRESS_BACKEND:-}" = "yad" ] \
    && printf '$ sudo %s\n' "$*" >&4 2>/dev/null || true

  if [ "$EUID" -eq 0 ]; then
    "$@" 2>&1 | _tee_streams
  elif [ -n "$SUDO_PASS" ]; then
    echo "$SUDO_PASS" | sudo -S "$@" 2>&1 | _tee_streams
  else
    log_cmd "$label" sudo "$@"
  fi

  local ec="${PIPESTATUS[0]}"
  [ "$ec" -eq 0 ] && log "OK" "$label" || log "FAIL" "$label (exit $ec)"
  return "$ec"
}

# =============================================================================

# SZEKCIÓ 13 — UTILITY FÜGGVÉNYEK
# =============================================================================

# Csomagkezelő segédek
pkg_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }
pkg_version()   { dpkg -l "$1" 2>/dev/null | awk '/^ii/{print $3}' | head -1; }
cmd_exists()    { command -v "$1" &>/dev/null; }
source_exists() {
  grep -rq "$1" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null
}

# get_real_user/home: alternatív elérési módok _REAL_* változókhoz
get_real_user() { echo "${SUDO_USER:-$USER}"; }
get_real_home() { getent passwd "$(get_real_user)" | cut -d: -f6; }

# ask_proceed: igen/nem kérdés feltevése, logolással.
#
# MÓDOK:
#   check mód     → automatikus KIHAGYÁS (return 1) — nem fut le semmi
#                   az ellenőrző mód CSAK OLVAS, soha nem ír!
#   STEP_INTERACTIVE=false → automatikus IGEN (return 0) — CI futtatáshoz
#   interaktív    → grafikus dialóg, user dönt
#
# Visszatér: 0=igen/folytat, 1=nem/kihagyja
ask_proceed() {
  local prompt="${1:-Folytatjuk?}"

  # ── Check mód: minden egyes ask_proceed automatikusan kihagyva ──────────────
  # Az ellenőrző mód célja: állapot felmérés, NEM módosítás.
  # Ha a check módban is megkérdeznénk, a user tudatlanul xorg.conf-ot írhat,
  # initramfs-t futtathat, stb. — ezt megelőzzük.
  if [ "${RUN_MODE:-install}" = "check" ]; then
    log "AUTO" "[check mód] kihagyva: $prompt"
    return 1   # "nem" — a lépés nem fut le
  fi

  # ── Automatikus mód (pl. CI/CD, STEP_INTERACTIVE=false) ─────────────────────
  if [ "$STEP_INTERACTIVE" = "false" ]; then
    log "AUTO" "$prompt → igen"
    return 0
  fi

  # ── Interaktív: grafikus dialóg ───────────────────────────────────────────────
  log "KÉRDÉS" "$prompt"
  dialog_yesno "Megerősítés" "\n  $prompt" 10
  local ans=$?

  if [ $ans -eq 0 ]; then
    log "USER" "igen → $prompt"
    return 0
  else
    log "USER" "nem → $prompt"
    return 1
  fi
}

# check_lock: párhuzamos futtatás megakadályozása lock fájllal.
# Ha létezik: megkérdezi a usert, törölje-e. Régi (2h+) lock-ot auto-törli.
check_lock() {
  local lock="$1"
  if [ -f "$lock" ]; then
    local age age_min
    age=$(( $(date +%s) - $(stat -c %Y "$lock") ))
    age_min=$(( age / 60 ))
    if [ "$age" -lt 7200 ]; then
      dialog_yesno "Lock fájl létezik" "
  A lock fájl ${age_min} perce létezik:
  $lock

  Lehetséges oka: megszakított előző futás.

  Töröljük és folytatjuk?" 14
      if [ $? -eq 0 ]; then
        rm -f "$lock"
        log "LOCK" "Lock törölve, folytatás: $lock"
      else
        log "LOCK" "Futás megszakítva a lock miatt: $lock"
        exit 0
      fi
    else
      log "LOCK" "Régi lock törölve (${age_min} perc): $lock"
      rm -f "$lock"
    fi
  fi
  touch "$lock"
  log "LOCK" "Lock létrehozva: $lock"
}

# ensure_deps: YAD és ccze bootstrap telepítése ha hiányzik.
# A 00_master.sh hívja az első dolog előtt.
ensure_deps() {
  # YAD telepítése ha van display és még nincs fenn
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && ! command -v yad &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq yad 2>/dev/null && {
      GUI_BACKEND="yad"
      export GUI_BACKEND
    } || true
  fi
  # ccze telepítése ha nincs (human log színezéséhez)
  command -v ccze &>/dev/null \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ccze 2>/dev/null \
    || true
}

# =============================================================================
# SZEKCIÓ 14 — BACKWARD KOMPATIBILITÁS
# =============================================================================
# Régebbi scriptekben wt_* prefix volt a dialog_ helyett.
# Ezeket megtartjuk hogy a migráció fokozatos lehessen.

wt_msg()       { dialog_msg "$@"; }
wt_warn()      { dialog_warn "$@"; }
wt_yesno()     { dialog_yesno "$@"; }
wt_input()     { dialog_input "$@"; }
wt_pass()      { dialog_pass "$@"; }
wt_menu()      { dialog_menu "$@"; }
wt_checklist() { dialog_checklist "$@"; }

# apt_install: egyszerű apt telepítés logba, progress nélkül (backward compat)
apt_install() {
  DEBIAN_FRONTEND=noninteractive sudo_run apt-get install -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "$@" >> "$LOGFILE_AI" 2>&1
}
