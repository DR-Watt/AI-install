#!/bin/bash
# ============================================================================
# lib/00_lib_compat.sh — INFRA Kompatibilitási Mátrix v1.2
#
# CÉL: GPU/OS/Driver/CUDA/PyTorch összefüggések egyetlen kereshető adatszerkezetben.
#      Megszünteti a szétszórt if/case elágazásokat hw_detect-ből és 01a-ból.
#
# ARCHITEKTÚRA:
#   Ez a fájl DATA — nem logika.
#   A hívó scriptek (hw_detect, 01a) csak compat_get() függvényt hívnak,
#   nem foglalkoznak azzal, hogy melyik GPU/OS kombinációhoz mi érvényes.
#
# KARBANTARTÁS:
#   Új GPU arch   → adj hozzá _COMPAT_MATRIX sorokat (arch|codename|mező)
#   Új OS verzió  → adj hozzá az új codename-mel ellátott sorokat
#   Verzió változás → csak az adott cell értékét módosítsd
#   A hívó scriptek (01a, hw_detect) NEM változnak!
#
# BETÖLTÉS: source-olja a 00_lib.sh master loader (00_lib_hw.sh ELŐTT!)
# NE futtasd közvetlenül!
#
# MEZŐK:
#   driver_pkg        — apt csomagnév (pl. "nvidia-driver-590-open")
#   driver_series     — sorozatszám stringként (pl. "590")
#   driver_repo       — forrás repo ("ubuntu_restricted" | "cuda_repo")
#   canonical_signed  — Canonical aláírt-e ("true"/"false")
#                       false → MOK enrollment szükséges lehet
#   cuda_native       — driver max. CUDA API ver. (pl. "13.1")
#   cuda_min          — minimum ajánlott CUDA toolkit (pl. "12.8")
#   cuda_recommended  — az adott GPU-hoz legjobb CUDA toolkit (pl. "13.1")
#   cuda_pkg          — ajánlott CUDA apt csomagnév
#   pytorch_index     — PyTorch cu-index (pl. "cu128")
#   vllm_support      — "yes" | "partial" | "no"
#   turboquant_mode   — cmake CUDA arch mód: "gpu120"|"gpu89"|"gpu86"|"gpu75"|"cpu"
#   ollama_gpu        — GPU Ollama futtatható-e: "true" | "false"
#   docker_gpu        — Docker GPU támogatás: "true" | "false"
#   hw_profile        — INFRA hw profil neve
#   open_required     — kötelező-e az open kernel modul: "true" | "false"
#
# FORRÁS:
#   NVIDIA CUDA Compatibility r595 (2026-03-31)
#   NVIDIA Driver Installation Guide r595 (2026-03-09)
#   Ubuntu package lists noble-updates/restricted (2026-04-11 telepítési log)
#
# FONTOS — cuda_native vs cuda_recommended különbség:
#   cuda_native     = nvidia-smi által mutatott max. támogatott CUDA API verzió
#   cuda_recommended = TÉNYLEGESEN ELÉRHETŐ ajánlott cuda-toolkit-* csomag
#
# v1.2 (2026-04-13 user teszt alapján):
#   A 12.8 és 13.x verziók Ubuntu 24.04-en ELÉRHETŐK a direkt NVIDIA CUDA repo-ból
#   DE CSAK ha a cuda-repository-pin-600 pin fájl be van állítva (priority 600).
#   Nélküle az Ubuntu repo 12.6-os csomagja "nyeri" a prioritásversenyt.
#   01a v6.12 biztosítja a pin fájl jelenlétét → 13.1 elérhető lesz a repo-ból.
#   Forrás: NVIDIA CUDA Installation Guide Linux — Network Repo (apt-get method)
#   https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
# ============================================================================

# ─── Kompatibilitási Mátrix ──────────────────────────────────────────────────
# Kulcs formátum: "GPU_ARCH|UBUNTU_CODENAME|MEZŐ"
# GPU_ARCH értékek: blackwell | ada | ampere | turing | pascal | igpu | nvidia-unknown
# Codename értékek: noble (24.04) | plucky (26.04)
declare -A _COMPAT_MATRIX

