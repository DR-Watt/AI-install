#!/bin/bash
# =============================================================================
# 01a_system_foundation.sh — System Foundation v6.12
#                            Ubuntu 24/26 LTS | NVIDIA | CUDA | Docker
#
# Dokumentáció
# ────────────
#   CUDA:   https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
#   NVIDIA: https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/
#   Docker: https://docs.docker.com/engine/install/ubuntu/
#   CTK:    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/
#   Compat: NVIDIA CUDA Compatibility r595 (2026-03-31)
#
# Változtatások v6.12 (CUDA pin fájl + update-alternatives):
#
#   FIX 1: cuda-repository-pin-600 pin fájl explicit letöltése
#     Probléma: az Ubuntu 24.04 alap CUDA repo-ban csak 12.6 van.
#     12.8, 13.x CSAK az NVIDIA direkt repo-ból érhetők el, de csak ha
#     a priority 600-as pin fájl be van állítva. Nélküle az Ubuntu 12.6
#     "nyeri" a prioritásversenyt → magasabb verziók láthatatlanok!
#     User teszt (2026-04-13): manuálisan futtatva a Gemini-javasolt lépéseket
#     (wget cuda-ubuntu2404.pin + add-apt-repository) → 12.8, 13.1, 13.2
#     mind elérhetővé vált és update-alternatives 4 opciót mutatott.
#     Fix: pin fájl letöltése wget-tel (fallback: kézi írás) a CUDA keyring
#     telepítése ELŐTT. A cuda_best_available() ezután megtalálja 13.1-et.
#     Forrás: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
#             Network Repo Installation for Ubuntu (official NVIDIA docs)
#
#   FIX 2: update-alternatives regisztrálás CUDA install után
#     Probléma: több CUDA verzió lehet telepítve egyszerre (12.6, 12.8, 13.1)
#     de nem volt könnyű váltani köztük.
#     Fix: minden /usr/local/cuda-X.Y könyvtárra: update-alternatives --install
#     Prioritás: major*10+minor (13.1→131, 12.8→128, 12.6→126)
#     Eredmény: sudo update-alternatives --config cuda → interaktív váltás
#
#   COMPAT MÁTRIX v1.2 (egyidejűleg):
#     noble + blackwell/ada/ampere: cuda_recommended 12.6 → 13.1
#     noble + blackwell/ada/ampere: pytorch_index cu126 → cu128
#     (turing/pascal marad 12.6)
#
# Változtatások v6.11 (2026-04-12 10:41 log analízis — 4 fix):
#
#   BUG 1 FIX — Broken dpkg state detektálása:
#     Tünet: hw_detect "apt-cache, max sorozat"-ot használ (dpkg nem talál
#     telepített csomagot), de nvidia-smi 590.48.01-et ad (kernel modul töltve)
#     → comp_check_nvidia_driver=ok → driver step skip → CTK install fail
#     Fix: dpkg --audit + dpkg -l iF/iU kód keresése → _DPKG_BROKEN flag
#
#   BUG 2 FIX — Driver step futtatása _DPKG_BROKEN esetén:
#     Ha _DPKG_BROKEN=true, a driver step akkor is fut ha _DRV_STATUS=ok
#     → nvidia_driver_purge + tiszta újratelepítés javítja a broken state-et
#
#   BUG 3 FIX — apt update + fix_broken CTK telepítés ELŐTT:
#     Tünet: "libnvidia-egl-wayland1 but it is not installable"
#     ("not installable" ≠ "not going to be installed" — APT cache-ben sincs!)
#     Fix: apt_mirror_check_fallback → apt-get update → apt_fix_broken
#     a CTK install ask_proceed ELŐTT futtatva (nem csak failsafe előtt)
#
#   BUG 4 FIX — MOD_01A_DONE csak FAIL==0 esetén:
#     Tünet: FAIL=2 session után MOD_01A_DONE=true → következő futás
#     nem futtatja újra a sikertelen lépéseket (pl. CTK)
#     Fix: MOD_01A_DONE=true csak ha FAIL==0
#          FAIL>0 esetén: MOD_01A_DONE="" (törlés)
#
# Változtatások v6.10 (2026-04-12 logok — mirror fallback + fix-broken):
#
#   BUG 1 FIX — hu.archive.ubuntu.com leállás → cascading Unmet deps failures:
#     Tünet: libnvidia-egl-wayland1 (main ág) csak archive mirror-on van,
#     security.ubuntu.com nem tükrözi → libnvidia-gl-590 nem konfigurálható
#     → MINDEN apt hívás Unmet dependencies-szel bukott (CUDA, cuDNN, CTK)
#     Fix: apt_mirror_check_fallback() — curl 5mp timeout, ha primary mirror
#     le van: sources.list → archive.ubuntu.com (Canonical global CDN)
#     apt_mirror_restore() — install után visszaállítja az eredeti mirror-t
#
#   BUG 2 FIX — Failed install utáni broken dpkg state blokkolja a failsafe-t:
#     Tünet: sikertelen driver install után a failsafe (570-open) is Unmet deps
#     hibával bukott, mert a részlegesen konfigurált csomag blokkolta az apt-ot
#     Fix: apt_fix_broken() hívása a failsafe install ELŐTT
#
# Változtatások v6.8 (compat mátrix integráció):
#
#   DRIVER KIVÁLASZTÁS → compat_get() alapú:
#     Az `if apt-cache show nvidia-driver-590-open` hardkódolt lánc helyett
#     compat_get("driver_pkg", arch, codename) adja a pontos ajánlást.
#     Ubuntu 24.04 noble:  590-open (Canonical-signed)
#     Ubuntu 26.04 plucky: 595-open (Canonical-signed)
#     Fallback: apt-cache max sorozat, majd DRIVER_MIN_PKG_BLACKWELL
#
#   CUDA KIVÁLASZTÁS → compat_get() alapú:
#     A ~40 soros case "$HW_GPU_ARCH" in blackwell)...ada|ampere)... blokk
#     helyett compat_get("cuda_recommended", arch, codename) egyetlen lookup.
#     Eredmény: 15 sor felváltja a 40 soros case blokkot.
#
#   CUDA UPGRADE TRIGGER → compat_get() alapú:
#     A hardkódolt "< 13" major check helyett version_ok() összehasonlítás
#     a compat_get("cuda_recommended") értékkel. OS-független, GPU-független.
#
# Változtatások v6.7 (2026-04-11 logok — 3 kritikus bug fix):
#   BUG 1: CUDA upgrade nem indult el 590 driver install után
#   BUG 2: CTK purge után nem reinstallálódott
#   BUG 3: INST_DRIVER_VER nem frissült 590 install után
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

