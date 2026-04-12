#!/bin/bash
# =============================================================================
# 00_master.sh — Vibe Coding Workspace Installer v6.5
#
# Változtatások v6.5 (2026-04-12 UI + state kezelés fix — 5 probléma):
#
#   FIX 1: MOD_DONE state → checklist default OFF (de mindig választható)
#     Probléma: MOD_01A_DONE=true ellenére 01a előre be volt jelölve
#     Fix: minden regisztrált modul esetén a state-ből olvassuk a MOD_X_DONE
#          értéket, és ha true → default=OFF. A checkbox mindig választható marad.
#     Ez minden registry stack-re érvényes (generikus megközelítés).
#
#   FIX 2: Minden checkbox mindig választható
#     Probléma: hardware-incompatible modulok ki voltak szürkítve (OFF-forced)
#     Fix: az inkompatibilis moduloknál csak label kerül hozzá, de az OFF-forced
#          beállítás megszűnik → a user manuálisan is kijelölheti
#
#   FIX 3: MOD_01A_REBOOTED automatikus detektálása
#     Probléma: reboot után MOD_01A_REBOOTED="" maradt (nem lett beállítva)
#     Fix: master indulásakor, ha REBOOT_NEEDED=true volt az előző session-ből,
#          és a master újra fut (= reboot megtörtént), beállítjuk a REBOOTED flagot
#     Ez generikusan működik: bármely REBOOT_BY_INFRA értékre
#
#   FIX 4: Üdvözlő dialog + checklist dinamikusan a registry-ből épül
#     Probléma: hardcoded modul lista, nem tükrözte a registry stack-ek számát
#     Fix: INFRA_IDS tömb alapján generált modul lista
#
#   FIX 5: Mód megjelenik az ablak fejlécében (minden dialógban)
#     Probléma: detect_run_mode dialógok nem mutatták a globális módot
#     Fix: MODE_TITLE prefix minden dialóg title-jában + export a child scriptekbe
#
# Változtatások v6.4.5 (REBOOT_NEEDED loop fix):
#   FIX: REBOOT_NEEDED=true esetén a loop most megáll (break)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/00_lib.sh"
REGISTRY="$SCRIPT_DIR/00_registry.sh"

[ -f "$LIB" ]      || { echo "HIBA: 00_lib.sh hiányzik!";      exit 1; }
[ -f "$REGISTRY" ] || { echo "HIBA: 00_registry.sh hiányzik!"; exit 1; }

_LIB_DIR="$SCRIPT_DIR/lib"
if [ ! -d "$_LIB_DIR" ]; then
  echo "HIBA: lib/ könyvtár hiányzik! ($LIB_DIR)"
  exit 1
fi
unset _LIB_DIR

INFRA_NAME="Vibe Coding Workspace"
INFRA_NUM="00"
source "$LIB"
source "$REGISTRY"

_LIB_MIN="6.4"
if ! printf '%s\n%s\n' "$_LIB_MIN" "$LIB_VERSION" | sort -V | head -1 | grep -qx "$_LIB_MIN"; then
  echo "HIBA: 00_lib.sh verzió $LIB_VERSION < minimum $_LIB_MIN"
  exit 1
fi

# ── Bootstrap ─────────────────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && { echo "HIBA: sudo szükséges!  sudo bash $0"; exit 1; }
ensure_deps
hw_detect
log_init
hw_show

# ── State inicializálás + keresztellenőrzés ───────────────────────────────────
infra_state_init
infra_state_validate
infra_state_show

# =============================================================================
# REBOOT DETEKTÁLÁS  [v6.5 FIX 3]
# =============================================================================
# Logika: ha REBOOT_NEEDED=true volt az előző session végén, és most újra fut
# a master (= felhasználó a reboot után elindította) → a reboot megtörtént.
#
# Ilyenkor:
#   - MOD_X_REBOOTED=true a REBOOT_BY_INFRA modul azonosítójára
#   - REBOOT_NEEDED, REBOOT_REASON, REBOOT_BY_INFRA törlése (tiszta állapot)
#
# Generikus: nem hardcode-olt "01a" → bármely modul beállíthatja REBOOT_BY_INFRA-t
# Pl: jövőbeli kernel modul installer is élhet ezzel a mechanizmussal.

