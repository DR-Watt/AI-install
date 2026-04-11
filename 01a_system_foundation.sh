#!/bin/bash
# =============================================================================
# 01a_system_foundation.sh — System Foundation v6.7
#                            Ubuntu 24 LTS | NVIDIA | CUDA | Docker
#
# Dokumentáció
# ────────────
#   CUDA:   https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
#   NVIDIA: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/ubuntu.html
#   Docker: https://docs.docker.com/engine/install/ubuntu/
#   CTK:    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/
#
# Változtatások v6.7 (2026-04-11 logok alapján — 3 kritikus bug):
#
#   BUG 1 FIX — CUDA upgrade nem indult el 590 driver install után:
#     A CUDA 4/7 lépés teljesen kihagyódott ("ok" volt a pre-install check)
#     Fix: _CUDA_UPGRADE_NEEDED flag — ha _DRIVER_SERIES ≥ 590 és CUDA < 13,
#          a CUDA lépés akkor is fut ha COMP_STATUS[cuda]="ok"
#     Forrás: NVIDIA CUDA Compatibility r595 — driver 590+ = CUDA 13.1 natív
#
#   BUG 2 FIX — CTK purge után nem reinstallálódott:
#     nvidia_driver_purge() eltávolítja az nvidia-container-toolkit-et
#     A CTK install lépés pre-install "ok" státuszt látott → kihagyta
#     Fix: sikeres driver install után COMP_STATUS[nvidia_ctk]="missing" reset
#
#   BUG 3 FIX — INST_DRIVER_VER nem frissült 590 install után:
#     State mutatott: INST_DRIVER_VER=580.126.09 (590 install után is!)
#     Fix: sikeres driver install után dpkg-ból olvassuk a tényleges verziót
#          és azonnal írjuk az INST_DRIVER_VER state kulcsba
#
# Változtatások v6.6:
#   APT mirror resilience, driver failsafe, 590+ névváltás
#
# Változtatások v6.5:
#   COMP STATE implementáció (sablon alapján)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" \
  || { echo "HIBA: 00_lib.sh hiányzik! ($LIB)"; exit 1; }

# =============================================================================
# KONFIGURÁCIÓ
# =============================================================================

INFRA_NUM="01a"
INFRA_NAME="System Foundation (pre-reboot)"
INFRA_HW_REQ="nvidia"

declare -A MIN_VER=(
  [driver]="570.0"
  [cuda]="12.6"
  [cudnn]="9.0"
  [docker]="24.0"
  [nvidia_ctk]="1.0"
)

# NVIDIA driver csomagnév prioritás (Ubuntu 24.04 noble, 2026-04-11):
#   1. Ubuntu noble-updates/restricted: nvidia-driver-590-open (590.48.01)
#      Canonical-signed → meglévő MOK kulcs elegendő, NEM kell új enrollment
#   2. Ubuntu noble-updates/restricted: nvidia-driver-580-open (stabil LTS)
#   3. CUDA repo: nvidia-open (590+ new naming)
#   4. Fallback: nvidia-driver-570-open (Blackwell minimum)
#
# Megjegyzés: a 590-open a UBUNTU RESTRICTED-ből jön (nem CUDA repóból)!
# Log bizonyíték: Get:1 http://hu.archive.ubuntu.com/ubuntu noble-updates/restricted
DRIVER_MIN_PKG_BLACKWELL="nvidia-driver-570-open"

CUDA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"

declare -A PKGS=(
  [base]="
    build-essential git curl wget unzip zip cmake ninja-build
    htop nvtop btop tree jq net-tools nmap
    ca-certificates gnupg lsb-release software-properties-common
    apt-transport-https pciutils ubuntu-drivers-common
    openssh-server xclip xdotool
    fonts-firacode fonts-jetbrains-mono zsh tmux screen
    p7zip-full ffmpeg imagemagick libssl-dev libffi-dev pkg-config ccze"
  [python_build]="
    liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev
    libbz2-dev zlib1g-dev libffi-dev tk-dev uuid-dev
    libncurses-dev libexpat1-dev libnss3-dev"
  [cuda_13_2]="cuda-toolkit-13-2 cuda-libraries-13-2 cuda-libraries-dev-13-2"
  [cuda_13_1]="cuda-toolkit-13-1 cuda-libraries-13-1 cuda-libraries-dev-13-1"
  [cuda_13_0]="cuda-toolkit-13-0 cuda-libraries-13-0 cuda-libraries-dev-13-0"
  [cuda_12_8]="cuda-toolkit-12-8 cuda-libraries-12-8 cuda-libraries-dev-12-8"
  [cuda_12_6]="cuda-toolkit-12-6 cuda-libraries-12-6 cuda-libraries-dev-12-6"
  [cudnn_nccl]="libcudnn9-cuda-12 libcudnn9-dev-cuda-12 libnccl2 libnccl-dev"
  [docker]="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  [nvidia_ctk]="nvidia-container-toolkit"
)

declare -A URLS=(
  [docker_gpg]="https://download.docker.com/linux/ubuntu/gpg"
  [docker_repo]="https://download.docker.com/linux/ubuntu"
  [nvidia_ctk_gpg]="https://nvidia.github.io/libnvidia-container/gpgkey"
  [nvidia_ctk_list]="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"
)

APT_PIN_NVIDIA='# 01a_system_foundation v6.7
Package: nvidia-* libnvidia-* xserver-xorg-video-nvidia-*
Pin: release o=Ubuntu
Pin-Priority: 1001'

COMP_NAMES=(nvidia_driver cuda cudnn docker nvidia_ctk)

# =============================================================================
# INICIALIZÁLÁS
# =============================================================================

[ "$EUID" -ne 0 ] && {
  echo "HIBA: root szükséges. Futtatás: sudo bash $(basename "$0")"
  exit 1
}

REAL_USER="${_REAL_USER}"
REAL_HOME="${_REAL_HOME}"

LOGFILE_AI="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_${INFRA_NUM}_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="$LOGFILE_AI"

LOCK="/tmp/.install_01a.lock"
check_lock "$LOCK"
trap 'rm -f "$LOCK"; log "LOCK" "Lock felszabadítva"' EXIT

hw_detect

infra_state_set "HW_PROFILE"     "$HW_PROFILE"
infra_state_set "HW_GPU_ARCH"    "$HW_GPU_ARCH"
infra_state_set "HW_GPU_NAME"    "$HW_GPU_NAME"
infra_state_set "HW_VLLM_OK"     "$HW_VLLM_OK"
infra_state_set "HW_CUDA_ARCH"   "${HW_CUDA_ARCH:-89}"
infra_state_set "HW_NVIDIA_OPEN" "$HW_NVIDIA_OPEN"

[ -z "$(infra_state_get "PYTORCH_INDEX" "")" ] && \
  infra_state_set "PYTORCH_INDEX" "cu126"

log_init

if ! infra_compatible "$INFRA_HW_REQ"; then
  dialog_warn "Hardver inkompatibilis" \
    "\n  NVIDIA GPU szükséges.\n  Profil: $HW_PROFILE" 10
  log "SKIP" "Hardver inkompatibilis → exit 2"; exit 2
fi

# =============================================================================
# DRIVER CSOMAGNÉV ÉS SOROZATSZÁM
# =============================================================================
# hw_detect() meghatározta HW_NVIDIA_PKG-t (dpkg alapján ha telepítve van,
# apt-cache max alapján ha nincs). Ez a szekció csak kinyeri a sorozatszámot.
#
# Ubuntu 24.04 (noble) driver helyzet (2026-04-11 log alapján):
#   590.48.01: noble-updates/restricted (Canonical-signed!) ← JELENLEGI MAX
#   580.126.09: noble-updates/restricted (stabil, korábbi)
# Mindkettő Ubuntu restricted → meglévő MOK key elegendő, NEM kell új enrollment!