# Abszolút minimum fallback — ha compat_get sem tud jobbat adni
# (pl. nincs hálózat és nincs semmi a repóban)
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

APT_PIN_NVIDIA='# 01a_system_foundation v6.12
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
infra_state_set "HW_OS_CODENAME" "$HW_OS_CODENAME"
infra_state_set "HW_OS_VERSION"  "$HW_OS_VERSION"

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
# hw_detect() meghatározta HW_NVIDIA_PKG-t:
#   - dpkg alapján ha valami telepítve van (tényleges)
#   - compat_get() alapján ha semmi nincs telepítve (ajánlott, OS-specifikus)
#
# v6.8 változás: ha HW_NVIDIA_PKG üres (hw_detect nem talált semmit),
# a fallback logika is compat_get()-et használ apt-cache ellenőrzéssel,
# nem hardkódolt driver neveket.

_DRIVER_PKG="${HW_NVIDIA_PKG}"
_DRIVER_SERIES="$(printf '%s' "$_DRIVER_PKG" | grep -oP '\d+' | head -1)"

# nvidia-open esetén (590+ új névformátum) nincsen szám a névben
if [ -z "$_DRIVER_SERIES" ] && [ -n "$_DRIVER_PKG" ]; then
  _DRIVER_SERIES=$(dpkg-query -f '${Version}\n' -W "$_DRIVER_PKG" 2>/dev/null \
    | grep -oP '^\d+' | head -1 || echo "590")
fi

if [ -z "$_DRIVER_PKG" ]; then
  log "HW" "Driver nincs telepítve — compat mátrix alapján keresés..."

  # 1. Compat mátrix: az aktuális GPU arch + OS ajánlott drivere
  _COMPAT_DRV=$(compat_get "driver_pkg"       "$HW_GPU_ARCH" "$HW_OS_CODENAME" "")
  _COMPAT_SERIES=$(compat_get "driver_series" "$HW_GPU_ARCH" "$HW_OS_CODENAME" "570")
  _COMPAT_SIGNED=$(compat_get "canonical_signed" "$HW_GPU_ARCH" "$HW_OS_CODENAME" "false")

  if [ -n "$_COMPAT_DRV" ] && apt-cache show "$_COMPAT_DRV" &>/dev/null; then
    _DRIVER_PKG="$_COMPAT_DRV"
    _DRIVER_SERIES="$_COMPAT_SERIES"
    _src_txt="$( [ "$_COMPAT_SIGNED" = "true" ] && echo "Ubuntu restricted, Canonical-signed ✓" \
                                                 || echo "CUDA repo — MOK szükséges lehet" )"
    log "HW" "Compat driver: $_DRIVER_PKG [$_src_txt]"
  else
    [ -n "$_COMPAT_DRV" ] && \
      log "WARN" "Compat driver nem elérhető: $_COMPAT_DRV → fallback keresés..."

    # 2. Fallback: legmagasabb elérhető sorozat apt-cache-ből
    _avail=$(apt-cache search '^nvidia-driver-[0-9]' 2>/dev/null \
      | grep -oP 'nvidia-driver-\K[0-9]+' | sort -n | tail -1)
    if [ -n "$_avail" ]; then
      _DRIVER_PKG="nvidia-driver-${_avail}-open"
      _DRIVER_SERIES="$_avail"
      log "HW" "Fallback: $_DRIVER_PKG (apt-cache max sorozat)"
    elif apt-cache show nvidia-open &>/dev/null; then
      _DRIVER_PKG="nvidia-open"; _DRIVER_SERIES="590"
      log "HW" "Fallback: nvidia-open (590+ új névformátum)"
    else
      _DRIVER_PKG="${DRIVER_MIN_PKG_BLACKWELL}"; _DRIVER_SERIES="570"
      log "HW" "Fallback: $_DRIVER_PKG (abszolút minimum)"
    fi
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

  # nvcc fallback ha sem nvcc, sem dpkg nem adott eredményt (lib v6.5: 13.x is keresve)
  if [ "${COMP_STATUS[cuda]:-missing}" = "missing" ]; then
    _nvcc_ver=$(PATH="/usr/local/cuda/bin:$PATH" nvcc --version 2>/dev/null \
                | grep -oP 'release \K[\d.]+' | head -1)
    if [ -n "$_nvcc_ver" ]; then
      COMP_STATUS[cuda]="ok"; COMP_VER[cuda]="$_nvcc_ver"
      log "COMP" "CUDA nvcc workaround: $_nvcc_ver"
    fi
  fi

  if [ "${COMP_STATUS[nvidia_driver]:-missing}" = "ok" ] && \
     ! echo "${COMP_VER[nvidia_driver]:-}" | grep -qE '^[0-9][0-9.]+$'; then
    COMP_STATUS[nvidia_driver]="broken"
    COMP_VER[nvidia_driver]="(kernel modul nem fut)"
  fi

  [ "$RUN_MODE" = "check" ] && { comp_save_state "$INFRA_NUM"; log "COMP" "Check mód: COMP state mentve"; }
