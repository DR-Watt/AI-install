#!/bin/bash
# =============================================================================
# 02_local_ai_stack.sh — Lokális AI Stack v6.3
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
# MÓDOK
# ─────
#   install   → hiányzó komponensek telepítése (TQ csak ha nincs kész)
#   update    → meglévők frissítése, TurboQuant újrafordítása
#   check     → READ-ONLY: csak státusz, SEMMI sem változik — EARLY EXIT
#   fix       → install-szerű, reboot nélkül (02-ben nincs reboot amúgy sem)
#   reinstall → teljes újratelepítés (TurboQuant is újrafordul)
#
# BUG-FIX NAPLÓ v6.3 (a futtatott logok alapján)
# ────────────────────────────────────────────────
#   [FIX] check mód early exit: v6.2-ben MISSING_COUNT>0 → install ágba esett
#         check módban is → TurboQuant + Ollama telepítést kért, 7+ perces futás!
#         Most: komponens felmérés után azonnal early exit check módban.
#   [FIX] TurboQuant újrafordítás: v6.2-ban minden futáskor felajánlotta a fordítást
#         még ha FEAT_TURBOQUANT=true volt és binary létezett.
#         Most: _tq_already_built pre-check → csak reinstall/update mód fordít újra.
#   [FIX] cmake flags üres: declare -A TQ_CMAKE_FLAGS a lib source után felülíródott
#         → 'cmake flags: ' üres volt a logban → CPU-only build lett gpu89 helyett.
#         Most: case statement + bash array → "${TQ_CMAKE_ARGS[@]}" expansion.
#   [FIX] Ollama verzió: 'ollama version' közvetlenül service start után üres volt
#         (STATE INST_OLLAMA_VER= üres maradt). Most: 5x retry + fallback módszerek.
#   [FIX] TQ log chmod: sudo alatt root:root lett a build log → nem volt húzható Claude-ba.
#         Most: touch + chmod 644 + chown a build log ELŐTT és UTÁN is.
#   [FIX] Fő log chmod: sudo alatt az install_02_*.log is root:root lett.
#         Most: log_init után + script végén is chmod/chown.
#   [NEW] Lib source V6/V7 kompatibilis: próbálja lib/00_lib_core.sh (V7),
#         fallback 00_lib.sh (V6).
#   [NEW] fix mód: lib infra_require() kezeli a bypass-t; 02-ban nincs extra.
#   [NEW] CUDA verzió backward kompatibilitás: CUDA_VER (régi) + INST_CUDA_VER (új).
#   [NEW] CUDA 12.8 ellenőrzés: integer összehasonlítás (nem awk) → megbízható.
#
# ELŐFELTÉTELEK
# ─────────────
#   • 00_lib.sh v6.2+ VAGY lib/00_lib_core.sh + lib/00_lib_state.sh (V7)
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
# =============================================================================

# ── Script könyvtár (szimlink-biztos) ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Közös függvénytár betöltése — V6 (00_lib.sh) és V7 (lib/) kompatibilis ───
# V7 struktúra: lib/00_lib_core.sh + lib/00_lib_state.sh
# V6 struktúra: 00_lib.sh (single file)
if [ -f "$SCRIPT_DIR/lib/00_lib_core.sh" ]; then
  source "$SCRIPT_DIR/lib/00_lib_core.sh" \
    || { echo "HIBA: lib/00_lib_core.sh betöltése sikertelen!"; exit 1; }
  source "$SCRIPT_DIR/lib/00_lib_state.sh" \
    || { echo "HIBA: lib/00_lib_state.sh betöltése sikertelen!"; exit 1; }
elif [ -f "$SCRIPT_DIR/00_lib.sh" ]; then
  source "$SCRIPT_DIR/00_lib.sh" \
    || { echo "HIBA: 00_lib.sh betöltése sikertelen!"; exit 1; }
else
  echo "HIBA: Lib nem található! (keresve: lib/00_lib_core.sh, 00_lib.sh)"
  echo "      Script könyvtára: $SCRIPT_DIR"
  exit 1
fi

# =============================================================================
# ██  SZEKCIÓ 1 — KONFIGURÁCIÓ  ── minden érték itt, kódban nincs magic string  ██
# =============================================================================

# ── Modul azonosítók ──────────────────────────────────────────────────────────
INFRA_NUM="02"
INFRA_NAME="Lokális AI Stack (Ollama + vLLM + TurboQuant)"
INFRA_HW_REQ="nvidia"   # infra_compatible() ellenőrzi — NVIDIA nélkül kihagyja

# ── Minimum elfogadható verziók ───────────────────────────────────────────────
declare -A MIN_VER=(
  [ollama]="0.5"    # Ollama minimum elfogadható verzió
  [vllm]="0.4"      # vLLM minimum — 0.4+ kell PagedAttention v2-höz
  [uv]="0.1"        # uv minimum (bármely verzió OK)
)

# ── TurboQuant llama.cpp fork repo URL-ek ─────────────────────────────────────
# Forrás: https://github.com/0xSero/turboquant (referencia implementáció)
#         https://arxiv.org/pdf/2504.19874 (TurboQuant ICLR 2026 paper)
declare -A TQ_REPOS=(
  [cpu]="https://github.com/seanrasch/llama-cpp-turboquant"
  [gpu89]="https://github.com/seanrasch/llama-cpp-turboquant"
  [gpu120]="https://github.com/0xSero/turboquant"   # Blackwell SM_120 Triton kernelekkel
)

# ── Telepítési útvonalak ──────────────────────────────────────────────────────
VENV="$_REAL_HOME/AI-VIBE/venvs/ai"    # PyTorch + vLLM + SDK-k venv-je (03 hozta létre)
VENV_PY="$VENV/bin/python"             # venv Python bináris
UV="$_REAL_HOME/.local/bin/uv"         # uv package manager (03 telepítette)
PYENV_ROOT="$_REAL_HOME/.pyenv"        # pyenv root (03 telepítette)

# ── AI SDK csomagok listája ────────────────────────────────────────────────────
# Forrás: PyPI + LangChain docs + Anthropic SDK docs + HuggingFace docs
readonly AI_PKGS=(
  langchain                 # RAG pipeline és AI workflow keretrendszer
  langchain-anthropic       # LangChain ↔ Claude API híd
  langchain-community       # community integrációk (Ollama, ChromaDB, stb.)
  anthropic                 # Anthropic Claude API Python SDK
  transformers              # HuggingFace modell keretrendszer
  datasets                  # HuggingFace adatkészlet kezelő
  accelerate                # HuggingFace GPU gyorsítás
  sentence-transformers     # embedding modellek (RAG-hoz szükséges)
  chromadb                  # lokális vektor adatbázis (RAG)
  huggingface-hub           # HF Hub API: modell letöltés, tokenek
  tiktoken                  # OpenAI/Anthropic tokenizer
  openai                    # OpenAI SDK — Ollama és vLLM OpenAI API kompatibilis
)

# =============================================================================
# SZEKCIÓ 2 — INICIALIZÁCIÓ
# =============================================================================

# ── Log inicializáció ─────────────────────────────────────────────────────────
# sudo alatt fut → a log fájlok root:root lennének → azonnal chmod/chown!
LOGFILE_AI="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_02_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="${_REAL_HOME}/AI-LOG-INFRA-SETUP/install_02_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="${LOGFILE_AI}"
mkdir -p "${_REAL_HOME}/AI-LOG-INFRA-SETUP"
log_init

# Azonnal jogosultság beállítás — hogy Claude-ba húzható legyen
chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}"    2>/dev/null || true
chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_HUMAN}" 2>/dev/null || true
chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true