_DRIVER_PKG="${HW_NVIDIA_PKG}"
_DRIVER_SERIES="$(printf '%s' "$_DRIVER_PKG" | grep -oP '\d+' | head -1)"

if [ -z "$_DRIVER_PKG" ]; then
  log "HW" "Telepített driver nincs — elérhető keresése..."

  # Ubuntu noble-updates/restricted — Canonical-signed, MOK nélkül tölt
  if apt-cache show nvidia-driver-590-open &>/dev/null; then
    _DRIVER_PKG="nvidia-driver-590-open"; _DRIVER_SERIES="590"
    log "HW" "Ubuntu restricted: nvidia-driver-590-open (590.48.01) → preferált"
  elif apt-cache show nvidia-driver-580-open &>/dev/null; then
    _DRIVER_PKG="nvidia-driver-580-open"; _DRIVER_SERIES="580"
    log "HW" "Ubuntu restricted: nvidia-driver-580-open"
  elif apt-cache show nvidia-driver-575-open &>/dev/null; then
    _DRIVER_PKG="nvidia-driver-575-open"; _DRIVER_SERIES="575"
    log "HW" "Ubuntu restricted: nvidia-driver-575-open"
  # CUDA repo: nvidia-open (590+ új névformátum) — NEM Canonical-signed
  elif apt-cache show nvidia-open &>/dev/null; then
    _DRIVER_PKG="nvidia-open"; _DRIVER_SERIES="590"
    log "HW" "CUDA repo: nvidia-open (590+ névformátum)"
    log "WARN" "CUDA repo-ból — nem Canonical-signed, MOK enrollment szükséges lehet"
  else
    _DRIVER_PKG="${DRIVER_MIN_PKG_BLACKWELL}"; _DRIVER_SERIES="570"
    log "HW" "Fallback: $_DRIVER_PKG (Blackwell minimum)"
  fi

else
  # Telepített driver volt — sorozatszám kinyerése
  # nvidia-open esetén (590+) nincsen szám a névben → dpkg verzióból
  if [ -z "$_DRIVER_SERIES" ]; then
    _DRIVER_SERIES=$(dpkg-query -f '${Version}\n' -W "$_DRIVER_PKG" 2>/dev/null \
      | grep -oP '^\d+' | head -1 || echo "590")
  fi
fi

# Blackwell biztonsági ellenőrzés: ZÁRT driver → "No devices found"
if [ "$HW_GPU_ARCH" = "blackwell" ] && \
   [[ "$_DRIVER_PKG" != *"-open" ]] && [ "$_DRIVER_PKG" != "nvidia-open" ]; then
  _DRIVER_PKG="${_DRIVER_PKG}-open"
  log "HW" "Blackwell: -open suffix kényszerítve → $_DRIVER_PKG"
fi

log "HW" "Végső driver csomag: $_DRIVER_PKG (sorozat: ${_DRIVER_SERIES:-?})"

# =============================================================================
# KOMPONENS FELMÉRÉS
# =============================================================================

log "COMP" "━━━ Komponens felmérés ━━━"

if [ "${COMP_USE_CACHED:-false}" = "true" ] && comp_state_exists "$INFRA_NUM"; then
  comp_load_state "$INFRA_NUM"
  log "COMP" "Mentett check betöltve — INFRA $INFRA_NUM ($(comp_state_age_hours "$INFRA_NUM") óra)"
else
  comp_check_nvidia_driver "${MIN_VER[driver]}"
  comp_check_cuda          "${MIN_VER[cuda]}"
  comp_check_cudnn         "${MIN_VER[cudnn]}"
  comp_check_docker        "${MIN_VER[docker]}"
  comp_check_nvidia_ctk    "${MIN_VER[nvidia_ctk]}"

  # CUDA 13.x workaround: comp_check_cuda 13.x dpkg-ből v6.5 lib óta már
  # helyesen detektál (comp_check_cuda háromszintű keresés). Ez a blokk
  # a nvcc-alapú fallback-et biztosítja ha sem nvcc, sem dpkg nem adott eredményt.
  if [ "${COMP_STATUS[cuda]:-missing}" = "missing" ]; then
    _nvcc_ver=$(PATH="/usr/local/cuda/bin:$PATH" nvcc --version 2>/dev/null \
                | grep -oP 'release \K[\d.]+' | head -1)
    if [ -n "$_nvcc_ver" ]; then
      COMP_STATUS[cuda]="ok"; COMP_VER[cuda]="$_nvcc_ver"
      log "COMP" "CUDA nvcc workaround: $_nvcc_ver"
    fi
  fi

  # "broken" lib workaround
  if [ "${COMP_STATUS[nvidia_driver]:-missing}" = "ok" ] && \
     ! echo "${COMP_VER[nvidia_driver]:-}" | grep -qE '^[0-9][0-9.]+$'; then
    log "WARN" "Driver version false positive → broken"
    COMP_STATUS[nvidia_driver]="broken"
    COMP_VER[nvidia_driver]="(kernel modul nem fut)"
  fi

  if [ "$RUN_MODE" = "check" ]; then
    comp_save_state "$INFRA_NUM"
    log "COMP" "Check mód: COMP state mentve"
  fi
fi

_DRV_STATUS="${COMP_STATUS[nvidia_driver]:-missing}"

STATUS=""
for _c in "${COMP_NAMES[@]}"; do STATUS+="$(comp_line "$_c" "$_c")"$'\n'; done

log_comp_status \
  "nvidia_driver|NVIDIA Driver|${MIN_VER[driver]}" \
  "cuda|CUDA Toolkit|${MIN_VER[cuda]}"             \
  "cudnn|cuDNN + NCCL|${MIN_VER[cudnn]}"           \
  "docker|Docker CE|${MIN_VER[docker]}"             \
  "nvidia_ctk|NVIDIA CTK|${MIN_VER[nvidia_ctk]}"

# =============================================================================
# DRIVER SERIES UPGRADE → CUDA UPGRADE TRIGGER  [v6.7 új]
# =============================================================================
# Bug: 2026-04-11 log — 590 driver install után CUDA lépés teljesen kihagyódott
# mert COMP_STATUS[cuda]="ok" (12.6 volt telepítve, "ok"-nak számított)
#
# Fix: ha a driver series ≥ 590, és a telepített CUDA < 13.x,
#      a CUDA upgrade szükséges a natív teljesítményhez.
#
# NVIDIA CUDA Compatibility doc r595 (2026-03-31):
#   driver 590+ = CUDA 13.1 natív
#   driver 595+ = CUDA 13.2 natív
# Forrás: https://docs.nvidia.com/deploy/pdf/CUDA_Compatibility.pdf
#
# _CUDA_UPGRADE_NEEDED=true esetén a CUDA install lépés (4/7) akkor is fut
# ha COMP_STATUS[cuda]="ok" — így 12.6 → 13.1 upgrade automatikusan megtörténik.

_CUDA_UPGRADE_NEEDED=false
if [ "${_DRIVER_SERIES:-0}" -ge 590 ] && \
   [ "${COMP_STATUS[cuda]:-missing}" = "ok" ]; then
  _cur_cuda_ver="${COMP_VER[cuda]:-12.6}"
  _cur_cuda_major="$(echo "$_cur_cuda_ver" | cut -d. -f1)"
  if [ "${_cur_cuda_major:-12}" -lt 13 ] 2>/dev/null; then
    _CUDA_UPGRADE_NEEDED=true
    log "INFO" "Driver $_DRIVER_SERIES + CUDA ${_cur_cuda_ver}: upgrade ajánlott (13.x elérhető)"
    log "INFO" "CUDA_UPGRADE_NEEDED=true → CUDA install lépés fut (ok státusz ellenére)"
  fi