fi

# dpkg broken state detektálás — az nvidia-smi "ok"-ot adhat miközben
# libnvidia-* csomagok féltelepített állapotban vannak (dpkg iF/iU kód).
# Tünet: hw_detect "apt-cache, max sorozat" ágat használ (dpkg nem talál
# telepített drivercsomagot) de nvidia-smi mégis visszaadja a verziót
# (kernel modul az előző reboot óta be van töltve).
_DPKG_BROKEN=false
_dpkg_broken_pkgs=""

# dpkg --audit: felsorolja a broken/half-installed csomagokat
if dpkg --audit 2>/dev/null | grep -qi "nvidia\|libnvidia"; then
  _DPKG_BROKEN=true
  _dpkg_broken_pkgs=$(dpkg --audit 2>/dev/null | head -5)
  log "WARN" "dpkg audit: broken NVIDIA csomagok detektálva"
  log "WARN" "  $(printf '%s' "$_dpkg_broken_pkgs" | head -2 | tr '
' ' ')"
fi

# dpkg -l: iF=halfinstalled, iU=halfconfigured kódok keresése
if ! $_DPKG_BROKEN && dpkg -l 2>/dev/null     | awk '{print $1, $2}'     | grep -qE '^(iF|iU)\s+(libnvidia|nvidia)'; then
  _DPKG_BROKEN=true
  log "WARN" "dpkg iF/iU: libnvidia-* féltelepített csomag detektálva"
fi

$_DPKG_BROKEN && log "WARN" "Broken dpkg state → driver step fut, apt --fix-broken szükséges"

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
# CUDA UPGRADE TRIGGER — v6.8: compat_get() alapú
# =============================================================================
# v6.7: hardkódolt "_cur_cuda_major < 13" check
# v6.8: version_ok() összehasonlítás a compat_get("cuda_recommended") értékkel
#
# Ez OS-függetlenül helyes:
#   noble  + ada:  cuda_recommended=13.1 → ha 12.6 van, upgrade szükséges
#   plucky + ada:  cuda_recommended=13.2 → ha 12.6 van, upgrade szükséges
#   noble  + turing: cuda_recommended=12.6 → ha 12.6 van, NEM kell upgrade
#
# Forrás: lib/00_lib_compat.sh cuda_recommended mezők

_CUDA_UPGRADE_NEEDED=false
if [ "${COMP_STATUS[cuda]:-missing}" = "ok" ]; then
  _cur_cuda_ver="${COMP_VER[cuda]:-12.6}"
  _cuda_recommended=$(compat_get "cuda_recommended" "$HW_GPU_ARCH" "$HW_OS_CODENAME" "12.6")
  if ! version_ok "$_cur_cuda_ver" "$_cuda_recommended"; then
    _CUDA_UPGRADE_NEEDED=true
    log "INFO" "CUDA upgrade: ${_cur_cuda_ver} → ${_cuda_recommended} (compat ajánlott, ${HW_GPU_ARCH}/${HW_OS_CODENAME})"
  fi
fi

# =============================================================================
# INST_* STATE SZINKRONIZÁLÁS
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
  OS:     Ubuntu ${HW_OS_VERSION} (${HW_OS_CODENAME})

  HIBRID:    1 monitor alaplapon (iGPU) + 1 az RTX portján
             PRIME on-demand, Wayland OK, kisebb fogyasztás

  DEDIKÁLT:  minden monitor RTX portjain
             Intel i915 blacklist, X11, max. teljesítmény" \
  18 2 \
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

_cuda_upgrade_txt=""
if $_CUDA_UPGRADE_NEEDED; then
  _cuda_rec=$(compat_get "cuda_recommended" "$HW_GPU_ARCH" "$HW_OS_CODENAME" "13.x")
  _cuda_upgrade_txt="
  ⚡ CUDA UPGRADE: ${COMP_VER[cuda]:-?} → ${_cuda_rec} (compat ajánlott)"
fi

if [ "$_FLOW" = "short" ]; then
  dialog_msg "INFRA ${INFRA_NUM} — ${INFRA_NAME}" "
  GPU:     $HW_GPU_NAME
  OS:      Ubuntu ${HW_OS_VERSION} (${HW_OS_CODENAME})
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
  trap - EXIT; rm -f "$LOCK"; exit 0