# ── INFRA state betöltése ─────────────────────────────────────────────────────
# Backward kompatibilitás: régi state CUDA_VER-t használt, újabb INST_CUDA_VER-t
INST_CUDA_VER=$(infra_state_get "INST_CUDA_VER" \
                "$(infra_state_get "CUDA_VER" "12.6")")
PYTORCH_INDEX=$(infra_state_get "PYTORCH_INDEX"  "cu126")
HW_GPU_ARCH=$(infra_state_get   "HW_GPU_ARCH"    "${HW_GPU_ARCH:-unknown}")
HW_CUDA_ARCH=$(infra_state_get  "HW_CUDA_ARCH"   "${HW_CUDA_ARCH:-89}")

log "STATE" "Betöltve: CUDA=${INST_CUDA_VER} | PyTorch=${PYTORCH_INDEX} | arch=SM_${HW_CUDA_ARCH} | GPU_ARCH=${HW_GPU_ARCH}"

# ── CUDA 12.8+ ellenőrzés integer összehasonlítással ─────────────────────────
# BUGFIX v6.3: awk-alapú összehasonlítás helyett integer cut — megbízhatóbb.
_cuda_maj=$(echo "${INST_CUDA_VER}" | cut -d. -f1)
_cuda_min=$(echo "${INST_CUDA_VER}" | cut -d. -f2)
_cuda_ge_128=false
{ [ "${_cuda_maj:-0}" -gt 12 ] || \
  { [ "${_cuda_maj:-0}" -eq 12 ] && [ "${_cuda_min:-0}" -ge 8 ]; }; } \
  && _cuda_ge_128=true

# ── TurboQuant alapértelmezett build mód ─────────────────────────────────────
if $_cuda_ge_128 && [ "$HW_GPU_ARCH" = "blackwell" ]; then
  TQ_DEFAULT_MODE="gpu120"  # Blackwell + CUDA 12.8+ → natív SM_120
elif [ "$HW_GPU_ARCH" = "blackwell" ]; then
  TQ_DEFAULT_MODE="gpu89"   # Blackwell de CUDA < 12.8 → Ada fallback
elif [ "$HW_GPU_ARCH" != "igpu" ] && [ "$HW_GPU_ARCH" != "unknown" ]; then
  TQ_DEFAULT_MODE="gpu89"   # Ada/Ampere/Turing
else
  TQ_DEFAULT_MODE="cpu"     # iGPU vagy ismeretlen
fi
log "STATE" "TurboQuant default: ${TQ_DEFAULT_MODE} (CUDA ge 12.8: ${_cuda_ge_128})"

# ── Lock fájl — párhuzamos futtatás megakadályozása ──────────────────────────
LOCK_FILE="${_REAL_HOME}/.infra-lock-02"
check_lock "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"; log "LOCK" "Lock törölve (trap EXIT)"' EXIT

# =============================================================================
# SZEKCIÓ 3 — HARDVER ÉS FÜGGŐSÉG ELLENŐRZÉS
# =============================================================================

# ── Hardver kompatibilitás ────────────────────────────────────────────────────
# BUGFIX v6.3.1: infra_compatible() a V7 libben másképp implementált →
# desktop-rtx profilra is false-t adott vissza "nvidia" HW_REQ esetén.
# Megoldás: NE használjuk infra_compatible()-t (lib-verziófüggő!),
# helyette közvetlen HW_PROFILE + HW_GPU_ARCH ellenőrzés az infra state-ből.
# A master registry HW_REQ="nvidia" checkje már szűr a 02 script futtatása előtt;
# itt csak a tényleg GPU-mentes gépeket zárjuk ki dupla biztonsági net-ként.
_hw_nvidia_ok=false
case "${HW_PROFILE:-}" in
  desktop-rtx|desktop-rtx-old|notebook-rtx)
    _hw_nvidia_ok=true ;;   # profil alapján egyértelműen NVIDIA
esac
# Ha profil alapján nem egyértelmű: GPU_ARCH alapján döntünk
# (pl. V7-ben más profil nevek jöhetnek)
if ! $_hw_nvidia_ok; then
  case "${HW_GPU_ARCH:-}" in
    blackwell|ada|ampere|turing|pascal|nvidia*)
      _hw_nvidia_ok=true ;;  # arch alapján NVIDIA
  esac
fi
# Ha HW_VLLM_OK=true vagy FEAT_GPU_ACCEL=true → biztosan van NVIDIA GPU
[ "$(infra_state_get "HW_VLLM_OK"    "false")" = "true" ] && _hw_nvidia_ok=true
[ "$(infra_state_get "FEAT_GPU_ACCEL" "false")" = "true" ] && _hw_nvidia_ok=true

if ! $_hw_nvidia_ok; then
  log "SKIP" "Hardver inkompatibilis: profil=${HW_PROFILE} arch=${HW_GPU_ARCH} — nincs NVIDIA GPU"
  dialog_warn "Hardver inkompatibilis — 02 kihagyva" \
    "\n  A 02-es modul NVIDIA GPU-t igényel.\n\n  Jelenlegi profil: ${HW_PROFILE}\n  GPU arch:        ${HW_GPU_ARCH}\n\n  Modul kihagyva (exit 2)." 14
  exit 2
fi
log "HW" "NVIDIA GPU ellenőrzés OK: profil=${HW_PROFILE} / arch=${HW_GPU_ARCH}"

# ── 03-as modul függőség ellenőrzés ───────────────────────────────────────────
# A lib infra_require() kezeli a mód-alapú bypass-t:
#   check/fix módban: logol de nem blokkol
#   install/update/reinstall: blokkol ha MOD_03_DONE != true
infra_require "03" "Python 3.12 + PyTorch + uv (03_python_aiml.sh)" || exit 1

# ── PATH beállítás (pyenv + uv + CUDA nvcc) ───────────────────────────────────
export PATH="/usr/local/cuda/bin:$PYENV_ROOT/bin:$_REAL_HOME/.local/bin:$PATH"
[ -d "$PYENV_ROOT/bin" ] && eval "$(pyenv init -)" 2>/dev/null || true
log "PATH" "Aktiválva: CUDA=/usr/local/cuda/bin | pyenv | uv"

# =============================================================================
# SZEKCIÓ 4 — KOMPONENS FELMÉRÉS
# =============================================================================

# ── uv: Astral uv package manager ────────────────────────────────────────────
comp_check_uv "${MIN_VER[uv]}" "$UV"

# ── Python AI venv ────────────────────────────────────────────────────────────
if [ -d "$VENV" ] && [ -x "$VENV_PY" ]; then
  COMP_STATUS[venv]="ok"
  COMP_VER[venv]="$("$VENV_PY" --version 2>/dev/null | grep -oP '[\d.]+')"
else
  COMP_STATUS[venv]="missing"; COMP_VER[venv]=""
fi

# ── PyTorch: Python import ellenőrzés ────────────────────────────────────────
if [ "${COMP_STATUS[venv]}" = "ok" ]; then
  _torch_ver=$("$VENV_PY" -c "import torch; print(torch.__version__)" 2>/dev/null)
  if [ -n "$_torch_ver" ]; then
    COMP_STATUS[torch]="ok"; COMP_VER[torch]="$_torch_ver"
  else
    COMP_STATUS[torch]="missing"; COMP_VER[torch]=""
  fi
else
  COMP_STATUS[torch]="missing"; COMP_VER[torch]=""
fi

# ── Ollama: comp_check_ollama() a lib-ben ─────────────────────────────────────
# Forrás: https://ollama.readthedocs.io/en/ — 'ollama version' az official parancs
comp_check_ollama "${MIN_VER[ollama]}"

# ── vLLM: comp_check_vllm() a lib-ben (Python import — nincs saját CLI) ──────
# Forrás: https://docs.vllm.ai/en/latest/
[ "${COMP_STATUS[venv]}" = "ok" ] \
  && comp_check_vllm "${MIN_VER[vllm]}" "$VENV_PY" \
  || { COMP_STATUS[vllm]="missing"; COMP_VER[vllm]=""; }

