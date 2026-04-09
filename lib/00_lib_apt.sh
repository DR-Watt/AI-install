#!/bin/bash
# ============================================================================
# 00_lib_apt.sh — Vibe Coding Workspace lib v6.4
#
# LEÍRÁS: APT segédek: apt_install_*, run_with_progress
# BETÖLTÉS: source-olja a 00_lib.sh master loader
# NE futtasd közvetlenül!
# ============================================================================

# SZEKCIÓ 5 — APT SEGÉDEK
# =============================================================================

# apt_install_log: apt telepítés, eredmény logba, DE progress bar nélkül.
# Kisebb csomagokhoz ahol nincs értelme progress ablakot nyitni.
apt_install_log() {
  local label="$1"; shift
  log "APT" "Telepítés: $*"
  [ "${_PROGRESS_BACKEND:-}" = "yad" ] \
    && printf '$ apt-get install %s\n' "$*" >&4 2>/dev/null || true

  echo "$SUDO_PASS" | sudo -S \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    "$@" 2>&1 | _tee_streams

  local ec="${PIPESTATUS[0]}"
  [ "$ec" -eq 0 ] \
    && log "OK" "Telepítve: $label" \
    || log "FAIL" "Sikertelen: $label (exit $ec)"
  return "$ec"
}

# apt_install_progress: apt telepítés progress ablakkal.
# A pipe miatt az exit code-ot temp fájlba mentjük (PIPESTATUS megkerülés).
# Paraméterek: $1=ablak cím, $2=progress szöveg, $3...=csomagok
apt_install_progress() {
  local title="$1" msg="$2"; shift 2
  log "APT" "Telepítés: $*"

  progress_open "$title" "$msg"
  log_term "$ apt-get install $*"

  # Exit code temp fájlba — a tee pipe elnyeli a tényleges exit code-ot
  local _ec_file; _ec_file=$(mktemp)
  {
    DEBIAN_FRONTEND=noninteractive sudo_run apt-get install -y \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "$@" 2>&1
    printf '%s' "$?" > "$_ec_file"
  } | _tee_streams &

  # Progress animáció amíg az apt fut
  local pid=$! i=5
  while kill -0 $pid 2>/dev/null; do
    progress_set "$i" "$msg"
    sleep 1
    [ $i -lt 90 ] && ((i+=2))
  done
  wait $pid

  local ec; ec=$(cat "$_ec_file" 2>/dev/null || echo "1")
  rm -f "$_ec_file"
  progress_close

  if [ "$ec" -eq 0 ]; then
    log "OK" "Telepítve: $*"
  else
    log "FAIL" "Hiba: $* (exit $ec)"
  fi
  return "$ec"
}

# run_with_progress: tetszőleges parancs futtatása progress ablakkal.
# Paraméterek: $1=ablak cím, $2=progress szöveg, $3...=parancs
run_with_progress() {
  local title="$1" msg="$2"; shift 2
  log "RUN" "$msg"

  progress_open "$title" "$msg"
  log_term "$ $*"

  "$@" 2>&1 | _tee_streams &
  local pid=$! i=5
  while kill -0 $pid 2>/dev/null; do
    progress_set "$i" "$msg"
    sleep 0.5
    [ $i -lt 90 ] && ((i+=3))
  done
  wait $pid; local ec=$?
  progress_close

  [ "$ec" -eq 0 ] && log "OK" "$msg" || log "FAIL" "$msg (exit $ec)"
  return $ec
}

# =============================================================================
