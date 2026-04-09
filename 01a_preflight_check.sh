#!/bin/bash
# =============================================================================
# 01a_preflight_check.sh — Pre-reboot GO / NO-GO ellenőrzés  v1.1
#
# Futtatás: sudo bash 01a_preflight_check.sh
#
# Mit ellenőriz reboot nélkül, terminálból:
#   1. Secure Boot állapot
#   2. NVIDIA driver csomag (telepítve / betöltve / csak telepítve)
#   3. DKMS modul az aktuális kernelre
#   4. KRITIKUS: modul aláírója CN = enrolled MOK kulcs CN
#   5. Nouveau blacklist
#   6. xorg.conf
#   7. initramfs tartalom
#   8. MOK enrollment állapot + jelszó emlékeztető
#
# Kimenet: GO / NO-GO verdikt
#
# v1.1 javítások:
#   • _BLOCK++ → ((_BLOCK++))  [aritmetikai operátor hiba]
#   • $(_KERN) → $_KERN        [command vs variable]
#   • Driver detektálás: dpkg-query -f format, awk $1=="ii" [\s compat]
#   • state_file: $REAL_HOME helyett $HOME (sudo alatt /root lett volna)
#   • Driver "nem betöltve de telepítve" külön ⚡ státusz (nem ✗)
#   • _PENDING_COUNT: fix newline-safe parse
# =============================================================================

_GR='\033[0;32m'; _YL='\033[0;33m'; _RD='\033[0;31m'
_CY='\033[0;36m'; _BD='\033[1m'; _NC='\033[0m'

ok()   { printf "${_GR}  ✓${_NC}  %s\n"  "$*"; }
warn() { printf "${_YL}  ⚠${_NC}  %s\n"  "$*"; }
fail() { printf "${_RD}  ✗${_NC}  %s\n"  "$*"; }
note() { printf "${_YL}  ⚡${_NC}  %s\n"  "$*"; }
info() { printf "${_CY}  ℹ${_NC}  %s\n"  "$*"; }
hdr()  { printf "\n${_BD}━━━ %s ━━━${_NC}\n" "$*"; }
sep()  { printf "%s\n" "──────────────────────────────────────────────────"; }

[ "$EUID" -ne 0 ] && {
  echo "HIBA: sudo szükséges. Futtatás: sudo bash $(basename "$0")"
  exit 1
}

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

# State olvasás — REAL_HOME-ból (sudo alatt $HOME=/root lenne → rossz fájl)
_state_get() {
  local key="$1" default="${2:-}"
  local sf="$REAL_HOME/.infra-state"
  [ -f "$sf" ] || { echo "$default"; return; }
  local val
  val=$(grep "^${key}=" "$sf" 2>/dev/null | cut -d= -f2- | head -1)
  echo "${val:-$default}"
}

# Számlálók — (()) kötelező az aritmetikához
_PASS=0; _WARN=0; _FAIL=0; _BLOCK=0
declare -a _ISSUES=()

_p() { ((_PASS++));                         ok   "$*"; }
_w() { ((_WARN++));                         warn "$*"; }
_f() { ((_FAIL++)); ((_BLOCK++)); _ISSUES+=("✗ $*"); fail "$*"; }
_n() { ((_WARN++));                         note "$*"; }  # ⚡ nem blokkoló különleges eset

printf "\n"
printf "${_BD}╔══════════════════════════════════════════════════════╗${_NC}\n"
printf "${_BD}║    01a Pre-reboot GO/NO-GO ellenőrzés  v1.1          ║${_NC}\n"
printf "${_BD}╚══════════════════════════════════════════════════════╝${_NC}\n"
printf "  Dátum:  $(date '+%Y-%m-%d %H:%M:%S')\n"
printf "  Kernel: $(uname -r)\n"
printf "  User:   $REAL_USER\n"

_KERN="$(uname -r)"

# =============================================================================
# 1. SECURE BOOT
# =============================================================================
hdr "1. Secure Boot"

_SB_OUT="$(mokutil --sb-state 2>/dev/null)"
if echo "$_SB_OUT" | grep -qi "SecureBoot enabled"; then
  _SB_ON=true;  _p "Secure Boot: BEKAPCSOLVA"
  info "A kernel csak aláírt modulokat tölt be → MOK ellenőrzés kritikus"