else
  log_infra_header "
    • Ubuntu alap + Python fordítási függőségek
    • NVIDIA ${_DRIVER_PKG} (${HW_GPU_ARCH}, SM_${HW_CUDA_ARCH})
    • MOK enrollment + CUDA toolkit + cuDNN 9 + NCCL
    • GPU mód konfig + Docker CE + NVIDIA CTK + initramfs → REBOOT"

  dialog_msg "INFRA ${INFRA_NUM} — ${INFRA_NAME}" "
  GPU:     $HW_GPU_NAME
  OS:      Ubuntu ${HW_OS_VERSION} (${HW_OS_CODENAME})
  Arch:    ${HW_GPU_ARCH} (SM_${HW_CUDA_ARCH})
  Driver:  $_DRIVER_PKG
  Mód:     ${_FLOW}
  ${_mok_status_txt}${_cuda_upgrade_txt}

  Lépések:
    1. Ubuntu alap + Python build deps
    2. NVIDIA ${_DRIVER_PKG}  ← open kernel
    3. MOK enrollment (Secure Boot)
    4. CUDA toolkit$($_CUDA_UPGRADE_NEEDED && echo " [UPGRADE]" || echo "")
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
    nvidia_mok_enroll; _mok_ec=$?
    case $_mok_ec in
      0) ((OK++))
         _mok_final="$(nvidia_mok_status)"
         if [ "$_mok_final" = "pending" ]; then
           _pass="$(infra_state_get "MOK_ENROLL_PASS" "")"
           dialog_msg "⚠  MOK enrollment — Fontos!" "
  REBOOT UTÁN kék/lila UEFI képernyő:
    1. Enroll MOK  2. Continue
    3. Jelszó: ${_pass:-(lásd ~/.infra-state MOK_ENROLL_PASS)}
    4. Yes → Reboot" 16
         fi ;;
      1) ((FAIL++)); log "FAIL" "MOK enrollment sikertelen" ;;
      2) ((SKIP++)); log "SKIP" "MOK.der hiányzik" ;;
    esac
  else
    ((SKIP++)); log "SKIP" "MOK enrollment kihagyva"
  fi

  log "STEP" "━━━ GPU mód konfiguráció ($GPU_MODE) ━━━"
  if ask_proceed "GPU mód konfiguráció?"; then
    if grep -q "01a_system_foundation" "/etc/modprobe.d/99-nvidia-options.conf" 2>/dev/null && \
       grep -q "01a_system_foundation" "/etc/X11/xorg.conf" 2>/dev/null; then
      log "OK" "GPU konfig fájlok naprakészek"; ((OK++))
    else
      _write_gpu_config "$GPU_MODE" && ((OK++)) || ((FAIL++))
    fi
  else
    ((SKIP++)); log "SKIP" "GPU konfig kihagyva"
  fi

  log "STEP" "━━━ initramfs frissítés ━━━"
  if ask_proceed "initramfs frissítése?"; then
    run_with_progress "initramfs" "initramfs újraépítése..." update-initramfs -u -k all
    [ $? -eq 0 ] && ((OK++)) || ((FAIL++))
  else
    ((SKIP++))
  fi

  show_result "$OK" "$SKIP" "$FAIL"
  [ "${OK:-0}" -gt 0 ] && [ "${RUN_MODE:-install}" != "check" ] && {
    infra_state_set "REBOOT_NEEDED"   "true"
    infra_state_set "REBOOT_REASON"   "MOK enrollment + GPU konfig (short path)"
    infra_state_set "REBOOT_BY_INFRA" "$INFRA_NUM"
  }

  [[ "$RUN_MODE" =~ ^(install|update|fix|reinstall)$ ]] && {
    comp_check_nvidia_driver "${MIN_VER[driver]}"
    PATH="/usr/local/cuda/bin:$PATH" comp_check_cuda "${MIN_VER[cuda]}"
    comp_check_cudnn "${MIN_VER[cudnn]}"; comp_check_docker "${MIN_VER[docker]}"
    comp_check_nvidia_ctk "${MIN_VER[nvidia_ctk]}"
    comp_save_state "$INFRA_NUM"; log "COMP" "Post-install COMP state mentve (rövid út)"
  }

  dialog_msg "Rövid út kész — REBOOT szükséges" "
  GPU mód: $GPU_MODE | MOK: $(nvidia_mok_status 2>/dev/null || echo '?')
  ➜  sudo reboot" 12
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

log "STEP" "━━━ 1/7: Alap rendszer csomagok ━━━"

if [ "$_DRV_STATUS" = "missing" ] || [ "$_DRV_STATUS" = "old" ] || \
   [ "$RUN_MODE" = "reinstall" ] || [ "$RUN_MODE" = "update" ]; then

  if ask_proceed "Alap fejlesztői csomagok + Python build deps?"; then
    log "APT" "apt-get update..."
    apt-get -o Acquire::http::Timeout=30 update -qq 2>&1 | tee -a "$LOGFILE_AI" || \
      log "WARN" "apt-get update részleges hiba — gyorsítótárazott lista marad"

    apt_install_progress "Alap csomagok" "Ubuntu alap + Python fordítási függőségek..." \
      --fix-missing ${PKGS[base]} ${PKGS[python_build]}

    if pkg_installed "build-essential" && pkg_installed "liblzma-dev" && \
       pkg_installed "zsh" && pkg_installed "ccze"; then
      ((OK++)); log "OK" "Alap csomagok OK"
    else
      _miss=0
      for _chk in build-essential zsh ccze liblzma-dev; do
        pkg_installed "$_chk" || { ((_miss++)); log "WARN" "Hiányzik: $_chk"; }
      done
      [ "$_miss" -gt 2 ] && ((FAIL++)) || ((SKIP++))
    fi
  else
    ((SKIP++)); log "SKIP" "Alap csomagok kihagyva"
  fi
