#!/bin/bash
# =============================================================================
# 00_master.sh — Vibe Coding Workspace Installer v6.4.5
#
# Változtatások v6.4.5 (2026-04-12 kritikus bugfix):
#   FIX: REBOOT_NEEDED=true esetén a loop most megáll (break)
#        Korábban: 01a után azonnal 01b is elindult → infra_require("01a") FAIL
#        Most: 01a befejeztével leáll, user manuálisan indítja 01b-t reboot után
#
# Változtatások v6.4.4 (módnév dialógokban + COMP STATE részletes log):
#   - dialog fejlécek: [$MODE_TITLE] prefix minden módválasztás utáni ablakban
#     COMP STATE ajánlat, Kilépés, Megerősítés, Hiba dialog
#   - COMP STATE log: "felhasználó → IGEN/NEM" döntés explicit logolva
#     COMP_USE_CACHED=true/false okának szöveges magyarázata a logban
#
# Változtatások v6.4.3 (COMP STATE integráció):
#   - COMP_USE_CACHED export: mentett check eredmények felajánlása
#     comp_state_master_summary() listázza a cachetelt modulokat
#     User dönthet: mentett state betöltése vs. friss check futtatása
#   - Child scriptek öröklik COMP_USE_CACHED=true/false
#
# Változtatások v6.4.2 (fix mód + reboot suppress):
#   - Módválasztó: 4. opció "javítás" (fix) mód
#     fix módban ask_proceed() interaktív, REBOOT_NEEDED guard aktív
#     Cél: hiányzó komponensek pótlása reboot nélkül, majd újraellenőrzés
#
# Változtatások v6.4 (split lib rendszer + bug fixek):
#   - LIB_VERSION ellenőrzés: minimum 6.4 (split lib, infra_require fix)
#   - lib/ alkönyvtár létezés ellenőrzés indításkor
#   - infra_require(): case-insensitive kulcs (01a → MOD_01A_DONE)
#   - detect_run_mode(): check módban nem változtat RUN_MODE-on
#   - YAD ablakok: 4K-ra méretezve, Pango font support
#   - hw_detect(): tényleges telepített driver detektálás dpkg alapján
#
# Változtatások v6.2 (03 Python/AI-ML v6.1 + lib v6.3 integráció):
#   - LIB_VERSION ellenőrzés: minimum 6.3 kell (comp_check_torch())
#   - Üdvözlő dialog: 03 leírás frissítve (LangChain, HuggingFace, bővített)
#   - INFRA_DEP map: 03 [01b→] megjegyzés pontosítva
#   - infra_state_validate() hívás a futtatás előtt (keresztellenőrzés)
#
# Változtatások v6.1 (lib v6.2 + 02 AI stack integráció):
#   - Üdvözlő dialog: 02 leírás pontosítva (Ollama+vLLM+TurboQuant)
#   - 02 futtatási sorrendje: 03 után (infra_require ellenőrzi)
#   - LIB_VERSION ellenőrzés: minimum 6.2 kell
#   - Egyéb: azonos logika a v6.0-val (state-alapú REBOOT, generic modulok)
#
# Változtatások v6.0:
#   - 01 → 01a (pre-reboot) + 01b (post-reboot) szétválasztás kezelése
#   - REBOOT_NEEDED: hardcoded [ "$id" = "01" ] helyett infra state-alapú
#     (infra_state_get "REBOOT_NEEDED") — bármely jövőbeli modul írhatja
#   - INFRA_REBOOT és INFRA_DEP map-ek frissítve: 01a, 01b
#   - Üdvözlő dialog sorrend aktualizálva
#   - Megerősítő szöveg generikus (nem "01-es modul")
#
# Futtatás: sudo bash 00_master.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/00_lib.sh"
REGISTRY="$SCRIPT_DIR/00_registry.sh"

[ -f "$LIB" ]      || { echo "HIBA: 00_lib.sh hiányzik!";      exit 1; }
[ -f "$REGISTRY" ] || { echo "HIBA: 00_registry.sh hiányzik!"; exit 1; }

