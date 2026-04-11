#!/bin/bash
# =============================================================================
# 01a_system_foundation.sh — System Foundation v6.6
#                            Ubuntu 24 LTS | NVIDIA | CUDA | Docker
#
# Szerepe az INFRA rendszerben
# ────────────────────────────
# Kizárólag REBOOT-ot igénylő kötelező lépések. A modul végén REBOOT szükséges.
#
# Dokumentáció
# ────────────
#   CUDA:     https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
#   NVIDIA:   https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/ubuntu.html
#   Docker:   https://docs.docker.com/engine/install/ubuntu/
#   CTK:      https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/
#
# Változtatások v6.6 (2026-04-11 logok alapján):
#
#   1. APT mirror resilience (hu.archive.ubuntu.com timeout)
#      - apt-get update: --timeout=30, nem-fatális hiba (|| true)
#        Ha a mirror nem érhető el, a gyorsítótárazott lista marad
#      - apt-get install: --fix-missing flag minden hívásnál
#        Ha egy csomag nem tölthető le (hálózati hiba), átugorja de telepíti a többit
#      - Alap csomagok: pkg_installed dönt (nem az apt exit kód!)
#        ha minden kritikus csomag már fent van → SKIP (nem FAIL/OK confusion)
#
#   2. NVIDIA driver verzió detektálás + 590+ névváltás
#      NVIDIA hivatalos doc (r595, 2026-03-09):
#        "Starting with branch 590, packages renamed: nvidia-open (no branch number)"
#      Forrás: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/ubuntu.html
#      Prioritás: Ubuntu restricted (580, stabil) > CUDA repo nvidia-open (590+)
#      590 és 595 Ubuntu 24.04-en: feature branch (nem production)
#
#   3. Driver install failsafe
#      Ha a célcsomag (pl. 580-open) telepítése sikertelen:
#      → automatikus fallback nvidia-driver-570-open-ra (Blackwell minimum)
#      → Ha az is sikertelen: FAIL + erős figyelmeztetés (reboot előtt NE indítsunk!)
#
#   4. Docker CE + NVIDIA CTK: architekturális megjegyzés
#      Docker CE nem igényel rebootot, de NVIDIA CTK előfeltétele Docker
#      Jövőbeli 04_docker.sh szétválasztás lehetséges
#
# Változtatások v6.5 (COMP STATE implementáció):
#   - COMP_USE_CACHED / comp_state_exists / comp_load_state blokk
#   - check mód early exit
#   - Post-install re-check + comp_save_state (rövid + teljes út végén)
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

# NVIDIA driver failsafe: Blackwell minimálisan szükséges driver
# Ha a célcsomag (580-open) telepítése sikertelen, ezt próbáljuk
DRIVER_MIN_PKG_BLACKWELL="nvidia-driver-570-open"

CUDA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb"

declare -A PKGS=(
  # ccze: 00_lib.sh dual stream ANSI log kimenetéhez szükséges
  [base]="
    build-essential git curl wget unzip zip cmake ninja-build
    htop nvtop btop tree jq net-tools nmap
    ca-certificates gnupg lsb-release software-properties-common
    apt-transport-https pciutils ubuntu-drivers-common
    openssh-server xclip xdotool
    fonts-firacode fonts-jetbrains-mono zsh tmux screen
    p7zip-full ffmpeg imagemagick libssl-dev libffi-dev pkg-config ccze"

  # Python fordítási függőségek — pyenv/CPython build előfeltételei
  # Forrás: https://docs.python.org/3.13/ → Build from source
  [python_build]="
    liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev
    libbz2-dev zlib1g-dev libffi-dev tk-dev uuid-dev
    libncurses-dev libexpat1-dev libnss3-dev"

  # CUDA toolkit csomagok — 3 réteg: toolkit + runtime lib + dev header
  # Forrás: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/
  [cuda_13_2]="cuda-toolkit-13-2 cuda-libraries-13-2 cuda-libraries-dev-13-2"
  [cuda_13_1]="cuda-toolkit-13-1 cuda-libraries-13-1 cuda-libraries-dev-13-1"
  [cuda_13_0]="cuda-toolkit-13-0 cuda-libraries-13-0 cuda-libraries-dev-13-0"
  [cuda_12_8]="cuda-toolkit-12-8 cuda-libraries-12-8 cuda-libraries-dev-12-8"
  [cuda_12_6]="cuda-toolkit-12-6 cuda-libraries-12-6 cuda-libraries-dev-12-6"

  # cuDNN 9 + NCCL — NCCL 2.29.7+cuda13.2 backward-kompatibilis cu12 ABI-val
  [cudnn_nccl]="libcudnn9-cuda-12 libcudnn9-dev-cuda-12 libnccl2 libnccl-dev"

  # Docker CE + NVIDIA CTK
  # Architekturális megj.: Docker CE reboot nélkül működik; CTK előfeltétele.
  # Jövőbeli refaktor: 04_docker.sh (tervezett szétválasztás)
  [docker]="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  [nvidia_ctk]="nvidia-container-toolkit"
)