elif echo "$_SB_OUT" | grep -qi "disabled\|not enabled"; then
  _SB_ON=false; _p "Secure Boot: kikapcsolva (MOK nem szükséges)"
else
  _SB_ON=true
  _w "Secure Boot állapot ismeretlen: '$_SB_OUT' — feltételezzük: BE"
fi

# =============================================================================
# 2. NVIDIA DRIVER CSOMAG
# =============================================================================
hdr "2. NVIDIA driver csomag"

# dpkg-query -f format: megbízható, awk $1=="ii" [\s mawk-kompatibilis]
_DRV_PKG=$(dpkg-query -f '${db:Status-Abbrev}|${Package}\n' \
             -W 'nvidia-driver-*' 2>/dev/null \
           | awk -F'|' '$1~/^ii/{print $2}' \
           | sort -t- -k3 -V | tail -1)

# Fallback: ha dpkg-query nem elérhető
[ -z "$_DRV_PKG" ] && _DRV_PKG=$(dpkg -l 2>/dev/null \
  | awk '$1=="ii" && $2~/^nvidia-driver-[0-9]/{print $2}' \
  | sort -t- -k3 -V | tail -1)

_DRV_VER=$(dpkg-query -f '${Version}\n' -W "$_DRV_PKG" 2>/dev/null | head -1)

if [ -n "$_DRV_PKG" ]; then
  if [[ "$_DRV_PKG" == *"-open" ]]; then
    _p "Driver csomag: $_DRV_PKG  ($_DRV_VER)  [open ✓]"
  else
    _f "Driver: $_DRV_PKG — PROPRIETARY! Blackwell-en nem működik."
    info "Megoldás: sudo apt purge '$_DRV_PKG' && sudo apt install nvidia-driver-580-open"
  fi

  # Betöltve-e most? (reboot előtt NEM lesz betöltve — ez normális)
  if lsmod | grep -q "^nvidia "; then
    _p "NVIDIA kernel modul: BETÖLTVE (aktív session)"
  else
    _n "NVIDIA kernel modul: NEM betöltve — ez normális reboot előtt!"
    info "nvidia-smi most nem válaszol, de reboot után fog"
  fi
else
  # Ellenőrzés DKMS alapján is — ha DKMS van, a csomag valószínűleg telepítve van
  if dkms status 2>/dev/null | grep -qi "nvidia.*installed"; then
    _n "dpkg-query nem találta a csomagot, DE DKMS nvidia modulja telepített"
    info "A driver valószínűleg telepítve van — dpkg cache esetleg frissítendő"
    info "Ellenőrizd: dpkg -l | grep nvidia-driver"
  else
    _f "NVIDIA driver csomag NINCS telepítve"
    info "Megoldás: sudo bash 01a_system_foundation.sh"
  fi
fi

# =============================================================================
# 3. DKMS MODUL
# =============================================================================
hdr "3. DKMS modul (kernel: $_KERN)"

_DKMS_OUT="$(dkms status 2>/dev/null | grep -i nvidia)"
if [ -z "$_DKMS_OUT" ]; then
  _f "DKMS: nincs nvidia bejegyzés"
  info "Megoldás: sudo dkms autoinstall"
else
  while IFS= read -r line; do info "$line"; done <<< "$_DKMS_OUT"

  # Az aktuális kernelre telepítve van-e?
  if echo "$_DKMS_OUT" | grep -q "$_KERN" && \
     echo "$_DKMS_OUT" | grep "$_KERN" | grep -q "installed"; then
    _p "DKMS modul telepítve az aktuális kernelre ($_KERN)"
  elif echo "$_DKMS_OUT" | grep -q "installed"; then
    # Van telepített, de nem az aktuális kernelre
    _DKMS_VER=$(echo "$_DKMS_OUT" | grep "installed" | grep -oP 'nvidia/\K[\d.]+' | head -1)
    _w "DKMS modul más kernelre telepítve, nem az aktuálisra ($_KERN)"
    info "Megoldás: sudo dkms install nvidia/$_DKMS_VER -k $_KERN"
  else
    _f "DKMS modul nem 'installed' állapotban"
  fi
fi

# =============================================================================
# 4. KRITIKUS: MODUL ALÁÍRÁS ↔ ENROLLED MOK EGYEZÉS
# =============================================================================
hdr "4. Modul aláírás ↔ MOK kulcs egyezés (KRITIKUS)"