# Split lib: a lib/ alkönyvtárnak léteznie kell (00_lib.sh loader betölti)
_LIB_DIR="$SCRIPT_DIR/lib"
if [ ! -d "$_LIB_DIR" ]; then
  echo "HIBA: lib/ könyvtár hiányzik! ($LIB_DIR)"
  echo "A 00_lib.sh v6.4+ a következő struktúrát igényli:"
  echo "  00_lib.sh         (master loader)"
  echo "  lib/00_lib_core.sh  lib/00_lib_hw.sh  lib/00_lib_ui.sh"
  echo "  lib/00_lib_state.sh lib/00_lib_comp.sh lib/00_lib_apt.sh"
  exit 1
fi
unset _LIB_DIR

INFRA_NAME="Vibe Coding Workspace"
INFRA_NUM="00"
source "$LIB"
source "$REGISTRY"

# ── LIB_VERSION ellenőrzés ────────────────────────────────────────────────────
# 00_lib.sh v6.4+ szükséges: split lib (lib/ alkönyvtár), infra_require case fix,
# detect_run_mode check mód javítás, YAD Pango font, hw_detect dpkg driver detektálás.
_LIB_MIN="6.4"
if ! printf '%s\n%s\n' "$_LIB_MIN" "$LIB_VERSION" | sort -V | head -1 | grep -qx "$_LIB_MIN"; then
  echo "HIBA: 00_lib.sh verzió $LIB_VERSION < minimum $_LIB_MIN"
  echo "Frissítsd a 00_lib.sh fájlt!"
  exit 1
fi

# ── Bootstrap ─────────────────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && { echo "HIBA: sudo szükséges!  sudo bash $0"; exit 1; }
ensure_deps
hw_detect
log_init
hw_show

# ── State inicializálás + keresztellenőrzés ───────────────────────────────────
# infra_state_init(): hiányzó kulcsokat feltölti alapértékekkel (nem írja felül!)
# infra_state_validate(): inkonzisztenciákat detektál és javít (pl. PYTORCH_INDEX)
infra_state_init
infra_state_validate
infra_state_show

# ── Üdvözlő + telepítési rend ─────────────────────────────────────────────────
dialog_msg "Vibe Coding Workspace v6.4.4" "
  Ubuntu 24 LTS + RTX 5090 fejlesztői környezet

  GPU:     $HW_GPU_NAME
  Profil:  $HW_PROFILE

  ── AJÁNLOTT TELEPÍTÉSI SORREND ──────────────────
  01a  System Foundation          ← KÖTELEZŐ ALAP
       Driver, CUDA, Docker, CTK
       ↓  ⚠  REBOOT SZÜKSÉGES  ⚠
  01b  Post-reboot konfiguráció   ← 01a + REBOOT után
       Oh My Zsh, shell setup
  03   Python 3.12 + AI/ML        ← 01b után
       pyenv, uv, PyTorch, LangChain, HuggingFace,
       FastAPI, JupyterLab, ruff, mypy, pre-commit
  02   Lokális AI stack           ← 03 után
       Ollama, vLLM, TurboQuant
  04   Node.js 22 LTS             ← független
  05   C64 toolchain              ← független
  06   Szerkesztők + CLINE        ← 03 után
  07   Sysadmin (PS7, Ansible)    ← független
  08   NAS scriptek               ← független
  ─────────────────────────────────────────────────
  A sudo jelszót csak egyszer kell megadni." 30

# ── Sudo jelszó ───────────────────────────────────────────────────────────────
sudo_init

# ── Működési mód választás ────────────────────────────────────────────────────
GLOBAL_MODE=$(dialog_menu "Működési mód" "
  Mit szeretnél csinálni?" \
  18 4 \
  "install" "Telepítő   — hiányzó komponensek felrakása" \
  "update"  "Frissítő   — meglévők frissítése újabb verzióra" \
  "check"   "Ellenőrző  — csak állapot felmérés, semmi sem változik" \
  "fix"     "Javítás    — hiányzó komponensek pótlása (reboot nélkül)")

[ -z "$GLOBAL_MODE" ] && { dialog_msg "Kilépés" "\n  Megszakítva."; exit 0; }
export RUN_MODE="$GLOBAL_MODE"
log "MODE" "Működési mód: $RUN_MODE"

case "$RUN_MODE" in
  install) MODE_TITLE="Telepítő" ;;
  update)  MODE_TITLE="Frissítő" ;;
  check)   MODE_TITLE="Ellenőrző" ;;
  fix)     MODE_TITLE="Javítás" ;;
  *)       MODE_TITLE="$RUN_MODE" ;;
