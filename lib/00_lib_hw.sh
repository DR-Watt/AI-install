#!/bin/bash
# ============================================================================
# 00_lib_hw.sh — Vibe Coding Workspace lib v6.4
#
# LEÍRÁS: Hardver detektálás: GPU/CPU profil, NVIDIA driver, hw_detect/show/has_nvidia
# BETÖLTÉS: source-olja a 00_lib.sh master loader
# NE futtasd közvetlenül!
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
#   Blackwell   SM_120  — RTX 5090/5080/5070 (2024-)    → PCI prefix: 2b,2c
#   Ada Lovelace SM_89  — RTX 4090/4080/4070 (2022-)    → PCI prefix: 26,27
#   Ampere      SM_86   — RTX 3090/3080/3070 (2020-)    → PCI prefix: 20,21
#   Turing      SM_75   — RTX 2080/2070 (2018-)         → PCI prefix: 1e,1f,2d
#   Pascal      SM_61   — GTX 1080/1070 (2016-)         → PCI prefix: 1b,1c
# (Pascal és alatta: vLLM nem támogatott)

hw_detect() {
  log "HW" "Hardver detektálás indítva..."

  # ── 1. Chassis típus (notebook azonosítás) ─────────────────────────────────
  # DMI chassis type kódok: 8=Portable, 9=Laptop, 10=Notebook,
  #   11=Hand Held, 14=Sub Notebook
  local chassis
  chassis=$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo "0")
  local is_notebook=false
  [[ "$chassis" =~ ^(8|9|10|11|14)$ ]] && is_notebook=true
  HW_IS_NOTEBOOK="$is_notebook"

  # ── 2. GPU-k összegyűjtése ────────────────────────────────────────────────
  # Minden VGA/3D/Display PCI eszközt összegyűjtünk
  local all_gpus
  all_gpus=$(lspci -nn 2>/dev/null | grep -iE "VGA|3D controller|Display controller")

  # ── 3. NVIDIA GPU azonosítás ───────────────────────────────────────────────
  # Vendor ID 10de = NVIDIA. Az első NVIDIA eszközt vesszük (ha több van, az első dGPU)
  local nvidia_line nvidia_pci_id
  nvidia_line=$(echo "$all_gpus" | grep -i "10de:" | head -1)
  nvidia_pci_id=$(echo "$nvidia_line" \
    | grep -oP '(?<=10de:)[0-9a-fA-F]+' | head -1 \
    | tr '[:upper:]' '[:lower:]')

  # ── 4. iGPU azonosítás ────────────────────────────────────────────────────
  # Intel=8086, AMD=1002 — ami nem NVIDIA
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
      2b|2c) is_blackwell=true ;;               # Blackwell SM_120
      26|27) is_ada=true ;;                     # Ada Lovelace SM_89
      20|21) is_ampere=true ;;                  # Ampere SM_86
      1e|1f|2d) is_turing=true ;;              # Turing SM_75
      1b|1c|1d) is_pascal=true ;;              # Pascal SM_61
      *) is_nvidia_old=true ;;                  # Régebbi
    esac
  fi

  # ── 6. GPU név (PCI ID fallback táblázat) ─────────────────────────────────
  # Új GPU-k nem szerepelnek az lspci adatbázisában → fallback táblázat
  declare -A _GPU_NAMES=(
    # Blackwell
    ["2b85"]="NVIDIA GeForce RTX 5090"
    ["2b87"]="NVIDIA GeForce RTX 5080"
    ["2b89"]="NVIDIA GeForce RTX 5070 Ti"
    ["2b8c"]="NVIDIA GeForce RTX 5070"
    ["2c85"]="NVIDIA GeForce RTX 5090 D"
    # Ada Lovelace
    ["2684"]="NVIDIA GeForce RTX 4090"
    ["2702"]="NVIDIA GeForce RTX 4080 Super"
    ["2782"]="NVIDIA GeForce RTX 4070 Ti Super"
    ["27b8"]="NVIDIA GeForce RTX 4060 Ti"
    # Ampere
    ["2204"]="NVIDIA GeForce RTX 3090"
    ["2206"]="NVIDIA GeForce RTX 3080"
    ["2484"]="NVIDIA GeForce RTX 3070"
  )

  local nvidia_name
  nvidia_name=$(echo "$nvidia_line" | sed 's/.*: //' | sed 's/ \[.*//' | cut -c1-50)
  # Ha az lspci "NVIDIA Corporation Device XXXX" formátumot ad (nincs a DB-ben):
  if echo "$nvidia_name" | grep -qE "^NVIDIA Corporation Device|^NVIDIA Corporation$"; then
    nvidia_name="${_GPU_NAMES[$nvidia_pci_id]:-NVIDIA GPU ($nvidia_pci_id)}"
  fi

  # ── 7. Hibrid mód detektálás ──────────────────────────────────────────────
  # Hibrid = iGPU + dGPU egyszerre aktív (Optimus/Prime laptop vagy hibrid asztali)
  HW_HYBRID=false
  if $is_nvidia && echo "$all_gpus" | grep -iqE "8086:|1002:"; then
    HW_HYBRID=true
  fi

  # ── 8. Profil meghatározás ────────────────────────────────────────────────
  # Prioritás: Blackwell > Ada > Ampere > Turing > Pascal > régi NVIDIA > notebook-igpu > desktop-igpu

  if $is_blackwell; then
    # ──────────────────────────────────────────────────────────────────────────
    # Blackwell (RTX 5090/5080/5070) — SM_120
    # KÖTELEZŐ: nvidia-driver-570-open (open kernel modul)
    # CUDA 12.8+ szükséges SM_120 natív támogatáshoz; 12.6 SM_89 fallbackkel fut
    # ──────────────────────────────────────────────────────────────────────────
    HW_PROFILE="desktop-rtx"
    HW_GPU_NAME="$nvidia_name (Blackwell SM_120)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="blackwell"
    HW_VLLM_OK=true
    HW_NVIDIA_OPEN=true    # Blackwell CSAK open modulal működik
    HW_CUDA_ARCH="120"
    HW_NVIDIA_PKG="nvidia-driver-570-open"
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_ada; then
    # ──────────────────────────────────────────────────────────────────────────
    # Ada Lovelace (RTX 4090/4080/4070) — SM_89
    # CUDA 12.x-szel teljes VLLM és TurboQuant támogatás
    # ──────────────────────────────────────────────────────────────────────────
    HW_PROFILE="desktop-rtx"
    HW_GPU_NAME="$nvidia_name (Ada Lovelace SM_89)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="ada"
    HW_VLLM_OK=true
    HW_NVIDIA_OPEN=false
    HW_CUDA_ARCH="89"
    HW_NVIDIA_PKG="nvidia-driver-570"
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_ampere; then
    # ──────────────────────────────────────────────────────────────────────────
    # Ampere (RTX 3090/3080/3070) — SM_86/80
    # Teljes vLLM és TurboQuant támogatás
    # ──────────────────────────────────────────────────────────────────────────
    HW_PROFILE="desktop-rtx"
    HW_GPU_NAME="$nvidia_name (Ampere SM_86)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="ampere"
    HW_VLLM_OK=true
    HW_NVIDIA_OPEN=false
    HW_CUDA_ARCH="86"
    HW_NVIDIA_PKG="nvidia-driver-570"
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_turing; then
    # ──────────────────────────────────────────────────────────────────────────
    # Turing (RTX 2080/2070) — SM_75
    # vLLM részleges támogatás; TurboQuant limitált
    # ──────────────────────────────────────────────────────────────────────────
    HW_PROFILE="desktop-rtx-old"
    HW_GPU_NAME="$nvidia_name (Turing SM_75)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="turing"
    HW_VLLM_OK=true   # Turing: vLLM fut de nem optimális
    HW_NVIDIA_OPEN=false
    HW_CUDA_ARCH="75"
    HW_NVIDIA_PKG="nvidia-driver-570"
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_pascal; then
    # ──────────────────────────────────────────────────────────────────────────
    # Pascal (GTX 1080/1070) — SM_61
    # CUDA igen, vLLM NEM (SM_70+ szükséges), Ollama GPU fut
    # ──────────────────────────────────────────────────────────────────────────
    HW_PROFILE="desktop-rtx-old"
    HW_GPU_NAME="$nvidia_name (Pascal SM_61)"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="pascal"
    HW_VLLM_OK=false  # vLLM SM_70+ igényel
    HW_NVIDIA_OPEN=false
    HW_CUDA_ARCH="61"
    HW_NVIDIA_PKG="nvidia-driver-570"
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_nvidia_old; then
    # ──────────────────────────────────────────────────────────────────────────
    # Ismeretlen/régi NVIDIA — CUDA-val próbáljuk, vLLM nélkül
    # ──────────────────────────────────────────────────────────────────────────
    HW_PROFILE="desktop-rtx-old"
    HW_GPU_NAME="$nvidia_name"
    HW_GPU_PCI="10de:$nvidia_pci_id"
    HW_GPU_ARCH="nvidia-unknown"
    HW_VLLM_OK=false
    HW_NVIDIA_OPEN=false
    HW_CUDA_ARCH="native"  # cmake -native: auto-detektál fordításkor
    HW_NVIDIA_PKG="nvidia-driver-570"
    $is_notebook && HW_PROFILE="notebook-rtx"

  elif $is_notebook; then
    # ──────────────────────────────────────────────────────────────────────────
    # Csak iGPU-s laptop (Intel HD/Xe, AMD Radeon iGPU)
    # CPU-only Ollama fut, minden más INFRA (Python, Node.js, VS Code) elérhető
    # ──────────────────────────────────────────────────────────────────────────
    HW_PROFILE="notebook-igpu"
    HW_GPU_NAME="${HW_GPU_IGPU:-Integrált GPU}"
    HW_GPU_PCI=""
    HW_GPU_ARCH="igpu"
    HW_VLLM_OK=false
    HW_NVIDIA_OPEN=false
    HW_CUDA_ARCH=""
    HW_NVIDIA_PKG=""

  else
    # ──────────────────────────────────────────────────────────────────────────
    # Asztali PC, csak iGPU (Intel/AMD) — irodai konfiguráció
    # CPU-only Ollama fut, minden más INFRA elérhető
    # ──────────────────────────────────────────────────────────────────────────
    HW_PROFILE="desktop-igpu"
    HW_GPU_NAME="${HW_GPU_IGPU:-Integrált GPU}"
    HW_GPU_PCI=""
    HW_GPU_ARCH="igpu"
    HW_VLLM_OK=false
    HW_NVIDIA_OPEN=false
    HW_CUDA_ARCH=""
    HW_NVIDIA_PKG=""
  fi

  # ── 9. NVIDIA driver csomagnév pontosítása ────────────────────────────────
  # A fenti ágak architektúra-alapon adnak alapértéket (pl. "nvidia-driver-570-open").
  # Utólag megnézzük mi van TÉNYLEGESEN telepítve dpkg-ból — ez a valódi érték.
  # Ha semmi sincs telepítve, az apt-cache-ból a legmagasabb elérhető sorozatot
  # ajánljuk (570 < 575 < 580 stb.).
  if hw_has_nvidia 2>/dev/null || $is_nvidia; then
    # A. Ténylegesen telepített nvidia-driver-*-open (Blackwell: kötelező -open)
    local _inst_open
    _inst_open=$(dpkg -l 'nvidia-driver-*-open' 2>/dev/null \
                 | awk '/^ii/{print $2}' | sort -V | tail -1)

    # B. Ténylegesen telepített nvidia-driver-* (zárt, nem-open)
    # FONTOS: awk-ban a && NEM mehet regex blokkon belül!
    #   HIBÁS:  awk '/^ii && !/open/{print $2}'  → syntax error
    #   HELYES: awk '/^ii/ && !/open/{print $2}'  → két külön feltétel
    local _inst_closed
    _inst_closed=$(dpkg -l 'nvidia-driver-[0-9]*' 2>/dev/null \
                   | awk '/^ii/ && !/open/{print $2}' | sort -V | tail -1)

    if [ -n "$_inst_open" ]; then
      # Telepített -open csomag van — azt mutatjuk
      HW_NVIDIA_PKG="$_inst_open"
      log "HW" "Driver (dpkg-open): $_inst_open"
    elif [ -n "$_inst_closed" ] && ! $HW_NVIDIA_OPEN; then
      # Telepített zárt csomag van, és az adott arch-on OK a zárt
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
      fi
      # Ha apt-cache sem talál semmit, az architektura-alap marad (fallback)
    fi
  fi

  # Exportálás — child scriptek (bash "$script") örököljék
  export HW_PROFILE HW_GPU_NAME HW_GPU_PCI HW_GPU_IGPU HW_GPU_ARCH
  export HW_VLLM_OK HW_NVIDIA_OPEN HW_CUDA_ARCH HW_HYBRID HW_NVIDIA_PKG
  export HW_IS_NOTEBOOK

  log "HW" "Profil:   $HW_PROFILE"
  log "HW" "dGPU:     ${HW_GPU_NAME:-—}"
  log "HW" "iGPU:     ${HW_GPU_IGPU:-—}"
  log "HW" "vLLM:     $HW_VLLM_OK | CUDA arch: ${HW_CUDA_ARCH:-—} | Driver: ${HW_NVIDIA_PKG:-—}"
  log "HW" "Hibrid:   $HW_HYBRID | Notebook: $HW_IS_NOTEBOOK"
}