# ── TurboQuant bináris: symlink VAGY llama-turboquant-* ──────────────────────
# A COMP_VER-t az infra state-ből olvassuk (build mód: cpu/gpu89/gpu120)
_tq_bin_ok=false
[ -f "${_REAL_HOME}/bin/llama-turboquant" ]                       && _tq_bin_ok=true
ls "${_REAL_HOME}/bin/llama-turboquant-"* &>/dev/null 2>&1        && _tq_bin_ok=true
if $_tq_bin_ok; then
  COMP_STATUS[turboquant]="ok"
  COMP_VER[turboquant]="$(infra_state_get "TURBOQUANT_BUILD_MODE" "ismeretlen")"
else
  COMP_STATUS[turboquant]="missing"; COMP_VER[turboquant]=""
fi

# ── AI SDK-k: Python import a venv-ben ────────────────────────────────────────
_sdk_check() {
  local key="$1" mod="$2" ver_attr="${3:-__version__}"
  if [ "${COMP_STATUS[venv]}" = "ok" ] && "$VENV_PY" -c "import ${mod}" 2>/dev/null; then
    COMP_STATUS[$key]="ok"
    COMP_VER[$key]=$("$VENV_PY" -c \
      "import ${mod}; print(getattr(${mod}, '${ver_attr}', 'ok'))" 2>/dev/null || echo "ok")
  else
    COMP_STATUS[$key]="missing"; COMP_VER[$key]=""
  fi
}
_sdk_check "langchain" "langchain"    "__version__"
_sdk_check "anthropic" "anthropic"    "__version__"
_sdk_check "hf"        "transformers" "__version__"

# ── Összesítés: log + hiányzók száma ─────────────────────────────────────────
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
log_comp_status "${COMP_CHECK[@]}"

COMP_KEYS=(uv venv torch ollama vllm turboquant langchain anthropic hf)
MISSING_COUNT=0
for _k in "${COMP_KEYS[@]}"; do
  [ "${COMP_STATUS[$_k]:-missing}" = "missing" ] && ((MISSING_COUNT++))
done

# =============================================================================
# SZEKCIÓ 5 — INFRA FEJLÉC + CHECK MÓD KEZELÉS
# =============================================================================

# ── Infra header logba ────────────────────────────────────────────────────────
log_infra_header "    • Ollama v${MIN_VER[ollama]}+  — lokális LLM szerver (OpenAI API kompatibilis)
    • vLLM v${MIN_VER[vllm]}+    — GPU inferencia (CUDA ${INST_CUDA_VER} / ${PYTORCH_INDEX})
    • TurboQuant        — KV cache kvantálás (llama.cpp fork, SM_${HW_CUDA_ARCH})
    • AI SDK-k          — LangChain, Anthropic, HuggingFace, ChromaDB"
log_install_paths "    /usr/local/bin/ollama                — Ollama bináris (rendszerszintű)
    ${VENV}/  — Python AI venv
    ${_REAL_HOME}/bin/llama-turboquant      — TurboQuant bináris (symlink)
    ${_REAL_HOME}/bin/start-vllm.sh        — vLLM indítószkript
    ${_REAL_HOME}/bin/ollama-proxy.sh      — Ollama OpenAI proxy szkript"

# ── Üdvözlő dialóg ───────────────────────────────────────────────────────────
dialog_msg "INFRA 02 — ${INFRA_NAME}" "
  GPU:     ${HW_GPU_NAME:-NVIDIA}
  Profil:  ${HW_PROFILE}  |  CUDA arch: SM_${HW_CUDA_ARCH}
  vLLM:    $(${HW_VLLM_OK:-false} && echo '✓ GPU módban fut' || echo '⚠ SM<70 — CPU-only')
  PyTorch: ${PYTORCH_INDEX}  |  Mód: ${RUN_MODE}
  TQ:      $($_tq_bin_ok && echo "✓ kész (${COMP_VER[turboquant]:-?})" || echo '✗ hiányzik')

  ── Komponens státusz ────────────────────────────────────
$(comp_line "uv"         "uv")
$(comp_line "venv"       "Python venv")
$(comp_line "torch"      "PyTorch")
$(comp_line "ollama"     "Ollama")
$(comp_line "vllm"       "vLLM")
$(comp_line "turboquant" "TurboQuant")
$(comp_line "langchain"  "LangChain")
$(comp_line "anthropic"  "Anthropic SDK")
$(comp_line "hf"         "HuggingFace")
  ─────────────────────────────────────────────────────────
  Log: ${LOGFILE_AI}" 36

# ══════════════════════════════════════════════════════════════════════════════
# ██  CHECK MÓD — EARLY EXIT  ██
# ══════════════════════════════════════════════════════════════════════════════
# BUGFIX v6.3: check módban SEMMI sem települ/fordul/töltődik le.
# v6.2-ben MISSING_COUNT>0 → "install mód" logba, de check guard hiányzott
# → TurboQuant dialog megjelent és a user igent mondott → 7+ perces build!
# ──────────────────────────────────────────────────────────────────────────────
if [ "$RUN_MODE" = "check" ]; then
  log "MODE" "check mód — read-only, csak státusz (semmi sem települ/fordul)"

  if [ "$MISSING_COUNT" -gt 0 ]; then
    # Hiányzó komponensek listázása — de NEM ajánlunk telepítést!
    _missing_list=""
    for _k in "${COMP_KEYS[@]}"; do
      [ "${COMP_STATUS[$_k]:-missing}" = "missing" ] && _missing_list+="    ✗ ${_k}\n"
    done
    dialog_warn "INFRA 02 — Ellenőrzés [check]" \
      "\n  ${MISSING_COUNT} hiányzó komponens:\n\n${_missing_list}\n  Telepítéshez: install módot válassz a masterben.\n  Gyorsjavításhoz: fix módot válassz (reboot nélkül)." 20
  else
    dialog_msg "INFRA 02 — Ellenőrzés [check] ✓" \
      "\n  Minden komponens telepítve és elérhető.\n\n  Részletek:\n  ${LOGFILE_AI}" 14
  fi

  # State: ha volt MOD_02_DONE=true, megtartjuk; ha üres volt, üres marad
  _prev_done=$(infra_state_get "MOD_02_DONE" "")
  [ "$_prev_done" = "true" ] && infra_state_set "MOD_02_DONE" "true"

  # Log jogosultság rendezés check módban is
  chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
  chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true

  log "MODE" "check mód befejezve — OK=${MISSING_COUNT} = 0 → minden rendben"
  exit 0
fi

# ── Futtatási mód döntés (telepítési módok: install/update/fix/reinstall) ─────
# detect_run_mode() csak akkor hívódik ha MINDEN OK és mód nem fix/reinstall.
# fix mód = install-szerű, de az infra_require() bypass a libben kezeli;
# 02-ban nincs reboot sem, szóval fix viselkedése = install viselkedése.
if [ "$MISSING_COUNT" -eq 0 ] && \
   [ "$RUN_MODE" != "fix" ]  && \
   [ "$RUN_MODE" != "reinstall" ]; then
  detect_run_mode COMP_KEYS   # Módosíthatja: skip/update/reinstall
else
  log "MODE" "Hiányzó: ${MISSING_COUNT} | mód: ${RUN_MODE} → nincs override"
fi

[ "$RUN_MODE" = "skip" ] && {
  dialog_msg "02 kihagyva" "\n  Minden komponens naprakész.\n  MOD_02_DONE state frissítve." 10
  infra_state_set "MOD_02_DONE" "true"
  exit 0
}

OK=0; SKIP=0; FAIL=0