MOK_CERT="/var/lib/shim-signed/mok/MOK.der"
_MOK_ENROLLED=false
_MOK_CN=""

if [ ! -f "$MOK_CERT" ]; then
  if $_SB_ON; then
    _f "MOK.der hiányzik ($MOK_CERT) — Secure Boot BE van kapcsolva!"
    info "Megoldás: sudo dkms autoinstall  (legenerálja a kulcsot)"
  else
    _p "MOK.der hiányzik — Secure Boot ki van kapcsolva, nem szükséges"
  fi
else
  _MOK_CN=$(openssl x509 -in "$MOK_CERT" -noout -subject 2>/dev/null \
            | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1)
  _MOK_FP=$(openssl x509 -in "$MOK_CERT" -noout -fingerprint -sha256 2>/dev/null \
            | cut -d= -f2-)

  info "MOK.der CN:          ${_MOK_CN:-(nem olvasható)}"
  info "MOK.der fingerprint: ${_MOK_FP:-(nem olvasható)}"

  # Enrolled-e?
  _ENROLLED_LIST="$(mokutil --list-enrolled 2>/dev/null)"
  if echo "$_ENROLLED_LIST" | grep -qi "$_MOK_CN"; then
    _p "MOK kulcs ENROLLED az UEFI-ben"
    _MOK_ENROLLED=true
  else
    _MOK_ENROLLED=false
    if $_SB_ON; then
      _f "MOK kulcs NINCS enrolled → Secure Boot blokkolja a drivert!"
      info "Megoldás: sudo mokutil --import $MOK_CERT"
    else
      _w "MOK kulcs nincs enrolled — Secure Boot ki van kapcsolva, OK"
    fi
  fi

  # Modul fájl keresés
  _MOD_FILE=$(find /lib/modules/"$_KERN"/updates/dkms/ \
              \( -name "nvidia.ko" -o -name "nvidia.ko.zst" \) 2>/dev/null | head -1)

  if [ -z "$_MOD_FILE" ]; then
    if $_SB_ON; then
      _f "nvidia.ko(.zst) nem található: /lib/modules/$_KERN/updates/dkms/"
    else
      _w "nvidia.ko(.zst) nem található — DKMS lehet nem futott le"
    fi
  else
    info "Modul fájl: $_MOD_FILE"

    # .zst kicsomagolás ha szükséges
    _MOD_WORK="$_MOD_FILE"
    _MOD_TEMP=""
    if [[ "$_MOD_FILE" == *.zst ]]; then
      _MOD_TEMP="/tmp/nv_preflight_$$.ko"
      zstd -d "$_MOD_FILE" -o "$_MOD_TEMP" -q --force 2>/dev/null \
        && _MOD_WORK="$_MOD_TEMP" \
        || { _w "nvidia.ko.zst kicsomagolás sikertelen — modinfo kihagyva"; _MOD_WORK=""; }
    fi

    if [ -n "$_MOD_WORK" ] && [ -f "$_MOD_WORK" ]; then
      _MOD_SIGNER=$(modinfo "$_MOD_WORK" 2>/dev/null | awk '/^signer:/{$1=""; print substr($0,2)}')
      _MOD_SIG_KEY=$(modinfo "$_MOD_WORK" 2>/dev/null | awk '/^sig_key:/{$1=""; print substr($0,2)}')
      [ -n "$_MOD_TEMP" ] && rm -f "$_MOD_TEMP"

      if [ -z "$_MOD_SIGNER" ]; then
        if $_SB_ON; then
          _f "Modul NINCS aláírva — Secure Boot blokkolni fogja"
          info "Megoldás: sudo dkms autoinstall"
        else
          _w "Modul nincs aláírva — Secure Boot ki van kapcsolva, OK"
        fi
      else
        info "Modul aláírója (CN): $_MOD_SIGNER"
        info "Modul sig_key:       ${_MOD_SIG_KEY:-(nem elérhető)}"

        # EGYEZÉS ELLENŐRZÉS — ez a legfontosabb teszt
        if [ "$_MOD_SIGNER" = "$_MOK_CN" ]; then
          if $_MOK_ENROLLED; then
            _p "EGYEZÉS ✓: modul aláírója = enrolled MOK kulcs"
            _p "  CN: '$_MOK_CN'"
            _p "  Secure Boot betölti a drivert reboot után"
          else
            if $_SB_ON; then
              _f "Kulcs egyezik, DE NINCS enrolled → Secure Boot blokkolja!"
              info "Megoldás: sudo mokutil --import $MOK_CERT"
            else
              _p "Kulcs egyezik (Secure Boot ki van kapcsolva)"
            fi
          fi
        else
          if $_SB_ON; then
            _f "ELTÉRÉS! Modul: '$_MOD_SIGNER' ≠ MOK.der: '$_MOK_CN'"
            _f "A modul EGY MÁSIK kulccsal van aláírva mint ami enrolled!"
            info "Megoldás: sudo dkms autoinstall  (újra aláírja a jelenlegi kulccsal)"
          else
            _w "Aláírás eltérés — Secure Boot ki van kapcsolva, nem kritikus"
          fi
        fi
      fi
    fi
  fi

  # Pending enrollment
  _PENDING_RAW="$(mokutil --list-new 2>/dev/null | grep -c "Subject:" 2>/dev/null)"
  _PENDING_COUNT="${_PENDING_RAW%%$'\n'*}"   # csak az első sor, newline-safe
  _PENDING_COUNT="${_PENDING_COUNT:-0}"
  if [ "$_PENDING_COUNT" -gt 0 ] 2>/dev/null; then
    _w "MOK enrollment PENDING — rebootkor kék képernyő jelenik meg"
    _STATE_PASS="$(_state_get "MOK_ENROLL_PASS" "")"
    [ -n "$_STATE_PASS" ] && \
      printf "\n  ${_BD}${_YL}  ⚠  MOK jelszó (kék képernyőn): %s${_NC}\n\n" "$_STATE_PASS"
  fi
