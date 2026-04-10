#!/bin/bash
# =============================================================================
# 02_local_ai_stack.sh — Lokális AI Stack v6.4
#                        Ollama + vLLM + TurboQuant llama.cpp fork
#
# Szerepe az INFRA rendszerben
# ────────────────────────────
#   ✓ Ollama — llama.cpp alapú lokális LLM szerver, OpenAI API kompatibilis
#   ✓ vLLM  — GPU-optimalizált inferencia (SM_70+ NVIDIA kell)
#   ✓ TurboQuant llama.cpp fork — KV cache kvantálás (PolarQuant + QJL)
#   ✓ AI SDK-k — LangChain, Anthropic, HuggingFace, ChromaDB
#   ✓ Indítószkriptek — ~/bin/start-vllm.sh, ~/bin/ollama-proxy.sh
#   → MOD_02_DONE + INST_OLLAMA_VER + INST_VLLM_VER + FEAT_TURBOQUANT state
#
# MÓDOK (v6.4)
# ─────────────
#   install   → hiányzó komponensek telepítése (TQ csak ha nincs kész)
#   update    → meglévők frissítése, TQ újrafordítása
#   check     → READ-ONLY: csak státusz — EARLY EXIT, semmi sem települ!
#   fix       → install-szerű, reboot nélkül (02-ben nincs reboot amúgy sem)
#   reinstall → teljes újratelepítés (TQ is újrafordul)
#
# JAVÍTÁSOK v6.4 (a futtatott logok alapján)
# ──────────────────────────────────────────
#   [FIX] 'local' top szinten: bash error "can only be used in a function"
#         Érintett sorok (v6.2): 240, 433, 498, 610, 921 — mind eltávolítva
#   [FIX] check mód early exit: v6.2-ban MISSING_COUNT>0 → install ágba esett
#         check módban is → telepítési dialógok + TQ build → 7+ perces futás!
#         Most: komponens felmérés után azonnali early exit check módban
#   [FIX] TurboQuant már kész → skip (v6.2-ban minden futáskor újrafordult)
#         Pre-check: binary OK + FEAT_TURBOQUANT=true + nem reinstall/update → skip
#   [FIX] cmake flags üres: ${TQ_CMAKE_FLAGS[$TQ_BUILD_MODE]} unquoted expansion
#         → GGML_CUDA=OFF lett gpu89 helyett (CPU-only build)
#         Most: case statement + TQ_CMAKE_ARGS=() bash array, "${TQ_CMAKE_ARGS[@]}"
#   [FIX] HW check: infra_compatible() V7 libben false-t adott desktop-rtx-re
#         Most: közvetlen HW_PROFILE + HW_GPU_ARCH + state flag ellenőrzés
#   [FIX] Ollama verzió üres: 'ollama version' service start után nem válaszol
#         Most: 5x retry loop 1 mp szünettel + dpkg fallback
#   [NEW] Log chmod: sudo alatt root:root log → chmod 644 + chown user
#         TQ build log is: touch + chmod ELŐRE + utólagos jogosultság rendezés
#   [NEW] fix mód: install-szerű, infra_require bypass a libben; 02-ban nincs reboot
#
# ELŐFELTÉTELEK
# ─────────────
#   • 00_lib.sh v6.4 (master loader: 6 lib fájlt tölt be helyes sorrendben)
#   • 01a kész: NVIDIA driver + CUDA (MOD_01A_DONE=true)
#   • 01b kész: shell setup (MOD_01B_DONE=true)
#   • 03 kész: pyenv + Python 3.12 + uv + ~/AI-VIBE/venvs/ai (MOD_03_DONE=true)
#   • NVIDIA GPU (SM_61+ Ollama GPU; SM_70+ vLLM)
#
# FUTTATÁS
# ────────
#   sudo bash 02_local_ai_stack.sh            # közvetlen
#   sudo bash 00_master.sh  (02 kijelölve)    # master-en keresztül
#
# DOKUMENTÁCIÓ REFERENCIÁK
# ─────────────────────────
#   Ollama:     https://ollama.readthedocs.io/en/
#   vLLM:       https://docs.vllm.ai/en/latest/
#   TurboQuant: https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/
#               https://arxiv.org/pdf/2504.19874
#               https://github.com/0xSero/turboquant
#   PyTorch:    https://docs.pytorch.org/docs/stable/index.html
#   uv:         https://docs.astral.sh/uv/
#   lib loader: 00_lib.sh — betöltési sorrend: core→hw→ui→state→comp→apt
# =============================================================================

# ── Script könyvtár (szimlink-biztos) ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Közös függvénytár betöltése ───────────────────────────────────────────────
LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" \
  || { echo "HIBA: 00_lib.sh hiányzik! Elvárt helye: $LIB"; exit 1; }

# =============================================================================
# ██  SZEKCIÓ 1 — KONFIGURÁCIÓ  ── minden érték itt, kódban nincs magic string  ██
# =============================================================================

# ── Modul azonosítók ──────────────────────────────────────────────────────────
INFRA_NUM="02"
INFRA_NAME="Lokális AI Stack (Ollama + vLLM + TurboQuant)"
INFRA_HW_REQ="nvidia"   # infra_compatible() ellenőrzi — NVIDIA nélkül kihagyja

# ── Célverziók ────────────────────────────────────────────────────────────────
# Ollama és vLLM: a legfrissebb stabil verzió töltődik le,
# de itt definiáljuk a minimum elfogadható verziószámokat.
declare -A MIN_VER=(
  [ollama]="0.5"          # Ollama minimum elfogadható verzió
  [vllm]="0.4"            # vLLM minimum — 0.4+ kell PagedAttention v2-höz
  [uv]="0.1"              # uv minimum (praktikusan bármely verzió OK)
)

# ── TurboQuant llama.cpp fork repo adatok ─────────────────────────────────────
# A TurboQuant-nak két aktív community fork-ja van:
#   seanrasch fork  — GPU-89/CPU build, cu126-kompatibilis
#   0xSero fork     — GPU-120 explicit SM_120 Blackwell Triton kernelekkel
# Forrás: https://github.com/0xSero/turboquant (referencia implementáció)
#         https://arxiv.org/pdf/2504.19874 (TurboQuant ICLR 2026 paper)
declare -A TQ_REPOS=(
  [cpu]="https://github.com/seanrasch/llama-cpp-turboquant"
  [gpu89]="https://github.com/seanrasch/llama-cpp-turboquant"
  [gpu120]="https://github.com/0xSero/turboquant"   # Blackwell SM_120 Triton kernelekkel
)

# ── Telepítési útvonalak ──────────────────────────────────────────────────────
# Ezek a változók az _REAL_HOME alapján töltik fel a tényleges értéket.
# A VENV változó a 03-as modul által létrehozott Python AI venv-re mutat.
VENV="$_REAL_HOME/AI-VIBE/venvs/ai"         # PyTorch + vLLM + SDK-k venv-je (03 hozta létre)
VENV_PY="$VENV/bin/python"                  # venv Python bináris
UV="$_REAL_HOME/.local/bin/uv"              # uv package manager (03 telepítette)
PYENV_ROOT="$_REAL_HOME/.pyenv"             # pyenv root (03 telepítette)

# ── AI SDK csomagok listája ────────────────────────────────────────────────────
# Ezek az AI SDK-k kerülnek az AI venv-be az uv pip install parancson keresztül.
# Forrás: PyPI + LangChain/Anthropic hivatalos dokumentáció
readonly AI_PKGS=(
  langchain                 # RAG pipeline és AI workflow keretrendszer
  langchain-anthropic       # LangChain ↔ Claude API híd
  langchain-community       # community integrációk (Ollama, ChromaDB, stb.)
  anthropic                 # Anthropic Claude API Python SDK
  transformers              # HuggingFace modell keretrendszer
  datasets                  # HuggingFace adatkészlet kezelő
  accelerate                # HuggingFace GPU gyorsítás (multi-GPU, mixed precision)
  sentence-transformers     # embedding modellek (RAG-hoz szükséges)
  chromadb                  # lokális vektor adatbázis (RAG)
  huggingface-hub           # HF Hub API: modell letöltés, tokenek
  tiktoken                  # OpenAI/Anthropic tokenizer (LangChain szükségeli)
  openai                    # OpenAI SDK — Ollama és vLLM OpenAI API kompatibilis!
)

# ── TurboQuant cmake build paraméterek táblázata ──────────────────────────────
# cmake flag-ek a build mód szerint (GGML_CUDA + CUDA arch beállítás)
# Forrás: llama.cpp build dokumentáció + TurboQuant fork README
declare -A TQ_CMAKE_FLAGS=(
  [cpu]="   -DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release"
  [gpu89]=  "-DGGML_CUDA=ON  -DCMAKE_CUDA_ARCHITECTURES=89  -DCMAKE_BUILD_TYPE=Release"
  [gpu120]= "-DGGML_CUDA=ON  -DCMAKE_CUDA_ARCHITECTURES=120 -DCMAKE_BUILD_TYPE=Release"
)
declare -A TQ_ARCH_LABEL=(
  [cpu]="CPU-only (nincs CUDA)"
  [gpu89]="GPU SM_89 — Ada Lovelace fallback (cu126 OK)"
  [gpu120]="GPU SM_120 — Blackwell natív (cu128 Nightly szükséges)"
)

# =============================================================================
# SZEKCIÓ 2 — INICIALIZÁCIÓ
# =============================================================================

# ── Log inicializáció ─────────────────────────────────────────────────────────
# Saját log fájl: install_02_DÁTUM.log — elkülönített, 02-es modul logja
# A LOGFILE_AI/LOGFILE_HUMAN felülírása a 00_lib.sh alapértékét módosítja
LOGFILE_AI="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_02_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_02_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="${LOGFILE_AI}"   # backward kompatibilitás
log_init

