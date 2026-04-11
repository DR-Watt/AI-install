#!/bin/bash
# ============================================================================
# 00_lib_hw.sh — Vibe Coding Workspace lib v6.5
#
# LEÍRÁS: Hardver detektálás: GPU/CPU profil, NVIDIA driver, hw_detect/show/has_nvidia
# BETÖLTÉS: source-olja a 00_lib.sh master loader (00_lib_compat.sh UTÁN!)
# NE futtasd közvetlenül!
#
# VÁLTOZTATÁSOK v6.5 (compat mátrix integráció):
#   - hw_detect() elején OS verzió detektálás (lsb_release)
#     → HW_OS_CODENAME és HW_OS_VERSION exportálva
#   - Architektúra ágakban HW_NVIDIA_PKG, HW_VLLM_OK, HW_TURBOQUANT_MODE
#     hardkódolt értékek → compat_get() hívások
#     Így a driver/CUDA ajánlás az OS-nek megfelelő értéket adja vissza
#   - Section 9 (driver pontosítás): nvidia-open (590+ névformátum) keresése hozzáadva
#     A dpkg override továbbra is prioritást élvez a compat ajánlással szemben
# ============================================================================

# SZEKCIÓ 6 — HARDVER DETEKTÁLÁS
# =============================================================================
#
# HW PROFIL MÁTRIX — mit enged meg az egyes profil:
#
#  Profil            | NVIDIA driver | CUDA | vLLM | Docker GPU | CPU Ollama
#  ------------------|---------------|------|------|------------|----------
#  desktop-rtx       | igen          | igen | igen | igen       | igen
#  desktop-rtx-old   | igen          | igen | nem  | igen       | igen
#  notebook-rtx      | igen (Optimus)| igen | igen | igen       | igen
#  notebook-igpu     | nem           | nem  | nem  | nem        | igen
#  desktop-igpu      | nem           | nem  | nem  | nem        | igen
#
# NVIDIA GPU generációk és SM számok:
#   Blackwell   SM_120  — RTX 5090/5080/5070 (2024-)
#   Ada Lovelace SM_89  — RTX 4090/4080/4070 (2022-)
#   Ampere      SM_86   — RTX 3090/3080/3070 (2020-)
#   Turing      SM_75   — RTX 2080/2070 (2018-)
#   Pascal      SM_61   — GTX 1080/1070 (2016-)