# ── Telepítési terv megjelenítése ─────────────────────────────────────────────
_status_lines=""
for _k in "${COMP_KEYS[@]}"; do
  _status_lines+="$(comp_line "$_k" "$_k")"$'\n'
done

dialog_yesno "Telepítési terv — INFRA 02" \
  "\n  Mód: [${RUN_MODE}] | Hiányzó: ${MISSING_COUNT}\n\n${_status_lines}\n  Folytatjuk a telepítéssel?" 28 \
  || { dialog_msg "Kilépés" "\n  02 megszakítva."; exit 0; }

# =============================================================================
# SZEKCIÓ 6 — TELEPÍTÉSI LÉPÉSEK
# =============================================================================

# ── 6a. uv telepítés / frissítés ─────────────────────────────────────────────
# Forrás: https://docs.astral.sh/uv/getting-started/installation/
if [ "${COMP_STATUS[uv]}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  log "STEP" "uv telepítése / frissítése..."
  run_with_progress "uv telepítése" "Astral uv letöltése és telepítése..." \
    bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
  export PATH="$_REAL_HOME/.local/bin:$PATH"
  comp_check_uv "${MIN_VER[uv]}" "$UV"
  [ "${COMP_STATUS[uv]}" = "ok" ] && ((OK++)) || ((FAIL++))
fi

# ── 6b. Python AI venv ellenőrzés / létrehozás ───────────────────────────────
# A venv-et a 03-as modul hozza létre. Ha hiányzik → figyelmeztetés + próba.
if [ "${COMP_STATUS[venv]}" != "ok" ]; then
  dialog_warn "Python AI venv hiányzik" \
    "\n  Helyszín: ${VENV}\n\n  A venv-et a 03-as modulnak kellett létrehoznia.\n  Futtasd: bash 03_python_aiml.sh\n\n  Próbáljuk most létrehozni Python 3.12-vel?" 16

  PY312=""
  [ -x "${PYENV_ROOT}/versions/3.12.9/bin/python3.12" ] \
    && PY312="${PYENV_ROOT}/versions/3.12.9/bin/python3.12"
  [ -z "$PY312" ] && PY312=$(find "${PYENV_ROOT}/versions" -name "python3.12" 2>/dev/null | head -1)
  [ -z "$PY312" ] && PY312=$(command -v python3.12 2>/dev/null)

  if [ -z "$PY312" ]; then
    dialog_warn "Python 3.12 nem található" \
      "\n  Python 3.12 nem elérhető.\n  Futtasd előbb: bash 03_python_aiml.sh" 10
    ((FAIL++))
  else
    mkdir -p "$(dirname "$VENV")"
    run_with_progress "venv létrehozása" "${VENV} venv létrehozása..." \
      "$UV" venv "$VENV" --python "$PY312"
    if [ -x "$VENV_PY" ]; then
      COMP_STATUS[venv]="ok"
      COMP_VER[venv]="$("$VENV_PY" --version 2>/dev/null | grep -oP '[\d.]+')"
      ((OK++))
    else
      ((FAIL++))
    fi
  fi
fi

# ── 6c. Ollama telepítése ─────────────────────────────────────────────────────
# Forrás: https://ollama.readthedocs.io/en/
# Az install.sh sudo-t igényel (rendszer PATH + systemd service).
#
# BUGFIX v6.3: 'ollama version' közvetlenül a service start után üres volt.
# Megoldás: 5x retry loop 1 másodperces szünettel + 3 alternatív lekérési módszer.
if [ "${COMP_STATUS[ollama]}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
  dialog_yesno "Ollama telepítése" \
    "\n  Ollama: lokális LLM szerver (llama.cpp alapú)\n  OpenAI kompatibilis REST API: http://localhost:11434\n\n  Telepítési módszer: curl https://ollama.ai/install.sh | sh\n  Telepítési hely:   /usr/local/bin/ollama\n  systemd service:   ollama.service\n\n  Folytatjuk?" 16 \
  && {
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

    # Service indítása
    sudo_run systemctl enable ollama 2>/dev/null || true
    sudo_run systemctl start  ollama 2>/dev/null || true

    # ── Ollama post-install re-verify + verzió lekérés ────────────────────────
    # BUGFIX v6.3: 'ollama version' közvetlenül service start után üres volt.
    # Forrás: https://ollama.readthedocs.io/en/ — 'ollama version' az official CLI.
    OLLAMA_VER=""
    _retry=0
    while [ -z "$OLLAMA_VER" ] && [ $_retry -lt 5 ]; do
      sleep 1
      # Módszer 1: ollama version (official CLI parancs)
      OLLAMA_VER=$(ollama version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
      # Módszer 2: ollama --version (alternatív flag)
      [ -z "$OLLAMA_VER" ] && \
        OLLAMA_VER=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
      ((_retry++))
    done
    # Módszer 3: dpkg (ha csomagból jött)
    [ -z "$OLLAMA_VER" ] && \
      OLLAMA_VER=$(dpkg -l ollama 2>/dev/null | awk '/^ii/{print $3}' \
                   | grep -oP '\d+\.\d+\.\d+' | head -1)
    # Fallback: csak jelezzük hogy telepítve van de verzió ismeretlen
    [ -z "$OLLAMA_VER" ] && command -v ollama &>/dev/null && OLLAMA_VER="telepítve"

    if command -v ollama &>/dev/null; then
      ((OK++))
      # Comp státusz frissítése: post-install re-verify után legyen ok
      COMP_STATUS[ollama]="ok"; COMP_VER[ollama]="$OLLAMA_VER"
      infra_state_set "INST_OLLAMA_VER" "$OLLAMA_VER"
      infra_state_set "FEAT_OLLAMA_GPU" "$(hw_has_nvidia && echo true || echo false)"
      log "OK" "Ollama telepítve: v${OLLAMA_VER} (retry: ${_retry})"

      dialog_msg "Ollama — Telepítve ✓" \
        "\n  ✓  Ollama: ${OLLAMA_VER}\n  ✓  systemd service: ollama.service\n  ✓  GPU: $(hw_has_nvidia && echo 'igen (NVIDIA)' || echo 'CPU-only')\n\n  API: http://localhost:11434\n  Első modell: ollama pull qwen2.5-coder:7b" 14
    else
      ((FAIL++))
      log "FAIL" "Ollama telepítés sikertelen — 'command -v ollama' hamis telepítés után"
      dialog_warn "Ollama — Hiba" \
        "\n  Ollama bináris nem érhető el a telepítés után.\n  Részletek: ${LOGFILE_AI}" 10
    fi
  } || ((SKIP++))
fi

# ── 6d. vLLM telepítése ───────────────────────────────────────────────────────
# Forrás: https://docs.vllm.ai/en/latest/getting_started/installation.html
# FONTOS: vLLM felülírja a PyTorch-ot ha nem pin-eljük előtte!
#   Lépések: 1. PyTorch pin cu126/cu128 → 2. vLLM --no-build-isolation
if ${HW_VLLM_OK:-false}; then
  if [ "${COMP_STATUS[vllm]}" != "ok" ] || [ "$RUN_MODE" = "reinstall" ]; then
    dialog_yesno "vLLM telepítése" \
      "\n  vLLM: GPU-optimalizált LLM inferencia szerver\n  PagedAttention v2 + continuous batching\n\n  GPU: ${HW_GPU_NAME}\n  CUDA: ${INST_CUDA_VER} (${PYTORCH_INDEX})\n\n  FONTOS: PyTorch-ot pin-eljük (${PYTORCH_INDEX})\n  hogy vLLM ne írja felül!\n\n  Méret: ~500 MB\n\n  Folytatjuk?" 20 \
    && {
      # 1. PyTorch pin (cu126 vagy cu128 verzióra)
      log "VLLM" "PyTorch pin: ${PYTORCH_INDEX}"
      "$UV" pip install \
        --python "$VENV_PY" \
        torch torchvision torchaudio \
        --index-url "https://download.pytorch.org/whl/${PYTORCH_INDEX}" \
        --force-reinstall >> "$LOGFILE_AI" 2>&1 \
      || log "WARN" "PyTorch pin hiba — vLLM install folytatódik"

      # 2. vLLM --no-build-isolation (az előzőleg pinnelt PyTorch-ot látja)
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
        sleep 3; [ $_vpct -lt 88 ] && ((_vpct+=2))
      done
      wait $VLLM_PID
      progress_close

      # Re-verify telepítés után
      if "$VENV_PY" -c "import vllm" 2>/dev/null; then
        VLLM_VER=$("$VENV_PY" -c "import vllm; print(vllm.__version__)" 2>/dev/null || echo "")
        ((OK++))
        COMP_STATUS[vllm]="ok"; COMP_VER[vllm]="$VLLM_VER"
        infra_state_set "INST_VLLM_VER" "$VLLM_VER"
        infra_state_set "FEAT_VLLM"     "true"
        log "OK" "vLLM telepítve: v${VLLM_VER}"
      else
        ((FAIL++))
        infra_state_set "FEAT_VLLM" "false"
        log "FAIL" "vLLM import sikertelen — PyTorch/CUDA kompatibilitás ellenőrizd"
        dialog_warn "vLLM — Hiba" \
          "\n  vLLM install sikertelen.\n\n  CUDA: ${INST_CUDA_VER} | PyTorch: ${PYTORCH_INDEX}\n\n  Log: ${LOGFILE_AI}" 14
      fi
    } || ((SKIP++))
  fi
else
  log "SKIP" "vLLM kihagyva: HW_VLLM_OK=false (profil: ${HW_PROFILE})"
  infra_state_set "FEAT_VLLM" "false"
  ((SKIP++))
  dialog_msg "vLLM — Kihagyva" \
    "\n  vLLM CUDA SM_70+ GPU-t igényel.\n  Jelenlegi: SM_${HW_CUDA_ARCH}\n\n  Ollama fut GPU-val, vLLM nélkül is." 12
fi

# ── 6e. AI SDK-k telepítése ───────────────────────────────────────────────────
if [ "${COMP_STATUS[langchain]}" != "ok" ] || \
   [ "${COMP_STATUS[anthropic]}" != "ok" ] || \
   [ "${COMP_STATUS[hf]}" != "ok" ]        || \
   [ "$RUN_MODE" = "reinstall" ]; then

  dialog_yesno "AI SDK-k telepítése" \
    "\n  LangChain + Anthropic + HuggingFace + ChromaDB\n\n  Méret: ~350–450 MB\n  Venv: ${VENV}\n\n  Folytatjuk?" 14 \
  && {
    log "SDK" "AI SDK-k telepítése: ${AI_PKGS[*]}"
    "$UV" pip install \
      --python "$VENV_PY" \
      "${AI_PKGS[@]}" >> "$LOGFILE_AI" 2>&1 \
    && { ((OK++)); log "OK" "AI SDK-k telepítve"; } \
    || { ((FAIL++)); log "FAIL" "AI SDK telepítés részben sikertelen — log: ${LOGFILE_AI}"; }
  } || ((SKIP++))
fi

# =============================================================================
# SZEKCIÓ 7 — TURBOQUANT llama.cpp fork fordítása
# =============================================================================
# TurboQuant: Google Research (ICLR 2026) KV cache kvantálás.
# Forrás: https://arxiv.org/pdf/2504.19874
#         https://github.com/0xSero/turboquant
#
# ── TurboQuant pre-check — ne fordítsuk újra ha már kész ─────────────────────
# BUGFIX v6.3: v6.2-ben minden futáskor felajánlotta az újrafordítást, még ha
# FEAT_TURBOQUANT=true volt és a binary létezett.
# Pre-check: binary OK ÉS FEAT_TURBOQUANT=true ÉS nem reinstall/update → skip.
# ─────────────────────────────────────────────────────────────────────────────
_tq_already_built=false
if $_tq_bin_ok && \
   [ "$(infra_state_get "FEAT_TURBOQUANT" "false")" = "true" ] && \
   [ "$RUN_MODE" != "reinstall" ] && \
   [ "$RUN_MODE" != "update" ]; then
  _tq_already_built=true
fi

if $_tq_already_built; then
  # TurboQuant már kész — skip + tájékoztatás
  _tq_prev_mode=$(infra_state_get "TURBOQUANT_BUILD_MODE" "ismeretlen")
  log "SKIP" "TurboQuant már kész (${_tq_prev_mode}) — kihagyva"
  log "SKIP" "Újrafordításhoz: 'update' vagy 'reinstall' módot válassz a masterben"
  ((SKIP++))
  dialog_msg "TurboQuant — Már kész ✓" \
    "\n  TurboQuant binary megtalálva.\n\n  Mód:    ${_tq_prev_mode}\n  Binary: ~/bin/llama-turboquant\n  State:  FEAT_TURBOQUANT=true\n\n  Újrafordításhoz: update/reinstall módot válassz.\n\n  Gyors teszt:\n    ~/bin/llama-turboquant --version" 18

else
  # TurboQuant nincs kész VAGY update/reinstall → fordítás

  # ── TurboQuant hardver detektálás ────────────────────────────────────────
  TQ_CUDA_VER=$(PATH="/usr/local/cuda/bin:$PATH" nvcc --version 2>/dev/null \
                | grep -oP 'release \K[\d.]+' | head -1 || echo "${INST_CUDA_VER}")
  TQ_GPU_PCI=$(lspci -nn 2>/dev/null \
               | grep -iE "VGA.*NVIDIA|3D controller.*NVIDIA" \
               | grep -oP '(?<=10de:)[0-9a-fA-F]+' | head -1 \
               | tr '[:upper:]' '[:lower:]')
  TQ_IS_BLACKWELL=false
  [[ "${TQ_GPU_PCI:0:2}" =~ ^(2b|2c)$ ]] && TQ_IS_BLACKWELL=true

  log "TQ" "Detektálva: PCI=10de:${TQ_GPU_PCI} | Blackwell=${TQ_IS_BLACKWELL} | CUDA=${TQ_CUDA_VER}"

  _rebuild_note=""
  [ "$RUN_MODE" = "update" ]    && _rebuild_note=" (update mód)"
  [ "$RUN_MODE" = "reinstall" ] && _rebuild_note=" (reinstall mód)"

  dialog_yesno "TurboQuant llama.cpp fork fordítása${_rebuild_note}" \
    "\n  GPU:       NVIDIA (PCI: 10de:${TQ_GPU_PCI:-?})\n  Blackwell: $([ "$TQ_IS_BLACKWELL" = true ] && echo 'IGEN — SM_120 elérhető' || echo 'nem')\n  CUDA:      ${TQ_CUDA_VER}\n  Ajánlott:  ${TQ_DEFAULT_MODE}\n\n  cpu     — gyors, nincs GPU gyorsítás\n  gpu89   — CUDA SM_89 (Ada fallback, cu126 OK)\n  gpu120  — CUDA SM_120 (Blackwell natív, cu128 kell)\n\n  Folytatjuk?" 22 \
  && {
    BLACKWELL_NOTE=""
    $TQ_IS_BLACKWELL && BLACKWELL_NOTE="  ← RTX 5090 AJÁNLOTT"

    TQ_BUILD_MODE=$(dialog_menu "TurboQuant fordítási mód" \
      "\n  GPU: 10de:${TQ_GPU_PCI:-?}  |  CUDA: ${TQ_CUDA_VER}\n  Blackwell: $([ "$TQ_IS_BLACKWELL" = true ] && echo 'IGEN' || echo 'nem')" \
      18 3 \
      "cpu"    "CPU-only fordítás (lassú, de biztos)" \
      "gpu89"  "GPU SM_89 — Ada Lovelace fallback (cu126 OK)" \
      "gpu120" "GPU SM_120 — Blackwell natív${BLACKWELL_NOTE}")

    [ -z "$TQ_BUILD_MODE" ] && { ((SKIP++)); } || {

      # ── cu128 figyelmeztetés: SM_120 de CUDA < 12.8 ──────────────────────
      if [ "$TQ_BUILD_MODE" = "gpu120" ] && ! $_cuda_ge_128; then
        dialog_warn "SM_120 — CUDA 12.8+ szükséges!" \
          "\n  Telepített CUDA: ${TQ_CUDA_VER}\n  SM_120 fordításhoz: CUDA 12.8+\n\n  OPCIÓ 1 — CUDA 12.8 frissítés:\n    sudo apt install cuda-toolkit-12-8\n\n  OPCIÓ 2 — Visszaváltás GPU-89-re (cu126 OK)\n\n  Visszaváltunk GPU-89-re?" 20
        [ $? -eq 0 ] && {
          TQ_BUILD_MODE="gpu89"
          log "TQ" "Visszaváltás GPU-89-re (CUDA ${TQ_CUDA_VER} < 12.8)"
          dialog_msg "Visszaváltás — GPU-89" "\n  OK — GPU-89 módban fordítunk." 8
        }
      fi

      # ── cmake arg-ok — BASH ARRAY-ként (nem declare -A!) ─────────────────
      # BUGFIX v6.3: declare -A TQ_CMAKE_FLAGS a lib source után felülíródott
      # → logban 'cmake flags: ' üres volt → CPU-only build lett gpu89 helyett!
      # Megoldás: case statement + bash array + "${TQ_CMAKE_ARGS[@]}" expansion.
      TQ_CMAKE_ARGS=()
      case "$TQ_BUILD_MODE" in
        cpu)
          TQ_CMAKE_ARGS=(-DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release)
          TQ_ARCH_LBL="CPU-only (nincs CUDA)"
          ;;
        gpu89)
          TQ_CMAKE_ARGS=(-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 -DCMAKE_BUILD_TYPE=Release)
          TQ_ARCH_LBL="GPU SM_89 — Ada Lovelace fallback (cu126 OK)"
          ;;
        gpu120)
          TQ_CMAKE_ARGS=(-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 -DCMAKE_BUILD_TYPE=Release)
          TQ_ARCH_LBL="GPU SM_120 — Blackwell natív (cu128 Nightly)"
          ;;
        *)
          TQ_CMAKE_ARGS=(-DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release)
          TQ_ARCH_LBL="CPU-only (fallback)"
          log "WARN" "Ismeretlen TQ_BUILD_MODE: ${TQ_BUILD_MODE} → CPU fallback"
          ;;
      esac
      TQ_REPO_URL="${TQ_REPOS[$TQ_BUILD_MODE]}"
      log "TQ" "Build mód: ${TQ_BUILD_MODE} | cmake args: ${TQ_CMAKE_ARGS[*]}"

      [ "$TQ_BUILD_MODE" = "gpu120" ] && dialog_msg "TurboQuant — 0xSero fork (SM_120)" \
        "\n  SM_120 fordításhoz a 0xSero forkot használjuk:\n  ${TQ_REPO_URL}\n\n  SM_120 explicit CUDA arch + Blackwell FP4/FP8 optimalizálás." 12

      # ── Könyvtár + klónozás ───────────────────────────────────────────────
      TQ_DIR="${_REAL_HOME}/src/llama-turboquant-${TQ_BUILD_MODE}"
      mkdir -p "${_REAL_HOME}/src" "${_REAL_HOME}/bin"

      # Reinstall: régi build könyvtár törlése (friss klón kell)
      [ "$RUN_MODE" = "reinstall" ] && [ -d "$TQ_DIR" ] && {
        rm -rf "$TQ_DIR"
        log "TQ" "Régi könyvtár törölve (reinstall): ${TQ_DIR}"
      }

      if [ ! -d "$TQ_DIR" ]; then
        log "TQ" "git clone: ${TQ_REPO_URL} → ${TQ_DIR}"
        run_with_progress "TurboQuant klónozás" "Klónozás: ${TQ_REPO_URL}..." \
          git clone --depth=1 "$TQ_REPO_URL" "$TQ_DIR"
      else
        log "TQ" "Könyvtár megvan: ${TQ_DIR} — klónozás kihagyva"
      fi

      # cmake + build-essential ellenőrzés (llama.cpp fordításhoz kell)
      command -v cmake &>/dev/null || \
        apt_install_log "cmake build-essential" cmake build-essential ninja-build

      # ── cmake konfiguráció + fordítás ─────────────────────────────────────
      cd "$TQ_DIR" || {
        log "FAIL" "TQ könyvtár nem elérhető: ${TQ_DIR}"
        ((FAIL++))
      }

      rm -rf build  # tiszta build minden alkalommal

      # TurboQuant saját build log (ne írja tele a fő logot)
      # BUGFIX v6.3: chmod 644 + chown ELŐRE (touch), hogy azonnal olvasható legyen
      LOGFILE_TQ="${_REAL_HOME}/AI-LOG-INFRA-SETUP/turboquant_${TQ_BUILD_MODE}_$(date '+%Y%m%d_%H%M%S').log"
      log "TQ" "Build log: ${LOGFILE_TQ}"
      touch "$LOGFILE_TQ"
      chmod 644 "$LOGFILE_TQ"
      chown "${_REAL_USER}:${_REAL_USER}" "$LOGFILE_TQ" 2>/dev/null || true

      NVCC_INFO=$(PATH="/usr/local/cuda/bin:$PATH" nvcc --version 2>/dev/null \
                  | head -1 || echo "nvcc: nem elérhető")

      progress_open "TurboQuant fordítása" "${TQ_ARCH_LBL}..."
      log_term "cmake: ${TQ_CMAKE_ARGS[*]}"

      # cmake konfiguráció — CUDA PATH kell nvcc-nek a GPU buildhez
      progress_set 5 "cmake konfiguráció (${TQ_ARCH_LBL})..."
      PATH="/usr/local/cuda/bin:$PATH" \
        cmake -B build "${TQ_CMAKE_ARGS[@]}" >> "$LOGFILE_TQ" 2>&1
      CMAKE_EC=$?
      # Build log jogosultság frissítés cmake után
      chmod 644 "$LOGFILE_TQ" 2>/dev/null || true
      chown "${_REAL_USER}:${_REAL_USER}" "$LOGFILE_TQ" 2>/dev/null || true

      if [ $CMAKE_EC -ne 0 ]; then
        progress_close
        log "FAIL" "cmake hiba (exit ${CMAKE_EC}) — log: ${LOGFILE_TQ}"
        ((FAIL++))
        dialog_warn "TurboQuant — cmake hiba" \
          "\n  cmake konfiguráció sikertelen (exit ${CMAKE_EC}).\n\n  Lehetséges okok:\n    gpu120: CUDA 12.8+ szükséges\n    gpu89:  nvcc nem elérhető (/usr/local/cuda/bin)\n    cpu:    build-essential hiányzik\n\n  Build log: ${LOGFILE_TQ}" 18
      else
        NPROC=$(nproc 2>/dev/null || echo 4)
        progress_set 20 "Fordítás (${NPROC} mag)... ~10–25 perc"
        log "TQ" "cmake --build (${NPROC} mag)..."

        cmake --build build --config Release -j"$NPROC" >> "$LOGFILE_TQ" 2>&1
        BUILD_EC=$?
        # Build log jogosultság frissítés build után
        chmod 644 "$LOGFILE_TQ" 2>/dev/null || true
        chown "${_REAL_USER}:${_REAL_USER}" "$LOGFILE_TQ" 2>/dev/null || true

        if [ $BUILD_EC -ne 0 ]; then
          progress_close
          log "FAIL" "cmake --build hiba (exit ${BUILD_EC}) — log: ${LOGFILE_TQ}"
          ((FAIL++))
          dialog_warn "TurboQuant — fordítási hiba" \
            "\n  cmake --build sikertelen (exit ${BUILD_EC}).\n  Build log: ${LOGFILE_TQ}" 12
        else
          progress_set 90 "Bináris másolása ~/bin-be..."

          # llama-cli keresése: fő helyszín + rekurzív fallback
          BINARY_NAME="llama-turboquant-${TQ_BUILD_MODE}"
          _found_bin=""
          [ -f "build/bin/llama-cli" ] && _found_bin="build/bin/llama-cli"
          [ -z "$_found_bin" ] && \
            _found_bin=$(find build -name "llama-cli" -type f 2>/dev/null | head -1)

          if [ -n "$_found_bin" ]; then
            cp "$_found_bin" "${_REAL_HOME}/bin/${BINARY_NAME}"
            chmod +x "${_REAL_HOME}/bin/${BINARY_NAME}"
            # Symlink: llama-turboquant → legutóbb fordított binárisra
            ln -sf "${_REAL_HOME}/bin/${BINARY_NAME}" "${_REAL_HOME}/bin/llama-turboquant"
            log "OK" "TurboQuant bináris: ~/bin/${BINARY_NAME} + symlink"
          fi

          progress_close

          if [ -f "${_REAL_HOME}/bin/${BINARY_NAME}" ]; then
            ((OK++))
            infra_state_set "FEAT_TURBOQUANT"       "true"
            infra_state_set "TURBOQUANT_BUILD_MODE" "$TQ_BUILD_MODE"

            dialog_msg "TurboQuant — Fordítás kész ✓" \
              "\n  Mód:    ${TQ_ARCH_LBL}\n  Repo:   ${TQ_REPO_URL}\n  CUDA:   ${NVCC_INFO}\n  Binary: ~/bin/${BINARY_NAME}\n  Link:   ~/bin/llama-turboquant → ${BINARY_NAME}\n\n  Teszt:\n    ~/bin/llama-turboquant --version\n\n  Futtatás:\n    ~/bin/llama-turboquant \\\\\n      -m ~/models/model.gguf \\\\\n      --kv-quant turbo3 -p 'Hello'" 22
          else
            ((FAIL++))
            infra_state_set "FEAT_TURBOQUANT" "false"
            log "FAIL" "Bináris nem jött létre: ~/bin/${BINARY_NAME}"
            dialog_warn "TurboQuant — Bináris hiányzik" \
              "\n  A fordítás sikeresnek tűnt de bináris nem keletkezett.\n  Build log: ${LOGFILE_TQ}" 14
          fi
        fi
      fi

      cd "$SCRIPT_DIR" || true
    }  # TQ_BUILD_MODE nem üres
  } || {
    ((SKIP++))
    log "SKIP" "TurboQuant fordítás kihagyva (user döntés)"
  }