# ── Log chmod — sudo alatt root:root lenne, nem húzható Claude-ba ─────────────
# [FIX v6.4] Azonnal átadjuk a real user-nek
chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true

# ── INFRA state betöltése (01a/03 által írt HW/CUDA/PyTorch adatok) ───────────
# Az infra state fájlból olvassuk a telepített verziót és feature flag-eket.
# Alapértékek: ha a state fájl még nem létezik (manuális futtatás esetén).
INST_CUDA_VER=$(infra_state_get "INST_CUDA_VER"  "12.6")
PYTORCH_INDEX=$(infra_state_get "PYTORCH_INDEX"  "cu126")
HW_GPU_ARCH=$(infra_state_get   "HW_GPU_ARCH"    "${HW_GPU_ARCH:-unknown}")
HW_CUDA_ARCH=$(infra_state_get  "HW_CUDA_ARCH"   "${HW_CUDA_ARCH:-89}")

log "STATE" "Betöltve: CUDA=${INST_CUDA_VER} | PyTorch=${PYTORCH_INDEX} | arch=SM_${HW_CUDA_ARCH} | GPU_ARCH=${HW_GPU_ARCH}"

# ── TurboQuant alapértelmezett build mód ─────────────────────────────────────
# A GPU arch és CUDA verzió alapján döntjük el melyik TQ mód ajánlott:
#   - Blackwell + CUDA 12.8 (cu128) → GPU-120 (natív SM_120, legjobb)
#   - Blackwell + CUDA 12.6 (cu126) → GPU-89  (Ada fallback, de fut RTX 5090-en)
#   - Ada/Ampere/Turing + bármely CUDA → GPU-89
#   - iGPU vagy nincs NVIDIA → CPU
if [ "$PYTORCH_INDEX" = "cu128" ] && [ "$HW_GPU_ARCH" = "blackwell" ]; then
  TQ_DEFAULT_MODE="gpu120"
elif [ "$HW_GPU_ARCH" = "blackwell" ]; then
  TQ_DEFAULT_MODE="gpu89"
elif [ "$HW_GPU_ARCH" != "igpu" ] && [ "$HW_GPU_ARCH" != "unknown" ]; then
  TQ_DEFAULT_MODE="gpu89"
else
  TQ_DEFAULT_MODE="cpu"
fi
log "STATE" "TurboQuant default build mód: ${TQ_DEFAULT_MODE}"

# ── Lock fájl — párhuzamos futtatás megakadályozása ──────────────────────────
# Egy futási sessionnél nem futhat párhuzamosan ugyanez a script.
# check_lock() kezeli: régi (2h+) lockot törli, fiatalabbat user döntésre bízza.
LOCK_FILE="${_REAL_HOME}/.infra-lock-02"
check_lock "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT   # cleanup ha a script bármely okból kilép

# =============================================================================
# SZEKCIÓ 3 — HARDVER ÉS FÜGGŐSÉG ELLENŐRZÉS
# =============================================================================

# ── Hardver kompatibilitás ────────────────────────────────────────────────────
# [FIX v6.4] infra_compatible() helyett közvetlen HW_PROFILE + HW_GPU_ARCH check.
# Gyökérok: infra_compatible() V7 libben másképp implementált →
# desktop-rtx profilra "nvidia" HW_REQ esetén false-t adott vissza.
# Háromszintes ellenőrzés (lib-verziófüggetlen):
_hw_nvidia_ok=false
case "${HW_PROFILE:-}" in
  desktop-rtx|desktop-rtx-old|notebook-rtx) _hw_nvidia_ok=true ;;
esac
! $_hw_nvidia_ok && case "${HW_GPU_ARCH:-}" in
  blackwell|ada|ampere|turing|pascal|nvidia*) _hw_nvidia_ok=true ;;
esac
[ "$(infra_state_get "HW_VLLM_OK"    "false")" = "true" ] && _hw_nvidia_ok=true
[ "$(infra_state_get "FEAT_GPU_ACCEL" "false")" = "true" ] && _hw_nvidia_ok=true

if ! $_hw_nvidia_ok; then
  log "SKIP" "Hardver inkompatibilis: profil=${HW_PROFILE} arch=${HW_GPU_ARCH} — nincs NVIDIA GPU"
  dialog_warn "Hardver inkompatibilis — 02 kihagyva" \
    "\n  A 02-es modul NVIDIA GPU-t igényel.\n\n  Profil: ${HW_PROFILE} | GPU arch: ${HW_GPU_ARCH}\n\n  Modul kihagyva (exit 2)." 14
  exit 2
fi
log "HW" "NVIDIA GPU OK: profil=${HW_PROFILE} / arch=${HW_GPU_ARCH}"

# ── 03-as modul függőség ellenőrzés ───────────────────────────────────────────
# A 02-es script a 03-as által telepített pyenv + uv + venv-t IGÉNYLI.
# infra_require() ellenőrzi a MOD_03_DONE=true flag-et az infra state-ben.
# Ha nem kész: dialóg + log + exit 1.
#
# MEGJEGYZÉS: Ha a 02-t közvetlenül futtatod (nem masterből), és a 03 kész de
# a state fájl nem tartalmazza a MOD_03_DONE flag-et, a dialógban igen-nel
# folytatható a futás (a MOD_03_DONE flag manuálisan is beállítható:
#   echo "MOD_03_DONE=true" >> ~/.infra-state)
infra_require "03" "Python 3.12 + PyTorch + uv (03_python_aiml.sh)" || exit 1

# ── PATH beállítás (pyenv + uv + CUDA nvcc) ───────────────────────────────────
# CUDA PATH: nvcc elérhetőség a TurboQuant cmake build-hez kell.
# pyenv PATH: a venv Python binárisának megtalálásához szükséges.
# FONTOS: ezek a PATH módosítások CSAK erre a script futásra vonatkoznak.
# A tartós shell konfiguráció a 01a (CUDA) és 03 (pyenv) dolga.
export PATH="/usr/local/cuda/bin:$PYENV_ROOT/bin:$_REAL_HOME/.local/bin:$PATH"
[ -d "$PYENV_ROOT/bin" ] && eval "$(pyenv init -)" 2>/dev/null || true
log "PATH" "Aktiválva: CUDA=/usr/local/cuda/bin | pyenv | uv"

# =============================================================================
# SZEKCIÓ 4 — KOMPONENS FELMÉRÉS
# =============================================================================
# A COMP_STATUS[] és COMP_VER[] tömbök a 00_lib.sh SZEKCIÓ 8-ból jönnek.
# Saját check parancsok ahol nincs dedikált comp_check_* függvény.

# ── COMP_CHECK tömb: minden ellenőrzendő komponens ───────────────────────────
# Formátum: "kulcs||min_ver" (a log_comp_status() ezt értelmezi)
COMP_CHECK=(
  "uv||${MIN_VER[uv]}"
  "venv||"
  "torch||"
  "ollama||${MIN_VER[ollama]}"
  "vllm||${MIN_VER[vllm]}"
  "turboquant||"
  "langchain||"
  "anthropic||"
  "hf||"
)

# ── Komponensek ellenőrzése ───────────────────────────────────────────────────
# uv: Astral uv package manager (03 telepítette) — comp_check_uv() a lib-ben
comp_check_uv   "${MIN_VER[uv]}"   "$UV"

# Python AI venv: a 03-as modul hozta létre ~/AI-VIBE/venvs/ai/
# Nincs dedikált comp_check_ — könyvtár + bináris létezés ellenőrzés
if [ -d "$VENV" ] && [ -x "$VENV_PY" ]; then
  COMP_STATUS[venv]="ok"; COMP_VER[venv]="$("$VENV_PY" --version 2>/dev/null | grep -oP '[\d.]+')"
else
  COMP_STATUS[venv]="missing"; COMP_VER[venv]=""
fi

# PyTorch: comp_check_torch() a lib-ben (00_lib_comp.sh)
# [FIX v6.4] 'local torch_ver' top szinten → bash error; comp_check_torch() használata
if [ "${COMP_STATUS[venv]}" = "ok" ]; then
  comp_check_torch "" "$VENV_PY"
else
  COMP_STATUS[torch]="missing"; COMP_VER[torch]=""
fi

# Ollama: dedikált comp_check_ollama() a lib-ben
comp_check_ollama "${MIN_VER[ollama]}"

# vLLM: dedikált comp_check_vllm() a lib-ben (v6.2 újdonság)
# Paraméter: min verzió + a venv Python bináris (nem a rendszer python!)
[ "${COMP_STATUS[venv]}" = "ok" ] \
  && comp_check_vllm "${MIN_VER[vllm]}" "$VENV_PY" \
  || { COMP_STATUS[vllm]="missing"; COMP_VER[vllm]=""; }

# TurboQuant bináris: ~/bin/llama-turboquant symlink vagy bármely llama-turboquant-*
# A llama-turboquant symlink a build után kerül ide (→ llama-turboquant-gpu89 stb.)
if [ -f "$_REAL_HOME/bin/llama-turboquant" ] || \
   ls "$_REAL_HOME/bin/llama-turboquant-"* &>/dev/null 2>&1; then
  COMP_STATUS[turboquant]="ok"
  COMP_VER[turboquant]="$(infra_state_get "TURBOQUANT_BUILD_MODE" "ismeretlen")"
else
  COMP_STATUS[turboquant]="missing"; COMP_VER[turboquant]=""
fi