fi

# =============================================================================
# INST_* STATE SZINKRONIZÁLÁS — minden módban fut (check is)
# =============================================================================

if [ "${COMP_STATUS[nvidia_driver]:-missing}" = "ok" ]; then
  _cur_drv="$(infra_state_get "INST_DRIVER_VER" "")"
  [ -z "$_cur_drv" ] && {
    infra_state_set "INST_DRIVER_VER" "${COMP_VER[nvidia_driver]}"
    log "STATE" "INST_DRIVER_VER szinkronizálva: ${COMP_VER[nvidia_driver]}"
  }
fi

if [ "${COMP_STATUS[cuda]:-missing}" = "ok" ] && ! $_CUDA_UPGRADE_NEEDED; then
  _cur_cuda="$(infra_state_get "INST_CUDA_VER" "")"
  [ -z "$_cur_cuda" ] && {
    infra_state_set "INST_CUDA_VER" "${COMP_VER[cuda]}"
    infra_state_set "CUDA_VER"      "${COMP_VER[cuda]}"
    log "STATE" "INST_CUDA_VER szinkronizálva: ${COMP_VER[cuda]}"
  }
fi

if [ "${COMP_STATUS[cudnn]:-missing}" = "ok" ]; then
  _cur_cudnn="$(infra_state_get "INST_CUDNN_VER" "")"
  [ -z "$_cur_cudnn" ] && {
    infra_state_set "INST_CUDNN_VER" "${COMP_VER[cudnn]}"
    log "STATE" "INST_CUDNN_VER szinkronizálva: ${COMP_VER[cudnn]}"
  }
fi

if [ "${COMP_STATUS[docker]:-missing}" = "ok" ]; then
  _cur_docker="$(infra_state_get "INST_DOCKER_VER" "")"
  [ -z "$_cur_docker" ] && {
    _docker_ver="${COMP_VER[docker]:-$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '')}"
    infra_state_set "INST_DOCKER_VER" "$_docker_ver"
    infra_state_set "DOCKER_VER"      "$_docker_ver"
    log "STATE" "INST_DOCKER_VER szinkronizálva: $_docker_ver"
  }
fi

# =============================================================================
# STATE → ACTIONS MÁTRIX
# =============================================================================

case "$_DRV_STATUS" in
  broken)
    _FLOW="short"
    _FLOW_DESC="Driver broken — MOK enrollment + GPU konfig + initramfs"
    ;;
  missing|old)
    _FLOW="full"
    _FLOW_DESC="Driver ${_DRV_STATUS} — teljes telepítés"
    ;;
  ok)
    _comp_keys=(nvidia_driver cuda cudnn docker nvidia_ctk)
    detect_run_mode _comp_keys
    _FLOW="$RUN_MODE"
    # Ha CUDA upgrade kell, nem mehetünk skip módba
    if $_CUDA_UPGRADE_NEEDED && [ "$_FLOW" = "skip" ]; then
      _FLOW="update"
      log "INFO" "CUDA upgrade szükséges → skip mód felülírva: update"
    fi
    _FLOW_DESC="Driver OK — mód: $_FLOW"
    ;;
  *)
    _FLOW="full"
    _FLOW_DESC="Ismeretlen állapot — teljes telepítés"
    ;;
esac

log "INFO" "Flow: $_FLOW — $_FLOW_DESC"

# =============================================================================
# GPU MÓD VÁLASZTÁS
# =============================================================================

GPU_MODE="$(infra_state_get "GPU_MODE" "")"

if [ -z "$GPU_MODE" ] || [ "$_DRV_STATUS" = "missing" ] || \
   [ "$RUN_MODE" = "reinstall" ] 2>/dev/null; then

  GPU_MODE=$(dialog_menu "GPU mód — Hogyan vannak bekötve a monitoraid?" "
  GPU:    $HW_GPU_NAME
  iGPU:   ${HW_GPU_IGPU:-nincs}

  HIBRID:    1 monitor alaplapon (iGPU) + 1 az RTX portján
             PRIME on-demand, Wayland OK, kisebb fogyasztás

  DEDIKÁLT:  minden monitor RTX portjain
             Intel i915 blacklist, X11, max. teljesítmény" \
  16 2 \
  "hybrid"    "Hibrid    — iGPU + NVIDIA PRIME on-demand" \
  "dedicated" "Dedikált  — csak NVIDIA RTX")

  [ -z "$GPU_MODE" ] && { dialog_msg "Kilépés" "\n  Megszakítva."; exit 0; }
  infra_state_set "GPU_MODE" "$GPU_MODE"
  log "CFG" "GPU mód: $GPU_MODE (state-be mentve)"
else
  log "CFG" "GPU mód (state-ből): $GPU_MODE"
fi

# =============================================================================
# ÜDVÖZLŐ DIALOG
# =============================================================================

_mok_status_txt=""
if [ "$_FLOW" = "short" ] || [ "$_FLOW" = "full" ]; then
  _mok_now="$(nvidia_mok_status 2>/dev/null || echo 'no_cert')"
  case "$_mok_now" in
    enrolled)     _mok_status_txt="  MOK: enrolled ✓ (UEFI ismeri a kulcsot)" ;;
    pending)      _mok_status_txt="  MOK: pending — rebootkor kék képernyő lesz" ;;
    not_enrolled) _mok_status_txt="  MOK: nem enrolled ⚡ — enrollment szükséges" ;;
    no_cert)      _mok_status_txt="  MOK: MOK.der hiányzik" ;;
  esac
fi

# CUDA upgrade info — ha upgrade szükséges, mutassuk a dialog-ban
_cuda_upgrade_txt=""
$_CUDA_UPGRADE_NEEDED && _cuda_upgrade_txt="
  ⚡ CUDA UPGRADE: ${COMP_VER[cuda]:-12.6} → 13.x (driver $_DRIVER_SERIES natív CUDA)"

if [ "$_FLOW" = "short" ]; then
  dialog_msg "INFRA ${INFRA_NUM} — ${INFRA_NAME}" "
  GPU:     $HW_GPU_NAME
  Driver:  $_DRIVER_PKG  ⚡ telepítve, de kernel modul nem fut
  ${_mok_status_txt}

  Rövid út: MOK enrollment + GPU konfig + initramfs → REBOOT
  Log: $LOGFILE_AI" 20

elif [ "$_FLOW" = "skip" ]; then
  dialog_msg "Minden naprakész" "\n${STATUS}\n  Semmi sem változik."
  log "SKIP" "Minden OK → kilépés"; exit 0

elif [ "$_FLOW" = "check" ]; then
  dialog_msg "[Ellenőrző] INFRA ${INFRA_NUM}" \
    "\n${STATUS}\n  [check mód — változtatás nem történt]"
  log "COMP" "Check mód: kilépés (nincs telepítés)"
  trap - EXIT; rm -f "$LOCK"
  exit 0