fi  # _tq_already_built

# =============================================================================
# SZEKCIÓ 8 — INDÍTÓSZKRIPTEK GENERÁLÁSA
# =============================================================================

mkdir -p "${_REAL_HOME}/bin"

# ── vLLM indítószkript (start-vllm.sh) ───────────────────────────────────────
# Forrás: https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html
if ${HW_VLLM_OK:-false} && [ ! -f "${_REAL_HOME}/bin/start-vllm.sh" ]; then
  cat > "${_REAL_HOME}/bin/start-vllm.sh" << VLLMEOF
#!/bin/bash
# =============================================================================
# start-vllm.sh — vLLM OpenAI API szerver indítója
# Generálva: INFRA 02 v6.3 — $(date '+%Y-%m-%d')
# Forrás: https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html
# =============================================================================
MODEL="\${1:-meta-llama/Llama-3.2-8B-Instruct}"
PORT="\${2:-8000}"
source "${VENV}/bin/activate"
echo "━━━ vLLM szerver ━━━"
echo "  Model:   \$MODEL"
echo "  Port:    \$PORT"
echo "  API:     http://localhost:\${PORT}/v1"
echo "  KV:      fp8 (vLLM beépített)"
echo ""
# --kv-cache-dtype fp8: vLLM beépített KV cache tömörítés
# (KÜLÖNBÖZIK a TurboQuant --kv-quant-tól; ez az OpenAI szerver módhoz való)
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