fi

# =============================================================================
# 2. LÉPÉS — NVIDIA OPEN DRIVER
# =============================================================================
# v6.7 bug fixek:
#   BUG 2 FIX: CTK reset driver install után (nvidia_driver_purge eltávolítja)
#   BUG 3 FIX: INST_DRIVER_VER dpkg-ből frissítve (nem pre-install comp check-ből)

log "STEP" "━━━ 2/7: NVIDIA open driver ($_DRIVER_PKG) ━━━"

if [ "$_DRV_STATUS" = "missing" ] || [ "$_DRV_STATUS" = "old" ] || \
   [ "$RUN_MODE" = "reinstall" ] || $_DPKG_BROKEN; then

  if ask_proceed "NVIDIA ${_DRIVER_PKG} telepítése?"; then

    # Mirror elérhetőség ellenőrzése — ha hu.archive.ubuntu.com le van állva,
    # az archive.ubuntu.com fallback-re váltunk a fő csomagok (libnvidia-egl-wayland1,
    # nvidia-prime stb.) letöltéséhez. A fallback az install után visszaáll.
    apt_mirror_check_fallback "$LOGFILE_AI"

    progress_open "NVIDIA Open Driver — ${_DRIVER_PKG}" "Előkészítés..."

    progress_set 5 "CUDA repo ideiglenes deaktiválása..."
    declare -a _CUDA_REPO_MOVED=()
    for _f in /etc/apt/sources.list.d/cuda*.list /etc/apt/sources.list.d/cuda*.sources; do
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

    # Mirror visszaállítása (ha fallback volt aktív)
    apt_mirror_restore

    if pkg_installed "$_DRIVER_PKG"; then
      log "OK" "NVIDIA driver telepítve: $_DRIVER_PKG"

      # BUG 3 FIX: INST_DRIVER_VER frissítése a tényleges dpkg verzióval
      _inst_drv_ver=$(dpkg-query -f '${Version}\n' -W "$_DRIVER_PKG" 2>/dev/null \
        | grep -oP '^[\d.]+' | head -1)
      [ -n "$_inst_drv_ver" ] && {
        infra_state_set "INST_DRIVER_VER" "$_inst_drv_ver"
        log "STATE" "INST_DRIVER_VER → $_inst_drv_ver (dpkg alapján)"
      }
      infra_state_set "HW_NVIDIA_PKG"        "$_DRIVER_PKG"
      infra_state_set "NVIDIA_DRIVER_PKG"    "$_DRIVER_PKG"
      infra_state_set "NVIDIA_DRIVER_SERIES" "${_DRIVER_SERIES:-?}"

      # BUG 2 FIX: CTK COMP reset — nvidia_driver_purge eltávolítja
      COMP_STATUS[nvidia_ctk]="missing"
      log "INFO" "CTK COMP reset → nvidia_driver_purge eltávolíthatta"
      ((OK++))

    else
      log "FAIL" "NVIDIA driver SIKERTELEN (exit ${_DRV_EC}): $_DRIVER_PKG"

      # dpkg broken state törlése a sikertelen install után.
      # A részlegesen konfigurált csomag (pl. libnvidia-gl-590 unconfigured
      # mert libnvidia-egl-wayland1 hiányzott) blokkolja az összes apt hívást.
      # A --fix-broken install megpróbálja befejezni vagy eltávolítani ezeket.
      log "INFO" "dpkg broken state törlése — failsafe előtt..."
      apt_fix_broken "$LOGFILE_AI"

      log "INFO" "Failsafe: $DRIVER_MIN_PKG_BLACKWELL..."
      DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing \
        -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        "$DRIVER_MIN_PKG_BLACKWELL" >> "$LOGFILE_AI" 2>&1

      if pkg_installed "$DRIVER_MIN_PKG_BLACKWELL"; then
        log "WARN" "Failsafe telepítve: $DRIVER_MIN_PKG_BLACKWELL"
        _fs_ver=$(dpkg-query -f '${Version}\n' -W "$DRIVER_MIN_PKG_BLACKWELL" 2>/dev/null \
          | grep -oP '^[\d.]+' | head -1)
        infra_state_set "HW_NVIDIA_PKG"        "$DRIVER_MIN_PKG_BLACKWELL"
        infra_state_set "NVIDIA_DRIVER_PKG"    "$DRIVER_MIN_PKG_BLACKWELL"
        infra_state_set "NVIDIA_DRIVER_SERIES" "570"
        [ -n "$_fs_ver" ] && infra_state_set "INST_DRIVER_VER" "$_fs_ver"
        COMP_STATUS[nvidia_ctk]="missing"
        _DRIVER_PKG="$DRIVER_MIN_PKG_BLACKWELL"; _DRIVER_SERIES="570"
        dialog_warn "NVIDIA Driver — Failsafe" "
  Fallback: $DRIVER_MIN_PKG_BLACKWELL
  Céldriver ($_DRIVER_PKG) nem volt elérhető.
  Log: $LOGFILE_AI" 14
        ((SKIP++))
      else
        log "FAIL" "Failsafe is sikertelen!"
        dialog_warn "NVIDIA Driver — SÚLYOS HIBA" "
  NE INDÍTSD ÚJRA!  Log: $LOGFILE_AI" 12
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
  nvidia_mok_enroll; _mok_ec=$?
  case $_mok_ec in
    0) ((OK++))
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
       fi ;;
    1) ((FAIL++)); dialog_warn "MOK enrollment sikertelen" \
         "\n  sudo mokutil --import /var/lib/shim-signed/mok/MOK.der" 10 ;;
    2) ((SKIP++)); dialog_warn "MOK.der hiányzik" "\n  sudo dkms autoinstall" 10 ;;
  esac