esac

# ── COMP STATE: mentett check eredmény ajánlat ────────────────────────────────
# comp_state_master_summary() (00_lib_comp.sh) végignézi az összes regisztrált
# INFRA ID-t, és listázza amelyikhez van mentett check eredmény (COMP_XX_TS).
#
# COMP_USE_CACHED=true → a child scriptek comp_load_state()-szel töltik a
#   COMP_STATUS[]/COMP_VER[] tömböket a state fájlból (nem futnak friss check-et).
# COMP_USE_CACHED=false → minden script saját comp_check_*()-eket futtat.
#
# MIKOR ajánljuk fel?
#   - check módban: mindig felajánljuk (check éppen a frissítés lenne → cache OK)
#   - install/update/fix módban: csak ha van cached state, user dönt
#     (friss check eredmény jobb az install döntésnél — de a user időt takaríthat meg)
#
# Alapértelmezés: COMP_USE_CACHED=false (biztonságos: mindig friss check)

COMP_USE_CACHED=false

# comp_state_master_summary kimenetét feldolgozzuk:
#   1. sor: darabszám (hány modul van cachelve)
#   többi sor: lista
_CACHED_SUMMARY="$(comp_state_master_summary "${INFRA_IDS[@]}")"
_CACHED_COUNT="$(echo "$_CACHED_SUMMARY" | head -1)"
_CACHED_LIST="$(echo "$_CACHED_SUMMARY" | tail -n +2)"

if [ "${_CACHED_COUNT:-0}" -gt 0 ]; then
  # Van legalább egy mentett check eredmény → felajánljuk
  if dialog_yesno "[$MODE_TITLE] Mentett check eredmények felajánlása" "
  ${_CACHED_COUNT} INFRA modulhoz van mentett komponens állapot:

${_CACHED_LIST}
  Felhasználjuk a mentett eredményeket?

  IGEN  → Gyorsabb: nem fut le újra a komponens ellenőrzés
          (Mentett állapot a state fájlból töltődik)
  NEM   → Minden modul frissen ellenőriz (lassabb, de pontosabb)" 20; then
    COMP_USE_CACHED=true
    log "MODE" "COMP state: felhasználó → IGEN — mentett check betöltve (${_CACHED_COUNT} modul)"
  else
    COMP_USE_CACHED=false
    log "MODE" "COMP state: felhasználó → NEM — friss check kérve"
  fi
else
  # Nincs mentett check → automatikusan friss check, felajánlás nem jelenik meg
  log "MODE" "COMP state: nincs mentett check — automatikus friss check"
fi

export COMP_USE_CACHED
# A döntés eredményét és okát explicit logoljuk — AI log olvashatóság miatt
if [ "$COMP_USE_CACHED" = "true" ]; then
  log "MODE" "COMP_USE_CACHED=true — mentett komponens állapot aktív (friss check nem fut)"
else
  log "MODE" "COMP_USE_CACHED=false — friss komponens ellenőrzés fut minden modulban"
fi

# ── INFRA checklist meta-adatok ───────────────────────────────────────────────
# INFRA_REBOOT: ezek az ID-k után REBOOT szükséges (a checklist-ben jelöljük)
# A tényleges REBOOT_NEEDED döntés az infra state-ből jön (nem hardcode).
declare -A INFRA_REBOOT=(
  ["01a"]=" ⚠ REBOOT"
)

# INFRA_DEP: függőségi jelzők a checklist leírásában (tájékoztató jellegű)
# Megjegyzés: a tényleges ellenőrzés infra_require()-rel történik a scripten belül.
#   03 az infra_require("01B") hívást használja (uppercase kulcs: MOD_01B_DONE)
declare -A INFRA_DEP=(
  ["01b"]=" [01a+REBOOT→]"
  ["02"]=" [03→]"
  ["03"]=" [01b→]"
  ["06"]=" [03→]"
)