fi

# =============================================================================
# 5. NOUVEAU BLACKLIST
# =============================================================================
hdr "5. Nouveau blacklist"

_NBL="/etc/modprobe.d/99-blacklist-nouveau.conf"
if [ -f "$_NBL" ] && grep -q "blacklist nouveau" "$_NBL"; then
  _p "Nouveau blacklist: $_NBL"
else
  _f "Nouveau blacklist HIÁNYZIK: $_NBL"
  info "Megoldás: sudo bash 01a_system_foundation.sh  (GPU konfig lépés)"
fi

lsmod | grep -q "^nouveau " && \
  _w "Nouveau modul MOST aktív — reboot után el kell tűnnie (normális pre-reboot)" || true

# =============================================================================
# 6. XORG.CONF
# =============================================================================
hdr "6. xorg.conf"

_XORG="/etc/X11/xorg.conf"
_GPU_MODE="$(_state_get "GPU_MODE" "")"
info "State GPU_MODE: ${_GPU_MODE:-(nem mentett)}"

if [ ! -f "$_XORG" ]; then
  _w "Nincs xorg.conf — X11 auto-detektál (általában OK)"
  info "Ha reboot után fekete képernyő: futtasd újra az 01a GPU konfig lépését"
else
  grep -E "Identifier|Driver|BusID" "$_XORG" | while IFS= read -r l; do
    info "  $l"
  done

  _xorg_has_modesetting=$(grep -c "modesetting" "$_XORG" 2>/dev/null || echo 0)
  _xorg_has_nvidia=$(grep -c '"nvidia"' "$_XORG" 2>/dev/null || echo 0)

  if [ "${_xorg_has_modesetting:-0}" -gt 0 ] && [ "${_xorg_has_nvidia:-0}" -gt 0 ]; then
    _p "xorg.conf: hibrid mód (modesetting iGPU + nvidia dGPU)"
  elif [ "${_xorg_has_nvidia:-0}" -gt 0 ]; then
    _p "xorg.conf: NVIDIA driver konfigurálva"
  else
    _w "xorg.conf: sem modesetting sem nvidia driver nem található"
  fi
fi

# =============================================================================
# 7. INITRAMFS TARTALOM
# =============================================================================
hdr "7. initramfs tartalom"

_INITRD="/boot/initrd.img-${_KERN}"
if [ ! -f "$_INITRD" ]; then
  _f "initramfs nem található: $_INITRD"
  info "Megoldás: sudo update-initramfs -u -k all"