else
  ((SKIP++)); log "SKIP" "MOK enrollment kihagyva"
fi

# =============================================================================
# 4. LÉPÉS — CUDA TOOLKIT
# =============================================================================
# v6.8: compat_get() alapú CUDA kiválasztás
#
# A korábbi ~40 soros case "$HW_GPU_ARCH" in blackwell)...ada|ampere)... blokk
# helyett egyetlen compat lookup + version_ok() összehasonlítás.
#
# Logika:
#   1. compat_get("cuda_recommended") → az arch+OS-nek megfelelő ajánlott verzió
#   2. cuda_best_available() → legjobb amit az apt-ból el lehet érni
#   3. Ha elérhető >= ajánlott: azt vesszük
#   4. Ha elérhető < ajánlott: ajánlottat próbáljuk, ha az sincs: elérhető fallback
#
# Példa jelenlegi rendszerre (pipi, 2026-04-11):
#   arch=blackwell, codename=noble → cuda_recommended=13.1
#   cuda_best_available() → "13.1" (ha CUDA repo konfigurálva)
#   Eredmény: CUDA 13.1 telepítendő, PyTorch cu128

log "STEP" "━━━ 4/7: CUDA toolkit ━━━"

if [ "${COMP_STATUS[cuda]:-missing}" != "ok" ] || \
   [ "$RUN_MODE" = "reinstall" ] || \
   $_CUDA_UPGRADE_NEEDED; then

  # Upgrade tájékoztató
  if $_CUDA_UPGRADE_NEEDED && [ "${COMP_STATUS[cuda]:-missing}" = "ok" ]; then
    _cuda_rec=$(compat_get "cuda_recommended" "$HW_GPU_ARCH" "$HW_OS_CODENAME" "13.x")
    dialog_msg "CUDA Upgrade szükséges" "
  GPU arch: $HW_GPU_ARCH | OS: Ubuntu ${HW_OS_VERSION} (${HW_OS_CODENAME})
  Telepített CUDA: ${COMP_VER[cuda]:-?}
  Compat ajánlott: $_cuda_rec

  Forrás: NVIDIA CUDA Compatibility r595 (2026-03-31)
    driver 590+ = CUDA 13.1 natív (noble)
    driver 595+ = CUDA 13.2 natív (plucky)

  Méret: ~3.5 GB — a folytatáshoz erősítsd meg." 20
  fi

  # ── CUDA repo pin fájl (KRITIKUS lépés!) ──────────────────────────────────────
  # A cuda-ubuntu2404.pin fájl (priority 600) nélkül az Ubuntu repo 12.6-os
  # csomagjai "nyerik" a prioritásversenyt → 12.8, 13.x csomagok LÁTHATATLANOK!
  # Hatás: apt-cache search cuda-toolkit-13-1 → No results (pin nélkül)
  #         apt-cache search cuda-toolkit-13-1 → Found    (pin fájllal)
  # Forrás: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
  #         Network Repo Installation for Ubuntu (apt-get method, Step 2)
  _CUDA_PIN="/etc/apt/preferences.d/cuda-repository-pin-600"
  if [ ! -f "$_CUDA_PIN" ]; then
    log "INFO" "CUDA pin fájl letöltése (priority 600 — magasabb CUDA verziók láthatóságához)..."
    wget -q       "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-ubuntu2404.pin"       -O "$_CUDA_PIN" >> "$LOGFILE_AI" 2>&1
    if [ $? -eq 0 ]; then
      log "OK" "CUDA pin fájl letöltve (priority 600)"
    else
      # Fallback: saját pin fájl írása ha wget nem sikerül
      log "WARN" "wget sikertelen — fallback pin fájl írása..."
      cat > "$_CUDA_PIN" << 'PINEOF'
