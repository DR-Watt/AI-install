#!/bin/bash
# ============================================================================
# 00_lib_apt.sh — Vibe Coding Workspace lib v6.5
#
# LEÍRÁS: APT segédek: apt_install_*, run_with_progress, mirror fallback
# BETÖLTÉS: source-olja a 00_lib.sh master loader
# NE futtasd közvetlenül!
#
# VÁLTOZTATÁSOK v6.5 (2026-04-12 logok alapján):
#   - apt_mirror_check_fallback(): Ubuntu mirror elérhetőség ellenőrzés
#     Probléma: hu.archive.ubuntu.com leállt → libnvidia-egl-wayland1 nem
#     tölthető le (main ágon van, security.ubuntu.com nem tükrözi) →
#     libnvidia-gl-590 nem konfigurálható → MINDEN apt hívás Unmet deps-szel
#     bukik, beleértve a failsafe drivert is.
#     Fix: 5 másodperces curl timeout-tal teszteljük az elsődleges mirror-t.
#     Ha nem elérhető: sources.list ideiglenesen archive.ubuntu.com-ra vált
#     (global Canonical CDN, mindig elérhető).
#   - apt_mirror_restore(): mirror visszaállítása az eredeti értékre
#   - apt_fix_broken(): dpkg broken state törlése — failed install után szükséges
# ============================================================================

# =============================================================================
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
# SZEKCIÓ 5b — UBUNTU MIRROR FALLBACK
# =============================================================================
# MIÉRT KELL? (2026-04-12 log analízis alapján)
#
# Tünet: hu.archive.ubuntu.com leállt a session alatt. A security.ubuntu.com
#   tükrözni szokta a noble-updates/restricted csomagokat (nvidia-*590*), de
#   a noble-updates/MAIN csomagokat (pl. libnvidia-egl-wayland1, nvidia-prime,
#   nvidia-settings) NEM tükrözi — ezek csak az archive mirror-on vannak.
#
# Következmény:
#   libnvidia-egl-wayland1 → NOT INSTALLED
#   libnvidia-gl-590 → installed but NOT CONFIGURED (depends on egl-wayland1)
#   nvidia-driver-590-open → installed but NOT CONFIGURED
#   dpkg broken state → MINDEN subsequent apt hívás Unmet dependencies-szel
#   → CUDA, cuDNN, Docker, CTK install mind fail (170 sor hiba a logban)
#   → failsafe (570-open) is fail (broken state miatt)
#
# Megoldás: mirror elérhetőség ellenőrzés curl-lel (5 mp timeout),
#   ha sikertelen: sources.list ideiglenesen archive.ubuntu.com-ra váltás.
#   Az archive.ubuntu.com a Canonical globális CDN, elvileg mindig elérhető.
#
# Forrás: Ubuntu dokumentáció — archive vs security mirror szerepkörök
#   https://ubuntu.com/server/docs/package-management

# ── Belső állapot változók (ne módosítsd közvetlenül) ─────────────────────────
_APT_MIRROR_SWITCHED=false   # igaz ha sources.list-et módosítottuk
_APT_MIRROR_ORIG_BAK=""      # biztonsági másolat elérési útja