# AI SDK-k: Python import ellenőrzés a venv-ben
# LangChain
if [ "${COMP_STATUS[venv]}" = "ok" ] && \
   "$VENV_PY" -c "import langchain" 2>/dev/null; then
  COMP_STATUS[langchain]="ok"
  COMP_VER[langchain]=$("$VENV_PY" -c "import langchain; print(langchain.__version__)" 2>/dev/null || echo "ok")
else
  COMP_STATUS[langchain]="missing"; COMP_VER[langchain]=""
fi

# Anthropic SDK
if [ "${COMP_STATUS[venv]}" = "ok" ] && \
   "$VENV_PY" -c "import anthropic" 2>/dev/null; then
  COMP_STATUS[anthropic]="ok"
  COMP_VER[anthropic]=$("$VENV_PY" -c "import anthropic; print(anthropic.__version__)" 2>/dev/null || echo "ok")
else
  COMP_STATUS[anthropic]="missing"; COMP_VER[anthropic]=""
fi

# HuggingFace Transformers
if [ "${COMP_STATUS[venv]}" = "ok" ] && \
   "$VENV_PY" -c "import transformers" 2>/dev/null; then
  COMP_STATUS[hf]="ok"
  COMP_VER[hf]=$("$VENV_PY" -c "import transformers; print(transformers.__version__)" 2>/dev/null || echo "ok")
else
  COMP_STATUS[hf]="missing"; COMP_VER[hf]=""
fi

# ── Komponens státusz összesítése ─────────────────────────────────────────────
log_comp_status "${COMP_CHECK[@]}"

# Hiányzó komponensek megszámlálása a futtatási mód döntéshez
COMP_KEYS=(uv venv torch ollama vllm turboquant langchain anthropic hf)
MISSING_COUNT=0
for _k in "${COMP_KEYS[@]}"; do
  [ "${COMP_STATUS[$_k]:-missing}" = "missing" ] && ((MISSING_COUNT++))
done

# =============================================================================
# SZEKCIÓ 5 — INFRA FEJLÉC + FUTTATÁSI MÓD DÖNTÉS
# =============================================================================

# ── Infra header logba ────────────────────────────────────────────────────────
log_infra_header "    • Ollama v${MIN_VER[ollama]}+    — lokális LLM szerver (OpenAI API kompatibilis)
    • vLLM v${MIN_VER[vllm]}+       — GPU inferencia szerver (CUDA ${INST_CUDA_VER} / ${PYTORCH_INDEX})
    • TurboQuant            — KV cache kvantálás (llama.cpp fork, SM_${HW_CUDA_ARCH})
    • AI SDK-k              — LangChain, Anthropic, HuggingFace, ChromaDB"
log_install_paths "    /usr/local/bin/ollama                 — Ollama bináris (rendszerszintű)
    ${VENV}/                — Python AI venv (vLLM, LangChain, SDK-k)
    ${_REAL_HOME}/bin/llama-turboquant        — TurboQuant bináris (symlink)
    ${_REAL_HOME}/bin/start-vllm.sh          — vLLM indítószkript
    ${_REAL_HOME}/bin/ollama-proxy.sh        — Ollama OpenAI proxy szkript"

# ── Üdvözlő dialóg ───────────────────────────────────────────────────────────
dialog_msg "INFRA 02 — ${INFRA_NAME}" "
  GPU:     ${HW_GPU_NAME:-NVIDIA (detektálás folyamatban)}
  Profil:  ${HW_PROFILE}  |  CUDA arch: SM_${HW_CUDA_ARCH}
  vLLM:    $(${HW_VLLM_OK} && echo '✓ GPU módban fut (SM_70+)' || echo '⚠ Nem elérhető (SM<70)')
  PyTorch: ${PYTORCH_INDEX}
  TQ mód:  ${TQ_DEFAULT_MODE}

  ── Telepítendő komponensek ──────────────────────────────
    Ollama         lokális LLM szerver (llama.cpp alapú)
    vLLM           GPU-optimalizált inferencia szerver
    TurboQuant     KV cache kvantálás (+35% RTX 5090-en)
    LangChain      RAG pipeline és AI workflow keretrendszer
    Anthropic SDK  Claude API integráció
    HuggingFace    Transformers + Datasets + Accelerate
    ChromaDB       lokális vektor adatbázis (RAG)
  ─────────────────────────────────────────────────────────

  Futási idő:  ~10–30 perc (TurboQuant fordítással)
  Log: ${LOGFILE_AI}" 28

# ── Futtatási mód döntés ──────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════════════
# [FIX v6.4] CHECK MÓD EARLY EXIT
# ══════════════════════════════════════════════════════════════════════════════
# check módban SEMMI sem települ/fordul/töltődik le — EARLY EXIT!
# v6.2-ban: MISSING_COUNT>0 → "install mód" log de check guard HIÁNYZOTT
# → telepítési dialógok megjelentek → TQ build → 7+ perces check módos futás!
if [ "$RUN_MODE" = "check" ]; then
  log "MODE" "check mód — read-only, csak státusz (semmi sem települ/fordul)"
  if [ "$MISSING_COUNT" -gt 0 ]; then
    _missing_list=""
    for _k in "${COMP_KEYS[@]}"; do
      [ "${COMP_STATUS[$_k]:-missing}" = "missing" ] && _missing_list+="    ✗ ${_k}\n"
    done
    dialog_warn "INFRA 02 — Ellenőrzés [check]" \
      "\n  ${MISSING_COUNT} hiányzó komponens:\n\n${_missing_list}\n  Telepítéshez: install módot válassz.\n  Gyorsjavításhoz: fix módot válassz (reboot nélkül)." 20
  else
    dialog_msg "INFRA 02 — Ellenőrzés [check] ✓" \
      "\n  Minden komponens telepítve és elérhető.\n  Log: ${LOGFILE_AI}" 12
  fi
  # State: ha volt MOD_02_DONE=true, megtartjuk; ha nem, nem állítjuk
  [ "$(infra_state_get "MOD_02_DONE" "")" = "true" ] && \
    infra_state_set "MOD_02_DONE" "true"
  chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
  chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
  log "MODE" "check mód befejezve"
  exit 0
fi

# detect_run_mode() a 00_lib.sh-ban: ha minden OK → skip/update/reinstall
# Ha bármi hiányzik VAGY fix/reinstall mód → nincs override
# fix mód = install-szerű, reboot nélkül (02-ban nincs reboot amúgy sem)
if [ "$MISSING_COUNT" -eq 0 ] && \
   [ "$RUN_MODE" != "fix" ]    && \
   [ "$RUN_MODE" != "reinstall" ]; then
  detect_run_mode COMP_KEYS   # módosítja a RUN_MODE változót
else
  log "MODE" "Hiányzó: ${MISSING_COUNT} | mód: ${RUN_MODE} → nincs override"
fi

# Skip esetén state-et írunk és kilépünk
[ "$RUN_MODE" = "skip" ] && {
  dialog_msg "02 kihagyva" "\n  Minden komponens naprakész.\n  MOD_02_DONE state írva." 10
  infra_state_set "MOD_02_DONE" "true"
  exit 0
}

# Összesítő számláló a show_result()-hoz
OK=0; SKIP=0; FAIL=0

# ── Komponens telepítési terv megjelenítése ───────────────────────────────────
STATUS_MSG=""
for _k in "${COMP_KEYS[@]}"; do
  STATUS_MSG+="$(comp_line "$_k" "$_k")"$'\n'
done

dialog_yesno "Telepítési terv — INFRA 02" \
  "\n  Mód: [${RUN_MODE}]\n\n${STATUS_MSG}\n  Folytatjuk a telepítéssel?" 24 \
  || { dialog_msg "Kilépés" "\n  02 megszakítva."; exit 0; }

# =============================================================================
# SZEKCIÓ 6 — TELEPÍTÉSI LÉPÉSEK
# =============================================================================