declare -A URLS=(
  [docker_gpg]="https://download.docker.com/linux/ubuntu/gpg"
  [docker_repo]="https://download.docker.com/linux/ubuntu"
  [nvidia_ctk_gpg]="https://nvidia.github.io/libnvidia-container/gpgkey"
  [nvidia_ctk_list]="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"
)

# Ubuntu repo nvidia-* csomagjai > CUDA repo csomagjai
# (Ubuntu-signált csomagok MOK enrollment nélkül betöltődnek)
APT_PIN_NVIDIA='# 01a_system_foundation v6.6
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
# DRIVER CSOMAGNÉV ÉS SOROZATSZÁM + 590+ NÉVVÁLTÁS DETEKTÁLÁS
# =============================================================================
# hw_detect() már meghatározta a ténylegesen telepített drivert (HW_NVIDIA_PKG).
#
# Ha semmi nincs telepítve, keressük a legjobb elérhető verziót:
#   A. Ubuntu restricted: nvidia-driver-580-open (stabil, Canonical-signed)
#   B. Ubuntu restricted: nvidia-driver-575-open
#   C. NVIDIA CUDA repo:  nvidia-open (590+ új névformátum)
#      NVIDIA r595 doc: "Starting with branch 590, packages renamed:
#      nvidia-open (no branch number), nvidia-driver-pinning-<branch> for locking"
#   D. Fallback: nvidia-driver-570-open (Blackwell minimum)
#
# 590/595 státusz Ubuntu 24.04-en (2026-04-11):
#   590: Ubuntu multiverse/proposed (community build, instabilitás ismert)
#   595: Ubuntu 26.04 only, 24.04-en nem érhető el
#   → Ubuntu restricted 580 marad az ajánlott stabil verzió

_DRIVER_PKG="${HW_NVIDIA_PKG}"
_DRIVER_SERIES="$(printf '%s' "$_DRIVER_PKG" | grep -oP '\d+' | head -1)"

if [ -z "$_DRIVER_PKG" ]; then
  log "HW" "Telepített driver nincs — elérhető keresése..."

  # A. Ubuntu restricted: 580-open (stabil, Canonical-signed, MOK nélkül tölt)
  if apt-cache show nvidia-driver-580-open &>/dev/null; then
    _DRIVER_PKG="nvidia-driver-580-open"; _DRIVER_SERIES="580"
    log "HW" "Ubuntu restricted: nvidia-driver-580-open → preferált (stabil)"

  # B. Ubuntu restricted: 575-open
  elif apt-cache show nvidia-driver-575-open &>/dev/null; then
    _DRIVER_PKG="nvidia-driver-575-open"; _DRIVER_SERIES="575"
    log "HW" "Ubuntu restricted: nvidia-driver-575-open"

  # C. NVIDIA CUDA repo: nvidia-open (590+ névformátum, feature branch)
  elif apt-cache show nvidia-open &>/dev/null; then
    _DRIVER_PKG="nvidia-open"; _DRIVER_SERIES="590"
    log "HW" "NVIDIA CUDA repo: nvidia-open (590+ feature branch)"
    log "WARN" "590 Ubuntu 24.04-en: multiverse/proposed, nem stabil production driver"

  # D. Fallback: 570-open (Blackwell minimális)
  else
    _DRIVER_PKG="${DRIVER_MIN_PKG_BLACKWELL}"; _DRIVER_SERIES="570"
    log "HW" "Fallback: $_DRIVER_PKG (minimális Blackwell driver)"
  fi

else
  # Telepített driver volt — sorozatszám kinyerése
  # 'nvidia-open' esetén (590+) nincsen szám a névben → dpkg-ből
  if [ -z "$_DRIVER_SERIES" ]; then
    _DRIVER_SERIES=$(dpkg-query -f '${Version}\n' -W "$_DRIVER_PKG" 2>/dev/null \
      | grep -oP '^\d+' | head -1 || echo "590")
  fi