else
  log_infra_header "
    • Ubuntu alap + Python fordítási függőségek
    • NVIDIA ${_DRIVER_PKG} (${HW_GPU_ARCH}, SM_${HW_CUDA_ARCH})
    • MOK enrollment + CUDA toolkit + cuDNN 9 + NCCL
    • GPU mód konfig + Docker CE + NVIDIA CTK + initramfs → REBOOT"

  dialog_msg "INFRA ${INFRA_NUM} — ${INFRA_NAME}" "
  GPU:     $HW_GPU_NAME
  Arch:    ${HW_GPU_ARCH} (SM_${HW_CUDA_ARCH})
  Driver:  $_DRIVER_PKG
  Mód:     ${_FLOW}
  ${_mok_status_txt}${_cuda_upgrade_txt}

  Lépések:
    1. Ubuntu alap + Python build deps
    2. NVIDIA ${_DRIVER_PKG}  ← open kernel
    3. MOK enrollment (Secure Boot)
    4. CUDA toolkit$(${_CUDA_UPGRADE_NEEDED} && echo " [UPGRADE: → 13.x]" || echo "")
    5. Nouveau blacklist + GPU mód
    6. Docker CE + NVIDIA CTK
    7. initramfs → REBOOT

  Log: $LOGFILE_AI" 30
fi

dialog_yesno "Megerősítés" "
${STATUS}
  Flow: $_FLOW_DESC
  GPU mód: $GPU_MODE
  ⚠  Reboot szükséges a végén!

  Folytatjuk?" 26 || { log "USER" "Megszakítva"; exit 0; }

OK=0; SKIP=0; FAIL=0

# =============================================================================
# ██  RÖVID ÚT — "broken" állapot  ██
# =============================================================================

if [ "$_FLOW" = "short" ]; then
  log "INFO" "━━━ RÖVID ÚT (broken) ━━━"

  log "STEP" "━━━ MOK enrollment ━━━"
  if ask_proceed "MOK enrollment ellenőrzése és elvégzése?"; then
    nvidia_mok_enroll
    _mok_ec=$?
    case $_mok_ec in
      0) ((OK++))
         _mok_final="$(nvidia_mok_status)"
         if [ "$_mok_final" = "pending" ]; then
           _pass="$(infra_state_get "MOK_ENROLL_PASS" "")"
           dialog_msg "⚠  MOK enrollment — Fontos!" "
  REBOOT UTÁN kék/lila UEFI képernyő jelenik meg.
    1. Enroll MOK  2. Continue
    3. Jelszó: ${_pass:-(lásd ~/.infra-state MOK_ENROLL_PASS)}
    4. Yes → Reboot" 16
         fi
         ;;
      1) ((FAIL++)); log "FAIL" "MOK enrollment sikertelen" ;;
      2) ((SKIP++)); log "SKIP" "MOK.der hiányzik" ;;
    esac
  else
    ((SKIP++)); log "SKIP" "MOK enrollment kihagyva"
  fi

  log "STEP" "━━━ GPU mód konfiguráció ($GPU_MODE) ━━━"
  if ask_proceed "GPU mód konfiguráció ellenőrzése/alkalmazása?"; then
    if grep -q "01a_system_foundation" "/etc/modprobe.d/99-nvidia-options.conf" 2>/dev/null && \
       grep -q "01a_system_foundation" "/etc/modprobe.d/99-blacklist-nouveau.conf" 2>/dev/null && \
       grep -q "01a_system_foundation" "/etc/X11/xorg.conf" 2>/dev/null; then
      log "OK" "GPU konfig fájlok naprakészek"
      ((OK++))
    else
      _write_gpu_config "$GPU_MODE" && ((OK++)) || ((FAIL++))
    fi
  else
    ((SKIP++)); log "SKIP" "GPU konfig kihagyva"
  fi

  log "STEP" "━━━ initramfs frissítés ━━━"
  if ask_proceed "initramfs frissítése?"; then
    run_with_progress "initramfs" "initramfs újraépítése minden kernelre..." \
      update-initramfs -u -k all
    [ $? -eq 0 ] && ((OK++)) || ((FAIL++))
  else
    ((SKIP++))
  fi

  show_result "$OK" "$SKIP" "$FAIL"

  if [ "${OK:-0}" -gt 0 ] && [ "${RUN_MODE:-install}" != "check" ]; then
    infra_state_set "REBOOT_NEEDED"   "true"
    infra_state_set "REBOOT_REASON"   "MOK enrollment + GPU konfig (short path)"
    infra_state_set "REBOOT_BY_INFRA" "$INFRA_NUM"
  fi

  if [[ "$RUN_MODE" =~ ^(install|update|fix|reinstall)$ ]]; then
    log "COMP" "Post-install re-check (rövid út)..."
    comp_check_nvidia_driver "${MIN_VER[driver]}"
    PATH="/usr/local/cuda/bin:$PATH" comp_check_cuda "${MIN_VER[cuda]}"
    comp_check_cudnn "${MIN_VER[cudnn]}"
    comp_check_docker "${MIN_VER[docker]}"
    comp_check_nvidia_ctk "${MIN_VER[nvidia_ctk]}"
    comp_save_state "$INFRA_NUM"
    log "COMP" "Post-install COMP state mentve (rövid út)"
  fi

  _pass_final="$(infra_state_get "MOK_ENROLL_PASS" "")"
  _mok_pending="$(infra_state_get "MOK_ENROLL_PENDING" "false")"

  dialog_msg "Rövid út kész — REBOOT szükséges" "
  GPU mód: $GPU_MODE | MOK: $(nvidia_mok_status 2>/dev/null || echo '?')
  Ellenőrzés reboot után: nvidia-smi && nvcc --version
  ➜  sudo reboot" 14

  dialog_yesno "Újraindítás most?" "  Újraindítjuk?" 10 && reboot

  trap - EXIT; rm -f "$LOCK"
  log "DONE" "INFRA ${INFRA_NUM} (rövid út) befejezve: OK=$OK SKIP=$SKIP FAIL=$FAIL"
  exit 0
fi

# =============================================================================
# ██  TELJES ÚT  ██
# =============================================================================

# =============================================================================
# 1. LÉPÉS — ALAP RENDSZER CSOMAGOK
# =============================================================================
# v6.6: APT mirror resilience (--timeout=30, --fix-missing, pkg_installed check)

log "STEP" "━━━ 1/7: Alap rendszer csomagok ━━━"

if [ "$_DRV_STATUS" = "missing" ] || [ "$_DRV_STATUS" = "old" ] || \
   [ "$RUN_MODE" = "reinstall" ] || [ "$RUN_MODE" = "update" ]; then

  if ask_proceed "Alap fejlesztői csomagok + Python build deps?"; then
    log "APT" "apt-get update (Acquire::http::Timeout=30)..."
    apt-get -o Acquire::http::Timeout=30 update -qq 2>&1 | \
      tee -a "$LOGFILE_AI" || \
      log "WARN" "apt-get update részleges hiba — gyorsítótárazott lista marad"

    apt_install_progress "Alap csomagok" \
      "Ubuntu alap + Python fordítási függőségek..." \
      --fix-missing \
      ${PKGS[base]} ${PKGS[python_build]}

    if pkg_installed "build-essential" && pkg_installed "liblzma-dev" && \
       pkg_installed "zsh" && pkg_installed "ccze"; then
      ((OK++)); log "OK" "Alap csomagok OK (kritikus csomagok telepítve)"
    else
      _missing_critical=0
      for _chk in build-essential zsh ccze liblzma-dev; do
        pkg_installed "$_chk" || { ((_missing_critical++)); log "WARN" "Hiányzik: $_chk"; }
      done
      if [ "$_missing_critical" -gt 2 ]; then
        ((FAIL++)); log "FAIL" "Alap csomagok: $_missing_critical kritikus csomag hiányzik"
      else
        ((SKIP++)); log "WARN" "Alap csomagok: $_missing_critical csomag hiányzik — továbblép"
      fi
    fi
  else
    ((SKIP++)); log "SKIP" "Alap csomagok kihagyva"
  fi