# ── 6a. uv ellenőrzés / telepítés ────────────────────────────────────────────
# Az uv-t a 03-as modul már telepítette; itt csak ellenőrizzük.
# Ha mégis hiányzik (pl. manuális 02 futtatás): telepítjük.
# Forrás: https://docs.astral.sh/uv/getting-started/installation/
if [ "${COMP_STATUS[uv]}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  log "STEP" "uv telepítése / frissítése..."
  run_with_progress "uv telepítése" "Az Astral uv package manager letöltése és telepítése..." \
    bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
  # PATH frissítés: az uv install.sh ~/.local/bin-be rakja az uv-t
  export PATH="$_REAL_HOME/.local/bin:$PATH"
  command -v uv &>/dev/null && ((OK++)) || ((FAIL++))
fi

# ── 6b. Python AI venv ellenőrzés ────────────────────────────────────────────
# A venv-et a 03-as modul hozta létre. Ha mégis hiányzik: figyelmeztetés.
# Ez általában a 03-as modul hiányát jelzi → infra_require("03") már elkapta.
if [ "${COMP_STATUS[venv]}" != "ok" ]; then
  dialog_warn "Python AI venv hiányzik" \
    "\n  Helyszín: ${VENV}\n\n  A venv-et a 03-as modulnak kellett létrehoznia.\n  Ellenőrizd: bash 03_python_aiml.sh\n\n  Próbáljuk most létrehozni Python 3.12-vel?" 16

  # Megkeressük a Python 3.12 binárist pyenv-ben
  PY312=""
  [ -x "${PYENV_ROOT}/versions/3.12.9/bin/python3.12" ] \
    && PY312="${PYENV_ROOT}/versions/3.12.9/bin/python3.12"
  # Fallback: bármely pyenv 3.12.x
  [ -z "$PY312" ] && PY312=$(find "${PYENV_ROOT}/versions" -name "python3.12" 2>/dev/null | head -1)
  [ -z "$PY312" ] && PY312=$(command -v python3.12 2>/dev/null)

  if [ -z "$PY312" ]; then
    dialog_warn "Python 3.12 nem található" \
      "\n  Python 3.12 bináris nem elérhető.\n  Futtasd előbb: bash 03_python_aiml.sh\n\n  02 folytatás megszakítva." 12
    ((FAIL++))
  else
    log "VENV" "venv létrehozása: ${VENV} (Python: ${PY312})"
    mkdir -p "$(dirname "$VENV")"
    run_with_progress "venv létrehozása" "${VENV} venv létrehozása..." \
      "$UV" venv "$VENV" --python "$PY312"
    [ -x "$VENV_PY" ] && { COMP_STATUS[venv]="ok"; ((OK++)); } || ((FAIL++))
  fi
fi

# ── 6c. Ollama telepítése ────────────────────────────────────────────────────
# Ollama: llama.cpp alapú lokális LLM szerver. Egyszerű telepítő szkript.
# Forrás: https://ollama.readthedocs.io/en/
# sudo szükséges: /usr/local/bin/ollama + systemd service telepítéshez
if [ "${COMP_STATUS[ollama]}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  dialog_yesno "Ollama telepítése" \
    "\n  Ollama: lokális LLM szerver (llama.cpp alapú)\n  OpenAI kompatibilis REST API: http://localhost:11434\n\n  Telepítési módszer: curl https://ollama.ai/install.sh | sh\n  Telepítési hely:   /usr/local/bin/ollama\n  systemd service:   ollama.service\n\n  sudo szükséges a rendszerszintű telepítéshez.\n\n  Folytatjuk?" 18 \
  && {
    # Ollama telepítő futtatása háttérben, progress bar alatt
    # FONTOS: az Ollama install.sh sudo-t igényel (rendszer PATH-ra kerül)
    sudo_run bash -c "curl -fsSL https://ollama.ai/install.sh | sh" \
      >> "$LOGFILE_AI" 2>&1 &
    OLLAMA_PID=$!

    progress_open "Ollama telepítése" "Ollama letöltése és telepítése..."
    _pct=5
    while kill -0 $OLLAMA_PID 2>/dev/null; do
      progress_set "$_pct" "Ollama telepítése..."
      sleep 1
      [ $_pct -lt 88 ] && ((_pct+=4))
    done
    wait $OLLAMA_PID
    progress_close

    if command -v ollama &>/dev/null; then
      # Systemd service regisztrálása és indítása
      # Forrás: Ollama Linux install dokumentáció
      sudo_run systemctl enable ollama 2>/dev/null || true
      sudo_run systemctl start  ollama 2>/dev/null || true

      # [FIX v6.4] Ollama verzió retry — 'ollama version' service start után nem válaszol
      # Forrás: https://ollama.readthedocs.io/en/ — 'ollama version' az official CLI
      OLLAMA_VER=""
      _retry=0
      while [ -z "$OLLAMA_VER" ] && [ $_retry -lt 5 ]; do
        sleep 1
        OLLAMA_VER=$(ollama version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        [ -z "$OLLAMA_VER" ] && \
          OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        ((_retry++))
      done
      # Dpkg fallback
      [ -z "$OLLAMA_VER" ] && \
        OLLAMA_VER=$(dpkg -l ollama 2>/dev/null | awk '/^ii/{print $3}' \
                     | grep -oP '\d+\.\d+\.\d+' | head -1)
      [ -z "$OLLAMA_VER" ] && OLLAMA_VER="telepítve"

      ((OK++))
      # Comp státusz frissítése a re-verify után
      COMP_STATUS[ollama]="ok"; COMP_VER[ollama]="$OLLAMA_VER"
      infra_state_set "INST_OLLAMA_VER" "$OLLAMA_VER"
      infra_state_set "FEAT_OLLAMA_GPU" "$(hw_has_nvidia && echo true || echo false)"
      log "OK" "Ollama telepítve: v${OLLAMA_VER} (retry: ${_retry})"

      dialog_msg "Ollama — Telepítve ✓" \
        "\n  ✓  Ollama: v${OLLAMA_VER}\n  ✓  systemd service: ollama.service\n  ✓  GPU: $(hw_has_nvidia && echo 'igen (NVIDIA)' || echo 'CPU-only')\n\n  API: http://localhost:11434\n  Első modell: ollama pull qwen2.5-coder:7b" 14
    else
      ((FAIL++))
      log "FAIL" "Ollama telepítés sikertelen"
      dialog_warn "Ollama — Hiba" "\n  Az Ollama telepítés sikertelen.\n  Részletek: ${LOGFILE_AI}" 10
    fi
  } || ((SKIP++))
fi

# ── 6d. vLLM telepítése ───────────────────────────────────────────────────────
# vLLM: GPU-optimalizált inferencia szerver.
# FONTOS: vLLM felülírja a PyTorch-ot ha nem pin-eljük előtte!
#   Megoldás: 1. pin cu126-os PyTorch → 2. vLLM --no-build-isolation
# Forrás: https://docs.vllm.ai/en/latest/getting_started/installation.html
#
# HARDVER FELTÉTEL: HW_VLLM_OK=true (SM_70+ NVIDIA szükséges)
if ${HW_VLLM_OK}; then
  if [ "${COMP_STATUS[vllm]}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
    dialog_yesno "vLLM telepítése" \
      "\n  vLLM: GPU-optimalizált LLM inferencia szerver\n  PagedAttention v2 + continuous batching\n\n  GPU: ${HW_GPU_NAME}\n  CUDA: ${INST_CUDA_VER} (${PYTORCH_INDEX})\n\n  FONTOS: A PyTorch verziót pin-eljük hogy vLLM ne\n  írja felül a ${PYTORCH_INDEX}-os verziót!\n\n  Letöltési méret: ~500 MB\n  Venv: ${VENV}\n\n  Folytatjuk?" 20 \
    && {
      # 1. lépés: PyTorch pin a cu126/cu128 verzióhoz
      # Anélkül a vLLM az alap CPU PyTorch-ot installálja — ez KERÜLENDŐ!
      log "VLLM" "PyTorch pin: ${PYTORCH_INDEX}"
      "$UV" pip install \
        --python "$VENV_PY" \
        torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/${PYTORCH_INDEX}" \
        --force-reinstall >> "$LOGFILE_AI" 2>&1 \
      || log "WARN" "PyTorch pin hiba — vLLM install folytatódik"

      # 2. lépés: vLLM telepítése --no-build-isolation-nal
      # --no-build-isolation: nem hozza létre saját build env-et →
      #   az előzőleg pinnelt PyTorch verziót fogja látni
      log "VLLM" "vLLM telepítése (--no-build-isolation)..."
      "$UV" pip install \
        --python "$VENV_PY" \
        vllm \
        --no-build-isolation >> "$LOGFILE_AI" 2>&1 &
      VLLM_PID=$!

      progress_open "vLLM telepítése" "uv pip install vllm (${PYTORCH_INDEX})..."
      _vpct=5
      while kill -0 $VLLM_PID 2>/dev/null; do
        progress_set "$_vpct" "vLLM telepítése (~500 MB)..."
        sleep 3
        [ $_vpct -lt 88 ] && ((_vpct+=2))
      done
      wait $VLLM_PID
      progress_close

      if "$VENV_PY" -c "import vllm" 2>/dev/null; then
        VLLM_VER=$("$VENV_PY" -c "import vllm; print(vllm.__version__)" 2>/dev/null || echo "")
        ((OK++))
        infra_state_set "INST_VLLM_VER"  "$VLLM_VER"
        infra_state_set "FEAT_VLLM"      "true"
        log "OK" "vLLM telepítve: v${VLLM_VER}"
      else
        ((FAIL++))
        infra_state_set "FEAT_VLLM" "false"
        log "FAIL" "vLLM import sikertelen — PyTorch/CUDA kompatibilitás ellenőrizd"
        dialog_warn "vLLM — Hiba" \
          "\n  vLLM install sikertelen.\n\n  Lehetséges ok: PyTorch ↔ CUDA verzió inkompatibilitás.\n  Telepített CUDA: ${INST_CUDA_VER}\n  PyTorch index:  ${PYTORCH_INDEX}\n\n  Log: ${LOGFILE_AI}" 16
      fi
    } || ((SKIP++))
  fi
else
  # vLLM nem elérhető ezen a hardveren (SM<70)
  log "SKIP" "vLLM kihagyva: HW_VLLM_OK=false (profil: ${HW_PROFILE})"
  infra_state_set "FEAT_VLLM" "false"
  ((SKIP++))
  dialog_msg "vLLM — Kihagyva" \
    "\n  vLLM CUDA SM_70+ GPU-t igényel.\n\n  Jelenlegi GPU: ${HW_GPU_NAME}\n  CUDA arch:    SM_${HW_CUDA_ARCH}\n\n  Ollama CPU-only módban fut — vLLM nélkül is használható.\n  TurboQuant llama.cpp fork telepítése folytatódik." 14
fi

# ── 6e. AI SDK-k telepítése ───────────────────────────────────────────────────
# LangChain + Anthropic + HuggingFace + ChromaDB + egyéb AI csomagok.
# Egyszerre telepítjük uv pip install-lal (gyorsabb mint egyenként).
# Forrás: PyPI + LangChain docs + Anthropic SDK docs
if [ "${COMP_STATUS[langchain]}" != "ok" ] || \
   [ "${COMP_STATUS[anthropic]}" != "ok" ] || \
   [ "${COMP_STATUS[hf]}" != "ok" ] || \
   [ "$RUN_MODE" = "reinstall" ]; then

  dialog_yesno "AI SDK-k telepítése" \
    "\n  Telepítendő csomagok:\n\n    LangChain + langchain-anthropic   — RAG + workflow\n    Anthropic SDK                      — Claude API\n    HuggingFace Transformers/Datasets  — modellek\n    sentence-transformers              — embedding\n    ChromaDB                           — vektor DB\n    OpenAI SDK                         — Ollama/vLLM API kompatibilitás\n\n  Méret: ~350–450 MB\n  Venv: ${VENV}\n\n  Folytatjuk?" 20 \
  && {
    log "SDK" "AI SDK-k telepítése: ${AI_PKGS[*]}"

    "$UV" pip install \
      --python "$VENV_PY" \
      "${AI_PKGS[@]}" \
      >> "$LOGFILE_AI" 2>&1 \
    && {
      ((OK++))
      log "OK" "AI SDK-k telepítve: LangChain + Anthropic + HuggingFace + ChromaDB"
    } || {
      ((FAIL++))
      log "FAIL" "AI SDK telepítés részben sikertelen — log: ${LOGFILE_AI}"
      dialog_warn "AI SDK — Figyelmeztetés" \
        "\n  Egyes SDK-k nem települtek.\n  Részletek: ${LOGFILE_AI}\n\n  A hiányzókat manuálisan pótold:\n    uv pip install --python ${VENV_PY} langchain anthropic transformers" 14
    }
  } || ((SKIP++))
fi

# =============================================================================
# SZEKCIÓ 7 — TURBOQUANT llama.cpp fork fordítása
# =============================================================================
# TurboQuant: Google Research (ICLR 2026) KV cache kvantálás.
# Algoritmus: PolarQuant + QJL (Quantized JL transform)
#   - 3-bit KV cache: 6x kisebb → 6x hosszabb kontextus ugyanannyi VRAM-ban
#   - RTX 5090 (Blackwell): +35% decode speed (PR#36 benchmark)
#   - Tréning nélkül alkalmazható (post-training, plug-in)
#
# Forrás: https://arxiv.org/pdf/2504.19874
#         https://github.com/0xSero/turboquant
#         https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/
#
# MEGJEGYZÉS: A TurboQuant vLLM-től FÜGGETLEN — az Ollama/llama.cpp GGUF
# modellekhez való. A vLLM saját fp8 KV cache-szel dolgozik (--kv-cache-dtype fp8).

# ── [FIX v6.4] TurboQuant pre-check — ne fordítsuk újra ha már kész ──────────
# v6.2-ban minden futáskor felajánlotta az újrafordítást, még ha
# FEAT_TURBOQUANT=true volt és binary is létezett.
# Pre-check: binary OK + FEAT_TURBOQUANT=true + nem reinstall/update → skip
_tq_bin_ok=false
[ -f "${_REAL_HOME}/bin/llama-turboquant" ]             && _tq_bin_ok=true
ls "${_REAL_HOME}/bin/llama-turboquant-"* &>/dev/null 2>&1 && _tq_bin_ok=true
_tq_already_built=false
if $_tq_bin_ok && \
   [ "$(infra_state_get "FEAT_TURBOQUANT" "false")" = "true" ] && \
   [ "$RUN_MODE" != "reinstall" ] && \
   [ "$RUN_MODE" != "update" ]; then
  _tq_already_built=true
fi

if $_tq_already_built; then
  _tq_prev_mode=$(infra_state_get "TURBOQUANT_BUILD_MODE" "ismeretlen")
  log "SKIP" "TurboQuant már kész (${_tq_prev_mode}) — kihagyva (reinstall/update = újrafordítás)"
  ((SKIP++))
  dialog_msg "TurboQuant — Már kész ✓" \
    "\n  Binary megtalálva: ~/bin/llama-turboquant\n  Mód: ${_tq_prev_mode}\n\n  Újrafordításhoz: update/reinstall módot válassz.\n\n  Teszt:\n    ~/bin/llama-turboquant --version" 16
else

# ── TurboQuant hardver detektálás ────────────────────────────────────────────
TQ_CUDA_VER=$(PATH="/usr/local/cuda/bin:$PATH" nvcc --version 2>/dev/null \
              | grep -oP 'release \K[\d.]+' | head -1 || echo "${INST_CUDA_VER}")
TQ_GPU_PCI=$(lspci -nn 2>/dev/null \
             | grep -i "VGA.*NVIDIA\|3D controller.*NVIDIA" \
             | grep -oP '(?<=10de:)[0-9a-fA-F]+' | head -1 \
             | tr '[:upper:]' '[:lower:]')
TQ_IS_BLACKWELL=false
[[ "${TQ_GPU_PCI:0:2}" =~ ^(2b|2c)$ ]] && TQ_IS_BLACKWELL=true

log "TQ" "Detektálva: PCI=10de:${TQ_GPU_PCI} | Blackwell=${TQ_IS_BLACKWELL} | CUDA=${TQ_CUDA_VER}"

_rebuild_note=""
[ "$RUN_MODE" = "update" ]    && _rebuild_note=" (update — újrafordítás)"
[ "$RUN_MODE" = "reinstall" ] && _rebuild_note=" (reinstall — teljes újrafordítás)"

dialog_yesno "TurboQuant llama.cpp fork fordítása${_rebuild_note}" \
  "\n  TurboQuant (ICLR 2026) — KV cache kvantálás\n\n  GPU:      NVIDIA (PCI: 10de:${TQ_GPU_PCI:-?})\n  Blackwell: $([ "$TQ_IS_BLACKWELL" = true ] && echo 'IGEN — SM_120 elérhető' || echo 'nem')\n  CUDA:     ${TQ_CUDA_VER}\n\n  FORDÍTÁSI MÓDOK:\n    CPU     — gyors, nincs GPU gyorsítás\n    GPU-89  — CUDA SM_89 (Ada fallback, cu126 OK)\n    GPU-120 — CUDA SM_120 (Blackwell natív, cu128 kell)\n\n  Az INFRA 02 által ajánlott mód: ${TQ_DEFAULT_MODE}\n\n  Folytatjuk?" 22 \
&& {

  # ── Build mód választás dialóg ──────────────────────────────────────────────
  BLACKWELL_NOTE=""
  $TQ_IS_BLACKWELL && BLACKWELL_NOTE="  ← RTX 5090 AJÁNLOTT (natív SM_120)"

  TQ_BUILD_MODE=$(dialog_menu "TurboQuant fordítási mód" \
    "\n  GPU: NVIDIA 10de:${TQ_GPU_PCI:-?}\n  CUDA: ${TQ_CUDA_VER}  |  Blackwell: $([ "$TQ_IS_BLACKWELL" = true ] && echo 'IGEN' || echo 'nem')\n\n  CPU:     Nincs CUDA — mindig fordítható\n  GPU-89:  CUDA SM_89 (Ada Lovelace) — cu126-tal működik\n  GPU-120: CUDA SM_120 (Blackwell natív) — cu128 Nightly kell!\n\n  SM_120 előnye RTX 5090-en:\n    FP4/FP8 Tensor mag natív kihasználása\n    GDDR7 sávszélesség optimalizálás\n    Fusált TurboQuant Triton kernelek" \
    24 3 \
    "cpu"    "CPU-only fordítás (lassú, de biztos)" \
    "gpu89"  "GPU SM_89 — Ada Lovelace fallback (cu126 OK)" \
    "gpu120" "GPU SM_120 — Blackwell natív${BLACKWELL_NOTE}")

  # Ha a user nem választott, kihagyjuk a TQ fordítást
  [ -z "$TQ_BUILD_MODE" ] && { ((SKIP++)); } || {

    # ── cu128 figyelmeztetés ha SM_120 választva de CUDA < 12.8 ───────────────
    # [FIX v6.4] 'local _cuda_major _cuda_minor' top szinten → eltávolítva
    if [ "$TQ_BUILD_MODE" = "gpu120" ]; then
      _cuda_major=$(echo "${TQ_CUDA_VER:-0.0}" | cut -d. -f1)
      _cuda_minor=$(echo "${TQ_CUDA_VER:-0.0}" | cut -d. -f2)

      if [ "${_cuda_major:-0}" -lt 12 ] || \
         ( [ "${_cuda_major:-0}" -eq 12 ] && [ "${_cuda_minor:-0}" -lt 8 ] ); then
        dialog_warn "SM_120 — CUDA 12.8+ szükséges!" \
          "\n  Telepített CUDA: ${TQ_CUDA_VER}\n  SM_120 (Blackwell natív) fordításhoz: CUDA 12.8+\n\n  OPCIÓ 1 — CUDA 12.8 frissítés:\n    sudo apt install cuda-toolkit-12-8\n    uv pip install --pre torch \\\\\n      --index-url https://download.pytorch.org/whl/nightly/cu128\n\n  OPCIÓ 2 — GPU-89-re váltás (cu126 OK):\n    Fut RTX 5090-en is, de nem natív Blackwell.\n\n  Visszaváltunk GPU-89-re?" 22

        [ $? -eq 0 ] && {
          TQ_BUILD_MODE="gpu89"
          log "TQ" "Visszaváltás GPU-89-re (CUDA ${TQ_CUDA_VER} < 12.8)"
          dialog_msg "Visszaváltás — GPU-89" "\n  OK — GPU-89 módban fordítunk.\n  Ada Lovelace fallback, cu126-tal működik." 8
        }
      fi
    fi

    # ── Repo + könyvtár meghatározása ─────────────────────────────────────────
    TQ_REPO_URL="${TQ_REPOS[$TQ_BUILD_MODE]}"
    TQ_ARCH_LBL="${TQ_ARCH_LABEL[$TQ_BUILD_MODE]}"
    TQ_DIR="${_REAL_HOME}/src/llama-turboquant-${TQ_BUILD_MODE}"
    mkdir -p "${_REAL_HOME}/src" "${_REAL_HOME}/bin"

    # SM_120 fork tájékoztató
    if [ "$TQ_BUILD_MODE" = "gpu120" ]; then
      dialog_msg "TurboQuant — 0xSero fork (SM_120)" \
        "\n  SM_120 fordításhoz a 0xSero forkot használjuk:\n  ${TQ_REPO_URL}\n\n  Ez a fork tartalmaz:\n    SM_120 explicit CUDA architektúra tám.\n    Blackwell FP4/FP8 Tensor mag optimalizálást\n    Fusált TurboQuant Triton kerneleket" 14
    fi

    # ── Klónozás ───────────────────────────────────────────────────────────────
    if [ ! -d "$TQ_DIR" ] || [ "$RUN_MODE" = "reinstall" ]; then
      [ -d "$TQ_DIR" ] && rm -rf "$TQ_DIR"
      log "TQ" "git clone: ${TQ_REPO_URL} → ${TQ_DIR}"
      run_with_progress "TurboQuant klónozás" \
        "Klónozás: ${TQ_REPO_URL}..." \
        git clone --depth=1 "$TQ_REPO_URL" "$TQ_DIR"
    else
      log "TQ" "Könyvtár már létezik: ${TQ_DIR} — klónozás kihagyva"
    fi

    # ── Build-függőségek (cmake, build-essential) ──────────────────────────────
    if ! command -v cmake &>/dev/null; then
      log "TQ" "cmake hiányzik — telepítés..."
      apt_install_log "cmake build-essential" cmake build-essential ninja-build
    fi

    # ── CMake konfiguráció + fordítás ─────────────────────────────────────────
    cd "$TQ_DIR" || { log "FAIL" "TurboQuant könyvtár nem elérhető: ${TQ_DIR}"; ((FAIL++)); }
    rm -rf build

    NVCC_INFO=$(PATH="/usr/local/cuda/bin:$PATH" nvcc --version 2>/dev/null \
                | head -1 || echo "nvcc: nem elérhető")

    # ── [FIX v6.4] cmake args BASH ARRAY — nem declare -A string expansion!  ──
    # BUG v6.2: ${TQ_CMAKE_FLAGS[$TQ_BUILD_MODE]} → unquoted → word split → üres!
    # Logban: 'cmake flags: ' üres → cmake -B build (semmi) → CPU-only build lett
    # Megoldás: case statement + TQ_CMAKE_ARGS=() bash array
    TQ_CMAKE_ARGS=()
    case "$TQ_BUILD_MODE" in
      cpu)
        TQ_CMAKE_ARGS=(-DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release)
        ;;
      gpu89)
        TQ_CMAKE_ARGS=(-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 -DCMAKE_BUILD_TYPE=Release)
        ;;
      gpu120)
        TQ_CMAKE_ARGS=(-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 -DCMAKE_BUILD_TYPE=Release)
        ;;
      *)
        TQ_CMAKE_ARGS=(-DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release)
        log "WARN" "Ismeretlen TQ_BUILD_MODE: ${TQ_BUILD_MODE} → CPU fallback"
        ;;
    esac
    log "TQ" "cmake args: ${TQ_CMAKE_ARGS[*]}"

    # TurboQuant saját build log
    # [FIX v6.4] touch + chmod ELŐRE → Hugo alatt is olvasható lesz
    LOGFILE_TQ="${_REAL_HOME}/AI-LOG-INFRA-SETUP/turboquant_${TQ_BUILD_MODE}_$(date '+%Y%m%d_%H%M%S').log"
    log "TQ" "Build log: ${LOGFILE_TQ}"
    touch "$LOGFILE_TQ"
    chmod 644 "$LOGFILE_TQ"
    chown "${_REAL_USER}:${_REAL_USER}" "$LOGFILE_TQ" 2>/dev/null || true

    progress_open "TurboQuant fordítása" "${TQ_ARCH_LBL}..."
    log_term "cmake: ${TQ_CMAKE_ARGS[*]}"

    # cmake konfiguráció — "${TQ_CMAKE_ARGS[@]}" expansion: minden arg külön
    progress_set 5 "cmake konfiguráció (${TQ_ARCH_LBL})..."
    PATH="/usr/local/cuda/bin:$PATH" \
      cmake -B build "${TQ_CMAKE_ARGS[@]}" >> "$LOGFILE_TQ" 2>&1
    CMAKE_EC=$?
    chmod 644 "$LOGFILE_TQ" 2>/dev/null || true   # cmake után frissítés

    if [ $CMAKE_EC -ne 0 ]; then
      progress_close
      log "FAIL" "TurboQuant cmake hiba (exit ${CMAKE_EC}) — log: ${LOGFILE_TQ}"
      ((FAIL++))
      dialog_warn "TurboQuant — cmake hiba" \
        "\n  cmake konfiguráció sikertelen (exit ${CMAKE_EC}).\n\n  Lehetséges okok:\n    GPU-120: CUDA 12.8+ szükséges\n    GPU-89:  nvcc nem elérhető\n    CPU:     build-essential hiányzik\n\n  Részletes log: ${LOGFILE_TQ}" 18
    else
      NPROC=$(nproc 2>/dev/null || echo 4)
      progress_set 20 "Fordítás (${NPROC} mag)... ~10–25 perc"
      log "TQ" "cmake --build (${NPROC} mag)..."

      cmake --build build --config Release -j"$NPROC" >> "$LOGFILE_TQ" 2>&1
      BUILD_EC=$?
      chmod 644 "$LOGFILE_TQ" 2>/dev/null || true   # build után frissítés
      chown "${_REAL_USER}:${_REAL_USER}" "$LOGFILE_TQ" 2>/dev/null || true

      if [ $BUILD_EC -ne 0 ]; then
        progress_close
        log "FAIL" "TurboQuant build hiba (exit ${BUILD_EC}) — log: ${LOGFILE_TQ}"
        ((FAIL++))
        dialog_warn "TurboQuant — fordítási hiba" \
          "\n  cmake --build sikertelen (exit ${BUILD_EC}).\n\n  Részletes log: ${LOGFILE_TQ}" 12
      else
        # ── Bináris másolása és symlink ───────────────────────────────────────
        progress_set 90 "Bináris másolása ~/bin-be..."
        BINARY_NAME="llama-turboquant-${TQ_BUILD_MODE}"

        if [ -f "build/bin/llama-cli" ]; then
          cp "build/bin/llama-cli" "${_REAL_HOME}/bin/${BINARY_NAME}"
          chmod +x "${_REAL_HOME}/bin/${BINARY_NAME}"
          ln -sf "${_REAL_HOME}/bin/${BINARY_NAME}" "${_REAL_HOME}/bin/llama-turboquant"
          log "OK" "TurboQuant bináris: ~/bin/${BINARY_NAME} + symlink"
        else
          log "WARN" "build/bin/llama-cli nem található — bináris keresés fallback"
          _found=$(find build -name "llama-cli" -type f 2>/dev/null | head -1)
          if [ -n "$_found" ]; then
            cp "$_found" "${_REAL_HOME}/bin/${BINARY_NAME}"
            chmod +x "${_REAL_HOME}/bin/${BINARY_NAME}"
            ln -sf "${_REAL_HOME}/bin/${BINARY_NAME}" "${_REAL_HOME}/bin/llama-turboquant"
            log "OK" "TurboQuant bináris (fallback path): ~/bin/${BINARY_NAME}"
          fi
        fi

        progress_close

        if [ -f "${_REAL_HOME}/bin/${BINARY_NAME}" ]; then
          ((OK++))
          infra_state_set "FEAT_TURBOQUANT"        "true"
          infra_state_set "TURBOQUANT_BUILD_MODE"  "$TQ_BUILD_MODE"

          dialog_msg "TurboQuant — Fordítás kész ✓" \
            "\n  Mód:    ${TQ_ARCH_LBL}\n  Repo:   ${TQ_REPO_URL}\n  CUDA:   ${NVCC_INFO}\n  Binary: ~/bin/${BINARY_NAME}\n  Link:   ~/bin/llama-turboquant → ${BINARY_NAME}\n\n  Teszt:\n    ~/bin/llama-turboquant --version\n\n  Futtatás GGUF modellel:\n    ~/bin/llama-turboquant \\\\\n      -m ~/models/qwen2.5-coder-32b-q4.gguf \\\\\n      --kv-quant turbo3 -p 'def fibonacci(n):'" 22
        else
          ((FAIL++))
          infra_state_set "FEAT_TURBOQUANT" "false"
          log "FAIL" "TurboQuant bináris nem jött létre: ~/bin/${BINARY_NAME}"
          dialog_warn "TurboQuant — Bináris hiányzik" \
            "\n  A fordítás sikeresnek tűnt, de a bináris nem jött létre.\n\n  Elvárt: ~/bin/${BINARY_NAME}\n  Build log: ${LOGFILE_TQ}" 16
        fi
      fi
    fi

    cd "$SCRIPT_DIR" || true   # visszatér a script könyvtárába
  }  # TQ_BUILD_MODE nem üres
} || {
  ((SKIP++))
  log "SKIP" "TurboQuant fordítás kihagyva (user döntés)"
}