fi

# Blackwell biztonsági ellenőrzés: GB202/GB203 ZÁRT driver → "No devices found"
if [ "$HW_GPU_ARCH" = "blackwell" ] && \
   [[ "$_DRIVER_PKG" != *"-open" ]] && [ "$_DRIVER_PKG" != "nvidia-open" ]; then
  _DRIVER_PKG="${_DRIVER_PKG}-open"
  log "HW" "Blackwell: -open suffix kényszerítve → $_DRIVER_PKG"
fi

log "HW" "Végső driver csomag: $_DRIVER_PKG (sorozat: ${_DRIVER_SERIES:-?})"

# =============================================================================
# KOMPONENS FELMÉRÉS
# =============================================================================
# COMP STATE rendszer: mentett check betöltése VAGY friss ellenőrzés.
# COMP_USE_CACHED=true: 00_master.sh exportálja ha a user kérte.
# Minta: 06_editors.sh (referencia implementáció)

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

  # CUDA 13.x workaround: comp_check_cuda csak cuda-toolkit-12-* mintát ismer dpkg-ből.
  # Explicit PATH szükséges: sudo kontextusban /usr/local/cuda/bin nem mindig elérhető.
  if [ "${COMP_STATUS[cuda]:-missing}" = "missing" ]; then
    _nvcc13=$(PATH="/usr/local/cuda/bin:$PATH" nvcc --version 2>/dev/null \
              | grep -oP 'release \K[\d.]+' | head -1)
    if [ -n "$_nvcc13" ] && [ "$(echo "$_nvcc13" | cut -d. -f1)" -ge 13 ] 2>/dev/null; then
      COMP_STATUS[cuda]="ok"; COMP_VER[cuda]="$_nvcc13"
      log "COMP" "CUDA 13.x workaround: $_nvcc13 (nvcc alapján)"
    fi
  fi

  # "broken" lib workaround — false positive "ok" "Nodeviceswerefound" esetén
  if [ "${COMP_STATUS[nvidia_driver]:-missing}" = "ok" ] && \
     ! echo "${COMP_VER[nvidia_driver]:-}" | grep -qE '^[0-9][0-9.]+$'; then
    log "WARN" "Driver version false positive: '${COMP_VER[nvidia_driver]}' → broken"
    COMP_STATUS[nvidia_driver]="broken"
    COMP_VER[nvidia_driver]="(kernel modul nem fut)"
  fi

  # check módban itt mentünk — más módokban a script VÉGÉN (post-install után)
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
# INST_* STATE SZINKRONIZÁLÁS — minden módban fut (check is)
# =============================================================================

if [ "${COMP_STATUS[nvidia_driver]:-missing}" = "ok" ]; then
  _cur_drv="$(infra_state_get "INST_DRIVER_VER" "")"
  [ -z "$_cur_drv" ] && {
    infra_state_set "INST_DRIVER_VER" "${COMP_VER[nvidia_driver]}"
    log "STATE" "INST_DRIVER_VER szinkronizálva: ${COMP_VER[nvidia_driver]}"
  }
fi

if [ "${COMP_STATUS[cuda]:-missing}" = "ok" ]; then
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
    _FLOW_DESC="Driver OK — mód: $RUN_MODE"
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