fi

# =============================================================================
# 2. LÉPÉS — NVIDIA OPEN DRIVER
# =============================================================================
# v6.7: Sikeres install után:
#   - INST_DRIVER_VER frissítése a tényleges dpkg verzióval (BUG 3 fix)
#   - COMP_STATUS[nvidia_ctk]="missing" reset (BUG 2 fix — CTK purge miatt)

log "STEP" "━━━ 2/7: NVIDIA open driver ($_DRIVER_PKG) ━━━"

if [ "$_DRV_STATUS" = "missing" ] || [ "$_DRV_STATUS" = "old" ] || \
   [ "$RUN_MODE" = "reinstall" ]; then

  if ask_proceed "NVIDIA ${_DRIVER_PKG} telepítése?"; then

    progress_open "NVIDIA Open Driver — ${_DRIVER_PKG}" "Előkészítés..."

    progress_set 5 "CUDA repo ideiglenes deaktiválása..."
    declare -a _CUDA_REPO_MOVED=()
    for _f in /etc/apt/sources.list.d/cuda*.list \
               /etc/apt/sources.list.d/cuda*.sources; do
      [ -f "$_f" ] || continue
      _bak="/tmp/$(basename "$_f").infra_bak"
      mv "$_f" "$_bak" 2>/dev/null && _CUDA_REPO_MOVED+=("$_bak|$_f") && \
        log "APT" "CUDA repo deaktiválva: $_f"
    done

    progress_set 14 "Régi NVIDIA csomagok eltávolítása..."
    nvidia_driver_purge "$LOGFILE_AI"

    progress_set 32 "APT pinning..."
    echo "$APT_PIN_NVIDIA" > /etc/apt/preferences.d/99-nvidia-ubuntu-priority

    progress_set 40 "APT lista frissítése..."
    apt-get -o Acquire::http::Timeout=30 update -qq >> "$LOGFILE_AI" 2>&1 || true
    progress_set 50 "${_DRIVER_PKG} letöltése és telepítése..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      --fix-missing \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "${_DRIVER_PKG}" nvidia-prime >> "$LOGFILE_AI" 2>&1
    _DRV_EC=$?

    progress_set 88 "CUDA repo visszakapcsolása..."
    for _entry in "${_CUDA_REPO_MOVED[@]}"; do
      _bak="${_entry%%|*}"; _orig="${_entry##*|}"
      [ -f "$_bak" ] && mv "$_bak" "$_orig" 2>/dev/null && \
        log "APT" "CUDA repo visszakapcsolva: $_orig"
    done
    apt-get -o Acquire::http::Timeout=30 update -qq >> "$LOGFILE_AI" 2>&1 || true
    progress_close

    if pkg_installed "$_DRIVER_PKG"; then
      log "OK" "NVIDIA driver telepítve: $_DRIVER_PKG"

      # ── BUG 3 FIX: INST_DRIVER_VER frissítése a tényleges dpkg verzióval ──
      # Bug: az INST_* szinkronizáló blokk a pre-install comp check-et használta
      # (COMP_STATUS[nvidia_driver]="missing" → nem szinkronizált), így
      # INST_DRIVER_VER=580.126.09 maradt a 590 install után is.
      # Fix: sikeres install után dpkg-ból olvassuk a pontos verziót.
      _inst_drv_ver=$(dpkg-query -f '${Version}\n' -W "$_DRIVER_PKG" 2>/dev/null \
        | grep -oP '^[\d.]+' | head -1)
      [ -n "$_inst_drv_ver" ] && {
        infra_state_set "INST_DRIVER_VER" "$_inst_drv_ver"
        log "STATE" "INST_DRIVER_VER frissítve: $_inst_drv_ver (dpkg alapján)"
      }

      infra_state_set "HW_NVIDIA_PKG"        "$_DRIVER_PKG"
      infra_state_set "NVIDIA_DRIVER_PKG"    "$_DRIVER_PKG"
      infra_state_set "NVIDIA_DRIVER_SERIES" "${_DRIVER_SERIES:-?}"

      # ── BUG 2 FIX: CTK reset — nvidia_driver_purge eltávolítja a CTK-t ──
      # Bug: nvidia_driver_purge() purge-olja a libnvidia-container* csomagokat,
      # amik a nvidia-container-toolkit függőségei → CTK eltávolítódik.
      # A CTK install lépés pre-install "ok" COMP_STATUS-t lát → kihagyja.
      # Fix: sikeres driver install után COMP_STATUS[nvidia_ctk]="missing" reset,
      # hogy a 6. lépés újra telepítse.
      COMP_STATUS[nvidia_ctk]="missing"
      log "INFO" "CTK COMP státusz reset → nvidia_driver_purge eltávolíthatta"

      ((OK++))
    else
      # ── DRIVER INSTALL FAILSAFE ────────────────────────────────────────────
      log "FAIL" "NVIDIA driver SIKERTELEN (exit ${_DRV_EC}): $_DRIVER_PKG"
      log "INFO" "Failsafe driver telepítése: $DRIVER_MIN_PKG_BLACKWELL..."

      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --fix-missing \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "$DRIVER_MIN_PKG_BLACKWELL" >> "$LOGFILE_AI" 2>&1

      if pkg_installed "$DRIVER_MIN_PKG_BLACKWELL"; then
        log "WARN" "Failsafe driver telepítve: $DRIVER_MIN_PKG_BLACKWELL"
        _fs_ver=$(dpkg-query -f '${Version}\n' -W "$DRIVER_MIN_PKG_BLACKWELL" 2>/dev/null \
          | grep -oP '^[\d.]+' | head -1)
        infra_state_set "HW_NVIDIA_PKG"        "$DRIVER_MIN_PKG_BLACKWELL"
        infra_state_set "NVIDIA_DRIVER_PKG"    "$DRIVER_MIN_PKG_BLACKWELL"
        infra_state_set "NVIDIA_DRIVER_SERIES" "570"
        [ -n "$_fs_ver" ] && infra_state_set "INST_DRIVER_VER" "$_fs_ver"
        COMP_STATUS[nvidia_ctk]="missing"
        _DRIVER_PKG="$DRIVER_MIN_PKG_BLACKWELL"; _DRIVER_SERIES="570"
        dialog_warn "NVIDIA Driver — Failsafe" "
  Fallback driver telepítve: $DRIVER_MIN_PKG_BLACKWELL
  Céldriver ($_DRIVER_PKG) nem volt elérhető.

  Frissítés később:
    sudo apt update && sudo apt install nvidia-driver-590-open
  Log: $LOGFILE_AI" 16
        ((SKIP++))
      else
        log "FAIL" "Failsafe driver is sikertelen!"
        dialog_warn "NVIDIA Driver — SÚLYOS HIBA" "
  Sem a céldriver, sem a fallback nem telepíthető.
  NE INDÍTSD ÚJRA! Előbb javítsd a drivert.
  Log: $LOGFILE_AI" 16
        ((FAIL++))
      fi
    fi
  else
    ((SKIP++)); log "SKIP" "Driver kihagyva"
  fi
fi

# =============================================================================
# 3. LÉPÉS — MOK ENROLLMENT
# =============================================================================

log "STEP" "━━━ 3/7: MOK enrollment (Secure Boot) ━━━"