fi  # _tq_already_built

# =============================================================================
# SZEKCIÓ 8 — INDÍTÓSZKRIPTEK GENERÁLÁSA
# =============================================================================
# Kényelmi szkriptek amelyeket a user azonnal használhat.
# ~/bin/-be kerülnek, a PATH-hoz a 03-as modul már hozzáadta.

mkdir -p "${_REAL_HOME}/bin"

# ── vLLM indítószkript (start-vllm.sh) ───────────────────────────────────────
# Forrás: https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html
# --kv-cache-dtype fp8: vLLM beépített fp8 KV cache (KÜLÖNBÖZIK a TurboQuant-tól!)
# TurboQuant a llama.cpp GGUF modellekhez való; vLLM --kv-cache-dtype az OpenAI
# szerver módhoz. Mindkettő KV cache tömörítés, de különböző rétegen.
if ${HW_VLLM_OK} && [ ! -f "${_REAL_HOME}/bin/start-vllm.sh" ]; then
  log "SCRIPT" "start-vllm.sh generálása..."
  cat > "${_REAL_HOME}/bin/start-vllm.sh" << VLLMEOF
#!/bin/bash
# =============================================================================
# start-vllm.sh — vLLM OpenAI API szerver indítója
# Generálva: INFRA 02 v6.4 — $(date '+%Y-%m-%d')
#
# Használat: ~/bin/start-vllm.sh [MODEL] [PORT]
# Pl.:       ~/bin/start-vllm.sh meta-llama/Llama-3.2-8B-Instruct 8000
#
# Forrás: https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html
# =============================================================================