# ── Checklist összeállítása ────────────────────────────────────────────────────
declare -a CHECKLIST_ARGS=()
for id in "${INFRA_IDS[@]}"; do
  local_name="${INFRA_NAME[$id]}"
  local_desc="${INFRA_DESC[$id]}"
  local_default="${INFRA_DEFAULT[$id]}"
  local_hw="${INFRA_HW_REQ[$id]}"
  local_script="$SCRIPT_DIR/${INFRA_SCRIPT[$id]}"

  suffix=""
  [ -n "${INFRA_REBOOT[$id]:-}" ] && suffix+="${INFRA_REBOOT[$id]}"
  [ -n "${INFRA_DEP[$id]:-}" ]    && suffix+="${INFRA_DEP[$id]}"

  compat_label=""
  if ! infra_compatible "$local_hw"; then
    compat_label=" [NEM ELÉRHETŐ: $HW_PROFILE]"
    local_default="OFF"
  fi
  [ ! -f "$local_script" ] && compat_label="${compat_label} [HIÁNYZIK]"

  CHECKLIST_ARGS+=("$id" "${id}. $local_name${suffix} — $local_desc$compat_label" "$local_default")
done

SELECTED=$(dialog_checklist \
  "$MODE_TITLE — INFRA kiválasztás" \
  "\n  [$RUN_MODE mód]  Válaszd ki a modulokat:\n  (⚠ REBOOT = újraindítás szükséges utána | [X→] = függőség)\n\n  A 01a minden más ELŐFELTÉTELE." \
  "30" "16" \
  "${CHECKLIST_ARGS[@]}")

[ -z "$SELECTED" ] && { dialog_msg "[$MODE_TITLE] Kilépés" "\n  Semmi nem lett kijelölve."; exit 0; }

# ── Megerősítés ───────────────────────────────────────────────────────────────
CONFIRM_MSG="\n  [$MODE_TITLE — $RUN_MODE mód]\n\n  Kijelölt modulok:\n"
HAS_REBOOT=false
for id in $(printf '%s' "$SELECTED" | tr -d '"' | tr ' ' '\n' | sort); do
  [ -z "$id" ] || [ -z "${INFRA_NAME[$id]:-}" ] && continue
  reboot_note=""
  [ -n "${INFRA_REBOOT[$id]:-}" ] && { reboot_note=" ← ⚠ REBOOT"; HAS_REBOOT=true; }
  CONFIRM_MSG+="    ✓  $id — ${INFRA_NAME[$id]}$reboot_note\n"
done
# Generikus reboot figyelmeztetés — nem hardcode-olt ID-ra hivatkozik
$HAS_REBOOT && CONFIRM_MSG+="\n  ⚠  REBOOT szükséges a jelölt modul(ok) után!\n"
CONFIRM_MSG+="\n  Folytatjuk?"

dialog_yesno "[$MODE_TITLE] Megerősítés" "$(printf '%b' "$CONFIRM_MSG")" 22 || {
  dialog_msg "[$MODE_TITLE] Kilépés" "\n  Megszakítva."
  exit 0
}

# ── Futtatás ──────────────────────────────────────────────────────────────────
TOTAL_OK=0; TOTAL_SKIP=0; TOTAL_FAIL=0
REBOOT_NEEDED=false