hw_detect() {
  log "HW" "Hardver detektálás indítva..."

  # ── 0. OS verzió detektálás ─────────────────────────────────────────────────
  # Szükséges a compat_get() hívásokhoz — OS-specifikus driver/CUDA ajánlások
  # Forrás: lsb_release (ubuntu-specific, minden Ubuntu-n elérhető)
  HW_OS_CODENAME=$(lsb_release -cs 2>/dev/null || echo "noble")
  HW_OS_VERSION=$(lsb_release -rs 2>/dev/null || echo "24.04")
  log "HW" "OS: Ubuntu ${HW_OS_VERSION} (${HW_OS_CODENAME})"

  # ── 1. Chassis típus (notebook azonosítás) ─────────────────────────────────
  local chassis
  chassis=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo "0")
  local is_notebook=false
  [[ "$chassis" =~ ^(8|9|10|11|14)$ ]] && is_notebook=true
  HW_IS_NOTEBOOK="$is_notebook"

  # ── 2. GPU-k összegyűjtése ────────────────────────────────────────────────
  local all_gpus
  all_gpus=$(lspci -nn 2>/dev/null | grep -iE "VGA|3D controller|Display controller")

  # ── 3. NVIDIA GPU azonosítás ───────────────────────────────────────────────
  local nvidia_line nvidia_pci_id
  nvidia_line=$(echo "$all_gpus" | grep -i "10de:" | head -1)
  nvidia_pci_id=$(echo "$nvidia_line" \
    | grep -oP '(?<=10de:)[0-9a-fA-F]+' | head -1 \
    | tr '[:upper:]' '[:lower:]')

  # ── 4. iGPU azonosítás ────────────────────────────────────────────────────
  local igpu_line
  igpu_line=$(echo "$all_gpus" | grep -ivE "10de:" | head -1)
  HW_GPU_IGPU=$(echo "$igpu_line" \
    | sed 's/.*: //' | sed 's/ \[.*//' | cut -c1-40)

  # ── 5. NVIDIA architektúra azonosítás PCI ID prefix alapján ───────────────
  local is_nvidia=false
  local is_blackwell=false is_ada=false is_ampere=false
  local is_turing=false is_pascal=false is_nvidia_old=false

  if [ -n "$nvidia_pci_id" ]; then
    is_nvidia=true
    case "${nvidia_pci_id:0:2}" in
      2b|2c) is_blackwell=true ;;
      26|27) is_ada=true ;;
      20|21) is_ampere=true ;;
      1e|1f|2d) is_turing=true ;;
      1b|1c|1d) is_pascal=true ;;
      *) is_nvidia_old=true ;;
    esac
  fi

  # ── 6. GPU név (PCI ID fallback táblázat) ─────────────────────────────────
  declare -A _GPU_NAMES=(
    ["2b85"]="NVIDIA GeForce RTX 5090"
    ["2b87"]="NVIDIA GeForce RTX 5080"
    ["2b89"]="NVIDIA GeForce RTX 5070 Ti"
    ["2b8c"]="NVIDIA GeForce RTX 5070"
    ["2c85"]="NVIDIA GeForce RTX 5090 D"
    ["2684"]="NVIDIA GeForce RTX 4090"
    ["2702"]="NVIDIA GeForce RTX 4080 Super"
    ["2782"]="NVIDIA GeForce RTX 4070 Ti Super"
    ["27b8"]="NVIDIA GeForce RTX 4060 Ti"
    ["2204"]="NVIDIA GeForce RTX 3090"
    ["2206"]="NVIDIA GeForce RTX 3080"
    ["2484"]="NVIDIA GeForce RTX 3070"
  )

  local nvidia_name
  nvidia_name=$(echo "$nvidia_line" | sed 's/.*: //' | sed 's/ \[.*//' | cut -c1-50)
  if echo "$nvidia_name" | grep -qE "^NVIDIA Corporation Device|^NVIDIA Corporation$"; then
    nvidia_name="${_GPU_NAMES[$nvidia_pci_id]:-NVIDIA GPU ($nvidia_pci_id)}"
  fi

  # ── 7. Hibrid mód detektálás ──────────────────────────────────────────────
  HW_HYBRID=false
  if $is_nvidia && echo "$all_gpus" | grep -iqE "8086:|1002:"; then
    HW_HYBRID=true
  fi

  # ── 8. Profil meghatározás (compat mátrix alapján) ────────────────────────
  # v6.5 változás: HW_NVIDIA_PKG, HW_VLLM_OK, HW_TURBOQUANT_MODE értékei
  # compat_get() hívásokból jönnek az OS-nek megfelelően, NEM hardkódolva.
  # Ez biztosítja hogy Ubuntu 24.04 és 26.04 eltérő driver/CUDA ajánlást kap.

  if $is_blackwell; then
    HW_PROFILE="desktop-rtx"
    HW_GPU_NAME="$nvidia_name (Blackwell SM_120)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="blackwell"
    HW_CUDA_ARCH="120"
    HW_NVIDIA_OPEN=true    # Blackwell KÖTELEZŐ open modul
    HW_NVIDIA_PKG=$(compat_get "driver_pkg" "blackwell" "$HW_OS_CODENAME" "nvidia-driver-570-open")
    # vllm_support: "yes"/"partial"/"no" → bash true/false
    compat_vllm_ok "blackwell" "$HW_OS_CODENAME" && HW_VLLM_OK=true || HW_VLLM_OK=false
    HW_TURBOQUANT_MODE=$(compat_get "turboquant_mode" "blackwell" "$HW_OS_CODENAME" "gpu120")
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_ada; then
    HW_PROFILE="desktop-rtx"
    HW_GPU_NAME="$nvidia_name (Ada Lovelace SM_89)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="ada"
    HW_CUDA_ARCH="89"
    HW_NVIDIA_OPEN=false
    HW_NVIDIA_PKG=$(compat_get "driver_pkg" "ada" "$HW_OS_CODENAME" "nvidia-driver-590-open")
    compat_vllm_ok "ada" "$HW_OS_CODENAME" && HW_VLLM_OK=true || HW_VLLM_OK=false
    HW_TURBOQUANT_MODE=$(compat_get "turboquant_mode" "ada" "$HW_OS_CODENAME" "gpu89")
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_ampere; then
    HW_PROFILE="desktop-rtx"
    HW_GPU_NAME="$nvidia_name (Ampere SM_86)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="ampere"
    HW_CUDA_ARCH="86"
    HW_NVIDIA_OPEN=false
    HW_NVIDIA_PKG=$(compat_get "driver_pkg" "ampere" "$HW_OS_CODENAME" "nvidia-driver-590-open")
    compat_vllm_ok "ampere" "$HW_OS_CODENAME" && HW_VLLM_OK=true || HW_VLLM_OK=false
    HW_TURBOQUANT_MODE=$(compat_get "turboquant_mode" "ampere" "$HW_OS_CODENAME" "gpu86")
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_turing; then
    HW_PROFILE="desktop-rtx-old"
    HW_GPU_NAME="$nvidia_name (Turing SM_75)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="turing"
    HW_CUDA_ARCH="75"
    HW_NVIDIA_OPEN=false
    HW_NVIDIA_PKG=$(compat_get "driver_pkg" "turing" "$HW_OS_CODENAME" "nvidia-driver-590-open")
    compat_vllm_ok "turing" "$HW_OS_CODENAME" && HW_VLLM_OK=true || HW_VLLM_OK=false
    HW_TURBOQUANT_MODE=$(compat_get "turboquant_mode" "turing" "$HW_OS_CODENAME" "gpu75")
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_pascal; then
    HW_PROFILE="desktop-rtx-old"
    HW_GPU_NAME="$nvidia_name (Pascal SM_61)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="pascal"
    HW_CUDA_ARCH="61"
    HW_NVIDIA_OPEN=false
    HW_NVIDIA_PKG=$(compat_get "driver_pkg" "pascal" "$HW_OS_CODENAME" "nvidia-driver-590-open")
    compat_vllm_ok "pascal" "$HW_OS_CODENAME" && HW_VLLM_OK=true || HW_VLLM_OK=false
    HW_TURBOQUANT_MODE=$(compat_get "turboquant_mode" "pascal" "$HW_OS_CODENAME" "cpu")
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_nvidia_old; then
    HW_PROFILE="desktop-rtx-old"
    HW_GPU_NAME="$nvidia_name"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="nvidia-unknown"
    HW_CUDA_ARCH="native"
    HW_NVIDIA_OPEN=false
    HW_NVIDIA_PKG=$(compat_get "driver_pkg" "nvidia-unknown" "$HW_OS_CODENAME" "nvidia-driver-590-open")
    HW_VLLM_OK=false
    HW_TURBOQUANT_MODE=$(compat_get "turboquant_mode" "nvidia-unknown" "$HW_OS_CODENAME" "cpu")
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_notebook; then
    HW_PROFILE="notebook-igpu"
    HW_GPU_NAME="${HW_GPU_IGPU:-Integrált GPU}"
    HW_GPU_PCI=""
    HW_GPU_ARCH="igpu"
    HW_VLLM_OK=false
    HW_NVIDIA_OPEN=false
    HW_CUDA_ARCH=""
    HW_NVIDIA_PKG=""
    HW_TURBOQUANT_MODE="cpu_only"

  else
    HW_PROFILE="desktop-igpu"
    HW_GPU_NAME="${HW_GPU_IGPU:-Integrált GPU}"
    HW_GPU_PCI=""
    HW_GPU_ARCH="igpu"
    HW_VLLM_OK=false
    HW_NVIDIA_OPEN=false
    HW_CUDA_ARCH=""
    HW_NVIDIA_PKG=""
    HW_TURBOQUANT_MODE="cpu_only"
  fi

  # ── 9. NVIDIA driver csomagnév pontosítása ────────────────────────────────
  # A section 8 compat_get()-ből adja az AJÁNLOTT drivert.
  # Ez a blokk felülírja azzal ami TÉNYLEGESEN TELEPÍTVE VAN (dpkg),
  # vagy az apt-cache alapján elérhető maximummal ha semmi nincs telepítve.
  # PRIORITÁS: dpkg (tényleges) > apt-cache max > compat ajánlott > arch alap

  if hw_has_nvidia 2>/dev/null || $is_nvidia; then
    # A. Ténylegesen telepített nvidia-driver-*-open
    local _inst_open
    _inst_open=$(dpkg -l 'nvidia-driver-*-open' 2>/dev/null \
                 | awk '/^ii/{print $2}' | sort -V | tail -1)

    # B. Ténylegesen telepített nvidia-driver-* (zárt, nem-open)
    # FONTOS: awk-ban a && NEM mehet regex blokkon belül!
    local _inst_closed
    _inst_closed=$(dpkg -l 'nvidia-driver-[0-9]*' 2>/dev/null \
                   | awk '/^ii/ && !/open/{print $2}' | sort -V | tail -1)

    # C. 590+ új névformátum: nvidia-open (branch-szám nélkül)
    # Forrás: NVIDIA Driver Installation Guide r595 — "Ubuntu 590 and later packages"
    local _inst_new_naming
    _inst_new_naming=$(dpkg -l 'nvidia-open' 2>/dev/null \
                       | awk '/^ii/{print $2}' | head -1)

    if [ -n "$_inst_open" ]; then
      HW_NVIDIA_PKG="$_inst_open"
      log "HW" "Driver (dpkg-open): $_inst_open"
    elif [ -n "$_inst_new_naming" ]; then
      HW_NVIDIA_PKG="$_inst_new_naming"
      log "HW" "Driver (dpkg-nvidia-open): $_inst_new_naming"
    elif [ -n "$_inst_closed" ] && ! $HW_NVIDIA_OPEN; then
      HW_NVIDIA_PKG="$_inst_closed"
      log "HW" "Driver (dpkg-closed): $_inst_closed"
    else
      # Semmi nincs telepítve → apt-cache: legmagasabb elérhető sorozat
      local _avail_series
      _avail_series=$(apt-cache search '^nvidia-driver-[0-9]' 2>/dev/null \
                      | grep -oP 'nvidia-driver-\K[0-9]+' | sort -n | tail -1)
      if [ -n "$_avail_series" ]; then
        if $HW_NVIDIA_OPEN; then
          HW_NVIDIA_PKG="nvidia-driver-${_avail_series}-open"
        else
          HW_NVIDIA_PKG="nvidia-driver-${_avail_series}"
        fi
        log "HW" "Driver (apt-cache, max sorozat): $HW_NVIDIA_PKG"
      elif apt-cache show nvidia-open &>/dev/null; then
        # 590+ új névformátum — nincs nvidia-driver-XXX-open de van nvidia-open
        HW_NVIDIA_PKG="nvidia-open"
        log "HW" "Driver (apt-cache, nvidia-open): nvidia-open (590+ naming)"
      fi
      # Ha apt-cache sem talál semmit, a compat ajánlott marad (section 8-ból)
    fi
  fi

  # Exportálás
  export HW_PROFILE HW_GPU_NAME HW_GPU_PCI HW_GPU_IGPU HW_GPU_ARCH
  export HW_VLLM_OK HW_NVIDIA_OPEN HW_CUDA_ARCH HW_HYBRID HW_NVIDIA_PKG
  export HW_IS_NOTEBOOK HW_OS_CODENAME HW_OS_VERSION HW_TURBOQUANT_MODE

  log "HW" "Profil:   $HW_PROFILE"
  log "HW" "dGPU:     ${HW_GPU_NAME:-—}"
  log "HW" "iGPU:     ${HW_GPU_IGPU:-—}"
  log "HW" "vLLM:     $HW_VLLM_OK | CUDA arch: ${HW_CUDA_ARCH:-—} | Driver: ${HW_NVIDIA_PKG:-—}"
  log "HW" "TurboQuant mód: ${HW_TURBOQUANT_MODE:-—}"
  log "HW" "Hibrid:   $HW_HYBRID | Notebook: $HW_IS_NOTEBOOK"
}