# ── Ollama OpenAI proxy szkript ───────────────────────────────────────────────
# Ollama 0.0.0.0-ra nyitja (alapból csak localhost) → más gépek is elérik
# Forrás: https://ollama.readthedocs.io/en/
if [ ! -f "${_REAL_HOME}/bin/ollama-proxy.sh" ]; then
  cat > "${_REAL_HOME}/bin/ollama-proxy.sh" << 'PROXYEOF'
#!/bin/bash
# =============================================================================
# ollama-proxy.sh — Ollama OpenAI API proxy (0.0.0.0:11434)
# Generálva: INFRA 02 v6.3
# Forrás: https://ollama.readthedocs.io/en/
# =============================================================================
echo "Ollama endpoint: http://0.0.0.0:11434/v1"
echo "Cursor/Continue.dev API key: bármi (Ollama nem ellenőrzi)"
OLLAMA_HOST=0.0.0.0 ollama serve
PROXYEOF
  chmod +x "${_REAL_HOME}/bin/ollama-proxy.sh"
  log "OK" "ollama-proxy.sh generálva: ~/bin/ollama-proxy.sh"
fi

# ~/bin PATH hozzáadás (03 általában már megtette)
for RC in "${_REAL_HOME}/.zshrc" "${_REAL_HOME}/.bashrc"; do
  [ -f "$RC" ] && ! grep -q 'PATH.*\$HOME/bin\|\$HOME/bin.*PATH' "$RC" 2>/dev/null \
    && echo 'export PATH="$HOME/bin:$PATH"' >> "$RC"