_reboot_needed_prev=$(infra_state_get "REBOOT_NEEDED" "false")
_reboot_by_prev=$(infra_state_get "REBOOT_BY_INFRA" "")

if [ "$_reboot_needed_prev" = "true" ] && [ -n "$_reboot_by_prev" ]; then
  # A master újra fut miközben REBOOT_NEEDED volt → reboot megtörtént
  _rebooted_key="MOD_$(printf '%s' "$_reboot_by_prev" | tr '[:lower:]' '[:upper:]')_REBOOTED"
  _done_key="MOD_$(printf '%s' "$_reboot_by_prev" | tr '[:lower:]' '[:upper:]')_DONE"

  if [ "$(infra_state_get "$_done_key" "")" = "true" ]; then
    infra_state_set "$_rebooted_key" "true"
    log "STATE" "REBOOT detektálva: $_rebooted_key=true (REBOOT_BY_INFRA=${_reboot_by_prev})"
  fi

  # Reboot flag-ek törlése — az új session-ben tiszta állapot
  infra_state_set "REBOOT_NEEDED"   "false"
  infra_state_set "REBOOT_REASON"   ""
  infra_state_set "REBOOT_BY_INFRA" ""
  log "STATE" "Reboot flag-ek törölve — új session, tiszta állapot"
fi
unset _reboot_needed_prev _reboot_by_prev _rebooted_key _done_key

# ── Üdvözlő dialog — dinamikus modul lista  [v6.5 FIX 4] ────────────────────
# A modul lista a registry INFRA_IDS alapján generálódik, nem hardcoded.
# Így ha új modul kerül a registry-be, automatikusan megjelenik itt is.

_welcome_mods=""
for _id in "${INFRA_IDS[@]}"; do
  _done_val=$(infra_state_get "MOD_$(printf '%s' "$_id" | tr '[:lower:]' '[:upper:]')_DONE" "")
  _done_mark="  "
  [ "$_done_val" = "true" ] && _done_mark="✓ "
  _welcome_mods+="  ${_done_mark}${_id}  ${INFRA_NAME[$_id]}"
  # Reboot jelzés ha szükséges
  [ -n "${INFRA_REBOOT[$_id]:-}" ] && _welcome_mods+=" ${INFRA_REBOOT[$_id]}"
  _welcome_mods+=$'\n'
done