# INFRA 01a — CUDA repository pin (priority 600)
# Forrás: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-ubuntu2404.pin
Package: *
Pin: origin developer.download.nvidia.com
Pin-Priority: 600
PINEOF
      log "OK" "Fallback CUDA pin fájl létrehozva: $_CUDA_PIN"
    fi
  else
    log "APT" "CUDA pin fájl már létezik: $_CUDA_PIN"
  fi

  # ── CUDA keyring + repo ────────────────────────────────────────────────────────
  # cuda-keyring csomag: GPG kulcs + sources.list.d bejegyzés (NVIDIA official módszer)
  # apt-key adv helyett — az deprecated Ubuntu 22.04+ óta
  if ! dpkg -l cuda-keyring 2>/dev/null | grep -q "^ii" ||      ! source_exists "developer.download.nvidia.com/compute/cuda"; then
    log "INFO" "CUDA keyring telepítése..."
    run_with_progress "CUDA Repo" "CUDA keyring letöltése..."       bash -c "wget -q '${CUDA_KEYRING_URL}' -O /tmp/cuda-keyring.deb                && DEBIAN_FRONTEND=noninteractive dpkg -i /tmp/cuda-keyring.deb                && rm -f /tmp/cuda-keyring.deb"
    [ $? -eq 0 ]       && log "OK" "CUDA keyring konfigurálva"       || { log "FAIL" "CUDA keyring sikertelen"; ((FAIL++)); }
  fi

  log "APT" "apt-get update (CUDA repo frissítve)..."
  apt-get -o Acquire::http::Timeout=30 update -qq >> "$LOGFILE_AI" 2>&1 || true
  log "OK" "CUDA repo konfigurálva"

  _best_cuda="$(cuda_best_available)"
  log "INFO" "Legjobb elérhető CUDA: ${_best_cuda:-nem találat}"

  if [ -z "$_best_cuda" ]; then
    log "WARN" "Nincs elérhető CUDA csomag"
    dialog_warn "CUDA — Nem elérhető" \
      "\n  Nincs cuda-toolkit-* csomag.\n  CUDA repo konfig ellenőrzése." 10
    ((SKIP++))
  else
    # ── v6.8: compat_get() alapú CUDA kiválasztás ────────────────────────────
    _CUDA_RECOMMENDED=$(compat_get "cuda_recommended" "$HW_GPU_ARCH" "$HW_OS_CODENAME" "12.6")
    _CUDA_PYTORCH_IDX=$(compat_get "pytorch_index" "$HW_GPU_ARCH" "$HW_OS_CODENAME" \
      "$(cuda_pytorch_index "$_best_cuda")")

    # Összehasonlítás: elérhető vs. ajánlott
    if version_ok "$_best_cuda" "$_CUDA_RECOMMENDED"; then
      # Legjobb elérhető >= ajánlott → azt vesszük
      _CUDA_VER="$_best_cuda"
      log "INFO" "CUDA: elérhető (${_best_cuda}) >= ajánlott (${_CUDA_RECOMMENDED}) [compat]"
    else
      # Elérhető < ajánlott → az ajánlott package elérhető-e?
      _rec_pkg="cuda-toolkit-$(echo "$_CUDA_RECOMMENDED" | tr '.' '-')"
      if apt-cache show "$_rec_pkg" &>/dev/null; then
        _CUDA_VER="$_CUDA_RECOMMENDED"
        log "INFO" "CUDA: ajánlott ${_CUDA_RECOMMENDED} elérhető → telepítendő [compat]"
      else
        _CUDA_VER="$_best_cuda"
        log "WARN" "CUDA: ajánlott ${_CUDA_RECOMMENDED} nem elérhető → fallback: ${_best_cuda}"
      fi
    fi

    _cuda_key="cuda_$(echo "$_CUDA_VER" | tr '.' '_')"
    _CUDA_PKGS="${PKGS[$_cuda_key]:-${PKGS[cuda_12_6]}}"
    _CUDA_PY_IDX="${_CUDA_PYTORCH_IDX:-$(cuda_pytorch_index "$_CUDA_VER")}"
    log "INFO" "Compat CUDA: $_CUDA_VER | PyTorch: $_CUDA_PY_IDX (${HW_GPU_ARCH}/${HW_OS_CODENAME})"

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
# ── CUDA toolkit PATH — 01a_system_foundation ──
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

        # ── update-alternatives regisztrálás ─────────────────────────────────
        # Minden telepített CUDA verzió regisztrálása az update-alternatives
        # rendszerbe → lehetővé teszi a gyors verzióváltást:
        #   sudo update-alternatives --config cuda
        # Forrás: update-alternatives(1) man page
        # Prioritás: major*10 + minor (pl. 13.1 → 131, 12.8 → 128, 12.6 → 126)
        log "INFO" "CUDA update-alternatives regisztrálása..."
        _alts_registered=0
        for _cuda_alt_dir in /usr/local/cuda-*/; do
          [ -d "$_cuda_alt_dir" ] || continue
          _cuda_alt_ver="${_cuda_alt_dir##*/cuda-}"
          _cuda_alt_ver="${_cuda_alt_ver%/}"
          _vmaj=$(echo "$_cuda_alt_ver" | cut -d. -f1)
          _vmin=$(echo "$_cuda_alt_ver" | cut -d. -f2)
          _vpri=$(( _vmaj * 10 + _vmin ))
          if update-alternatives --install /usr/local/cuda cuda                "$_cuda_alt_dir" "$_vpri" >> "$LOGFILE_AI" 2>&1; then
            log "INFO" "  CUDA alt: $_cuda_alt_ver (prioritás: $_vpri)"
            (( _alts_registered++ ))
          fi
        done

        if [ "$_alts_registered" -gt 0 ]; then
          # Aktív verzió = most telepített (_CUDA_VER / _INST_VER)
          _set_ver="${_CUDA_VER:-$_INST_VER}"
          if [ -d "/usr/local/cuda-${_set_ver}" ]; then
            update-alternatives --set cuda "/usr/local/cuda-${_set_ver}"               >> "$LOGFILE_AI" 2>&1 ||               update-alternatives --auto cuda >> "$LOGFILE_AI" 2>&1 || true
            log "OK" "Aktív CUDA: ${_set_ver} — váltás: sudo update-alternatives --config cuda"
          else
            update-alternatives --auto cuda >> "$LOGFILE_AI" 2>&1 || true
            log "OK" "CUDA update-alternatives beállítva (auto mód)"
          fi
        fi

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
    _IDX="$(compat_get "pytorch_index" "$HW_GPU_ARCH" "$HW_OS_CODENAME" "$(cuda_pytorch_index "$_SYNC")")"
    _CURR="$(infra_state_get "PYTORCH_INDEX" "cu126")"
    [ "$_CURR" != "$_IDX" ] && {
      infra_state_set "CUDA_VER" "$_SYNC"
      infra_state_set "INST_CUDA_VER" "$_SYNC"
      infra_state_set "PYTORCH_INDEX" "$_IDX"
      log "STATE" "CUDA state szinkronizálva: $_SYNC → $_IDX [compat]"
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
# 01a_system_foundation v6.12 — Nouveau blacklist
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
BEOF

  cat > /etc/modprobe.d/99-nvidia-options.conf << 'MEOF'
# 01a_system_foundation v6.12 — NVIDIA kernel modul opciók
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
# 01a_system_foundation v6.12 — Hibrid GPU mód
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
# 01a_system_foundation v6.12 — Intel iGPU blacklist
blacklist i915
blacklist intel_agp
BEOF
    cat > /etc/X11/xorg.conf << 'XEOF'
# 01a_system_foundation v6.12 — Dedikált GPU mód
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
# v6.7 BUG 2 FIX: COMP_STATUS[nvidia_ctk]="missing" ha driver install futott
# → CTK mindig reinstallálódik driver upgrade után

log "STEP" "━━━ 6/7: Docker CE ━━━"

if [ "${COMP_STATUS[docker]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  if ask_proceed "Docker CE telepítése?"; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "${URLS[docker_gpg]}" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
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

if [ "${COMP_STATUS[nvidia_ctk]:-missing}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  # CTK telepítés előtt: dpkg broken state javítás
  # Eset: libnvidia-gl-590 unconfigured (libnvidia-egl-wayland1 nem volt letölthető)
  # → minden apt hívás "Unmet dependencies" hibával bukik amíg javítva nincs
  # "not installable" = APT cache-ben sincs a csomag → apt update + fix-broken kell
  if $_DPKG_BROKEN || dpkg --audit 2>/dev/null | grep -qi "nvidia\|libnvidia"; then
    log "INFO" "CTK előkészítés: dpkg broken state javítása..."
    apt_mirror_check_fallback "$LOGFILE_AI"
    log "APT" "apt-get update (CTK broken state fix előtt)..."
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::http::Timeout=20       update -qq >> "$LOGFILE_AI" 2>&1 || true
    apt_fix_broken "$LOGFILE_AI"
    apt_mirror_restore
    _DPKG_BROKEN=false  # javítás után reset
    log "INFO" "CTK előkészítés kész — dpkg state javítva"
  fi

  if ask_proceed "NVIDIA Container Toolkit telepítése?"; then
    curl -fsSL "${URLS[nvidia_ctk_gpg]}" \
      | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

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
      log "INFO" "nvidia-cdi-refresh.service hiba VÁRHATÓ pre-reboot — normális"
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
  run_with_progress "initramfs" "initramfs újraépítése minden kernelre..." \
    update-initramfs -u -k all
  _ec=$?
  [ $_ec -eq 0 ] && ((OK++)) || {
    ((FAIL++)); log "FAIL" "initramfs SIKERTELEN (exit $_ec)"
    dialog_warn "initramfs — Hiba" "\n  sudo update-initramfs -u -k all" 10
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

  # MOD_01A_DONE: csak ha nincs FAIL — biztosítja hogy 01b csak sikeres
  # install után fut le. Ha FAIL>0 (pl. CTK hiányzik), a flag nem kerül
  # beállításra → a következő 01a futás újra megpróbálja a hiányzó lépéseket.
  # MOD_01A_REBOOTED-t a 01b script indulása állítja be.
  if [ "${FAIL:-0}" -eq 0 ]; then
    infra_state_set "MOD_01A_DONE" "true"
    log "STATE" "MOD_01A_DONE=true → 01b_post_reboot.sh futtatható REBOOT után"
  else
    log "WARN" "FAIL=$FAIL → MOD_01A_DONE NEM kerül beállításra (hibás lépések)"
    log "WARN" "Következő 01a futás javítja a hiányzó komponenseket"
    # Ha volt korábban MOD_01A_DONE (pl. előző futásból), töröljük
    infra_state_set "MOD_01A_DONE" ""
  fi
fi
infra_state_show

if [[ "$RUN_MODE" =~ ^(install|update|fix|reinstall)$ ]]; then
  log "COMP" "Post-install re-check (mód: $RUN_MODE)..."
  comp_check_nvidia_driver "${MIN_VER[driver]}"
  PATH="/usr/local/cuda/bin:$PATH" comp_check_cuda "${MIN_VER[cuda]}"
  comp_check_cudnn "${MIN_VER[cudnn]}"
  comp_check_docker "${MIN_VER[docker]}"
  comp_check_nvidia_ctk "${MIN_VER[nvidia_ctk]}"
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
  dialog_msg "Következő lépések — INFRA ${INFRA_NUM}" "
  GPU mód: $GPU_MODE
  Driver:  $_DRIVER_PKG
  CUDA:    $(infra_state_get "CUDA_VER" "?")
  PyTorch: $(infra_state_get "PYTORCH_INDEX" "?")
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
  Újraindítjuk?" 14 && { log "REBOOT" "Azonnali reboot"; reboot; }
  fi
fi

trap - EXIT; rm -f "$LOCK"
log "DONE" "INFRA ${INFRA_NUM} befejezve: OK=$OK SKIP=$SKIP FAIL=$FAIL"