# hw_show: grafikus ablak a detektált hardverről és az elérhető INFRA-król.
# Hívás: hw_detect() után, a user tájékoztatásához.
hw_show() {
  # Képesség szövegek a profil alapján
  local gpu_accel_txt cuda_txt driver_txt hybrid_txt vibe_txt ollama_txt

  if hw_has_nvidia; then
    gpu_accel_txt="✓ GPU gyorsítás (NVIDIA)"
    cuda_txt="SM_${HW_CUDA_ARCH}"
    # Tényleges telepített driver verziót mutatjuk (nvidia-smi alapján ha fut)
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
  CUDA arch:     $cuda_txt
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
  ────────────────────────────────────────────────" 28
}

# hw_has_nvidia: true ha az aktuális profil NVIDIA GPU-val rendelkezik.
# Használat: if hw_has_nvidia; then ... fi
hw_has_nvidia() {
  case "$HW_PROFILE" in
    desktop-rtx|desktop-rtx-old|notebook-rtx) return 0 ;;
    *) return 1 ;;
  esac
}

# hw_capability: adott képesség elérhetőségét adja vissza az aktuális profilhoz.
# Paraméter: "vllm" | "cuda" | "docker_gpu" | "ollama" | "cpu_only"
# Visszatér: "true" vagy "false"
hw_capability() {
  local cap="$1"
  case "$cap" in
    cuda|nvidia_driver)
      hw_has_nvidia && echo "true" || echo "false" ;;
    vllm|docker_gpu)
      $HW_VLLM_OK && echo "true" || echo "false" ;;
    ollama)
      echo "true" ;;  # Ollama minden platformon fut (CPU-only módban is)
    cpu_only)
      hw_has_nvidia && echo "false" || echo "true" ;;
    *)
      echo "false" ;;
  esac
}

# =============================================================================