else
  # Legfontosabb: a nouveau blacklist benne van-e?
  _INITRD_NBL=$(lsinitramfs "$_INITRD" 2>/dev/null | grep "blacklist-nouveau" | head -1)
  _INITRD_NV_OPT=$(lsinitramfs "$_INITRD" 2>/dev/null | grep "nvidia-options" | head -1)

  if [ -n "$_INITRD_NBL" ]; then
    _p "initramfs: nouveau blacklist megvan  ($( basename "$_INITRD_NBL" ))"
  else
    _w "initramfs: nouveau blacklist hiányzik"
    info "Megoldás: sudo update-initramfs -u -k all"
  fi

  [ -n "$_INITRD_NV_OPT" ] && \
    _p "initramfs: NVIDIA modul opciók megvannak  ($( basename "$_INITRD_NV_OPT" ))" || true

  _INITRD_TIME=$(date -d "@$(stat -c %Y "$_INITRD" 2>/dev/null)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  info "initramfs utolsó módosítás: ${_INITRD_TIME:-ismeretlen}"
fi

# =============================================================================
# 8. MOK JELSZÓ / ENROLLMENT ÖSSZESÍTŐ
# =============================================================================
hdr "8. MOK jelszó / enrollment összesítő"

_STATE_MOK_PASS="$(_state_get "MOK_ENROLL_PASS" "")"
_STATE_MOK_PENDING="$(_state_get "MOK_ENROLL_PENDING" "false")"

info "State MOK_ENROLL_PENDING: $_STATE_MOK_PENDING"
info "State MOK_ENROLL_PASS:    ${_STATE_MOK_PASS:-(nincs mentve)}"

if [ "$_STATE_MOK_PENDING" = "true" ] && [ -n "$_STATE_MOK_PASS" ]; then
  printf "\n"
  printf "  ${_BD}${_YL}┌─────────────────────────────────────────────────┐${_NC}\n"
  printf "  ${_BD}${_YL}│  ⚠  REBOOT UTÁN KÉK KÉPERNYŐN ADD MEG:         │${_NC}\n"
  printf "  ${_BD}${_YL}│                                                 │${_NC}\n"
  printf "  ${_BD}${_YL}│  1. Enroll MOK                                  │${_NC}\n"
  printf "  ${_BD}${_YL}│  2. Continue                                    │${_NC}\n"
  printf "  ${_BD}${_YL}│  3. Jelszó:  %-33s │${_NC}\n" "$_STATE_MOK_PASS"
  printf "  ${_BD}${_YL}│  4. Yes  →  Reboot                              │${_NC}\n"
  printf "  ${_BD}${_YL}└─────────────────────────────────────────────────┘${_NC}\n"
  printf "\n"
elif $_MOK_ENROLLED; then
  _p "MOK enrolled — rebootkor NEM lesz kék képernyő (helyes)"
  info "A driver közvetlenül betöltődik, jelszó nem szükséges"
fi

# =============================================================================
# VERDIKT
# =============================================================================
sep
printf "\n"
printf "  Összesítő:  ${_GR}✓ OK: %d${_NC}  ${_YL}⚠ Figyelem: %d${_NC}  ${_RD}✗ Blokkoló: %d${_NC}\n\n" \
  "$_PASS" "$_WARN" "$_BLOCK"

if [ "$_BLOCK" -eq 0 ]; then
  printf "${_GR}${_BD}  ✅  GO — Reboot biztonságosan elvégezhető${_NC}\n"
  [ "$_WARN" -gt 0 ] && info "(figyelmeztető pontok vannak, de nem blokkolóak)"
  [ "$_STATE_MOK_PENDING" = "true" ] && [ -n "$_STATE_MOK_PASS" ] && \
    printf "\n  ${_YL}⚠  Reboot után kék MOK képernyő — jelszó: %s${_NC}\n" "$_STATE_MOK_PASS"
  printf "\n  ${_BD}sudo reboot${_NC}\n"
else
  printf "${_RD}${_BD}  ❌  NO-GO — Blokkoló problémák:${_NC}\n\n"
  for issue in "${_ISSUES[@]}"; do
    printf "    %s\n" "$issue"
  done
  printf "\n  Javítás után: sudo bash $(basename "$0")\n"
fi

printf "\n"
sep