if [ "$_FLOW" = "short" ]; then
  dialog_msg "INFRA ${INFRA_NUM} — ${INFRA_NAME}" "
  GPU:     $HW_GPU_NAME
  Driver:  $_DRIVER_PKG  ⚡ telepítve, de kernel modul nem fut

  ${_mok_status_txt}

  Rövid út — csak ami szükséges:
    • MOK enrollment ellenőrzése
    • GPU mód konfiguráció (xorg.conf + modprobe)
    • initramfs frissítés  →  REBOOT

  A driver csomag és DKMS RENDBEN VAN.
  REBOOT után nvidia-smi-nak működnie kell.

  Log: $LOGFILE_AI" 22

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
  ${_mok_status_txt}

  Lépések:
    1. Ubuntu alap + Python build deps
    2. NVIDIA ${_DRIVER_PKG}  ← open kernel
    3. MOK enrollment (Secure Boot)
    4. CUDA toolkit + cuDNN 9 + NCCL
    5. Nouveau blacklist + GPU mód
    6. Docker CE + NVIDIA CTK
    7. initramfs → REBOOT

  Log: $LOGFILE_AI" 28
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
         if [ "$_mok_final" = "not_enrolled" ]; then
           log "WARN" "nvidia_mok_enroll 0-val tért vissza de not_enrolled — manual check"
         elif [ "$_mok_final" = "pending" ]; then
           _pass="$(infra_state_get "MOK_ENROLL_PASS" "")"
           dialog_msg "⚠  MOK enrollment — Fontos!" "
  REBOOT UTÁN kék/lila UEFI képernyő jelenik meg.

    1. Enroll MOK
    2. Continue
    3. Jelszó: ${_pass:-(lásd ~/.infra-state MOK_ENROLL_PASS)}
    4. Yes → Reboot

  E NÉLKÜL az NVIDIA driver NEM töltődik be Secure Boot alatt!" 18
         fi
         ;;
      1) ((FAIL++)); log "FAIL" "MOK enrollment sikertelen" ;;
      2) ((SKIP++)); log "SKIP" "MOK.der hiányzik — dkms autoinstall szükséges?" ;;
    esac
  else
    ((SKIP++)); log "SKIP" "MOK enrollment kihagyva"
  fi

  log "STEP" "━━━ GPU mód konfiguráció ($GPU_MODE) ━━━"
  if ask_proceed "GPU mód konfiguráció ellenőrzése/alkalmazása?"; then
    _gpu_conf_ok=true
    _nvidia_opts_file="/etc/modprobe.d/99-nvidia-options.conf"
    _nouveau_file="/etc/modprobe.d/99-blacklist-nouveau.conf"
    _xorg_file="/etc/X11/xorg.conf"

    if grep -q "01a_system_foundation" "$_nvidia_opts_file" 2>/dev/null && \
       grep -q "01a_system_foundation" "$_nouveau_file" 2>/dev/null && \
       grep -q "01a_system_foundation" "$_xorg_file" 2>/dev/null; then
      log "OK" "GPU konfig fájlok naprakészek"
      ((OK++))
    else
      log "INFO" "GPU konfig fájlok újraírása szükséges"
      _gpu_conf_ok=false
    fi

    if ! $_gpu_conf_ok; then
      _write_gpu_config "$GPU_MODE" && ((OK++)) || ((FAIL++))
    fi
  else
    ((SKIP++)); log "SKIP" "GPU konfig kihagyva"
  fi

  log "STEP" "━━━ initramfs frissítés ━━━"
  if ask_proceed "initramfs frissítése?"; then
    run_with_progress "initramfs" \
      "initramfs újraépítése minden kernelre..." \
      update-initramfs -u -k all
    [ $? -eq 0 ] && ((OK++)) || ((FAIL++))
  else
    ((SKIP++))
    log "SKIP" "initramfs kihagyva — MANUÁLISAN: sudo update-initramfs -u -k all"
  fi

  show_result "$OK" "$SKIP" "$FAIL"

  if [ "${OK:-0}" -gt 0 ] && [ "${RUN_MODE:-install}" != "check" ]; then
    infra_state_set "REBOOT_NEEDED"   "true"
    infra_state_set "REBOOT_REASON"   "MOK enrollment + GPU konfig (short path)"
    infra_state_set "REBOOT_BY_INFRA" "$INFRA_NUM"
  fi

  # Post-install COMP STATE mentés — rövid út
  if [[ "$RUN_MODE" =~ ^(install|update|fix|reinstall)$ ]]; then
    log "COMP" "Post-install re-check (rövid út, mód: $RUN_MODE)..."
    comp_check_nvidia_driver "${MIN_VER[driver]}"
    PATH="/usr/local/cuda/bin:$PATH" comp_check_cuda "${MIN_VER[cuda]}"
    comp_check_cudnn         "${MIN_VER[cudnn]}"
    comp_check_docker        "${MIN_VER[docker]}"
    comp_check_nvidia_ctk    "${MIN_VER[nvidia_ctk]}"
    comp_save_state "$INFRA_NUM"
    log "COMP" "Post-install COMP state mentve (rövid út)"
  fi

  _pass_final="$(infra_state_get "MOK_ENROLL_PASS" "")"
  _mok_pending="$(infra_state_get "MOK_ENROLL_PENDING" "false")"

  dialog_msg "Rövid út kész — REBOOT szükséges" "
  GPU mód: $GPU_MODE
  MOK:     $(nvidia_mok_status 2>/dev/null || echo '?')

  $([ "$_mok_pending" = "true" ] && [ -n "$_pass_final" ] && \
    echo "  ⚠  Reboot után kék képernyőn add meg:
       Jelszó: $_pass_final
       (Enroll MOK → Continue → jelszó → Yes → Reboot)")

  Ellenőrzés reboot után:
    nvidia-smi
    nvcc --version

  ➜  sudo reboot" 22

  dialog_yesno "Újraindítás most?" "
  $([ "$_mok_pending" = "true" ] && [ -n "$_pass_final" ] && \
    printf '  ⚠  MOK jelszó: %s\n  (kék képernyőn)\n\n' "$_pass_final")
  Újraindítjuk?" 14 && reboot

  trap - EXIT; rm -f "$LOCK"
  log "DONE" "INFRA ${INFRA_NUM} (rövid út) befejezve: OK=$OK SKIP=$SKIP FAIL=$FAIL"
  exit 0
fi

# =============================================================================
# ██  TELJES ÚT — missing / old / reinstall / update  ██
# =============================================================================

# =============================================================================
# 1. LÉPÉS — ALAP RENDSZER CSOMAGOK
# =============================================================================
# v6.6: APT mirror resilience
# hu.archive.ubuntu.com 2026-04-11 logban timeout-olt (ubuntu-drivers-common)
# Megoldás:
#   1. apt-get update: --timeout=30, nem-fatális (|| true)
#      Ha timeout → gyorsítótárazott lista marad (legtöbbször elegendő)
#   2. apt-get install: --fix-missing
#      Hálózati hiba esetén átugorja a nem letölthető csomagot
#   3. Eredmény ellenőrzés: pkg_installed a KRITIKUS csomagokra
#      Nem az apt exit kód (100 = 1 csomag nem töltődött, a többi OK)

log "STEP" "━━━ 1/7: Alap rendszer csomagok ━━━"

if [ "$_DRV_STATUS" = "missing" ] || [ "$_DRV_STATUS" = "old" ] || \
   [ "$RUN_MODE" = "reinstall" ] || [ "$RUN_MODE" = "update" ]; then

  if ask_proceed "Alap fejlesztői csomagok + Python build deps?"; then
    # apt-get update timeout=30 — ha a mirror nem érhető el, nem szabad megakadni
    log "APT" "apt-get update (Acquire::http::Timeout=30)..."
    apt-get -o Acquire::http::Timeout=30 update -qq 2>&1 | \
      tee -a "$LOGFILE_AI" || \
      log "WARN" "apt-get update részleges hiba — gyorsítótárazott lista marad"

    # --fix-missing: ha 1-2 csomag (pl. ubuntu-drivers-common upgrade) nem tölthető le
    # a többi települ, nem áll le a teljes folyamat
    apt_install_progress "Alap csomagok" \
      "Ubuntu alap + Python fordítási függőségek..." \
      --fix-missing \
      ${PKGS[base]} ${PKGS[python_build]}

    # Eredmény: pkg_installed dönt a KRITIKUS csomagokra
    # (apt exit 100 = 1 csomag nem töltődött le, de a többi OK — ez nem FAIL)
    if pkg_installed "build-essential" && pkg_installed "liblzma-dev" && \
       pkg_installed "zsh" && pkg_installed "ccze"; then
      ((OK++)); log "OK" "Alap csomagok OK (kritikus csomagok telepítve)"
    else
      # Hány kritikus csomag hiányzik?
      _missing_critical=0
      for _chk_pkg in build-essential zsh ccze liblzma-dev; do
        pkg_installed "$_chk_pkg" || {
          ((_missing_critical++))
          log "WARN" "Hiányzó kritikus csomag: $_chk_pkg"
        }
      done
      if [ "$_missing_critical" -gt 2 ]; then
        ((FAIL++)); log "FAIL" "Alap csomagok: $_missing_critical kritikus csomag hiányzik"
      else
        # 1-2 nem-kritikus hiány (pl. ubuntu-drivers-common upgrade) → nem blokkoló
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
# v6.6: Driver install failsafe
# Ha a célcsomag telepítése sikertelen → fallback a minimális Blackwell driverre
# (nvidia-driver-570-open) hogy reboot után ne legyen fekete képernyő.

log "STEP" "━━━ 2/7: NVIDIA open driver ($_DRIVER_PKG) ━━━"

if [ "$_DRV_STATUS" = "missing" ] || [ "$_DRV_STATUS" = "old" ] || \
   [ "$RUN_MODE" = "reinstall" ]; then

  if ask_proceed "NVIDIA ${_DRIVER_PKG} telepítése?"; then

    progress_open "NVIDIA Open Driver — ${_DRIVER_PKG}" "Előkészítés..."

    # CUDA repo ideiglenes kikapcsolása (APT pinning konfliktus)
    progress_set 5 "CUDA repo ideiglenes deaktiválása..."
    declare -a _CUDA_REPO_MOVED=()
    for _f in /etc/apt/sources.list.d/cuda*.list \
               /etc/apt/sources.list.d/cuda*.sources; do
      [ -f "$_f" ] || continue
      _bak="/tmp/$(basename "$_f").infra_bak"
      mv "$_f" "$_bak" 2>/dev/null && _CUDA_REPO_MOVED+=("$_bak|$_f") && \
        log "APT" "CUDA repo deaktiválva: $_f"
    done

    # Régi NVIDIA csomagok tiszta eltávolítása (DEBIAN_FRONTEND=noninteractive)
    progress_set 14 "Régi NVIDIA csomagok eltávolítása..."
    nvidia_driver_purge "$LOGFILE_AI"

    # APT pinning — Ubuntu repo > CUDA repo
    progress_set 32 "APT pinning..."
    echo "$APT_PIN_NVIDIA" > /etc/apt/preferences.d/99-nvidia-ubuntu-priority

    # Driver telepítés
    progress_set 40 "APT lista frissítése..."
    apt-get -o Acquire::http::Timeout=30 update -qq >> "$LOGFILE_AI" 2>&1 || true
    progress_set 50 "${_DRIVER_PKG} letöltése és telepítése (~450MB)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      --fix-missing \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "${_DRIVER_PKG}" nvidia-prime >> "$LOGFILE_AI" 2>&1
    _DRV_EC=$?

    # CUDA repo visszakapcsolása
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
      infra_state_set "HW_NVIDIA_PKG"        "$_DRIVER_PKG"
      infra_state_set "NVIDIA_DRIVER_PKG"    "$_DRIVER_PKG"
      infra_state_set "NVIDIA_DRIVER_SERIES" "${_DRIVER_SERIES:-?}"
      ((OK++))
    else
      # ── DRIVER INSTALL FAILSAFE ────────────────────────────────────────────
      # A célcsomag telepítése sikertelen. Megpróbáljuk a minimális Blackwell
      # drivert bejuttatni hogy reboot után a rendszer működőképes legyen.
      log "FAIL" "NVIDIA driver SIKERTELEN (exit ${_DRV_EC}): $_DRIVER_PKG"
      log "INFO" "Failsafe driver telepítése: $DRIVER_MIN_PKG_BLACKWELL..."

      DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --fix-missing \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "$DRIVER_MIN_PKG_BLACKWELL" >> "$LOGFILE_AI" 2>&1

      if pkg_installed "$DRIVER_MIN_PKG_BLACKWELL"; then
        log "WARN" "Failsafe driver telepítve: $DRIVER_MIN_PKG_BLACKWELL"
        log "WARN" "Célcsomag ($__DRIVER_PKG) nem volt telepíthető!"
        infra_state_set "HW_NVIDIA_PKG"        "$DRIVER_MIN_PKG_BLACKWELL"
        infra_state_set "NVIDIA_DRIVER_PKG"    "$DRIVER_MIN_PKG_BLACKWELL"
        infra_state_set "NVIDIA_DRIVER_SERIES" "570"
        _DRIVER_PKG="$DRIVER_MIN_PKG_BLACKWELL"
        _DRIVER_SERIES="570"
        dialog_warn "NVIDIA Driver — Failsafe" "
  A kívánt driver ($_DRIVER_PKG) nem volt telepíthető.
  Fallback driver telepítve: $DRIVER_MIN_PKG_BLACKWELL

  A rendszer reboot után működőképes lesz, de
  később érdemes frissíteni a 580+ verzióra:
    sudo apt update && sudo apt install nvidia-driver-580-open

  Log: $LOGFILE_AI" 18
        ((SKIP++))   # részleges siker — nem teljes OK, nem katasztrófa
      else
        log "FAIL" "Failsafe driver is sikertelen: $DRIVER_MIN_PKG_BLACKWELL"
        dialog_warn "NVIDIA Driver — SÚLYOS HIBA" "
  Sem a céldriver, sem a fallback driver nem volt telepíthető.

  Lehetséges okok:
    • Hálózati hiba (APT repo nem elérhető)
    • Kernel inkompatibilitás: uname -r
    • dpkg félbeszakadt: sudo dpkg --configure -a

  A rendszer REBOOT UTÁN NEM MŰKÖDŐKÉPES NVIDIA-val!
  NE INDÍTSD ÚJRA amíg a driver nincs telepítve!

  Log: $LOGFILE_AI" 18
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
  Az NVIDIA DKMS modul aláírva.
  Az UEFI-nek jóvá kell hagynia a kulcsot.

  REBOOT UTÁN kék/lila UEFI képernyő:
  (\"Shim UEFI key management\")

    1.  Enroll MOK
    2.  Continue
    3.  Jelszó:  ${_pass:-(lásd ~/.infra-state MOK_ENROLL_PASS)}
    4.  Yes
    5.  Reboot

  E NÉLKÜL az NVIDIA driver NEM töltődik be Secure Boot alatt!" 22

      elif [ "$_mok_final" = "enrolled" ]; then
        log "OK" "MOK enrolled — Secure Boot kompatibilis"
      fi
      ;;

    1) ((FAIL++))
       dialog_warn "MOK enrollment sikertelen" "
  Manuálisan:
    sudo mokutil --import /var/lib/shim-signed/mok/MOK.der

  Ha Secure Boot ki van kapcsolva: nem szükséges." 12 ;;

    2) ((SKIP++))
       dialog_warn "MOK.der hiányzik" "
  A DKMS nem hozta létre a kulcsot.
  Megoldás:
    sudo dkms autoinstall
  Majd futtasd újra ezt a scriptet." 12 ;;
  esac