if ask_proceed "MOK enrollment ellenőrzése?"; then
  nvidia_mok_enroll
  _mok_ec=$?

  case $_mok_ec in
    0)
      ((OK++))
      _mok_final="$(nvidia_mok_status)"
      log "INFO" "MOK végállapot: $_mok_final"
      if [ "$_mok_final" = "pending" ]; then
        _pass="$(infra_state_get "MOK_ENROLL_PASS" "")"
        dialog_msg "⚠  MOK enrollment — Fontos!" "
  REBOOT UTÁN kék/lila UEFI képernyő:
    1.  Enroll MOK  2.  Continue
    3.  Jelszó: ${_pass:-(lásd ~/.infra-state MOK_ENROLL_PASS)}
    4.  Yes → Reboot" 18
      elif [ "$_mok_final" = "enrolled" ]; then
        log "OK" "MOK enrolled — Secure Boot kompatibilis"
      fi
      ;;
    1) ((FAIL++))
       dialog_warn "MOK enrollment sikertelen" \
         "\n  sudo mokutil --import /var/lib/shim-signed/mok/MOK.der" 10 ;;
    2) ((SKIP++))
       dialog_warn "MOK.der hiányzik" "\n  sudo dkms autoinstall" 10 ;;
  esac
else
  ((SKIP++)); log "SKIP" "MOK enrollment kihagyva"
fi

# =============================================================================
# 4. LÉPÉS — CUDA TOOLKIT
# =============================================================================
# v6.7: _CUDA_UPGRADE_NEEDED flag — 590+ driver esetén CUDA 13.x ajánlott
#
# Ha _CUDA_UPGRADE_NEEDED=true:
#   - A lépés akkor is fut ha COMP_STATUS[cuda]="ok" (12.6 volt telepítve)
#   - cuda_best_available() megkeresi a legjobb elérhető verziót (13.1 vagy 13.2)
#   - Blackwell esetén: 13.x automatikusan választódik (SM_120 natív support)
#   - INST_CUDA_VER, CUDA_VER, PYTORCH_INDEX mind frissülnek
#
# CUDA Compatibility (NVIDIA r595 doc):
#   driver 590+ = CUDA 13.1 natív → cu128 PyTorch index
#   driver 595+ = CUDA 13.2 natív → cu128 PyTorch index

log "STEP" "━━━ 4/7: CUDA toolkit ━━━"

# $_CUDA_UPGRADE_NEEDED: driver 590+ → CUDA < 13.x esetén true (ld. fent)
if [ "${COMP_STATUS[cuda]:-missing}" != "ok" ] || \
   [ "$RUN_MODE" = "reinstall" ] || \
   $_CUDA_UPGRADE_NEEDED; then

  # CUDA upgrade tájékoztató ha upgrade (nem fresh install) triggelte
  if $_CUDA_UPGRADE_NEEDED && [ "${COMP_STATUS[cuda]:-missing}" = "ok" ]; then
    dialog_msg "CUDA Upgrade szükséges" "
  Driver: $_DRIVER_PKG (sorozat: $_DRIVER_SERIES)
  Telepített CUDA: ${COMP_VER[cuda]:-12.6}

  NVIDIA CUDA Compatibility doc (r595, 2026-03-31):
    driver 590+ = CUDA 13.1 natív
    driver 595+ = CUDA 13.2 natív

  Az upgrade CUDA 13.x-re javítja az RTX 5090 (SM_120) teljesítményét.
  PyTorch index is frissülni fog: cu126 → cu128

  Méret: ~3.5 GB — a folytatáshoz erősítsd meg." 20
  fi

  if ! source_exists "developer.download.nvidia.com/compute/cuda"; then
    log "INFO" "CUDA repo konfigurálása..."
    run_with_progress "CUDA Repo" "CUDA keyring letöltése és konfigurálása..." \
      bash -c "wget -q '$CUDA_KEYRING_URL' -O /tmp/cuda-keyring.deb \
               && DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/cuda-keyring.deb \
               && rm -f /tmp/cuda-keyring.deb"
    [ $? -eq 0 ] && \
      apt-get -o Acquire::http::Timeout=30 update -qq >> "$LOGFILE_AI" 2>&1 \
      && log "OK" "CUDA repo konfigurálva" \
      || { log "FAIL" "CUDA keyring sikertelen"; ((FAIL++)); }
  fi

  _best_cuda="$(cuda_best_available)"
  log "INFO" "Legjobb elérhető CUDA: ${_best_cuda:-nem találat}"

  if [ -z "$_best_cuda" ]; then
    log "WARN" "Nincs elérhető CUDA csomag"
    dialog_warn "CUDA — Nem elérhető" \
      "\n  Nincs cuda-toolkit-* csomag.\n  Ellenőrizd a CUDA repo konfigurációt." 10
    ((SKIP++))
  else
    _CUDA_VER=""; _CUDA_PKGS=""; _CUDA_PY_IDX=""

    case "$HW_GPU_ARCH" in
      blackwell)
        case "$_best_cuda" in
          13.*) _CUDA_VER="$_best_cuda"
                _cuda_key="cuda_$(echo "$_best_cuda" | tr '.' '_')"
                _CUDA_PKGS="${PKGS[$_cuda_key]:-${PKGS[cuda_13_2]}}"
                log "INFO" "Blackwell SM_120: CUDA $_best_cuda natív" ;;
          12.8) _CUDA_VER="12.8"; _CUDA_PKGS="${PKGS[cuda_12_8]}"
                log "INFO" "Blackwell SM_120: CUDA 12.8" ;;
          12.6) _CUDA_VER="12.6"; _CUDA_PKGS="${PKGS[cuda_12_6]}"
                log "WARN" "Blackwell: 12.8+ nem elérhető → 12.6 SM_89 compat mód" ;;
        esac ;;
      ada|ampere)
        case "$_best_cuda" in
          13.*)
            _CHOICE=$(dialog_menu "CUDA verzió" "GPU: $HW_GPU_NAME" 12 2 \
              "new"    "CUDA ${_best_cuda} — legfrissebb" \
              "stable" "CUDA 12.6 — stabil LTS (ajánlott)")
            if [ "$_CHOICE" = "new" ]; then
              _CUDA_VER="$_best_cuda"
              _cuda_key="cuda_$(echo "$_best_cuda" | tr '.' '_')"
              _CUDA_PKGS="${PKGS[$_cuda_key]:-${PKGS[cuda_13_2]}}"
            else
              _CUDA_VER="12.6"; _CUDA_PKGS="${PKGS[cuda_12_6]}"
            fi ;;
          12.8) _CUDA_VER="12.8"; _CUDA_PKGS="${PKGS[cuda_12_8]}" ;;
          *)    _CUDA_VER="12.6"; _CUDA_PKGS="${PKGS[cuda_12_6]}" ;;
        esac
        log "INFO" "${HW_GPU_ARCH}: CUDA $_CUDA_VER kiválasztva" ;;
      *)
        _CUDA_VER="${_best_cuda:-12.6}"; _CUDA_PKGS="${PKGS[cuda_12_6]}"
        log "INFO" "Ismeretlen arch: CUDA $_CUDA_VER alapértelmezés" ;;
    esac

    _CUDA_PY_IDX="$(cuda_pytorch_index "$_CUDA_VER")"

    if ask_proceed "CUDA ${_CUDA_VER} telepítése? (~3.5 GB)"; then
      apt_install_progress "CUDA ${_CUDA_VER}" "CUDA ${_CUDA_VER} telepítése..." \
        --no-install-recommends --fix-missing ${_CUDA_PKGS}

      export PATH="/usr/local/cuda/bin:$PATH"
      _INST_VER=$(nvcc --version 2>/dev/null | grep -oP 'release \K[\d.]+' | head -1)
      [ -z "$_INST_VER" ] && _INST_VER=$(dpkg -l "cuda-toolkit-*" 2>/dev/null \
        | awk '/^ii/{print $3}' | grep -oP '^[\d.]+' | sort -V | tail -1)
      [ -z "$_INST_VER" ] && _INST_VER="$_CUDA_VER"

      if [ -f "/usr/local/cuda/bin/nvcc" ] || \
         pkg_installed "cuda-toolkit-${_CUDA_VER//./-}"; then

        _PATH_BLOCK='