# apt_mirror_check_fallback: Ellenőrzi az Ubuntu mirror elérhetőségét.
# Ha az elsődleges mirror nem elérhető, ideiglenesen archive.ubuntu.com-ra vált.
#
# Logika:
#   1. Kinyeri az elsődleges mirror URL-t a /etc/apt/sources.list-ből
#   2. curl-lel 5 mp-es timeout-tal teszteli az elérhetőséget
#   3. Ha nem elérhető: backup készítés + sed csere archive.ubuntu.com-ra
#   4. apt-get update a fallback mirror-ral
#
# Hívás: a driver install kísérlet ELŐTT (nvidia_driver_purge után)
# Visszatér: 0=mirror elérhető (nincs változás), 1=fallback aktív
apt_mirror_check_fallback() {
  local logfile="${LOGFILE_AI:-/dev/null}"

  # Elsődleges mirror URL kinyerése sources.list-ből
  # Minta: "deb http://hu.archive.ubuntu.com/ubuntu noble main ..."
  local primary_mirror
  primary_mirror=$(grep -m1 '^deb ' /etc/apt/sources.list 2>/dev/null \
    | grep -oP 'https?://[^/\s]+' | head -1)

  # Ha nem sikerül azonosítani a mirror-t, nem csinálunk semmit
  if [ -z "$primary_mirror" ]; then
    log "APT" "Mirror nem azonosítható sources.list-ből — ellenőrzés kihagyva"
    return 0
  fi

  log "APT" "Ubuntu mirror elérhetőség ellenőrzése: $primary_mirror ..."

  # Elérhetőség tesztelése curl-lel (5 mp timeout, csak header)
  # --head: csak HTTP fejlécet kér — minimális adatforgalom
  # --silent: ne írjon stderr-re a curl
  if curl --head --silent \
       --connect-timeout 5 --max-time 8 \
       "${primary_mirror}/ubuntu/" > /dev/null 2>&1; then
    log "APT" "Mirror elérhető: $primary_mirror"
    return 0
  fi

  # Mirror nem elérhető — fallback aktiválása
  log "WARN" "Mirror NEM elérhető: $primary_mirror"
  log "INFO" "Fallback: archive.ubuntu.com-ra váltás (Canonical global CDN)"

  # Biztonsági másolat készítése az eredeti sources.list-ről
  _APT_MIRROR_ORIG_BAK=$(mktemp /tmp/sources.list.infra.XXXXXX)
  cp /etc/apt/sources.list "$_APT_MIRROR_ORIG_BAK"

  # Helyi mirror domain kinyerése és cseréje (pl. "hu.archive.ubuntu.com")
  # A sed csak az exact domainnevet cseréli, nem az egész URL-t
  local local_domain
  local_domain=$(printf '%s' "$primary_mirror" | grep -oP '(?<=https?://)[^/]+')
  sed -i "s|${local_domain}|archive.ubuntu.com|g" /etc/apt/sources.list

  log "APT" "sources.list módosítva: $local_domain → archive.ubuntu.com"

  # APT lista frissítése a fallback mirror-ral
  log "APT" "apt-get update (fallback mirror)..."
  DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::http::Timeout=20 \
    -o Acquire::https::Timeout=20 \
    update -qq >> "$logfile" 2>&1 || true

  _APT_MIRROR_SWITCHED=true
  log "APT" "Fallback mirror aktív: archive.ubuntu.com — driver install folytatódik"
  return 1
}

# apt_mirror_restore: Sources.list visszaállítása az eredeti értékre.
# Hívás: driver install UTÁN (sikeres vagy sikertelen esetén egyaránt).
# Biztonsági hálóként: ha a backup nem létezik, csak logol és visszatér.
apt_mirror_restore() {
  local logfile="${LOGFILE_AI:-/dev/null}"

  if ! $_APT_MIRROR_SWITCHED; then
    return 0  # Nem volt módosítás — nincs mit visszaállítani
  fi

  if [ -f "$_APT_MIRROR_ORIG_BAK" ]; then
    cp "$_APT_MIRROR_ORIG_BAK" /etc/apt/sources.list
    rm -f "$_APT_MIRROR_ORIG_BAK"
    _APT_MIRROR_ORIG_BAK=""
    _APT_MIRROR_SWITCHED=false

    log "APT" "sources.list visszaállítva (eredeti mirror visszakapcsolva)"

    # APT lista frissítése az eredeti mirror-ral (nem critikus — hiba esetén továbblép)
    DEBIAN_FRONTEND=noninteractive apt-get \
      -o Acquire::http::Timeout=20 \
      update -qq >> "$logfile" 2>&1 || \
      log "WARN" "apt update (mirror restore után) részleges hiba — cache marad"
  else
    log "WARN" "apt_mirror_restore: backup fájl nem található — manuális ellenőrzés szükséges"
    log "WARN" "  sources.list tartalma: $(head -3 /etc/apt/sources.list 2>/dev/null | tr '\n' ' ')"
    _APT_MIRROR_SWITCHED=false
  fi
}

# apt_fix_broken: dpkg broken state törlése apt --fix-broken install-lel.
# MIKOR kell: ha driver install részlegesen sikertelen volt (pakkok letöltve
#   de nem konfigurálva) — ebben az állapotban MINDEN apt hívás Unmet deps-szel
#   bukik. A --fix-broken install megpróbálja befejezni vagy eltávolítani a
#   fél-telepített csomagokat.
#
# Forrás: Debian/Ubuntu apt dokumentáció — "apt --fix-broken install" use case
# Paraméterek: $1=logfile (opcionális)
# Visszatér: 0=tiszta állapot, 1=javítás sikertelen (kritikus)
apt_fix_broken() {
  local logfile="${1:-${LOGFILE_AI:-/dev/null}}"
  log "APT" "dpkg broken state ellenőrzése és javítása..."

  DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    >> "$logfile" 2>&1
  local ec=$?

  if [ $ec -eq 0 ]; then
    log "OK" "dpkg állapot rendben (fix-broken OK)"
  else
    log "WARN" "apt --fix-broken install exit $ec — folytatás megkísérelve"
  fi
  return $ec
}