else
  ((SKIP++)); log "SKIP" "MOK enrollment kihagyva"
fi

# =============================================================================
# 4. LÉPÉS — CUDA TOOLKIT
# =============================================================================
# A CUDA repo az NVIDIA CDN-ről tölt (nem Ubuntu mirror) → stabilabb elérés

log "STEP" "━━━ 4/7: CUDA toolkit ━━━"

if [ "${COMP_STATUS[cuda]:-missing}" != "ok" ] || \
   [ "$RUN_MODE" = "reinstall" ]; then

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
    log "WARN" "Nincs elérhető CUDA csomag a repo-ban"
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
                log "INFO" "Blackwell SM_120: CUDA 12.8 natív" ;;
          12.6) _CUDA_VER="12.6"; _CUDA_PKGS="${PKGS[cuda_12_6]}"
                log "WARN" "Blackwell: 12.8+ nem elérhető → 12.6 SM_89 compat mód"
                dialog_msg "CUDA — Figyelmeztetés" "
  SM_120 natív teljesítményhez CUDA 12.8+ szükséges.
  Most: CUDA 12.6 (SM_89 kompatibilitási módban fut).
  Ha elérhetővé válik: sudo apt install cuda-toolkit-13-2" 12 ;;
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
      infra_state_set "CUDA_VER" "$_SYNC"; infra_state_set "PYTORCH_INDEX" "$_IDX"
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
# 5. LÉPÉS — NOUVEAU BLACKLIST + GPU MÓD KONFIGURÁCIÓ
# =============================================================================