MODEL="\${1:-meta-llama/Llama-3.2-8B-Instruct}"
PORT="\${2:-8000}"

# A vLLM az AI venv-ben van — activate szükséges
source "${VENV}/bin/activate"

echo "━━━ vLLM szerver indítása ━━━"
echo "  Model:        \$MODEL"
echo "  Port:         \$PORT"
echo "  KV cache:     fp8 (vLLM beépített)"
echo "  GPU util:     90%"
echo "  Max kontextus: 32768 token"
echo ""
echo "  API: http://localhost:\${PORT}/v1"
echo "  Dokumentáció: https://docs.vllm.ai/en/latest/"
echo ""

# vLLM OpenAI kompatibilis szerver
# --dtype bfloat16:           Blackwell/Ada precision formátum
# --kv-cache-dtype fp8:       vLLM beépített KV cache tömörítés
# --gpu-memory-utilization:   VRAM kihasználás (0.9 = 90%)
# --max-model-len:            Max kontextus hossz tokenekben
# --tensor-parallel-size 1:  Egy GPU (RTX 5090 32GB elég a legtöbb modellnek)
python -m vllm.entrypoints.openai.api_server \\
  --model "\$MODEL" \\
  --port "\$PORT" \\
  --dtype bfloat16 \\
  --kv-cache-dtype fp8 \\
  --gpu-memory-utilization 0.90 \\
  --max-model-len 32768 \\
  --tensor-parallel-size 1
