#!/bin/bash
# ============================================================================
# 00_lib_ui.sh — Vibe Coding Workspace lib v6.4
#
# LEÍRÁS: GUI réteg: YAD/whiptail dialóg absztrakció, progress bar, ensure_deps
# BETÖLTÉS: source-olja a 00_lib.sh master loader
# NE futtasd közvetlenül!
# ============================================================================

# SZEKCIÓ 11 — GUI ABSZTRAKCIÓS RÉTEG (YAD / WHIPTAIL)
# =============================================================================
# Minden dialog függvény először a YAD verziót próbálja, fallback whiptail.
# A MODE_TITLE automatikusan kerül az ablakcímbe ahol releváns.

# _mode_prefix: mód felirat az ablakcímekbe.
_mode_prefix() {
  case "${RUN_MODE:-}" in
    install)   echo "[Telepítő]"     ;;
    update)    echo "[Frissítő]"     ;;
    check)     echo "[Ellenőrző]"    ;;
    reinstall) echo "[Újratelepítő]" ;;
    *)         echo ""               ;;
  esac
}

# _yd_text: YAD --text tartalom előkészítése Pango markup-pal.
# A font méretet a YAD_FONT_SIZE változóval lehet állítani (default: 13).
# Csak YAD módban ad markup-ot — whiptail-ben plain text marad.
# Használat: yad --text="$(_yd_text "$msg")"
YAD_FONT_SIZE="${YAD_FONT_SIZE:-13}"