_write_gpu_config() {
  local mode="${1:-hybrid}"

  cat > /etc/modprobe.d/99-blacklist-nouveau.conf << 'BEOF'
# 01a_system_foundation v6.6 — Nouveau blacklist
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
BEOF

  # modeset=1: Wayland/GBM | fbdev=1: boot splash | NVreg: suspend VRAM megőrzés
  cat > /etc/modprobe.d/99-nvidia-options.conf << 'MEOF'
# 01a_system_foundation v6.6 — NVIDIA kernel modul opciók
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
MEOF

  if [ "$mode" = "hybrid" ]; then
    prime-select on-demand 2>/dev/null || true

    # Intel iGPU Bus ID — hex→dec konverzió, Xorg "PCI:B:D:F" formátum
    local intel_busid
    intel_busid=$(lspci | grep -i "VGA.*Intel" | head -1 | awk '{print $1}' | \
      awk -F'[:.]' '{printf "PCI:%d:%d:%d",
        strtonum("0x"$1), strtonum("0x"$2), strtonum("0x"$3)}' 2>/dev/null)
    intel_busid="${intel_busid:-PCI:0:2:0}"
    log "CFG" "Intel iGPU Bus ID: $intel_busid"

    cat > /etc/X11/xorg.conf << XEOF
# 01a_system_foundation v6.6 — Hibrid GPU mód (Intel iGPU + NVIDIA RTX)
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
# 01a_system_foundation v6.6 — Intel iGPU blacklist (dedikált NVIDIA mód)
blacklist i915
blacklist intel_agp
BEOF

    cat > /etc/X11/xorg.conf << 'XEOF'
# 01a_system_foundation v6.6 — Dedikált GPU mód (csak NVIDIA RTX)
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
# Architekturális megjegyzés:
# Docker CE önmagában nem igényel rebootot. A NVIDIA CTK viszont pre-reboot
# konfigurálást igényel (daemon.json beállítás), és a GPU-Docker integráció
# csak reboot után (futó NVIDIA driver) fog ténylegesen működni.
#
# Ha a jövőben Docker CE és CTK kiválik egy 04_docker.sh szálba:
# - comp_check_docker / comp_check_nvidia_ctk változatlan marad
# - 02_local_ai_stack.sh infra_require("docker") fogja kezelni a függőséget
# - registry.sh-ba kerül: 04_docker entry HW_REQ="" (hardver független)

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
      # Docker CDN-ről tölt (nem Ubuntu mirror) → stabil elérés
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
# nvidia-cdi-refresh.service SIKERTELEN lesz pre-reboot állapotban — VÁRHATÓ!
# /dev/nvidia* csak driver betöltés (reboot) után létezik.

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
    "initramfs újraépítése minden kernelre — pár percet vehet igénybe..." \
    update-initramfs -u -k all
  _ec=$?
  [ $_ec -eq 0 ] && ((OK++)) || {
    ((FAIL++)); log "FAIL" "initramfs SIKERTELEN (exit $_ec)"
    dialog_warn "initramfs — Hiba" \
      "\n  Manuálisan: sudo update-initramfs -u -k all\n  Log: $LOGFILE_AI" 10
  }
else
  ((SKIP++)); log "SKIP" "initramfs kihagyva — MANUÁLISAN: sudo update-initramfs -u -k all"
fi

# =============================================================================
# REBOOT FLAG
# =============================================================================

if [ "${OK:-0}" -gt 0 ] && \
   [ "$_FLOW" != "skip" ] && [ "$_FLOW" != "check" ] && \
   [ "${RUN_MODE:-install}" != "check" ]; then
  infra_state_set "REBOOT_NEEDED"   "true"
  infra_state_set "REBOOT_REASON"   "NVIDIA ${_DRIVER_SERIES:-?}-open driver + initramfs"
  infra_state_set "REBOOT_BY_INFRA" "$INFRA_NUM"
  log "STATE" "REBOOT_NEEDED=true (OK=$OK lépés végrehajtva)"
else
  log "STATE" "REBOOT_NEEDED nem változik (mód: ${RUN_MODE:-install}, flow: ${_FLOW}, OK=${OK:-0})"
fi
infra_state_show

# =============================================================================
# POST-INSTALL COMP STATE MENTÉS — teljes út
# =============================================================================

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
     3. Yes → Reboot
"

if [ "${RUN_MODE:-install}" = "check" ]; then
  dialog_msg "[Ellenőrző] Kész — INFRA ${INFRA_NUM}" "
  GPU mód: $GPU_MODE
  MOK állapot: $(nvidia_mok_status 2>/dev/null || echo '?')

  Minden komponens naprakész — változtatás nem történt.
  Ellenőrző mód: a rendszer nem módosult.

  Komponens összesítő:
${STATUS}
  AI log: $LOGFILE_AI" 20

else
  dialog_msg "Következő lépések — INFRA ${INFRA_NUM}" "
  GPU mód: $GPU_MODE
  $([ "$GPU_MODE" = "hybrid" ] \
    && echo "  Kábelezés: 1 monitor alaplapon (iGPU), 1 az RTX portján" \
    || echo "  Kábelezés: minden monitor az RTX portjain")
  MOK állapot: $(nvidia_mok_status 2>/dev/null || echo '?')
${_MOK_NOTE}
  Ellenőrzés REBOOT után:
    nvidia-smi
    nvcc --version
    docker run --rm --gpus all \\
      nvidia/cuda:$(infra_state_get "CUDA_VER" "12.6")-base-ubuntu24.04 \\
      nvidia-smi

  Takarítás: sudo apt autoremove

  ⚠  REBOOT SZÜKSÉGES!  →  sudo reboot
  Reboot után: 01b_post_reboot.sh" 30

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