# ── CUDA toolkit PATH — 01a_system_foundation ──────────────────────────────
export CUDA_HOME=/usr/local/cuda
export PATH="${CUDA_HOME}/bin${PATH:+:${PATH}}"
export LD_LIBRARY_PATH="${CUDA_HOME}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"'
        for _rc in "$REAL_HOME/.bashrc" "$REAL_HOME/.zshrc"; do
          [ -f "$_rc" ] && ! grep -q "CUDA_HOME" "$_rc" && \
            printf '\n%s\n' "$_PATH_BLOCK" >> "$_rc" && \
            log "PATH" "CUDA PATH hozzáadva: $_rc"
        done

        infra_state_set "CUDA_VER"      "$_INST_VER"
        infra_state_set "INST_CUDA_VER" "$_INST_VER"
        infra_state_set "PYTORCH_INDEX" "$_CUDA_PY_IDX"
        log "STATE" "CUDA $_INST_VER → PyTorch index: $_CUDA_PY_IDX"
        infra_state_show; ((OK++))
      else
        log "FAIL" "CUDA ${_CUDA_VER} telepítés sikertelen"
        dialog_warn "CUDA — Hiba" "\n  df -h /usr\n  Log: $LOGFILE_AI" 10
        ((FAIL++))
      fi
    else
      ((SKIP++)); log "SKIP" "CUDA kihagyva"
    fi
  fi

elif [ "$RUN_MODE" = "update" ]; then
  export PATH="/usr/local/cuda/bin:$PATH"
  _SYNC=$(nvcc --version 2>/dev/null | grep -oP 'release \K[\d.]+' | head -1)
  if [ -n "$_SYNC" ]; then
    _IDX="$(cuda_pytorch_index "$_SYNC")"
    _CURR="$(infra_state_get "PYTORCH_INDEX" "cu126")"
    [ "$_CURR" != "$_IDX" ] && {
      infra_state_set "CUDA_VER" "$_SYNC"
      infra_state_set "INST_CUDA_VER" "$_SYNC"
      infra_state_set "PYTORCH_INDEX" "$_IDX"
      log "STATE" "CUDA state szinkronizálva: $_SYNC → $_IDX"
    }
  fi
  ((SKIP++)); log "SKIP" "CUDA megvan — update módban kihagyva"
fi

# =============================================================================
# 4b. cuDNN 9 + NCCL
# =============================================================================

log "STEP" "━━━ 4b: cuDNN 9 + NCCL ━━━"