hw_show() {
  local gpu_accel_txt cuda_txt driver_txt hybrid_txt vibe_txt ollama_txt

  if hw_has_nvidia; then
    gpu_accel_txt="✓ GPU gyorsítás (NVIDIA)"
    cuda_txt="SM_${HW_CUDA_ARCH}"
    local _smi_ver
    _smi_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
               | head -1 | tr -d ' ')
    if echo "${_smi_ver:-}" | grep -qE '^[0-9][0-9.]+$'; then
      driver_txt="$HW_NVIDIA_PKG (v${_smi_ver})"
    else
      driver_txt="$HW_NVIDIA_PKG"
    fi
    ollama_txt="✓ GPU + CPU"
  else
    gpu_accel_txt="— Csak CPU"
    cuda_txt="—"
    driver_txt="nem szükséges"
    ollama_txt="✓ CPU-only"
  fi

  $HW_HYBRID  && hybrid_txt="igen (${HW_GPU_IGPU:-iGPU} + dGPU)" || hybrid_txt="nem"
  $HW_VLLM_OK && vibe_txt="✓ Teljes (GPU)" || vibe_txt="✓ Alap (CPU)"

  dialog_msg "Hardver detektálás eredménye" "
  Profil:        $HW_PROFILE
  dGPU:          ${HW_GPU_NAME:-—}
  iGPU:          ${HW_GPU_IGPU:-—}
  OS:            Ubuntu ${HW_OS_VERSION} (${HW_OS_CODENAME})
  CUDA arch:     $cuda_txt
  TurboQuant:    ${HW_TURBOQUANT_MODE:-—}
  Hibrid:        $hybrid_txt
  Driver pkg:    $driver_txt

  ── INFRA elérhetőség ──────────────────────────────
  01a System Foundation     $(hw_has_nvidia && echo '✓' || echo '— (kihagyható)')
  01b User Environment      ✓ (minden hardveren)
  02  Lokális AI (vLLM)     $($HW_VLLM_OK && echo '✓ GPU' || echo '— CPU-only Ollama')
  03  Python + PyTorch       ✓ ($gpu_accel_txt)
  04  Node.js + TypeScript   ✓ (hardverfüggetlen)
  05  C64 toolchain          ✓ (hardverfüggetlen)
  06  VS Code + CLINE        ✓ (hardverfüggetlen)
  07  Sysadmin               ✓ (hardverfüggetlen)
  08  NAS scriptek           ✓ (hardverfüggetlen)
  ────────────────────────────────────────────────" 30
}

hw_has_nvidia() {
  case "$HW_PROFILE" in
    desktop-rtx|desktop-rtx-old|notebook-rtx) return 0 ;;
    *) return 1 ;;
  esac
}

hw_capability() {
  local cap="$1"
  case "$cap" in
    cuda|nvidia_driver)
      hw_has_nvidia && echo "true" || echo "false" ;;
    vllm|docker_gpu)
      $HW_VLLM_OK && echo "true" || echo "false" ;;
    ollama)
      echo "true" ;;
    cpu_only)
      hw_has_nvidia && echo "false" || echo "true" ;;
    *)
      echo "false" ;;
  esac
}