dialog_msg "Vibe Coding Workspace v6.5" "
  Ubuntu 24 LTS + RTX 5090 fejlesztői környezet

  GPU:     $HW_GPU_NAME
  Profil:  $HW_PROFILE

  ── REGISZTRÁLT INFRA MODULOK (${#INFRA_IDS[@]} db) ──────────────────
${_welcome_mods}
  ✓ = már kész | ⚠ REBOOT = újraindítás szükséges utána
  ─────────────────────────────────────────────────────
  A sudo jelszót csak egyszer kell megadni." 32

unset _welcome_mods _id _done_val _done_mark

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
# Exportálva: a child scriptek (01a, 01b...) is használhatják dialóg title-khez
export MODE_TITLE

# ── COMP STATE: mentett check eredmény ajánlat ────────────────────────────────
COMP_USE_CACHED=false

_CACHED_SUMMARY="$(comp_state_master_summary "${INFRA_IDS[@]}")"
_CACHED_COUNT="$(echo "$_CACHED_SUMMARY" | head -1)"
_CACHED_LIST="$(echo "$_CACHED_SUMMARY" | tail -n +2)"

if [ "${_CACHED_COUNT:-0}" -gt 0 ]; then
  if dialog_yesno "[$MODE_TITLE] Mentett check eredmények" "
  ${_CACHED_COUNT} INFRA modulhoz van mentett komponens állapot:

${_CACHED_LIST}
  Felhasználjuk a mentett eredményeket?

  IGEN  → Gyorsabb (mentett állapot töltődik be)
  NEM   → Friss check minden modulban (pontosabb)" 20; then
    COMP_USE_CACHED=true
    log "MODE" "COMP state: felhasználó → IGEN — mentett check betöltve (${_CACHED_COUNT} modul)"
  else
    COMP_USE_CACHED=false
    log "MODE" "COMP state: felhasználó → NEM — friss check kérve"
  fi
else
  log "MODE" "COMP state: nincs mentett check — automatikus friss check"
fi

export COMP_USE_CACHED
if [ "$COMP_USE_CACHED" = "true" ]; then
  log "MODE" "COMP_USE_CACHED=true — mentett komponens állapot aktív"
else
  log "MODE" "COMP_USE_CACHED=false — friss komponens ellenőrzés fut minden modulban"
fi

# ── INFRA checklist meta-adatok ───────────────────────────────────────────────
# INFRA_REBOOT: reboot szükséges ezek után (checklist label, nem hardcode döntés)
# A tényleges REBOOT_NEEDED az infra state-ből jön (infra modul írja).
declare -A INFRA_REBOOT=(
  ["01a"]=" ⚠ REBOOT"
)

# INFRA_DEP: függőségi jelzők (tájékoztató, tényleges ellenőrzés infra_require()-rel)
declare -A INFRA_DEP=(
  ["01b"]=" [01a+REBOOT→]"
  ["02"]=" [03→]"
  ["03"]=" [01b→]"
  ["06"]=" [03→]"
)

# =============================================================================
# CHECKLIST ÖSSZEÁLLÍTÁSA  [v6.5 FIX 1 + FIX 2]
# =============================================================================
# FIX 1: MOD_DONE state alapján határozzuk meg a default értéket
#   - MOD_X_DONE=true → default=OFF (de jelöljük ✓ jellel, és marad választható)
#   - MOD_X_DONE=""/false → INFRA_DEFAULT[$id] érték (registry-ből)
#
# FIX 2: Hardware-inkompatibilis modulok MINDIG választhatók maradnak
#   - Korábban: compat_label hozzáadása ÉS default=OFF kényszerítés → NEM volt kijelölhető
#   - Most: csak label kerül hozzá, default VÁLTOZATLAN → user manuálisan is kijelölheti
#   - Indoklás: user döntse el, a script belsejében infra_compatible() blokkol ha kell
#
# Checklist formátum: id, label, default (ON/OFF)
declare -a CHECKLIST_ARGS=()

for id in "${INFRA_IDS[@]}"; do
  local_name="${INFRA_NAME[$id]}"
  local_desc="${INFRA_DESC[$id]}"
  local_hw="${INFRA_HW_REQ[$id]}"
  local_script="$SCRIPT_DIR/${INFRA_SCRIPT[$id]}"

  # ── MOD_DONE state → default OFF ha már kész [FIX 1] ─────────────────────
  # Ha MOD_X_DONE=true → a modul sikeresen lefutott → alapértelmezés: ne legyen
  # előre bejelölve (felesleges újrafuttatás elkerülése). De a user kijelölheti!
  _mod_key="MOD_$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')_DONE"
  _mod_done=$(infra_state_get "$_mod_key" "")
  _mod_rebooted=$(infra_state_get \
    "MOD_$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')_REBOOTED" "")

  if [ "$_mod_done" = "true" ]; then
    local_default="OFF"   # Kész → ne jelöljük be automatikusan
    # Vizuális jelzés a labelben: kész, és esetleg rebootolva is
    _done_mark="✓"
    [ -n "$_mod_rebooted" ] && _done_mark="✓↺"  # ✓↺ = kész + rebootolva
  else
    local_default="${INFRA_DEFAULT[$id]}"
    _done_mark=""
  fi

  # ── Suffix: reboot + függőség jelzők ─────────────────────────────────────
  suffix=""
  [ -n "${INFRA_REBOOT[$id]:-}" ] && suffix+="${INFRA_REBOOT[$id]}"
  [ -n "${INFRA_DEP[$id]:-}" ]    && suffix+="${INFRA_DEP[$id]}"
  [ -n "$_done_mark" ]            && suffix+=" [${_done_mark}]"

  # ── Hardware kompatibilitás — CSAK label, NEM tiltja le [FIX 2] ──────────
  # Ha a hardver nem kompatibilis, jelezzük a leírásban, de a default-ot
  # NEM kényszerítjük OFF-ra. A user manuálisan kijelölheti, de a script
  # belsejében infra_compatible() vagy infra_run() visszatér 2-vel.
  compat_label=""
  if ! infra_compatible "$local_hw"; then
    compat_label=" ⚠[${HW_PROFILE}]"
  fi

  # Script létezés jelzés
  [ ! -f "$local_script" ] && compat_label="${compat_label} [HIÁNYZIK]"

  CHECKLIST_ARGS+=(
    "$id"
    "${id}. ${local_name}${suffix} — ${local_desc}${compat_label}"
    "$local_default"
  )
done

# ── Módcím a checklist fejlécben [FIX 5] ─────────────────────────────────────
# Az ablak TITLE mutatja a módot ("Telepítő — INFRA kiválasztás")
# A description body szöveg is tartalmazza: "[install mód] Válaszd ki..."
SELECTED=$(dialog_checklist \
  "$MODE_TITLE — INFRA kiválasztás" \
  "\n  [$RUN_MODE mód]  Válaszd ki a modulokat:\n  (⚠ REBOOT = újraindítás szükséges | [X→] = függőség | [✓] = kész)\n\n  A 01a minden más ELŐFELTÉTELE." \
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

  # REBOOT_NEEDED törlése az előző futásból — csak az aktuális modul értéke számít
  infra_state_set "REBOOT_NEEDED" "false"

  infra_run "$id" "$SCRIPT_DIR" "$RUN_MODE"
  EC=$?

  case $EC in
    0)  ((TOTAL_OK++))
        if [ "$(infra_state_get "REBOOT_NEEDED" "false")" = "true" ]; then
          if [ "${RUN_MODE:-install}" = "check" ]; then
            log "MASTER" "INFRA $id: OK (check mód: REBOOT_NEEDED flag ignorálva)"
            infra_state_set "REBOOT_NEEDED" "false"
          else
            REBOOT_NEEDED=true
            log "MASTER" "INFRA $id: OK — REBOOT_NEEDED flag aktív"
            # v6.4.5 FIX: REBOOT_NEEDED=true → loop megállítása
            # A reboot utáni modulok csak az újraindítás után futtathatók
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
  # NE töröljük REBOOT_NEEDED-et itt — a következő master induláskor
  # a reboot detektálás ezt felhasználja MOD_X_REBOOTED beállításához!
  # (A REBOOT_NEEDED=false csak AKKOR törlődik, ha a master ÚJRA indul reboot után)
  dialog_msg "[$MODE_TITLE] Kész — Újraindítás szükséges!" "$(printf '%b' "$SUMMARY")" 24
  dialog_yesno "Újraindítás" "\n  Újraindítjuk most a gépet?" 10 && reboot
elif [ "$TOTAL_FAIL" -gt 0 ]; then
  dialog_warn "[$MODE_TITLE] Befejezve — hibákkal" "$(printf '%b' "$SUMMARY")" 20
else
  dialog_msg  "[$MODE_TITLE] Befejezve — Minden OK!" "$(printf '%b' "$SUMMARY")" 18
fi

log "MASTER" "Befejezve: OK=$TOTAL_OK SKIP=$TOTAL_SKIP FAIL=$TOTAL_FAIL"