_yd_text() {
  local msg="$1"
  if [ "$GUI_BACKEND" = "yad" ]; then
    # Pango markup: span font megadja a méretet pixelben
    # A szövegben lévő < > & karaktereket escape-eljük (XML-safe)
    local safe_msg
    safe_msg=$(printf '%s' "$msg" \
      | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    printf '<span font="%d">%s</span>' "$YAD_FONT_SIZE" "$safe_msg"
  else
    printf '%s' "$msg"
  fi
}

# _yd_title: YAD ablak cím Pango markup-pal (nem támogatott --title-ben,
# de a --text első sora bold/large lehet)
# Használat: dialog_msg hívja automatikusan
_yd_title_prefix() {
  # A mode prefix a cím elejébe kerül
  local pfx
  pfx=$(_mode_prefix)
  [ -n "$pfx" ] && printf '%s ' "$pfx" || true
}


dialog_msg() {
  local title="$1" msg="$2" h="${3:-$WT_H}"
  log "UI" "MSG: $title"
  if [ "$GUI_BACKEND" = "yad" ]; then
    yad --title="$title" --text="$(_yd_text "$msg")" \
      --button="OK:0" \
      --width=780 --center --on-top 2>/dev/null
  else
    whiptail --title "$title" --msgbox "$msg" "$h" "$WT_W"
  fi
}

dialog_warn() {
  local title="⚠  $1" msg="$2" h="${3:-$WT_H}"
  log "WARN" "$1"
  if [ "$GUI_BACKEND" = "yad" ]; then
    yad --title="$title" --text="$(_yd_text "$msg")" --image=dialog-warning \
      --button="OK:0" \
      --width=780 --center --on-top 2>/dev/null
  else
    whiptail --title "$title" --msgbox "$msg" "$h" "$WT_W"
  fi
}

dialog_yesno() {
  local title="$1" msg="$2" h="${3:-12}"
  if [ "$GUI_BACKEND" = "yad" ]; then
    yad --title="$title" --text="$(_yd_text "$msg")" \
      --button="Igen:0" --button="Nem:1" \
      --width=780 --center --on-top 2>/dev/null
  else
    whiptail --title "$title" --yesno "$msg" "$h" "$WT_W"
  fi
}

dialog_input() {
  local title="$1" msg="$2" default="${3:-}" h="${4:-10}"
  if [ "$GUI_BACKEND" = "yad" ]; then
    yad --title="$title" --text="$(_yd_text "$msg")" \
      --entry --entry-text="$default" \
      --button="OK:0" --button="Mégsem:1" \
      --width=780 --center --on-top 2>/dev/null
  else
    whiptail --title "$title" --inputbox "$msg" "$h" "$WT_W" "$default" \
      3>&1 1>&2 2>&3
  fi
}

dialog_pass() {
  local title="$1" msg="$2" h="${3:-10}"
  if [ "$GUI_BACKEND" = "yad" ]; then
    yad --title="$title" --text="$(_yd_text "$msg")" \
      --entry --hide-text \
      --button="OK:0" --button="Mégsem:1" \
      --width=780 --center --on-top 2>/dev/null
  else
    whiptail --title "$title" --passwordbox "$msg" "$h" "$WT_W" \
      3>&1 1>&2 2>&3
  fi
}

# dialog_menu: egyválasztós menü (radiolist).
# Forrás: yad-guide.ingk.se/list/yad-list.html — radiolist szekció
# Paraméterek: $1=cím, $2=szöveg, $3=h, $4=lh, $5...=tag leírás párok
dialog_menu() {
  local title="$1" msg="$2" h="${3:-20}" lh="${4:-10}"; shift 4
  if [ "$GUI_BACKEND" = "yad" ]; then
    # YAD radiolist: első oszlop=radio állapot, második=rejtett tag, harmadik=leírás
    # --print-column=2 adja vissza a kiválasztott tag-et
    local -a yad_data=()
    local first=true
    while [ $# -ge 2 ]; do
      $first && yad_data+=("true") || yad_data+=("false")
      yad_data+=("$1" "$2")
      first=false
      shift 2
    done
    yad --title="$title" --text="$(_yd_text "$msg")" \
      --list --radiolist --no-headers \
      --column="" --column="tag":HD --column="Leírás" \
      --width=840 --height=480 --center --on-top \
      --button="OK:0" --button="Mégsem:1" \
      --print-column=2 \
      "${yad_data[@]}" 2>/dev/null | tr -d '|'
  else
    whiptail --title "$title" --menu "$msg" "$h" "$WT_W" "$lh" "$@" \
      3>&1 1>&2 2>&3
  fi
}

# dialog_checklist: többválasztós jelölőnégyzet lista.
# Forrás: yad-guide.ingk.se/list/yad-list.html — checklist szekció
# Paraméterek: $1=cím, $2=szöveg, $3=h, $4=lh, $5...=tag leírás ON/OFF hármasok
dialog_checklist() {
  local title="$1" msg="$2" h="${3:-22}" lh="${4:-12}"; shift 4
  if [ "$GUI_BACKEND" = "yad" ]; then
    local -a yad_data=()
    while [ $# -ge 3 ]; do
      [ "$3" = "ON" ] && yad_data+=("true") || yad_data+=("false")
      yad_data+=("$1" "$2")
      shift 3
    done
    yad --title="$title" --text="$(_yd_text "$msg")" \
      --list --checklist --no-headers \
      --column="" --column="tag":HD --column="Leírás" \
      --width=920 --height=620 --center --on-top \
      --print-column=2 --separator=" " \
      "${yad_data[@]}" 2>/dev/null | tr -d '|'
  else
    whiptail --title "$title" --checklist "$msg" "$h" "$WT_W" "$lh" "$@" \
      3>&1 1>&2 2>&3
  fi
}

# =============================================================================
# SZEKCIÓ 12 — PROGRESS BAR (YAD PANED TERMINÁL)
# =============================================================================
#
# ARCHITEKTÚRA (YAD módban):
#   FD3 → PROG_FIFO → yad --progress (alsó panel: %)
#   FD4 → TERM_FIFO → yad --text-info --tail (felső panel: élő log)
#   yad --paned --key=$$ → konténer, OK gombra vár (NEM auto-zár)
#
# Forrás: yad-guide.ingk.se/paned/yad-paned.html
#         yad-guide.ingk.se/progress/yad-progress.html
#         yad-guide.ingk.se/text/yad-text.html

# progress_open: YAD paned terminál + progress bar megnyitása.
# Paraméterek: $1=ablak cím, $2=progress felirat
progress_open() {
  local title="$1" msg="$2"

  if [ "$GUI_BACKEND" = "yad" ]; then
    # Named FIFO-k létrehozása (mktemp -u: csak a nevet generálja, nem hozza létre)
    TERM_FIFO="$(mktemp -u /tmp/yad_term_XXXXXX)"
    PROG_FIFO="$(mktemp -u /tmp/yad_prog_XXXXXX)"
    mkfifo "$TERM_FIFO" "$PROG_FIFO"

    local yad_key=$$  # Az aktuális process PID mint egyedi kulcs

    # Felső panel: szöveges terminál (élő log)
    # --tail: automatikusan az utolsó sorhoz görget
    # --no-buttons: nincs gomb a panelen (a paned konténer OK gombja vezérel)
    yad --text-info --tail --no-buttons \
        --plug="$yad_key" --tabnum=1 \
        < "$TERM_FIFO" &

    # Alsó panel: progress bar
    # --auto-kill: ha a konténer bezárul, ez is leáll
    yad --progress --text="$(_yd_text "$msg")" \
        --no-buttons --auto-kill \
        --plug="$yad_key" --tabnum=2 \
        < "$PROG_FIFO" &

    # Paned konténer: --orient=vert → felső terminál + alsó progress
    # --splitter=320: felső panel magassága pixelben
    # --button="OK:0": a user manuálisan zárja be
    yad --paned --key="$yad_key" \
        --title="$title" \
        --orient=vert --splitter=320 \
        --width=960 --height=720 \
        --center --on-top \
        --button="OK:0" 2>/dev/null &
    YAD_PANED_PID=$!

    # FD3 → progress panel, FD4 → terminál panel
    exec 3>"$PROG_FIFO"
    exec 4>"$TERM_FIFO"

    _PROGRESS_BACKEND="yad"

    # Fejléc a terminál ablakban (és a logban a log_term révén)
    log_term "$(printf '═%.0s' {1..68})"
    log_term " $title"
    log_term "$(printf '═%.0s' {1..68})"
  else
    # Whiptail fallback: egyszerű gauge, nincs terminál panel
    exec 3> >(whiptail --title "$title" --gauge "$msg" 8 "$WT_W" 0)
    _PROGRESS_BACKEND="whiptail"
  fi
}

# progress_set: progress % és felirat frissítése.
# Forrás: yad-guide.ingk.se/progress/yad-progress.html
#   YAD formátum: szám sor = százalék; "# szöveg" sor = felirat csere
#   Whiptail: XXX blokkok közt
# Paraméterek: $1=százalék (0-100), $2=felirat (opcionális)
progress_set() {
  local pct="$1" msg="${2:-}"
  if [ "${_PROGRESS_BACKEND:-whiptail}" = "yad" ]; then
    printf '%d\n' "$pct" >&3
    [ -n "$msg" ] && printf '# %s\n' "$msg" >&3
  else
    if [ -n "$msg" ]; then
      printf 'XXX\n%d\n%s\nXXX\n' "$pct" "$msg" >&3
    else
      printf '%d\n' "$pct" >&3
    fi
  fi
}

# progress_close: progress befejezése, ablak lezárása user interakció után.
# YAD módban az OK gombra VÁR — a felhasználó látja az eredményt!
# Whiptail módban Enter-re vár.
progress_close() {
  printf '100\n' >&3 2>/dev/null
  exec 3>&-

  if [ "${_PROGRESS_BACKEND:-}" = "yad" ]; then
    log_term "$(printf '─%.0s' {1..68})"
    log_term " [Kész — OK gombbal zárható]"
    exec 4>&-

    # Várunk amíg a user az OK gombra kattint (nem auto-záródik!)
    if [ -n "${YAD_PANED_PID:-}" ]; then
      wait "${YAD_PANED_PID}" 2>/dev/null || true
    fi

    # Cleanup
    rm -f "${TERM_FIFO:-}" "${PROG_FIFO:-}"
    TERM_FIFO="" PROG_FIFO="" YAD_PANED_PID=""
  else
    echo ""
    read -r -t 30 -p "  [Kész — nyomj Enter-t a folytatáshoz]" || true
  fi
  _PROGRESS_BACKEND=""
}

# =============================================================================