done

# =============================================================================
# SZEKCIÓ 9 — OLLAMA MODELLEK LETÖLTÉSE (interaktív)
# =============================================================================

OLLAMA_AVAIL=false
command -v ollama &>/dev/null && OLLAMA_AVAIL=true
$OLLAMA_AVAIL || systemctl is-active --quiet ollama 2>/dev/null && OLLAMA_AVAIL=true

if $OLLAMA_AVAIL; then
  PULL_MODELS=$(dialog_checklist \
    "Ollama — Modellek letöltése" \
    "  RTX 5090 (32GB VRAM) modell ajánlások:\n\n  KÓDGENERÁLÁS:\n    qwen2.5-coder:32b ~20GB ← FŐ MODELL, legjobb kód\n    qwen2.5-coder:7b   ~5GB ← gyors, könnyű feladatok\n  REASONING:\n    deepseek-r1:32b   ~20GB ← legerősebb reasoning\n    qwen2.5:32b       ~20GB ← általános + MAGYAR\n  EMBEDDING (RAG-hoz kötelező):\n    nomic-embed-text ~274MB ← helyi RAG embedding\n\n  Válaszd ki mit töltünk le (Space = kijelölés):" \
    30 18 \
    "qwen2.5-coder:32b"     "Kódgenerálás — FŐ modell (~20GB)"           OFF \
    "qwen2.5-coder:7b"      "Kódgenerálás — gyors (~5GB)"                ON  \
    "deepseek-coder-v2:16b" "Kódgenerálás — alternatíva (~10GB)"         OFF \
    "deepseek-r1:32b"       "Reasoning — legerősebb (~20GB)"             OFF \
    "qwen2.5:32b"           "Általános + MAGYAR (~20GB)"                 OFF \
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
        sleep 3; [ $_mpct -lt 90 ] && ((_mpct++))
      done
      wait $PULL_PID
      progress_close
      ollama list 2>/dev/null | grep -q "${MODEL%%:*}" \
        && log "OK"   "Modell letöltve: ${MODEL}" \
        || log "WARN" "Modell ellenőrizd: ${MODEL} — ollama list"
    done
    _installed=$(ollama list 2>/dev/null | tail -n +2 | awk '{print "    " $1 "  " $3}')
    dialog_msg "Modellek letöltve ✓" \
      "\n  Telepített modellek:\n${_installed:-  (ollama list-hez restart szükséges)}" 16
  fi
fi

# =============================================================================
# SZEKCIÓ 10 — TURBOQUANT MODELL KONVERZIÓ ASSZISZTENS
# =============================================================================

TQ_BIN=""
[ -f "${_REAL_HOME}/bin/llama-turboquant" ] && TQ_BIN="${_REAL_HOME}/bin/llama-turboquant"
[ -z "$TQ_BIN" ] && TQ_BIN=$(ls "${_REAL_HOME}/bin/llama-turboquant-"* 2>/dev/null | head -1)

if [ -n "$TQ_BIN" ] && command -v ollama &>/dev/null; then
  OLLAMA_MODELS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -v '^$')
  MODEL_COUNT=$(printf '%s' "$OLLAMA_MODELS" | grep -c . 2>/dev/null || echo 0)

  if [ "$MODEL_COUNT" -gt 0 ]; then
    dialog_yesno "TurboQuant — Futtatási parancsok generálása" \
      "\n  TQ bináris: ${TQ_BIN}\n  Ollama modellek: ${MODEL_COUNT} db\n\n$(printf '%s\n' "$OLLAMA_MODELS" | awk '{print "    " $0}')\n\n  TurboQuant = KV cache tömörítés futtatás közben.\n  NEM módosítja a modell fájlt!\n\n  Generáljuk a futtatási parancsokat?" 22 \
    && {
      TQ_CHECKLIST_ITEMS=()
      while IFS= read -r MODEL; do
        [ -z "$MODEL" ] && continue
        if echo "$MODEL" | grep -qiE "70b|72b"; then       REC="ERŐSEN AJÁNLOTT"
        elif echo "$MODEL" | grep -qiE "32b|34b"; then     REC="AJÁNLOTT"
        elif echo "$MODEL" | grep -qiE "13b|16b"; then     REC="hasznos"
        else                                                REC="enyhe előny"
        fi
        TQ_CHECKLIST_ITEMS+=("$MODEL" "${REC}" "OFF")
      done <<< "$OLLAMA_MODELS"

      SELECTED_MODELS=$(dialog_checklist \
        "TurboQuant — Modell kiválasztás" \
        "\n  Válaszd ki melyik modellekhez generálunk parancsot:" \
        22 "${#TQ_CHECKLIST_ITEMS[@]}" \
        "${TQ_CHECKLIST_ITEMS[@]}")

      if [ -n "$SELECTED_MODELS" ]; then
        TQ_MODE=$(dialog_menu "TurboQuant kvantálási szint" \
          "\n  turbo3 = 3-bit: 6x kisebb KV cache | +35% decode (ajánlott)\n  turbo4 = 4-bit: 4x kisebb KV cache | +20% decode" \
          14 2 \
          "turbo3" "3-bit — legjobb sebesség + memória (ajánlott)" \
          "turbo4" "4-bit — jobb minőség, kevesebb tömörítés")
        [ -z "$TQ_MODE" ] && TQ_MODE="turbo3"

        TQ_SCRIPT="${_REAL_HOME}/bin/run-tq-models.sh"
        printf "#!/bin/bash\n# TurboQuant run script — generálva: %s | kvantálás: %s\n\n" \
          "$(date)" "$TQ_MODE" > "$TQ_SCRIPT"
        for MODEL in $(printf '%s' "$SELECTED_MODELS" | tr -d '"' | tr ' ' '\n'); do
          [ -z "$MODEL" ] && continue
          printf "# %s (%s):\n%s \\\\\n  -m \$(ollama show %s --modelfile 2>/dev/null | grep '^FROM' | awk '{print \$2}') \\\\\n  --kv-quant %s -c 32768 -p 'Hello'\n\n" \
            "$MODEL" "$TQ_MODE" "$TQ_BIN" "$MODEL" "$TQ_MODE" >> "$TQ_SCRIPT"
        done
        chmod +x "$TQ_SCRIPT"
        log "TQ" "Run script generálva: ${TQ_SCRIPT}"
      fi
    }
  fi