VLLMEOF
  chmod +x "${_REAL_HOME}/bin/start-vllm.sh"
  log "OK" "start-vllm.sh generálva: ~/bin/start-vllm.sh"
  ((OK++))
fi

# ── Ollama OpenAI-kompatibilis proxy szkript ──────────────────────────────────
# Ollama alapból a localhost 11434-en fut — ez a szkript 0.0.0.0-ra nyitja
# hogy más gépek is elérhessék, pl. Cursor/Continue.dev remote AI backend.
# OpenAI endpoint: http://localhost:11434/v1
if [ ! -f "${_REAL_HOME}/bin/ollama-proxy.sh" ]; then
  log "SCRIPT" "ollama-proxy.sh generálása..."
  cat > "${_REAL_HOME}/bin/ollama-proxy.sh" << 'PROXYEOF'
#!/bin/bash
# =============================================================================
# ollama-proxy.sh — Ollama OpenAI-kompatibilis API proxy
# Generálva: INFRA 02 v6.4
#
# Az Ollama-t 0.0.0.0-ra nyitja (alapból csak localhost).
# OpenAI kompatibilis endpoint: http://HOSTNAME:11434/v1
#
# Cursor, Continue.dev és más toolok számára:
#   Base URL: http://localhost:11434/v1
#   API key:  bármi (Ollama nem ellenőrzi)
#
# Forrás: https://ollama.readthedocs.io/en/
# =============================================================================

echo "Ollama indítása OpenAI-kompatibilis módban..."
echo "  Endpoint: http://0.0.0.0:11434/v1"
echo "  Modellek: ollama list"
echo ""
OLLAMA_HOST=0.0.0.0 ollama serve
PROXYEOF
  chmod +x "${_REAL_HOME}/bin/ollama-proxy.sh"
  log "OK" "ollama-proxy.sh generálva: ~/bin/ollama-proxy.sh"
fi

# ~/bin PATH hozzáadás (ha még nincs benne a shell RC-kben)
# A 03-as modul általában már megtette, de biztonság kedvéért itt is elvégezzük.
for RC in "${_REAL_HOME}/.zshrc" "${_REAL_HOME}/.bashrc"; do
  [ -f "$RC" ] && grep -q 'PATH.*\$HOME/bin' "$RC" 2>/dev/null \
    || { [ -f "$RC" ] && echo 'export PATH="$HOME/bin:$PATH"' >> "$RC"; }
done

# =============================================================================
# SZEKCIÓ 9 — OLLAMA MODELLEK LETÖLTÉSE (interaktív)
# =============================================================================
# Az Ollama modell letöltés opcionális — a user maga dönti el mit tölt le.
# A checklist előre kijelöl néhány ajánlott modellt.
# Modell ajánlások: RTX 5090 (32GB VRAM) profil alapján.

# Ollama elérhetőség ellenőrzés (telepített + service fut)
OLLAMA_AVAIL=false
command -v ollama &>/dev/null && OLLAMA_AVAIL=true
# Service ellenőrzés: systemctl vagy socket
if ! $OLLAMA_AVAIL; then
  systemctl is-active --quiet ollama 2>/dev/null && OLLAMA_AVAIL=true
fi

if $OLLAMA_AVAIL; then
  # Modell letöltési ajánlatok
  # Méretbecslések: ~Q4_K_M kvantálás, tipikus GGUF méret
  MODEL_MSG="
  RTX 5090 (32GB VRAM) modell ajánlások:

  KÓDGENERÁLÁS:
    qwen2.5-coder:32b    ~20GB  ← FŐ MODELL, legjobb kód (INFRA ajánlott)
    qwen2.5-coder:7b      ~5GB  ← gyors, könnyű feladatokhoz
    deepseek-coder-v2:16b ~10GB ← alternatív kódoló modell

  REASONING / ÁLTALÁNOS:
    deepseek-r1:32b      ~20GB  ← legerősebb reasoning
    qwen2.5:32b          ~20GB  ← általános, MAGYAR is!
    qwen2.5:72b          ~43GB  ← csak kvantálva fér el!

  EMBEDDING (RAG-hoz kötelező):
    nomic-embed-text      ~274MB ← helyi RAG embedding

  MULTIMODAL:
    llava:13b             ~8GB   ← kép + szöveg értés

  32GB VRAM: egyszerre 1 nagy modell (32B) futtatható."

  PULL_MODELS=$(dialog_checklist \
    "Ollama — Modellek letöltése" \
    "${MODEL_MSG}
  Válaszd ki mit töltünk le most (Space = kijelölés):" \
    32 18 \
    "qwen2.5-coder:32b"     "Kódgenerálás — FŐ modell (~20GB)"           OFF \
    "qwen2.5-coder:7b"      "Kódgenerálás — gyors, kis (~5GB)"           ON  \
    "deepseek-coder-v2:16b" "Kódgenerálás — alternatíva (~10GB)"         OFF \
    "deepseek-r1:32b"       "Reasoning — legerősebb (~20GB)"             OFF \
    "qwen2.5:32b"           "Általános + MAGYAR (~20GB)"                 OFF \
    "qwen2.5:72b"           "Nagy modell — csak kvantálva (~43GB)!"      OFF \
    "nomic-embed-text"      "RAG embedding — szükséges RAG-hoz (~274MB)" ON  \
    "llava:13b"             "Multimodal — kép+szöveg (~8GB)"             OFF)

  if [ -n "$PULL_MODELS" ]; then
    log "MODEL" "Letöltendő modellek: ${PULL_MODELS}"

    for MODEL in $(printf '%s' "$PULL_MODELS" | tr -d '"' | tr ' ' '\n'); do
      [ -z "$MODEL" ] && continue

      log "MODEL" "ollama pull: ${MODEL}"
      ollama pull "$MODEL" >> "$LOGFILE_AI" 2>&1 &
      PULL_PID=$!

      progress_open "Ollama — modell letöltés" "${MODEL}"
      _mpct=3
      while kill -0 $PULL_PID 2>/dev/null; do
        progress_set "$_mpct" "${MODEL} letöltése..."
        sleep 3
        [ $_mpct -lt 90 ] && ((_mpct++))
      done
      wait $PULL_PID
      progress_close

      if ollama list 2>/dev/null | grep -q "${MODEL%%:*}"; then
        log "OK" "Modell letöltve: ${MODEL}"
      else
        log "WARN" "Modell letöltés bizonytalan: ${MODEL} — ellenőrizd: ollama list"
      fi
    done

    # Telepített modellek listája
    INSTALLED_MODELS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print "    " $1 "  " $3}')
    dialog_msg "Modellek letöltve ✓" \
      "\n  Telepített modellek:\n${INSTALLED_MODELS:-  (ollama list futtatásához restart szükséges)}\n\n  Parancssori ellenőrzés: ollama list" 16
  fi
fi

# =============================================================================
# SZEKCIÓ 10 — TURBOQUANT MODELL KONVERZIÓ ASSZISZTENS
# =============================================================================
# Ha a TurboQuant bináris elérhető ÉS vannak Ollama modellek:
# felajánljuk a futtatási parancsok generálását.
# MEGJEGYZÉS: A TurboQuant NEM módosítja a modell fájlt — runtime kvantálás!
# A --kv-quant paraméterrel aktiválod futtatáskor.