# ════════════════════════════════════════════════════════════════════════════
# Ubuntu 24.04 LTS — noble
#
# CUDA helyzet (v1.2 — 2026-04-13 user teszt megerősítette):
#   Driver: 590.48.01 (noble-updates/restricted, Canonical-signed)
#   CUDA 12.8, 13.1, 13.2 ELÉRHETŐ a direkt NVIDIA CUDA repo-ból
#   Feltétel: cuda-repository-pin-600 pin fájl (priority 600) kell!
#   01a v6.12 biztosítja a pin fájlt → 13.1 az ajánlott (SM_120 natív)
# ════════════════════════════════════════════════════════════════════════════

# ── Blackwell: RTX 5090/5080/5070 (GB202/GB203/GB205) — SM_120 ──────────────
# Log bizonyíték (2026-04-11): 590.48.01 noble-updates/restricted-ből
# Canonical-signed → meglévő MOK elegendő, NEM kell új enrollment
# CUDA 13.1: SM_120 natív támogatás, cu128 PyTorch index (v1.2 frissítve)
_COMPAT_MATRIX["blackwell|noble|driver_pkg"]="nvidia-driver-590-open"
_COMPAT_MATRIX["blackwell|noble|driver_series"]="590"
_COMPAT_MATRIX["blackwell|noble|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["blackwell|noble|canonical_signed"]="true"
_COMPAT_MATRIX["blackwell|noble|cuda_native"]="13.1"
_COMPAT_MATRIX["blackwell|noble|cuda_min"]="12.8"
_COMPAT_MATRIX["blackwell|noble|cuda_recommended"]="13.1"
_COMPAT_MATRIX["blackwell|noble|cuda_pkg"]="cuda-toolkit-13-1"
_COMPAT_MATRIX["blackwell|noble|pytorch_index"]="cu128"
_COMPAT_MATRIX["blackwell|noble|vllm_support"]="yes"
_COMPAT_MATRIX["blackwell|noble|turboquant_mode"]="gpu120"
_COMPAT_MATRIX["blackwell|noble|ollama_gpu"]="true"
_COMPAT_MATRIX["blackwell|noble|docker_gpu"]="true"
_COMPAT_MATRIX["blackwell|noble|hw_profile"]="desktop-rtx"
_COMPAT_MATRIX["blackwell|noble|open_required"]="true"

# ── Ada Lovelace: RTX 4090/4080/4070 (AD102/AD103/AD104) — SM_89 ────────────
_COMPAT_MATRIX["ada|noble|driver_pkg"]="nvidia-driver-590-open"
_COMPAT_MATRIX["ada|noble|driver_series"]="590"
_COMPAT_MATRIX["ada|noble|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["ada|noble|canonical_signed"]="true"
_COMPAT_MATRIX["ada|noble|cuda_native"]="13.1"
_COMPAT_MATRIX["ada|noble|cuda_min"]="12.4"
_COMPAT_MATRIX["ada|noble|cuda_recommended"]="13.1"
_COMPAT_MATRIX["ada|noble|cuda_pkg"]="cuda-toolkit-13-1"
_COMPAT_MATRIX["ada|noble|pytorch_index"]="cu128"
_COMPAT_MATRIX["ada|noble|vllm_support"]="yes"
_COMPAT_MATRIX["ada|noble|turboquant_mode"]="gpu89"
_COMPAT_MATRIX["ada|noble|ollama_gpu"]="true"
_COMPAT_MATRIX["ada|noble|docker_gpu"]="true"
_COMPAT_MATRIX["ada|noble|hw_profile"]="desktop-rtx"
_COMPAT_MATRIX["ada|noble|open_required"]="false"

# ── Ampere: RTX 3090/3080/3070 (GA102/GA103/GA104) — SM_86 ─────────────────
_COMPAT_MATRIX["ampere|noble|driver_pkg"]="nvidia-driver-590-open"
_COMPAT_MATRIX["ampere|noble|driver_series"]="590"
_COMPAT_MATRIX["ampere|noble|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["ampere|noble|canonical_signed"]="true"
_COMPAT_MATRIX["ampere|noble|cuda_native"]="13.1"
_COMPAT_MATRIX["ampere|noble|cuda_min"]="12.4"
_COMPAT_MATRIX["ampere|noble|cuda_recommended"]="13.1"
_COMPAT_MATRIX["ampere|noble|cuda_pkg"]="cuda-toolkit-13-1"
_COMPAT_MATRIX["ampere|noble|pytorch_index"]="cu128"
_COMPAT_MATRIX["ampere|noble|vllm_support"]="yes"
_COMPAT_MATRIX["ampere|noble|turboquant_mode"]="gpu86"
_COMPAT_MATRIX["ampere|noble|ollama_gpu"]="true"
_COMPAT_MATRIX["ampere|noble|docker_gpu"]="true"
_COMPAT_MATRIX["ampere|noble|hw_profile"]="desktop-rtx"
_COMPAT_MATRIX["ampere|noble|open_required"]="false"

# ── Turing: RTX 2080/2070/2060 (TU102/TU104/TU106) — SM_75 ─────────────────
# vLLM: fut de nem optimális (SM_70 minimális, SM_75 részleges)
# TurboQuant: FP4/FP8 limitált
_COMPAT_MATRIX["turing|noble|driver_pkg"]="nvidia-driver-590-open"
_COMPAT_MATRIX["turing|noble|driver_series"]="590"
_COMPAT_MATRIX["turing|noble|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["turing|noble|canonical_signed"]="true"
_COMPAT_MATRIX["turing|noble|cuda_native"]="13.1"
_COMPAT_MATRIX["turing|noble|cuda_min"]="12.4"
_COMPAT_MATRIX["turing|noble|cuda_recommended"]="12.6"
_COMPAT_MATRIX["turing|noble|cuda_pkg"]="cuda-toolkit-12-6"
_COMPAT_MATRIX["turing|noble|pytorch_index"]="cu126"
_COMPAT_MATRIX["turing|noble|vllm_support"]="partial"
_COMPAT_MATRIX["turing|noble|turboquant_mode"]="gpu75"
_COMPAT_MATRIX["turing|noble|ollama_gpu"]="true"
_COMPAT_MATRIX["turing|noble|docker_gpu"]="true"
_COMPAT_MATRIX["turing|noble|hw_profile"]="desktop-rtx-old"
_COMPAT_MATRIX["turing|noble|open_required"]="false"

# ── Pascal: GTX 1080/1070 (GP102/GP104) — SM_61 ─────────────────────────────
# vLLM: NEM fut (SM_70+ szükséges)
# Ollama: GPU módban fut (CUDA kernel elérhető Pascal-on)
_COMPAT_MATRIX["pascal|noble|driver_pkg"]="nvidia-driver-590-open"
_COMPAT_MATRIX["pascal|noble|driver_series"]="590"
_COMPAT_MATRIX["pascal|noble|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["pascal|noble|canonical_signed"]="true"
_COMPAT_MATRIX["pascal|noble|cuda_native"]="13.1"
_COMPAT_MATRIX["pascal|noble|cuda_min"]="12.4"
_COMPAT_MATRIX["pascal|noble|cuda_recommended"]="12.6"
_COMPAT_MATRIX["pascal|noble|cuda_pkg"]="cuda-toolkit-12-6"
_COMPAT_MATRIX["pascal|noble|pytorch_index"]="cu126"
_COMPAT_MATRIX["pascal|noble|vllm_support"]="no"
_COMPAT_MATRIX["pascal|noble|turboquant_mode"]="cpu"
_COMPAT_MATRIX["pascal|noble|ollama_gpu"]="true"
_COMPAT_MATRIX["pascal|noble|docker_gpu"]="true"
_COMPAT_MATRIX["pascal|noble|hw_profile"]="desktop-rtx-old"
_COMPAT_MATRIX["pascal|noble|open_required"]="false"

# ── Intel/AMD iGPU — CPU-only mód ───────────────────────────────────────────
_COMPAT_MATRIX["igpu|noble|driver_pkg"]=""
_COMPAT_MATRIX["igpu|noble|driver_series"]=""
_COMPAT_MATRIX["igpu|noble|driver_repo"]=""
_COMPAT_MATRIX["igpu|noble|canonical_signed"]="true"
_COMPAT_MATRIX["igpu|noble|cuda_native"]=""
_COMPAT_MATRIX["igpu|noble|cuda_min"]=""
_COMPAT_MATRIX["igpu|noble|cuda_recommended"]=""
_COMPAT_MATRIX["igpu|noble|cuda_pkg"]=""
_COMPAT_MATRIX["igpu|noble|pytorch_index"]=""
_COMPAT_MATRIX["igpu|noble|vllm_support"]="no"
_COMPAT_MATRIX["igpu|noble|turboquant_mode"]="cpu_only"
_COMPAT_MATRIX["igpu|noble|ollama_gpu"]="false"
_COMPAT_MATRIX["igpu|noble|docker_gpu"]="false"
_COMPAT_MATRIX["igpu|noble|hw_profile"]="desktop-igpu"
_COMPAT_MATRIX["igpu|noble|open_required"]="false"

# ── Ismeretlen NVIDIA GPU ────────────────────────────────────────────────────
_COMPAT_MATRIX["nvidia-unknown|noble|driver_pkg"]="nvidia-driver-590-open"
_COMPAT_MATRIX["nvidia-unknown|noble|driver_series"]="590"
_COMPAT_MATRIX["nvidia-unknown|noble|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["nvidia-unknown|noble|canonical_signed"]="true"
_COMPAT_MATRIX["nvidia-unknown|noble|cuda_native"]="13.1"
_COMPAT_MATRIX["nvidia-unknown|noble|cuda_min"]="12.4"
_COMPAT_MATRIX["nvidia-unknown|noble|cuda_recommended"]="12.6"
_COMPAT_MATRIX["nvidia-unknown|noble|cuda_pkg"]="cuda-toolkit-12-6"
_COMPAT_MATRIX["nvidia-unknown|noble|pytorch_index"]="cu126"
_COMPAT_MATRIX["nvidia-unknown|noble|vllm_support"]="no"
_COMPAT_MATRIX["nvidia-unknown|noble|turboquant_mode"]="cpu"
_COMPAT_MATRIX["nvidia-unknown|noble|ollama_gpu"]="true"
_COMPAT_MATRIX["nvidia-unknown|noble|docker_gpu"]="true"
_COMPAT_MATRIX["nvidia-unknown|noble|hw_profile"]="desktop-rtx-old"
_COMPAT_MATRIX["nvidia-unknown|noble|open_required"]="false"

# ════════════════════════════════════════════════════════════════════════════
# Ubuntu 26.04 — plucky
# 595.58.03: Ubuntu restricted (plucky/restricted)
# Forrás: NVIDIA Driver Installation Guide r595 + Ubuntu package info
# CudaNoStablePerfLimit: P0 PState elérése CUDA appok számára (595+ újdonság)
# ════════════════════════════════════════════════════════════════════════════

# ── Blackwell: RTX 5090/5080/5070 — SM_120 ──────────────────────────────────
_COMPAT_MATRIX["blackwell|plucky|driver_pkg"]="nvidia-driver-595-open"
_COMPAT_MATRIX["blackwell|plucky|driver_series"]="595"
_COMPAT_MATRIX["blackwell|plucky|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["blackwell|plucky|canonical_signed"]="true"
_COMPAT_MATRIX["blackwell|plucky|cuda_native"]="13.2"
_COMPAT_MATRIX["blackwell|plucky|cuda_min"]="12.8"
_COMPAT_MATRIX["blackwell|plucky|cuda_recommended"]="13.2"
_COMPAT_MATRIX["blackwell|plucky|cuda_pkg"]="cuda-toolkit-13-2"
_COMPAT_MATRIX["blackwell|plucky|pytorch_index"]="cu128"
_COMPAT_MATRIX["blackwell|plucky|vllm_support"]="yes"
_COMPAT_MATRIX["blackwell|plucky|turboquant_mode"]="gpu120"
_COMPAT_MATRIX["blackwell|plucky|ollama_gpu"]="true"
_COMPAT_MATRIX["blackwell|plucky|docker_gpu"]="true"
_COMPAT_MATRIX["blackwell|plucky|hw_profile"]="desktop-rtx"
_COMPAT_MATRIX["blackwell|plucky|open_required"]="true"

# ── Ada Lovelace: RTX 4090/4080/4070 — SM_89 ────────────────────────────────
_COMPAT_MATRIX["ada|plucky|driver_pkg"]="nvidia-driver-595-open"
_COMPAT_MATRIX["ada|plucky|driver_series"]="595"
_COMPAT_MATRIX["ada|plucky|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["ada|plucky|canonical_signed"]="true"
_COMPAT_MATRIX["ada|plucky|cuda_native"]="13.2"
_COMPAT_MATRIX["ada|plucky|cuda_min"]="12.4"
_COMPAT_MATRIX["ada|plucky|cuda_recommended"]="13.2"
_COMPAT_MATRIX["ada|plucky|cuda_pkg"]="cuda-toolkit-13-2"
_COMPAT_MATRIX["ada|plucky|pytorch_index"]="cu128"
_COMPAT_MATRIX["ada|plucky|vllm_support"]="yes"
_COMPAT_MATRIX["ada|plucky|turboquant_mode"]="gpu89"
_COMPAT_MATRIX["ada|plucky|ollama_gpu"]="true"
_COMPAT_MATRIX["ada|plucky|docker_gpu"]="true"
_COMPAT_MATRIX["ada|plucky|hw_profile"]="desktop-rtx"
_COMPAT_MATRIX["ada|plucky|open_required"]="false"

# ── Ampere: RTX 3090/3080/3070 — SM_86 ──────────────────────────────────────
_COMPAT_MATRIX["ampere|plucky|driver_pkg"]="nvidia-driver-595-open"
_COMPAT_MATRIX["ampere|plucky|driver_series"]="595"
_COMPAT_MATRIX["ampere|plucky|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["ampere|plucky|canonical_signed"]="true"
_COMPAT_MATRIX["ampere|plucky|cuda_native"]="13.2"
_COMPAT_MATRIX["ampere|plucky|cuda_min"]="12.4"
_COMPAT_MATRIX["ampere|plucky|cuda_recommended"]="13.2"
_COMPAT_MATRIX["ampere|plucky|cuda_pkg"]="cuda-toolkit-13-2"
_COMPAT_MATRIX["ampere|plucky|pytorch_index"]="cu128"
_COMPAT_MATRIX["ampere|plucky|vllm_support"]="yes"
_COMPAT_MATRIX["ampere|plucky|turboquant_mode"]="gpu86"
_COMPAT_MATRIX["ampere|plucky|ollama_gpu"]="true"
_COMPAT_MATRIX["ampere|plucky|docker_gpu"]="true"
_COMPAT_MATRIX["ampere|plucky|hw_profile"]="desktop-rtx"
_COMPAT_MATRIX["ampere|plucky|open_required"]="false"

# ── Turing: RTX 2080/2070/2060 — SM_75 ──────────────────────────────────────
_COMPAT_MATRIX["turing|plucky|driver_pkg"]="nvidia-driver-595-open"
_COMPAT_MATRIX["turing|plucky|driver_series"]="595"
_COMPAT_MATRIX["turing|plucky|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["turing|plucky|canonical_signed"]="true"
_COMPAT_MATRIX["turing|plucky|cuda_native"]="13.2"
_COMPAT_MATRIX["turing|plucky|cuda_min"]="12.4"
_COMPAT_MATRIX["turing|plucky|cuda_recommended"]="12.6"
_COMPAT_MATRIX["turing|plucky|cuda_pkg"]="cuda-toolkit-12-6"
_COMPAT_MATRIX["turing|plucky|pytorch_index"]="cu126"
_COMPAT_MATRIX["turing|plucky|vllm_support"]="partial"
_COMPAT_MATRIX["turing|plucky|turboquant_mode"]="gpu75"
_COMPAT_MATRIX["turing|plucky|ollama_gpu"]="true"
_COMPAT_MATRIX["turing|plucky|docker_gpu"]="true"
_COMPAT_MATRIX["turing|plucky|hw_profile"]="desktop-rtx-old"
_COMPAT_MATRIX["turing|plucky|open_required"]="false"

# ── Pascal: GTX 1080/1070 — SM_61 ───────────────────────────────────────────
_COMPAT_MATRIX["pascal|plucky|driver_pkg"]="nvidia-driver-595-open"
_COMPAT_MATRIX["pascal|plucky|driver_series"]="595"
_COMPAT_MATRIX["pascal|plucky|driver_repo"]="ubuntu_restricted"
_COMPAT_MATRIX["pascal|plucky|canonical_signed"]="true"
_COMPAT_MATRIX["pascal|plucky|cuda_native"]="13.2"
_COMPAT_MATRIX["pascal|plucky|cuda_min"]="12.4"
_COMPAT_MATRIX["pascal|plucky|cuda_recommended"]="12.6"
_COMPAT_MATRIX["pascal|plucky|cuda_pkg"]="cuda-toolkit-12-6"
_COMPAT_MATRIX["pascal|plucky|pytorch_index"]="cu126"
_COMPAT_MATRIX["pascal|plucky|vllm_support"]="no"
_COMPAT_MATRIX["pascal|plucky|turboquant_mode"]="cpu"
_COMPAT_MATRIX["pascal|plucky|ollama_gpu"]="true"
_COMPAT_MATRIX["pascal|plucky|docker_gpu"]="true"
_COMPAT_MATRIX["pascal|plucky|hw_profile"]="desktop-rtx-old"
_COMPAT_MATRIX["pascal|plucky|open_required"]="false"

# ── iGPU / CPU-only — plucky ─────────────────────────────────────────────────
_COMPAT_MATRIX["igpu|plucky|driver_pkg"]=""
_COMPAT_MATRIX["igpu|plucky|driver_series"]=""
_COMPAT_MATRIX["igpu|plucky|canonical_signed"]="true"
_COMPAT_MATRIX["igpu|plucky|cuda_recommended"]=""
_COMPAT_MATRIX["igpu|plucky|pytorch_index"]=""
_COMPAT_MATRIX["igpu|plucky|vllm_support"]="no"
_COMPAT_MATRIX["igpu|plucky|turboquant_mode"]="cpu_only"
_COMPAT_MATRIX["igpu|plucky|ollama_gpu"]="false"
_COMPAT_MATRIX["igpu|plucky|docker_gpu"]="false"
_COMPAT_MATRIX["igpu|plucky|hw_profile"]="desktop-igpu"
_COMPAT_MATRIX["igpu|plucky|open_required"]="false"

# ─── Lookup függvények ────────────────────────────────────────────────────────

# compat_get: értéket olvas a kompatibilitási mátrixból.
# Paraméterek:
#   $1 = mező neve (pl. "driver_pkg", "cuda_recommended", "pytorch_index")
#   $2 = gpu_arch  (pl. "blackwell", "ada", "igpu") — default: "nvidia-unknown"
#   $3 = os_codename (pl. "noble", "plucky") — default: "noble"
#   $4 = default érték ha nincs találat (opcionális)
# Visszatér: a keresett érték stdouton, vagy $4 ha nincs találat
# Megjegyzés: ha az adott codename nem definiált, "noble" fallback-et próbál
compat_get() {
  local field="$1"
  local arch="${2:-nvidia-unknown}"
  local codename="${3:-noble}"
  local default="${4:-}"

  local key="${arch}|${codename}|${field}"
  local val="${_COMPAT_MATRIX[$key]:-}"

  # Fallback: noble ha az adott codename nem ismert
  if [ -z "$val" ] && [ "$codename" != "noble" ]; then
    val="${_COMPAT_MATRIX["${arch}|noble|${field}"]:-}"
  fi

  # Végső fallback: nvidia-unknown|noble ha az arch sem ismert
  if [ -z "$val" ] && [ "$arch" != "nvidia-unknown" ]; then
    val="${_COMPAT_MATRIX["nvidia-unknown|noble|${field}"]:-}"
  fi

  echo "${val:-$default}"
}

# compat_has: igaz ha létezik az adott arch|codename kombináció.
compat_has() {
  local arch="${1:-}" codename="${2:-noble}"
  [ -n "${_COMPAT_MATRIX["${arch}|${codename}|driver_series"]:-}" ]
}

# compat_vllm_ok: visszaad bash true/false-t a vllm_support mező alapján.
# "yes" vagy "partial" → 0 (igaz), "no" → 1 (hamis)
compat_vllm_ok() {
  local arch="${1:-}" codename="${2:-noble}"
  local support
  support=$(compat_get "vllm_support" "$arch" "$codename" "no")
  case "$support" in
    yes|partial) return 0 ;;
    *)           return 1 ;;
  esac
}

# compat_dump: debug — az adott arch|codename összes mezőjének kiírása
compat_dump() {
  local arch="${1:-blackwell}" codename="${2:-noble}"
  echo "=== compat_dump: $arch / $codename ==="
  for field in driver_pkg driver_series driver_repo canonical_signed \
               cuda_native cuda_min cuda_recommended cuda_pkg pytorch_index \
               vllm_support turboquant_mode ollama_gpu docker_gpu \
               hw_profile open_required; do
    printf "  %-22s = %s\n" "$field" "$(compat_get "$field" "$arch" "$codename")"
  done
}