fi

# =============================================================================
# SZEKCIÓ 11 — GPU TESZT
# =============================================================================

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
    print("  → reboot szükséges (NVIDIA driver nem töltődött be)")
PYEOF
)
  log "GPU_TEST" "${GPU_TEST}"
  dialog_msg "GPU teszt eredménye" "\n${GPU_TEST}\n\n  Ha CUDA elérhető=False: sudo reboot szükséges!" 14
fi

# =============================================================================
# SZEKCIÓ 12 — STATE ÍRÁS + ÖSSZESÍTŐ
# =============================================================================

# ── Infra state frissítése ────────────────────────────────────────────────────
infra_state_set "MOD_02_DONE" "true"

# FEAT_VLLM frissítése az aktuális Python import alapján
"${VENV_PY}" -c "import vllm" 2>/dev/null \
  && infra_state_set "FEAT_VLLM" "true" \
  || infra_state_set "FEAT_VLLM" "false"

# INST_OLLAMA_VER: ha még üres (pl. Ollama már kész volt, nem újratelepítve)
if [ -z "$(infra_state_get "INST_OLLAMA_VER" "")" ] && command -v ollama &>/dev/null; then
  _ov=$(ollama version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
  [ -z "$_ov" ] && _ov=$(ollama --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
  infra_state_set "INST_OLLAMA_VER" "${_ov:-telepítve}"
fi

# State konzisztencia validáció
infra_state_validate

# ── Fő log jogosultság — utolsó beállítás (futás közben root is írt bele) ─────
chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
log "OK" "Log jogosultságok beállítva: 644 / ${_REAL_USER}"

# ── Összesítő ─────────────────────────────────────────────────────────────────
show_result "$OK" "$SKIP" "$FAIL"

dialog_msg "INFRA 02 — Összefoglalás" \
  "\n  ── Ollama ──────────────────────────────────────────────
    ollama serve
    ollama pull qwen2.5-coder:7b
    ~/bin/ollama-proxy.sh           # OpenAI proxy

  ── vLLM ────────────────────────────────────────────────
    ~/bin/start-vllm.sh meta-llama/Llama-3.2-8B-Instruct

  ── TurboQuant ──────────────────────────────────────────
    ~/bin/llama-turboquant --version
    ~/bin/run-tq-models.sh          # generált futtatók

  ── API végpontok ───────────────────────────────────────
    Ollama:  http://localhost:11434
    vLLM:    http://localhost:8000/v1

  ── Ellenőrzés ──────────────────────────────────────────
    source ${VENV}/bin/activate
    python -c 'import torch, vllm, langchain; print(\"OK\")'

  ── Log fájlok (644 / ${_REAL_USER}) ─────────────────────
    AI log:    ${LOGFILE_AI}
    TQ build:  ~/AI-LOG-INFRA-SETUP/turboquant_*.log" 34

log "MASTER" "INFRA 02 befejezve: OK=${OK} SKIP=${SKIP} FAIL=${FAIL}"