for id in $(printf '%s' "$SELECTED" | tr -d '"' | tr ' ' '\n' | sort); do
  [ -z "$id" ] || [ -z "${INFRA_NAME[$id]:-}" ] && continue

  log "MASTER" "━━━ INFRA $id — ${INFRA_NAME[$id]} [$MODE_TITLE] ━━━"

  # Futtatás előtt töröljük a REBOOT_NEEDED flag-et az előző futásból,
  # hogy csak az aktuális modul által írt érték legyen érvényes.
  infra_state_set "REBOOT_NEEDED" "false"

  infra_run "$id" "$SCRIPT_DIR" "$RUN_MODE"
  EC=$?

  case $EC in
    0)  ((TOTAL_OK++))
        # State-alapú REBOOT_NEEDED — az infra modul írja, mi olvassuk.
        # Check módban: REBOOT_NEEDED soha nem propagálódik a local változóba.
        #   Indoklás: check módban ask_proceed auto-kihagyja a lépéseket,
        #   tehát valójában semmi sem változott → nincs reboot szükség.
        #   Ha mégis true kerül a state-be (script bug), ezt ignoráljuk.
        if [ "$(infra_state_get "REBOOT_NEEDED" "false")" = "true" ]; then
          if [ "${RUN_MODE:-install}" = "check" ]; then
            # Check módban: csak logolunk, NEM állítjuk be a local flag-et
            log "MASTER" "INFRA $id: OK (check mód: REBOOT_NEEDED flag ignorálva)"
            infra_state_set "REBOOT_NEEDED" "false"  # javítjuk is a state-et
          else
            REBOOT_NEEDED=true
            log "MASTER" "INFRA $id: OK — REBOOT_NEEDED flag aktív"
          # v6.4.5 FIX: REBOOT_NEEDED=true → loop megállítása
          # 01b (és más modulok) REBOOT ELŐTT NEM futtathatók.
          # A felhasználó a reboot után indítja újra a mastert és választja 01b-t.
          log "MASTER" "REBOOT_NEEDED=true — loop leállítva, további modulok kihagyva"
          break
          fi
        else
          log "MASTER" "INFRA $id: OK"
        fi
        ;;
    2)  ((TOTAL_SKIP++))
        log "SKIP" "INFRA $id kihagyva (hardver inkompatibilis)" ;;
    *)  ((TOTAL_FAIL++))
        log "FAIL" "INFRA $id hibával végzett (exit $EC)"
        dialog_yesno "[$MODE_TITLE] Hiba — INFRA $id" \
          "\n  ${INFRA_NAME[$id]} hibával végzett.\n\n  Folytatjuk a többivel?" 12 || break ;;
  esac
done

# ── Összesítő ─────────────────────────────────────────────────────────────────
SUMMARY="\n  Mód: $MODE_TITLE ($RUN_MODE)\n\n"
SUMMARY+="  ✓  Sikeres:   $TOTAL_OK\n"
SUMMARY+="  -  Kihagyott: $TOTAL_SKIP\n"
[ "$TOTAL_FAIL" -gt 0 ] && SUMMARY+="  ✗  Hibás:    $TOTAL_FAIL\n"
SUMMARY+="\n  AI log:    $LOGFILE_AI\n  Human log: $LOGFILE_HUMAN"

if $REBOOT_NEEDED; then
  _REBOOT_REASON="$(infra_state_get "REBOOT_REASON" "NVIDIA driver betöltés")"
  _REBOOT_BY="$(infra_state_get "REBOOT_BY_INFRA" "")"
  SUMMARY+="\n\n  ⚠  ÚJRAINDÍTÁS SZÜKSÉGES!"
  [ -n "$_REBOOT_BY" ] && SUMMARY+="\n  Modul: INFRA ${_REBOOT_BY}"
  SUMMARY+="\n  Ok: ${_REBOOT_REASON}"
  # Flag törlése — reboot után clean állapot
  infra_state_set "REBOOT_NEEDED" "false"
  dialog_msg "[$MODE_TITLE] Kész — Újraindítás szükséges!" "$(printf '%b' "$SUMMARY")" 24
  dialog_yesno "Újraindítás" "\n  Újraindítjuk most a gépet?" 10 && reboot
elif [ "$TOTAL_FAIL" -gt 0 ]; then
  dialog_warn "[$MODE_TITLE] Befejezve — hibákkal" "$(printf '%b' "$SUMMARY")" 20
else
  dialog_msg  "[$MODE_TITLE] Befejezve — Minden OK!" "$(printf '%b' "$SUMMARY")" 18
fi

log "MASTER" "Befejezve: OK=$TOTAL_OK SKIP=$TOTAL_SKIP FAIL=$TOTAL_FAIL"