TQ_BIN=""
[ -f "${_REAL_HOME}/bin/llama-turboquant" ] \
  && TQ_BIN="${_REAL_HOME}/bin/llama-turboquant"
[ -z "$TQ_BIN" ] && TQ_BIN=$(ls "${_REAL_HOME}/bin/llama-turboquant-"* 2>/dev/null | head -1)

if [ -n "$TQ_BIN" ] && command -v ollama &>/dev/null; then
  OLLAMA_MODELS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^$')
  MODEL_COUNT=$(printf '%s' "$OLLAMA_MODELS" | grep -c . 2>/dev/null || echo 0)

  if [ "$MODEL_COUNT" -gt 0 ]; then
    dialog_yesno "TurboQuant — Modell parancsok generálása" \
      "\n  TurboQuant bináris: ${TQ_BIN}\n  Ollama modellek:    ${MODEL_COUNT} db\n\n$(printf '%s\n' "$OLLAMA_MODELS" | awk '{print "    " $0}')\n\n  Mit tesz a TurboQuant?\n    KV cache-t tömöríti 3–4 bitre futtatás KÖZBEN.\n    NEM módosítja a modell fájlt!\n    A --kv-quant paraméterrel aktiválod.\n\n  Mikor éri meg?\n    ✓ Nagy modellek (32B+) — 6x kisebb KV cache\n    ✓ Hosszú kontextus (128k+ token)\n    ✗ Kis modellek (7B alatt) — kevés előny\n\n  Generáljuk a futtatási parancsokat?" 26 \
    && {
      # Modell kiválasztás
      TQ_CHECKLIST_ITEMS=()
      while IFS= read -r MODEL; do
        [ -z "$MODEL" ] && continue
        # Méret + ajánlás a modell neve alapján (heurisztika)
        if echo "$MODEL" | grep -qiE "70b|72b|65b"; then
          SIZE="~40-45GB"; REC="ERŐSEN AJÁNLOTT"
        elif echo "$MODEL" | grep -qiE "32b|34b|33b"; then
          SIZE="~18-20GB"; REC="AJÁNLOTT"
        elif echo "$MODEL" | grep -qiE "13b|14b|15b|16b"; then
          SIZE="~8-10GB";  REC="hasznos"
        elif echo "$MODEL" | grep -qiE "7b|8b|9b"; then
          SIZE="~4-5GB";   REC="enyhe előny"
        else
          SIZE="?";        REC="mérlegelendő"
        fi
        TQ_CHECKLIST_ITEMS+=("$MODEL" "${SIZE} — ${REC}" "OFF")
      done <<< "$OLLAMA_MODELS"

      SELECTED_MODELS=$(dialog_checklist \
        "TurboQuant — Modell kiválasztás" \
        "\n  Válaszd ki melyik modellekhez generálunk parancsot:\n\n  ERŐSEN AJÁNLOTT = 32GB VRAM alig elég\n  hasznos = van előny, de nem kritikus\n\n  A --kv-quant futtatáskor aktiválódik — nincs újraletöltés!" \
        26 "${#TQ_CHECKLIST_ITEMS[@]}" \
        "${TQ_CHECKLIST_ITEMS[@]}")

      if [ -n "$SELECTED_MODELS" ]; then
        # KV kvantálás szint választás
        TQ_MODE=$(dialog_menu "TurboQuant kvantálási szint" \
          "\n  turbo3 = 3-bit KV cache\n    6x kisebb memória | +35% decode RTX 5090-en\n    Minimális minőségveszteség (~0.3% PPL)\n\n  turbo4 = 4-bit KV cache\n    4x kisebb memória | +20% decode speed\n    Szinte veszteségmentes (cos_sim=0.997)\n\n  Ajánlás: turbo3 nagy modellekhez" \
          18 2 \
          "turbo3" "3-bit — legjobb sebesség + memória (ajánlott)" \
          "turbo4" "4-bit — jobb minőség, kevesebb tömörítés")
        [ -z "$TQ_MODE" ] && TQ_MODE="turbo3"

        # Futtatási parancsok generálása
        TQ_COMMANDS="# TurboQuant futtatási parancsok\n# Generálva: $(date) | Kvantálás: ${TQ_MODE}\n# Binary: ${TQ_BIN}\n\n"
        for MODEL in $(printf '%s' "$SELECTED_MODELS" | tr -d '"' | tr ' ' '\n'); do
          [ -z "$MODEL" ] && continue
          TQ_COMMANDS+="# ${MODEL} (${TQ_MODE}):\n"
          TQ_COMMANDS+="${TQ_BIN} \\\\\n"
          TQ_COMMANDS+="  -m \$(ollama show ${MODEL} --modelfile 2>/dev/null | grep '^FROM' | awk '{print \$2}') \\\\\n"
          TQ_COMMANDS+="  --kv-quant ${TQ_MODE} \\\\\n"
          TQ_COMMANDS+="  -c 32768 \\\\\n"
          TQ_COMMANDS+="  -p 'Hello'\n\n"
        done

        # Szkript mentése
        TQ_SCRIPT="${_REAL_HOME}/bin/run-tq-models.sh"
        printf "#!/bin/bash\n%b" "$TQ_COMMANDS" > "$TQ_SCRIPT"
        chmod +x "$TQ_SCRIPT"
        log "TQ" "TurboQuant run script: ${TQ_SCRIPT}"

        dialog_msg "TurboQuant — Parancsok generálva ✓" \
          "\n  Kvantálás: ${TQ_MODE} | Binary: ${TQ_BIN}\n  Script: ~/bin/run-tq-models.sh\n\n$(printf '%b' "$TQ_COMMANDS" | head -20)\n\n  Megjegyzések:\n    • --kv-quant futtatáskor aktiválódik\n    • Nincs szükség újraletöltésre\n    • Ollama-val párhuzamosan futtatható" 32
      fi
    }
  fi
fi

# =============================================================================
# SZEKCIÓ 11 — GPU TESZT
# =============================================================================
# PyTorch GPU elérhetőség teszt — a telepítés után azonnal megmutatja
# hogy a CUDA + GPU kapcsolat működik-e a venv-ben.

if [ "${COMP_STATUS[venv]}" = "ok" ] && "$VENV_PY" -c "import torch" 2>/dev/null; then
  GPU_TEST=$("$VENV_PY" << 'PYEOF' 2>/dev/null
import torch
print(f"PyTorch:        {torch.__version__}")
print(f"CUDA elérhető:  {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"GPU:            {torch.cuda.get_device_name(0)}")
    mem = torch.cuda.get_device_properties(0).total_memory
    print(f"VRAM:           {mem/1024**3:.1f} GB")
    print(f"CUDA verzió:    {torch.version.cuda}")
    sm = torch.cuda.get_device_capability(0)
    print(f"Compute Cap.:   SM_{sm[0]}{sm[1]}")
else:
    print("  → Ha CUDA False: reboot szükséges (NVIDIA driver)")
PYEOF
)
  log "GPU_TEST" "${GPU_TEST}"
  dialog_msg "GPU teszt eredménye" "\n${GPU_TEST}\n\n  Ha CUDA elérhető=False: sudo reboot szükséges!" 14
fi

# =============================================================================
# SZEKCIÓ 12 — STATE ÍRÁS + ÖSSZESÍTŐ
# =============================================================================

# ── Infra state frissítése ────────────────────────────────────────────────────
# MOD_02_DONE=true: jelzi a masternek és más moduloknak hogy a 02 kész.
infra_state_set "MOD_02_DONE" "true"

# FEAT_VLLM frissítése az aktuális állapot alapján
"${VENV_PY}" -c "import vllm" 2>/dev/null \
  && infra_state_set "FEAT_VLLM" "true" \
  || infra_state_set "FEAT_VLLM" "false"

# INST_OLLAMA_VER: ha még nem írta be az install szekció (pl. már kész volt)
if [ -z "$(infra_state_get "INST_OLLAMA_VER" "")" ] && command -v ollama &>/dev/null; then
  _ov=$(ollama version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
  [ -z "$_ov" ] && _ov=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
  infra_state_set "INST_OLLAMA_VER" "${_ov:-telepítve}"
fi

# State konzisztencia validáció
infra_state_validate

# ── Log chmod — utolsó beállítás (futás közben root is írt bele) ───────────────
chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
log "OK" "Log jogosultságok: 644 / ${_REAL_USER}"

# ── Összesítő + log ───────────────────────────────────────────────────────────
show_result "$OK" "$SKIP" "$FAIL"

# Végső összefoglaló dialóg
dialog_msg "INFRA 02 — Összefoglalás" \
  "\n  ── Ollama ────────────────────────────────────────────
    ollama serve                    # szerver indítása
    ollama pull qwen2.5-coder:7b    # modell letöltése
    ~/bin/ollama-proxy.sh           # OpenAI proxy módban

  ── vLLM ──────────────────────────────────────────────
    ~/bin/start-vllm.sh meta-llama/Llama-3.2-8B-Instruct

  ── TurboQuant ────────────────────────────────────────
    ~/bin/llama-turboquant --version
    ~/bin/run-tq-models.sh          # generált parancsok

  ── API végpontok ──────────────────────────────────────
    Ollama:  http://localhost:11434
    vLLM:    http://localhost:8000/v1

  ── Ellenőrzés ────────────────────────────────────────
    source ${VENV}/bin/activate
    python -c 'import torch, vllm, langchain, anthropic; print(\"OK\")'

  ── Log fájlok ────────────────────────────────────────
    AI log:    ${LOGFILE_AI}
    TQ build:  ${_REAL_HOME}/AI-LOG-INFRA-SETUP/turboquant_*.log" 34

log "MASTER" "INFRA 02 befejezve: OK=${OK} SKIP=${SKIP} FAIL=${FAIL}"