if [ "${COMP_STATUS[cudnn]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "cuDNN 9 + NCCL telepítése?"; then
    apt_install_progress "cuDNN + NCCL" "cuDNN 9 + NCCL telepítése..." \
      --fix-missing ${PKGS[cudnn_nccl]}
    if pkg_installed "libcudnn9-cuda-12" && pkg_installed "libnccl2"; then
      ((OK++)); log "OK" "cuDNN 9 + NCCL telepítve"
    else
      ((FAIL++)); log "FAIL" "cuDNN + NCCL sikertelen"
    fi
  else
    ((SKIP++)); log "SKIP" "cuDNN + NCCL kihagyva"
  fi
fi

# =============================================================================
# 5. LÉPÉS — NOUVEAU BLACKLIST + GPU MÓD
# =============================================================================

_write_gpu_config() {
  local mode="${1:-hybrid}"

  cat > /etc/modprobe.d/99-blacklist-nouveau.conf << 'BEOF'
# 01a_system_foundation v6.7 — Nouveau blacklist
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
BEOF

  cat > /etc/modprobe.d/99-nvidia-options.conf << 'MEOF'
# 01a_system_foundation v6.7 — NVIDIA kernel modul opciók
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
MEOF

  if [ "$mode" = "hybrid" ]; then
    prime-select on-demand 2>/dev/null || true
    local intel_busid
    intel_busid=$(lspci | grep -i "VGA.*Intel" | head -1 | awk '{print $1}' | \
      awk -F'[:.]' '{printf "PCI:%d:%d:%d",
        strtonum("0x"$1), strtonum("0x"$2), strtonum("0x"$3)}' 2>/dev/null)
    intel_busid="${intel_busid:-PCI:0:2:0}"
    log "CFG" "Intel iGPU Bus ID: $intel_busid"
    cat > /etc/X11/xorg.conf << XEOF
# 01a_system_foundation v6.7 — Hibrid GPU mód
Section "ServerLayout"
    Identifier "hybrid-layout"
    Screen 0 "iGPU-Screen"
    Inactive "dGPU"
    Option "AllowNVIDIAGPUScreens"
EndSection
Section "Device"
    Identifier "iGPU"
    Driver "modesetting"
    BusID "$intel_busid"
EndSection
Section "Screen"
    Identifier "iGPU-Screen"
    Device "iGPU"
EndSection
Section "Device"
    Identifier "dGPU"
    Driver "nvidia"
EndSection
Section "Screen"
    Identifier "dGPU-Screen"
    Device "dGPU"
EndSection
XEOF
    sed -i 's/^WaylandEnable=false/#WaylandEnable=false/' \
      /etc/gdm3/custom.conf 2>/dev/null || true
    log "CFG" "Hibrid xorg.conf írva, GDM3 Wayland engedélyezve"
  else
    prime-select nvidia 2>/dev/null || true
    cat > /etc/modprobe.d/99-blacklist-igpu.conf << 'BEOF'
# 01a_system_foundation v6.7 — Intel iGPU blacklist
blacklist i915
blacklist intel_agp
BEOF
    cat > /etc/X11/xorg.conf << 'XEOF'
# 01a_system_foundation v6.7 — Dedikált GPU mód
Section "ServerLayout"
    Identifier "dedicated-layout"
    Screen 0 "nvidia-screen"
EndSection
Section "Device"
    Identifier "nvidia-gpu"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration" "true"
EndSection
Section "Screen"
    Identifier "nvidia-screen"
    Device "nvidia-gpu"
EndSection
XEOF
    sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' \
      /etc/gdm3/custom.conf 2>/dev/null || true
    log "CFG" "Dedikált xorg.conf írva, GDM3 Wayland letiltva"
  fi
  return 0
}

log "STEP" "━━━ 5/7: Nouveau blacklist + GPU mód ($GPU_MODE) ━━━"

if ask_proceed "GPU mód konfigurálása?"; then
  _write_gpu_config "$GPU_MODE" && ((OK++)) && \
    log "OK" "GPU konfiguráció kész ($GPU_MODE)" || ((FAIL++))
else
  ((SKIP++)); log "SKIP" "GPU konfiguráció kihagyva"
fi

# =============================================================================
# 6. LÉPÉS — DOCKER CE + NVIDIA CONTAINER TOOLKIT
# =============================================================================
# v6.7: COMP_STATUS[nvidia_ctk] resetelve driver install után (BUG 2 fix)
# → A CTK itt "missing"-nek látja magát → telepíti

log "STEP" "━━━ 6/7: Docker CE ━━━"

if [ "${COMP_STATUS[docker]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "Docker CE telepítése?"; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "${URLS[docker_gpg]}" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg

    if ! source_exists "download.docker.com"; then
      printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] %s %s stable\n' \
        "$(dpkg --print-architecture)" "${URLS[docker_repo]}" "$(lsb_release -cs)" \
        > /etc/apt/sources.list.d/docker.list
      apt-get -o Acquire::http::Timeout=30 update -qq >> "$LOGFILE_AI" 2>&1 || true
    fi

    apt_install_progress "Docker CE" "Docker CE + Buildx + Compose..." \
      --fix-missing ${PKGS[docker]}

    if pkg_installed "docker-ce"; then
      usermod -aG docker "$REAL_USER" 2>/dev/null || true
      systemctl enable --now docker.service containerd.service >> "$LOGFILE_AI" 2>&1 || true
      _DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
      infra_state_set "DOCKER_VER" "$_DOCKER_VER"
      log "OK" "Docker CE $_DOCKER_VER"; ((OK++))
    else
      log "FAIL" "Docker CE sikertelen"; ((FAIL++))
    fi
  else
    ((SKIP++)); log "SKIP" "Docker CE kihagyva"
  fi
fi

log "STEP" "━━━ NVIDIA Container Toolkit ━━━"
# Megjegyzés: COMP_STATUS[nvidia_ctk]="missing" ha driver install futott (BUG 2 fix)
# → Ez a blokk az if-feltétel miatt mindig fut driver install után

if [ "${COMP_STATUS[nvidia_ctk]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "NVIDIA Container Toolkit telepítése?"; then
    curl -fsSL "${URLS[nvidia_ctk_gpg]}" \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null

    if ! source_exists "nvidia.github.io/libnvidia-container"; then
      curl -sL "${URLS[nvidia_ctk_list]}" \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        > /etc/apt/sources.list.d/nvidia-container-toolkit.list
      apt-get -o Acquire::http::Timeout=30 update -qq >> "$LOGFILE_AI" 2>&1 || true
    fi

    apt_install_progress "NVIDIA CTK" "NVIDIA Container Toolkit..." \
      --fix-missing ${PKGS[nvidia_ctk]}

    if pkg_installed "nvidia-container-toolkit"; then
      nvidia-ctk runtime configure --runtime=docker >> "$LOGFILE_AI" 2>&1
      systemctl restart docker 2>/dev/null || true
      log "OK" "NVIDIA CTK telepítve, Docker runtime konfigurálva"
      log "INFO" "nvidia-cdi-refresh.service hiba VÁRHATÓ pre-reboot — nem probléma"
      _CTK_VER="$(nvidia-ctk --version 2>/dev/null | grep -oP '[\d.]+' | head -1 || echo '?')"
      infra_state_set "NVIDIA_CTK_VER" "$_CTK_VER"; ((OK++))
    else
      log "FAIL" "NVIDIA CTK sikertelen"; ((FAIL++))
    fi
  else
    ((SKIP++)); log "SKIP" "NVIDIA CTK kihagyva"
  fi
fi

# =============================================================================
# 7. LÉPÉS — INITRAMFS
# =============================================================================

log "STEP" "━━━ 7/7: initramfs ━━━"

if ask_proceed "initramfs frissítése?"; then
  run_with_progress "initramfs" \
    "initramfs újraépítése minden kernelre..." \
    update-initramfs -u -k all
  _ec=$?
  [ $_ec -eq 0 ] && ((OK++)) || {
    ((FAIL++)); log "FAIL" "initramfs SIKERTELEN (exit $_ec)"
    dialog_warn "initramfs — Hiba" \
      "\n  sudo update-initramfs -u -k all\n  Log: $LOGFILE_AI" 10
  }
else
  ((SKIP++)); log "SKIP" "initramfs kihagyva"
fi

# =============================================================================
# REBOOT FLAG + COMP STATE MENTÉS
# =============================================================================

if [ "${OK:-0}" -gt 0 ] && \
   [ "$_FLOW" != "skip" ] && [ "$_FLOW" != "check" ] && \
   [ "${RUN_MODE:-install}" != "check" ]; then
  infra_state_set "REBOOT_NEEDED"   "true"
  infra_state_set "REBOOT_REASON"   "NVIDIA ${_DRIVER_SERIES:-?}-open driver + initramfs"
  infra_state_set "REBOOT_BY_INFRA" "$INFRA_NUM"
  log "STATE" "REBOOT_NEEDED=true (OK=$OK lépés végrehajtva)"
else
  log "STATE" "REBOOT_NEEDED nem változik (mód: ${RUN_MODE:-install}, flow: ${_FLOW})"
fi
infra_state_show

if [[ "$RUN_MODE" =~ ^(install|update|fix|reinstall)$ ]]; then
  log "COMP" "Post-install re-check (mód: $RUN_MODE)..."
  comp_check_nvidia_driver "${MIN_VER[driver]}"
  PATH="/usr/local/cuda/bin:$PATH" comp_check_cuda "${MIN_VER[cuda]}"
  comp_check_cudnn         "${MIN_VER[cudnn]}"
  comp_check_docker        "${MIN_VER[docker]}"
  comp_check_nvidia_ctk    "${MIN_VER[nvidia_ctk]}"
  comp_save_state "$INFRA_NUM"
  log "COMP" "Post-install COMP state mentve"
fi

show_result "$OK" "$SKIP" "$FAIL"

_pass_final="$(infra_state_get "MOK_ENROLL_PASS" "")"
_mok_pending="$(infra_state_get "MOK_ENROLL_PENDING" "false")"
_MOK_NOTE=""
[ "$_mok_pending" = "true" ] && [ -n "$_pass_final" ] && \
  _MOK_NOTE="
  ⚠  MOK ENROLLMENT — reboot után kék képernyőn:
     1. Enroll MOK → Continue
     2. Jelszó: $_pass_final
     3. Yes → Reboot"

if [ "${RUN_MODE:-install}" = "check" ]; then
  dialog_msg "[Ellenőrző] Kész — INFRA ${INFRA_NUM}" "
  GPU mód: $GPU_MODE | MOK: $(nvidia_mok_status 2>/dev/null || echo '?')
  Minden komponens naprakész — változtatás nem történt.
${STATUS}  AI log: $LOGFILE_AI" 20
else
  _cuda_installed="$(infra_state_get "CUDA_VER" "?")"
  _pytorch_idx="$(infra_state_get "PYTORCH_INDEX" "?")"
  dialog_msg "Következő lépések — INFRA ${INFRA_NUM}" "
  GPU mód: $GPU_MODE
  Driver:  $_DRIVER_PKG
  CUDA:    $_cuda_installed
  PyTorch: $_pytorch_idx
  MOK:     $(nvidia_mok_status 2>/dev/null || echo '?')
${_MOK_NOTE}
  Ellenőrzés REBOOT után:
    nvidia-smi
    nvcc --version
    python3 -c 'import torch; print(torch.cuda.is_available())'

  ⚠  REBOOT SZÜKSÉGES!  →  sudo reboot
  Reboot után: 01b_post_reboot.sh" 28

  if [ "${OK:-0}" -gt 0 ]; then
    dialog_yesno "Újraindítás most?" "
  $([ "$_mok_pending" = "true" ] && [ -n "$_pass_final" ] && \
    printf '  ⚠  MOK jelszó: %s  (kék képernyőn)\n\n' "$_pass_final")
  Újraindítjuk?" 14 && {
      log "REBOOT" "Felhasználó azonnali reboot-ot kért"
      reboot
    }
  fi
fi

trap - EXIT; rm -f "$LOCK"
log "DONE" "INFRA ${INFRA_NUM} befejezve: OK=$OK SKIP=$SKIP FAIL=$FAIL"
