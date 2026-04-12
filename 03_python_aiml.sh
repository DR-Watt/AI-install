#!/bin/bash
# =============================================================================
# 03_python_aiml.sh — Python 3.12 + PyTorch + AI/ML Stack v6.5
#
# Szerepe az INFRA rendszerben
# ────────────────────────────
#   ✓ pyenv — Python verziókezelő (több verzió párhuzamosan)
#   ✓ Python 3.12.9 — forrásból fordítva (PGO + LTO optimalizálás)
#       FONTOS: liblzma-dev KÖTELEZŐ fordítás előtt (PyTorch modellek!)
#   ✓ uv — Astral ultra-gyors Python csomagkezelő (Rust alapú, ~100x gyorsabb)
#   ✓ ~/AI-VIBE/venvs/ai/ — izolált AI/ML fejlesztői virtuális környezet
#   ✓ PyTorch 2.x — CUDA index az infra state-ből (cu126|cu128|cpu)
#   ✓ Teljes AI/ML csomag stack (LangChain, HuggingFace, OpenAI, Anthropic...)
#   ✓ Fejlesztői eszközök (ruff, mypy, pytest, pre-commit, jupyter)
#   ✓ Projekt template (pyproject.toml, .cursorrules, .vscode/settings.json)
#   ✓ MOD_03_DONE=true → infra state (02_local_ai_stack.sh előfeltétele)
#
# NEM tartalmaz (→ 02_local_ai_stack.sh):
#   ✗ Ollama, vLLM, TurboQuant
#   ✗ Docker GPU konfiguráció
#
# Előfeltételek
# ─────────────
#   • 01b_post_reboot.sh sikeresen lefutott (MOD_01B_DONE=true)
#   • Fordítási függőségek (liblzma-dev stb.) — a modul maga telepíti
#   • sudo jogosultság (apt fordítási függőségekhez)
#   • Internet elérés (pyenv, uv, PyTorch letöltés)
#
# Futtatás
# ────────
#   sudo bash 03_python_aiml.sh           # közvetlen
#   sudo bash 00_master.sh  (03 kijelölve) # master-en keresztül
#
# RUN_MODE értékek (00_master.sh v6.5)
# ────────────────────────────────────
#   install   → csak hiányzó komponensek felrakása (alapértelmezett)
#   update    → uv + csomagok frissítése, pyenv frissítése
#   reinstall → teljes újratelepítés (--force flag pyenv-nek)
#   check     → csak állapot felmérés, semmi sem változik
#   fix       → hiányzó komponensek pótlása reboot nélkül (≈ install)
#               infra_require NEM blokkol fix módban (lib kezeli)
#               REBOOT_NEEDED NEM propagálódik (master kezeli)
#
# Változtatások v6.5 (2026-04-12 log analízis — 3 bug fix)
# ──────────────────────────────────────────────────────────
#   [BUG 1 FIX] apt_install_progress false FAIL — build deps lépésben:
#     Tünet: apt "already newest version" → 0 upgraded, 0 installed → apt
#     exit code 0, DE apt_install_progress mégis visszaad 1-et. A 03 szál
#     0 upgraded esetén nem veszi "OK"-nak az apt_install_progress-t.
#     Fix: pkg_installed() alapú közvetlen ellenőrzés apt exit code helyett.
#     Ha a kritikus csomagok (liblzma-dev, libssl-dev stb.) dpkg szerint
#     telepítve vannak → ((OK++)), dependetlenül az apt_install_progress
#     visszatérési értékétől.
#
#   [BUG 2 FIX] zsh:1: no matches found: uvicorn[standard] — KRITIKUS:
#     Tünet: 'su - pipi -c "uv pip install ... uvicorn[standard] ..."'
#     Gyökérok: su - login shellként zsh-t indít (pipi default shell).
#     A zsh a szögletes zárójelet [standard] glob mintának értelmezi.
#     Ha nincs "uvicorn" nevű fájl s/t/a/n/d/a/r/d karakterekre végződve:
#     "no matches found" → exit 1 → FAIL → FastAPI, LangChain, HF, Jupyter
#     NEM települ (az összes csomag elvész!)
#     Fix: ALL_PKGS tömböt /tmp/infra_03_requirements.txt fájlba írjuk,
#     és 'uv pip install -r <fájl>' hívjuk — NEM parancssor argumentumként.
#     A fájlban lévő sorok nem esnek át shell globbing-on.
#
#   [BUG 3 FIX] MOD_03_DONE inkonzisztens írási feltétel — 01a BUG 4 FIX minta:
#     Tünet: FAIL=2 esetén is MOD_03_DONE=true → 02/06 szálak úgy futnak
#     mintha a 03 kész lenne, de FastAPI/LangChain/HF hiányzik.
#     Gyökérok v6.4: 'if FAIL==0 OR OK>0' feltétel (01a v6.11 BUG 4 FIX előtt)
#     Fix: 01a v6.11 BUG 4 FIX mintájára:
#       MOD_03_DONE=true CSAK ha FAIL==0
#       FAIL>0 esetén: MOD_03_DONE="" (törlés, ha volt korábbi true)
#
#   [NEW] infra_state_group_ts "INST_03" — 01a/01b konzisztencia:
#     01a és 01b INST_TS csoportos timestampot ír a state szekciós megjelenítéshez.
#     A 03 szál eddig nem írta → [03 — Python/AI-ML] szekcióban nincs timestamp.
#     Fix: infra_state_group_ts "INST_03" hívás a state írás VÉGÉN.
#
# Változtatások v6.4 (CORE v6.5 szinkronizáció)
# ────────────────────────────────────────────────
#   [FIX] PYTORCH_INDEX=cpu tévesen — hw_has_nvidia() alapú javítás
#   [NEW] detect_run_mode integráció — skip/update/reinstall dialóg
#   [NEW] Log chmod — sudo alatt root:root log
#   [FIX] check mód early exit — explicit dialóg
#
# Dokumentáció referenciák
# ────────────────────────
#   Python 3.12:   https://docs.python.org/3.12/
#   pyenv:         https://github.com/pyenv/pyenv#installation
#   uv:            https://docs.astral.sh/uv/
#   PyTorch:       https://docs.pytorch.org/docs/stable/index.html
#   LangChain:     https://python.langchain.com/docs/get_started/
#   HuggingFace:   https://huggingface.co/docs/transformers/
# =============================================================================

# ── Script könyvtár (szimlink-biztos) ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Közös függvénytár betöltése ───────────────────────────────────────────────
LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" \
  || { echo "HIBA: 00_lib.sh hiányzik! Elvárt helye: $LIB"; exit 1; }

# =============================================================================
# ██  SZEKCIÓ 1 — KONFIGURÁCIÓ  ██
# =============================================================================

INFRA_NUM="03"
INFRA_NAME="Python 3.12 + PyTorch + AI/ML Stack"
INFRA_HW_REQ=""

PY_VER="3.12.9"
PY_CONFIGURE_OPTS="--enable-optimizations"

declare -A MIN_VER=(
  [python]="3.12.0"
  [uv]="0.4.0"
)

declare -A PKGS=(
  [python_build]="liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev
                  libbz2-dev zlib1g-dev libffi-dev tk-dev uuid-dev
                  libncurses-dev xz-utils libxml2-dev libxmlsec1-dev
                  libssl-dev libnss3-dev"
)

declare -A URLS=(
  [pyenv_install]="https://pyenv.run"
  [uv_install]="https://astral.sh/uv/install.sh"
)

TORCH_PKGS="torch torchvision torchaudio"

AI_PKGS_API=(
  "fastapi" "uvicorn[standard]" "pydantic>=2.0" "pydantic-settings"
  "sqlmodel" "httpx" "aiohttp" "requests" "aiofiles" "websockets"
)
AI_PKGS_LLM=(
  "openai>=1.0" "anthropic>=0.25" "langchain>=0.2" "langchain-core"
  "langchain-community" "langchain-openai" "langchain-anthropic" "langgraph"
)
AI_PKGS_HF=(
  "huggingface-hub>=0.22" "transformers>=4.40" "datasets>=2.19"
  "tokenizers>=0.19" "accelerate>=0.29" "safetensors>=0.4"
  "peft>=0.10" "sentence-transformers" "einops" "tiktoken"
)
AI_PKGS_DATA=(
  "numpy>=1.26" "pandas>=2.0" "polars>=0.20" "scipy>=1.12"
  "scikit-learn>=1.4" "matplotlib>=3.8" "seaborn>=0.13"
  "plotly>=5.18" "pillow>=10.0"
)
AI_PKGS_DEV=(
  "ruff>=0.4" "black>=24.0" "isort>=5.13" "mypy>=1.9"
  "pytest>=8.0" "pytest-asyncio>=0.23" "pytest-cov>=5.0"
  "pre-commit>=3.7" "ipython>=8.22"
)
AI_PKGS_JUPYTER=(
  "jupyter>=1.0" "jupyterlab>=4.0" "notebook>=7.0"
  "ipywidgets>=8.0" "ipykernel>=6.29"
)
AI_PKGS_UTIL=(
  "tqdm>=4.66" "rich>=13.7" "python-dotenv>=1.0" "pyyaml>=6.0"
  "toml>=0.10" "typer>=0.12" "loguru>=0.7" "tenacity>=8.2"
  "psutil>=5.9" "beautifulsoup4>=4.12" "packaging"
)

COMP_SPECS=(
  "Python build deps|build_deps|"
  "pyenv|pyenv|"
  "Python ${PY_VER}|python|${PY_VER}"
  "lzma modul|lzma_ok|"
  "uv csomagkezelő|uv|${MIN_VER[uv]}"
  "AI/ML venv|venv|"
  "PyTorch (CUDA)|torch|"
  "FastAPI|fastapi|"
  "JupyterLab|jupyter|"
  "LangChain|langchain|"
  "HuggingFace Hub|huggingface_hub|"
  "Projekt template|template|"
)

PYENV_ROOT="$_REAL_HOME/.pyenv"
VENV_DIR="$_REAL_HOME/AI-VIBE/venvs/ai"
VENV_PY="$VENV_DIR/bin/python"
VENV_UV="$_REAL_HOME/.local/bin/uv"
PY_BIN="$PYENV_ROOT/versions/$PY_VER/bin/python3"
TEMPLATE_DIR="$_REAL_HOME/templates/python-ai"
LOCK_FILE="/tmp/infra_03_python.lock"
# [BUG 2 FIX] Temp requirements fájl — zsh globbing megkerüléséhez
# Az uv pip install parancssor argumentumaiba kerülő csomagneveket (pl. uvicorn[standard])
# a zsh glob mintának értelmezi → NEM adhatók parancssor argumentumként login shell-en át.
REQ_FILE="/tmp/infra_03_requirements.txt"

# =============================================================================
# ██  SZEKCIÓ 2 — INICIALIZÁLÁS  ██
# =============================================================================

LOGFILE_AI="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_03_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_03_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="$LOGFILE_AI"
log_init

chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true

check_lock "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE" "$REQ_FILE"' EXIT

CUDA_VER=$(infra_state_get "INST_CUDA_VER" "12.6")
PYTORCH_INDEX=$(infra_state_get "PYTORCH_INDEX" "cu126")
HW_GPU_ARCH_ST=$(infra_state_get "HW_GPU_ARCH" "igpu")

# [FIX v6.4] hw_has_nvidia() alapú GPU detektálás — nem FEAT_GPU_ACCEL state kulcs
if ! hw_has_nvidia; then
  PYTORCH_INDEX="cpu"
  log "STATE" "CPU-only profil: PYTORCH_INDEX=cpu (hw_has_nvidia=false, profil: ${HW_PROFILE})"
else
  _expected_idx="$(cuda_pytorch_index "$CUDA_VER" 2>/dev/null || echo "")"
  if [ -n "$_expected_idx" ] && [ "$PYTORCH_INDEX" != "$_expected_idx" ]; then
    log "WARN" "PYTORCH_INDEX mismatch: state=$PYTORCH_INDEX, várható=$_expected_idx"
    PYTORCH_INDEX="$_expected_idx"
    infra_state_set "PYTORCH_INDEX" "$_expected_idx"
  fi
fi

log "STATE" "Betöltve: CUDA=$CUDA_VER | PyTorch=$PYTORCH_INDEX | GPU arch=$HW_GPU_ARCH_ST | profil=$HW_PROFILE"

infra_state_init

infra_compatible "$INFRA_HW_REQ" || {
  dialog_warn "Hardver inkompatibilis" \
    "\n  HW_REQ: $INFRA_HW_REQ | Profil: $HW_PROFILE\n  Modul kihagyva." 10
  exit 2
}

if [[ "${RUN_MODE:-install}" != "reinstall" ]]; then
  infra_require "01b" "User Environment (01b_post_reboot.sh)" || {
    dialog_yesno "Függőség figyelmeztető" \
      "\n  MOD_01B_DONE nincs beállítva.\n\n  A 01b (Zsh, shell setup) fut le ELŐTTE.\n\n  Ennek ellenére folytatjuk?" 14 || exit 1
    log "WARN" "01b függőség manuálisan bypass-olva"
  }
fi

export PYENV_ROOT
export PATH="$PYENV_ROOT/bin:$_REAL_HOME/.local/bin:$PATH"
[ -d "$PYENV_ROOT/bin" ] && eval "$(pyenv init -)" 2>/dev/null || true

# =============================================================================
# ██  SZEKCIÓ 3 — KOMPONENS FELMÉRÉS  ██
# =============================================================================

log "COMP" "━━━ Komponens állapot felmérés ━━━"

if [ "${COMP_USE_CACHED:-false}" = "true" ] && comp_state_exists "$INFRA_NUM"; then
  comp_load_state "$INFRA_NUM"
  _state_age=$(comp_state_age_hours "$INFRA_NUM")
  log "COMP" "Mentett check eredmény betöltve — INFRA $INFRA_NUM (${_state_age} óra)"
else
  _build_deps_ok=true
  for pkg in liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev \
             libbz2-dev libffi-dev libssl-dev; do
    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || { _build_deps_ok=false; break; }
  done
  $_build_deps_ok \
    && COMP_STATUS[build_deps]="ok" || COMP_STATUS[build_deps]="missing"
  log "COMP" "  build_deps: ${COMP_STATUS[build_deps]}"

  if command -v pyenv &>/dev/null || [ -x "$PYENV_ROOT/bin/pyenv" ]; then
    COMP_STATUS[pyenv]="ok"
    COMP_VER[pyenv]="$(pyenv --version 2>/dev/null | grep -oP '[\d.]+' | head -1)"
  else
    COMP_STATUS[pyenv]="missing"
  fi
  log "COMP" "  pyenv: ${COMP_STATUS[pyenv]} ${COMP_VER[pyenv]:-}"

  comp_check_python "$PY_VER" "$PYENV_ROOT"
  log "COMP" "  python: ${COMP_STATUS[python]:-missing} ${COMP_VER[python]:-}"

  if [ -x "$PY_BIN" ] && "$PY_BIN" -c "import lzma, bz2, readline" 2>/dev/null; then
    COMP_STATUS[lzma_ok]="ok"
  else
    COMP_STATUS[lzma_ok]="missing"
  fi
  log "COMP" "  lzma_ok: ${COMP_STATUS[lzma_ok]}"

  comp_check_uv "${MIN_VER[uv]}" "$VENV_UV"
  log "COMP" "  uv: ${COMP_STATUS[uv]:-missing} ${COMP_VER[uv]:-}"

  if [ -d "$VENV_DIR" ] && [ -x "$VENV_PY" ]; then
    COMP_STATUS[venv]="ok"
  else
    COMP_STATUS[venv]="missing"
  fi
  log "COMP" "  venv: ${COMP_STATUS[venv]}"

  comp_check_torch "" "$VENV_PY"
  log "COMP" "  torch: ${COMP_STATUS[torch]:-missing} ${COMP_VER[torch]:-}"

  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import fastapi" 2>/dev/null; then
    COMP_STATUS[fastapi]="ok"
  else
    COMP_STATUS[fastapi]="missing"
  fi
  log "COMP" "  fastapi: ${COMP_STATUS[fastapi]}"

  if [ -x "$VENV_DIR/bin/jupyter" ]; then
    COMP_STATUS[jupyter]="ok"
    COMP_VER[jupyter]="$("$VENV_DIR/bin/jupyter" --version 2>/dev/null | head -1)"
  else
    COMP_STATUS[jupyter]="missing"
  fi
  log "COMP" "  jupyter: ${COMP_STATUS[jupyter]}"

  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import langchain" 2>/dev/null; then
    COMP_STATUS[langchain]="ok"
  else
    COMP_STATUS[langchain]="missing"
  fi
  log "COMP" "  langchain: ${COMP_STATUS[langchain]}"

  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import huggingface_hub" 2>/dev/null; then
    COMP_STATUS[huggingface_hub]="ok"
  else
    COMP_STATUS[huggingface_hub]="missing"
  fi
  log "COMP" "  huggingface_hub: ${COMP_STATUS[huggingface_hub]}"

  if [ -f "$TEMPLATE_DIR/pyproject.toml" ] && \
     [ -f "$TEMPLATE_DIR/.cursorrules" ]; then
    COMP_STATUS[template]="ok"
  else
    COMP_STATUS[template]="missing"
  fi
  log "COMP" "  template: ${COMP_STATUS[template]}"

  if [ "${RUN_MODE:-install}" = "check" ]; then
    comp_save_state "$INFRA_NUM"
    log "COMP" "Check mód: COMP state mentve"
  fi
fi

MISSING=0
STATUS_LINES=""
for spec in "${COMP_SPECS[@]}"; do
  IFS='|' read -r label key min_v <<< "$spec"
  st="${COMP_STATUS[$key]:-missing}"
  ver="${COMP_VER[$key]:-}"
  if [ "$st" = "missing" ]; then
    ((MISSING++)); STATUS_LINES+="  ✗  $label\n"
    log "COMP" "  ✗  $label — hiányzik"
  elif [ "$st" = "old" ]; then
    ((MISSING++)); STATUS_LINES+="  ⚠  $label — $ver (elavult)\n"
    log "COMP" "  ⚠  $label — $ver elavult"
  else
    STATUS_LINES+="  ✓  $label — $ver\n"
    log "COMP" "  ✓  $label — $ver"
  fi
done
log "COMP" "━━━ Összesítés: ${MISSING} hiányzó/elavult ━━━"

declare -a COMP_KEYS=(build_deps pyenv python lzma_ok uv venv torch fastapi jupyter langchain huggingface_hub template)

# =============================================================================
# ██  SZEKCIÓ 4 — FUTTATÁSI MÓD DÖNTÉS  ██
# =============================================================================

log_infra_header "   • pyenv | Python ${PY_VER} (PGO+LTO) | uv
   • AI/ML venv: PyTorch ${PYTORCH_INDEX} + LangChain + HuggingFace + FastAPI + JupyterLab
   • Fejlesztői eszközök: ruff, mypy, pytest, pre-commit
   • Projekt template: pyproject.toml, .cursorrules, .vscode/settings.json"
log_install_paths "   $PYENV_ROOT — pyenv + Python ${PY_VER}
   $_REAL_HOME/.local/bin/uv — uv csomagkezelő
   $VENV_DIR — AI/ML venv
   $TEMPLATE_DIR — projekt template"

if [ "${RUN_MODE:-install}" = "check" ]; then
  log "MODE" "check mód — read-only"
  if [ "$MISSING" -gt 0 ]; then
    dialog_warn "[Ellenőrző] $INFRA_NAME" \
      "\n$(printf '%b' "$STATUS_LINES")\n  $MISSING hiányzó — install/fix módban javítható." 30
  else
    dialog_msg "[Ellenőrző] $INFRA_NAME ✓" \
      "\n$(printf '%b' "$STATUS_LINES")\n  PyTorch: $PYTORCH_INDEX | CUDA: $CUDA_VER" 28
  fi
  exit 0
fi

if [ "${RUN_MODE:-install}" = "reinstall" ]; then
  for spec in "${COMP_SPECS[@]}"; do
    IFS='|' read -r label key _ <<< "$spec"
    COMP_STATUS["$key"]="missing"
  done
  MISSING=${#COMP_SPECS[@]}
  log "MODE" "Reinstall: minden komponens újratelepítve ($MISSING db)"
fi

if [ "$MISSING" -eq 0 ] && \
   [ "${RUN_MODE:-install}" != "fix" ] && \
   [ "${RUN_MODE:-install}" != "reinstall" ]; then
  detect_run_mode COMP_KEYS
  log "MODE" "detect_run_mode: RUN_MODE=$RUN_MODE"
fi

if [ "${RUN_MODE:-install}" = "skip" ]; then
  dialog_msg "[03] ✓ Minden naprakész" \
    "\n$(printf '%b' "$STATUS_LINES")\n  MOD_03_DONE state írva." 28
  infra_state_set "MOD_03_DONE" "true"
  chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
  chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
  exit 0
fi

case "${RUN_MODE:-install}" in
  update)    _mode_label="Frissítés" ;;
  reinstall) _mode_label="Újratelepítés" ;;
  fix)       _mode_label="Javítás" ;;
  *)         _mode_label="Telepítés" ;;
esac

dialog_yesno "[$_mode_label] — $INFRA_NAME" \
  "\n  Komponensek:\n$(printf '%b' "$STATUS_LINES")
  PyTorch: $PYTORCH_INDEX | CUDA: $CUDA_VER
  Python: $PY_VER (pyenv)
  Venv: $VENV_DIR

  A $_mode_label elkezdéséhez nyomj Igent." 30 || exit 0

OK=0; SKIP=0; FAIL=0

# =============================================================================
# ██  SZEKCIÓ 5 — 1/7: FORDÍTÁSI FÜGGŐSÉGEK  ██
# =============================================================================

if [ "${COMP_STATUS[build_deps]}" != "ok" ] || \
   [ "${RUN_MODE:-install}" = "reinstall" ]; then

  dialog_yesno "1/7 — Fordítási függőségek" "
  A pyenv Python-t FORRÁSBÓL FORDÍTJA.
  Szükséges csomagok:

    liblzma-dev     — ⚠ KRITIKUS: xz/lzma (PyTorch modellek!)
    libreadline-dev — readline (Python REPL)
    libssl-dev      — ssl (https, Anthropic API)
    libffi-dev      — ctypes, cffi
    + szql, bz2, zlib, tk, uuid, ncurses, xml, nss

  Ha HIÁNYOZNAK fordítás előtt: lzma modul NEM FORDUL!
  sudo szükséges.
  Folytatjuk?" 26 || { ((SKIP++)); goto_step_2=false; }

  if [ "${goto_step_2:-true}" = "true" ]; then
    log "STEP" "1/7 Fordítási függőségek telepítése..."
    # shellcheck disable=SC2086
    apt_install_progress "Python fordítási függőségek" \
      "Python build deps telepítése (sudo)..." \
      ${PKGS[python_build]}

    # [BUG 1 FIX] pkg_installed() ellenőrzés az apt_install_progress exit code HELYETT.
    # Az apt_install_progress "already newest version" esetén megbízhatatlan exit code-ot
    # ad vissza (race condition a _ec_file írás/olvasás között). A dpkg-alapú
    # ellenőrzés biztos: ha a csomag telepítve van, OK — függetlenül az apt EC-től.
    _build_check=true
    for _chk_pkg in liblzma-dev libssl-dev libffi-dev libreadline-dev; do
      dpkg -l "$_chk_pkg" 2>/dev/null | grep -q "^ii" || { _build_check=false; break; }
    done
    if $_build_check; then
      ((OK++))
      log "OK" "Python fordítási függőségek OK (dpkg alapján)"
    else
      ((FAIL++))
      log "FAIL" "Fordítási függőségek részlegesen hiányznak"
      dialog_warn "Build deps — Hiba" \
        "\n  liblzma-dev / libssl-dev / libffi-dev / libreadline-dev\n  nem települt. Python fordítás kihagyva!" 12
    fi
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 6 — 2/7: PYENV  ██
# =============================================================================

_pyenv_needs_install=false
[ "${COMP_STATUS[pyenv]}" != "ok" ] && _pyenv_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _pyenv_needs_install=true

if $_pyenv_needs_install || [ "${RUN_MODE:-install}" = "update" ]; then
  if [ "${RUN_MODE:-install}" = "update" ] && [ "${COMP_STATUS[pyenv]}" = "ok" ]; then
    if dialog_yesno "2/7 — pyenv frissítés" \
      "\n  pyenv: ${COMP_VER[pyenv]:-?} → legújabb\n  Folytatjuk?" 10; then
      run_with_progress "pyenv frissítés" "pyenv update..." \
        su - "$_REAL_USER" -c "pyenv update" \
        && ((OK++)) || ((FAIL++))
    else
      ((SKIP++))
    fi
  elif $_pyenv_needs_install; then
    dialog_yesno "2/7 — pyenv telepítése" "
  pyenv: Python verziókezelő
  Hely: ~/.pyenv | Shell: ~/.zshrc + ~/.bashrc + ~/.profile
  Forrás: https://pyenv.run
  Folytatjuk?" 12 || { ((SKIP++)); goto_step_3=false; }

    if [ "${goto_step_3:-true}" = "true" ]; then
      log "STEP" "2/7 pyenv telepítése..."
      if [ ! -d "$PYENV_ROOT" ]; then
        run_with_progress "pyenv telepítés" "curl pyenv.run | bash..." \
          su - "$_REAL_USER" -c "curl -fsSL ${URLS[pyenv_install]} | bash" \
          && ((OK++)) || ((FAIL++))
      else
        run_with_progress "pyenv frissítés" "pyenv update..." \
          su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv update" \
          && ((OK++)) || ((FAIL++))
      fi

      for RC in "$_REAL_HOME/.zshrc" "$_REAL_HOME/.bashrc" "$_REAL_HOME/.profile"; do
        grep -q "PYENV_ROOT" "$RC" 2>/dev/null && continue
        cat >> "$RC" << 'PYENVRC'

# ── pyenv konfiguráció (vibe-coding-infra) ────────────────────────────────────
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"
PYENVRC
        log "INFO" "pyenv init hozzáadva: $RC"
      done
      export PATH="$PYENV_ROOT/bin:$PATH"
      eval "$(pyenv init -)" 2>/dev/null || true
    fi
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 7 — 3/7: PYTHON 3.12.X FORDÍTÁSA  ██
# =============================================================================

NEED_PY=false
[ "${COMP_STATUS[python]}" != "ok" ]     && NEED_PY=true
[ "${COMP_STATUS[lzma_ok]}" != "ok" ]    && NEED_PY=true
[ "${RUN_MODE:-install}" = "reinstall" ] && NEED_PY=true

if $NEED_PY; then
  FORCE_FLAG=""
  [ "${COMP_STATUS[python]}" = "ok" ] && FORCE_FLAG="--force"
  BUILD_MSG="Python ${PY_VER} fordítása"
  [ -n "$FORCE_FLAG" ] && BUILD_MSG="Python ${PY_VER} ÚJRAFORDÍTÁSA (lzma fix)"

  dialog_yesno "3/7 — $BUILD_MSG" "
  Optimalizálás: $PY_CONFIGURE_OPTS (PGO + LTO, ~8-12 perc)
  FONTOS: liblzma-dev a 1. lépésben települt — KÖTELEZŐ!
  Log: $LOGFILE_AI
  Folytatjuk?" 16 || { ((SKIP++)); goto_step_4=false; }

  if [ "${goto_step_4:-true}" = "true" ]; then
    log "STEP" "3/7 Python ${PY_VER} fordítása (${PY_CONFIGURE_OPTS})..."
    PYTHON_CONFIGURE_OPTS="$PY_CONFIGURE_OPTS" \
      su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv install $FORCE_FLAG $PY_VER" \
      >> "$LOGFILE_AI" 2>&1 &
    PY_PID=$!
    progress_open "Python ${PY_VER} fordítása" "pyenv install (PGO+LTO, ~8-12 perc)"
    i=2
    while kill -0 $PY_PID 2>/dev/null; do
      progress_set "$i" "Python ${PY_VER} fordítása..."; sleep 5; [ $i -lt 88 ] && ((i++))
    done
    progress_close; wait $PY_PID; PY_EC=$?

    if [ $PY_EC -ne 0 ]; then
      ((FAIL++))
      dialog_warn "Python fordítás — HIBA" "\n  exit $PY_EC | Log: $LOGFILE_AI" 12
    else
      su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv global $PY_VER" >> "$LOGFILE_AI" 2>&1
      if "$PY_BIN" -c "import lzma; import bz2; import readline; import ssl" 2>/dev/null; then
        ((OK++))
        log "OK" "Python ${PY_VER} OK | lzma, ssl, readline: OK"
        infra_state_set "INST_PYTHON_VER" "$PY_VER"
        dialog_msg "✓ Python ${PY_VER} — Sikeres" "
  ✓  lzma: OK (PyTorch checkpointok olvashatók!)
  ✓  ssl, readline: OK" 12
      else
        ((FAIL++))
        dialog_warn "Python — LZMA HIBA" \
          "\n  lzma modul HIÁNYZIK! Fordítsd újra (reinstall) az 1. lépés után.\n  Log: $LOGFILE_AI" 12
      fi
    fi
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 8 — 4/7: UV  ██
# =============================================================================

_uv_needs_install=false
[ "${COMP_STATUS[uv]}" != "ok" ] && _uv_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _uv_needs_install=true

if $_uv_needs_install || [ "${RUN_MODE:-install}" = "update" ]; then
  if [ "${RUN_MODE:-install}" = "update" ] && [ "${COMP_STATUS[uv]}" = "ok" ]; then
    dialog_yesno "4/7 — uv frissítés" \
      "\n  ${COMP_VER[uv]:-?} → legújabb\n  Folytatjuk?" 10 || { ((SKIP++)); goto_step_5=false; }
    [ "${goto_step_5:-true}" = "true" ] && \
      run_with_progress "uv self update" "uv self update..." \
        su - "$_REAL_USER" -c "$VENV_UV self update" \
        && ((OK++)) || ((FAIL++))
  elif $_uv_needs_install; then
    dialog_yesno "4/7 — uv telepítése" "
  Astral uv: ~100x gyorsabb mint pip (Rust alapú)
  Hely: ~/.local/bin/uv | Forrás: https://docs.astral.sh/uv/
  Folytatjuk?" 12 || { ((SKIP++)); goto_step_5=false; }
    if [ "${goto_step_5:-true}" = "true" ]; then
      log "STEP" "4/7 uv telepítése..."
      run_with_progress "uv telepítés" "curl astral.sh/uv | sh..." \
        su - "$_REAL_USER" -c "curl -LsSf ${URLS[uv_install]} | sh" \
        && ((OK++)) || ((FAIL++))
      export PATH="$_REAL_HOME/.local/bin:$PATH"
    fi
  fi

  if command -v "$VENV_UV" &>/dev/null || command -v uv &>/dev/null; then
    UV_INSTALLED_VER=$("$VENV_UV" --version 2>/dev/null || uv --version 2>/dev/null)
    log "OK" "uv: $UV_INSTALLED_VER"
    infra_state_set "INST_UV_VER" "$(echo "$UV_INSTALLED_VER" | grep -oP '[\d.]+' | head -1)"
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 9 — 5/7: VIRTUÁLIS KÖRNYEZET + AI/ML CSOMAG STACK  ██
# =============================================================================

_venv_needs_work=false
[ "${COMP_STATUS[venv]}" != "ok" ]            && _venv_needs_work=true
[ "${COMP_STATUS[fastapi]}" != "ok" ]         && _venv_needs_work=true
[ "${COMP_STATUS[jupyter]}" != "ok" ]         && _venv_needs_work=true
[ "${COMP_STATUS[langchain]}" != "ok" ]       && _venv_needs_work=true
[ "${COMP_STATUS[huggingface_hub]}" != "ok" ] && _venv_needs_work=true
[ "${RUN_MODE:-install}" = "reinstall" ]      && _venv_needs_work=true
[ "${RUN_MODE:-install}" = "update" ]         && _venv_needs_work=true

if $_venv_needs_work; then
  case "${RUN_MODE:-install}" in
    update)    _MODE_DESC="Csomagok frissítése" ;;
    reinstall) _MODE_DESC="Venv újratelepítése" ;;
    *)         _MODE_DESC="Venv + csomagok telepítése" ;;
  esac

  dialog_yesno "5/7 — $_MODE_DESC" "
  Venv: $VENV_DIR | Python: $PY_VER

  Csomag csoportok (62 db):
    API:    FastAPI, uvicorn[standard], pydantic v2, httpx
    LLM:    openai, anthropic, langchain, langgraph
    HF:     transformers, datasets, safetensors, peft, accelerate
    Data:   numpy, pandas, polars, scipy, sklearn, matplotlib
    Dev:    ruff, mypy, pytest, pre-commit, ipython
    Jupyter: jupyterlab 4.x, ipywidgets, ipykernel
    Util:   rich, typer, loguru, tenacity, psutil

  PyTorch külön (6. lépés, ~3 GB)
  Becsült: ~3-8 perc
  Folytatjuk?" 28 || { ((SKIP++)); goto_step_6=false; }

  if [ "${goto_step_6:-true}" = "true" ]; then
    log "STEP" "5/7 AI/ML venv + csomagok..."

    if [ "${RUN_MODE:-install}" = "reinstall" ] && [ -d "$VENV_DIR" ]; then
      rm -rf "$VENV_DIR"; log "INFO" "Reinstall: régi venv törölve"
    fi

    if [ ! -d "$VENV_DIR" ]; then
      mkdir -p "$(dirname "$VENV_DIR")"
      su - "$_REAL_USER" -c \
        "$VENV_UV venv '$VENV_DIR' --python '$PY_BIN'" >> "$LOGFILE_AI" 2>&1
    fi

    ALL_PKGS=(
      "${AI_PKGS_API[@]}" "${AI_PKGS_LLM[@]}" "${AI_PKGS_HF[@]}"
      "${AI_PKGS_DATA[@]}" "${AI_PKGS_DEV[@]}" "${AI_PKGS_JUPYTER[@]}"
      "${AI_PKGS_UTIL[@]}"
    )
    log "INFO" "Összes csomag: ${#ALL_PKGS[@]} db"

    # [BUG 2 FIX] zsh globbing megkerülése: requirements fájl
    # ─────────────────────────────────────────────────────────────────────────
    # MIÉRT: 'su - pipi' login shellként zsh-t indít. A zsh az
    # 'uvicorn[standard]' szögletes zárójelét glob mintaként értelmezi:
    #   zsh:1: no matches found: uvicorn[standard]
    # Következmény: az összes csomag telepítése meghiúsul (exit 1), mert
    # a zsh a parancsot el sem juttatja az uv-hez.
    #
    # MEGOLDÁS: a csomagneveket /tmp/infra_03_requirements.txt fájlba írjuk
    # (soronként egy csomag), és 'uv pip install -r <fájl>' hívjuk.
    # A fájlba írt sorok NEM esnek át shell glob expansion-ön.
    #
    # ELLENŐRZÉS: uvicorn[standard], uvicorn\[standard\], --no-globs
    # mind alternatív megközelítések, de a requirements fájl a legrobusztusabb
    # és legkompatibilisabb módszer (uv docs: supported natively).
    # ─────────────────────────────────────────────────────────────────────────
    printf '%s\n' "${ALL_PKGS[@]}" > "$REQ_FILE"
    log "INFO" "Csomaglista írva: $REQ_FILE (zsh globbing megkerülés)"
    chown "$_REAL_USER:$_REAL_USER" "$REQ_FILE" 2>/dev/null || true

    UV_FLAGS=""
    [ "${RUN_MODE:-install}" = "update" ] && UV_FLAGS="--upgrade"

    su - "$_REAL_USER" -c \
      "$VENV_UV pip install $UV_FLAGS --python '$VENV_PY' -r '$REQ_FILE'" \
      >> "$LOGFILE_AI" 2>&1 &
    UV_PID=$!
    progress_open "AI/ML csomagok" "uv pip install -r requirements (${#ALL_PKGS[@]} db)..."
    i=5
    while kill -0 $UV_PID 2>/dev/null; do
      progress_set "$i" "AI/ML csomagok (~3-8 perc)..."; sleep 2; [ $i -lt 90 ] && ((i+=3))
    done
    progress_close; wait $UV_PID; PKGS_EC=$?

    rm -f "$REQ_FILE"  # cleanup

    if [ $PKGS_EC -ne 0 ]; then
      ((FAIL++))
      log "FAIL" "Csomag telepítés sikertelen (exit $PKGS_EC)"
      dialog_warn "AI/ML csomagok — Hiba" \
        "\n  exit $PKGS_EC\n  Log: $LOGFILE_AI\n\n  Esetleges okok:\n  • Hálózati hiba\n  • Inkompatibilis csomagverzió" 14
    else
      ((OK++))
      log "OK" "AI/ML csomag stack telepítve (${#ALL_PKGS[@]} db)"
    fi

    log "INFO" "JupyterLab kernel regisztráció..."
    su - "$_REAL_USER" -c \
      "JUPYTER_DATA_DIR='$_REAL_HOME/.local/share/jupyter'
       '$VENV_PY' -m ipykernel install \
         --user --name aiml --display-name 'Python 3.12 (AI/ML)'" \
      >> "$LOGFILE_AI" 2>&1
    chown -R "$_REAL_USER:$_REAL_USER" \
      "$_REAL_HOME/.local/share/jupyter" 2>/dev/null || true
    log "OK" "JupyterLab kernel 'Python 3.12 (AI/ML)' regisztrálva"

    chown -R "$_REAL_USER:$_REAL_USER" "$VENV_DIR" 2>/dev/null || true
    chown -R "$_REAL_USER:$_REAL_USER" "$_REAL_HOME/AI-VIBE" 2>/dev/null || true
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 10 — 6/7: PYTORCH  ██
# =============================================================================

_torch_needs_install=false
[ "${COMP_STATUS[torch]}" != "ok" ] && _torch_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _torch_needs_install=true
[ "${RUN_MODE:-install}" = "update" ] && _torch_needs_install=true

if $_torch_needs_install; then
  TORCH_INDEX_URL="https://download.pytorch.org/whl/${PYTORCH_INDEX}"
  TORCH_SIZE_EST="~2.5-3 GB"
  [ "$PYTORCH_INDEX" = "cpu" ] && TORCH_SIZE_EST="~180 MB"

  dialog_yesno "6/7 — PyTorch telepítése" "
  PyTorch 2.x — ${PYTORCH_INDEX}
  URL: $TORCH_INDEX_URL | Méret: $TORCH_SIZE_EST

  $([ "$PYTORCH_INDEX" != "cpu" ] && echo "CUDA ellenőrzés REBOOT UTÁN:
    python -c 'import torch; print(torch.cuda.is_available())'
  Várható: True (most False lehet — normális!)" \
  || echo "CPU-only (iGPU profil).")
  Folytatjuk?" 20 || { ((SKIP++)); goto_step_7=false; }

  if [ "${goto_step_7:-true}" = "true" ]; then
    log "STEP" "6/7 PyTorch: ${PYTORCH_INDEX}"
    UV_FLAGS=""
    [ "${RUN_MODE:-install}" = "update" ] && UV_FLAGS="--upgrade"

    # PyTorch csomagneveiben nincs szögletes zárójel → parancssor argument biztonságos
    su - "$_REAL_USER" -c \
      "$VENV_UV pip install $UV_FLAGS \
        --python '$VENV_PY' $TORCH_PKGS \
        --index-url '$TORCH_INDEX_URL'" \
      >> "$LOGFILE_AI" 2>&1 &
    TORCH_PID=$!
    progress_open "PyTorch ${PYTORCH_INDEX}" "torch + torchvision + torchaudio ($TORCH_SIZE_EST)..."
    i=2
    while kill -0 $TORCH_PID 2>/dev/null; do
      progress_set "$i" "PyTorch letöltése..."; sleep 5; [ $i -lt 88 ] && ((i++))
    done
    progress_close; wait $TORCH_PID; TORCH_EC=$?

    if [ $TORCH_EC -ne 0 ]; then
      ((FAIL++))
      dialog_warn "PyTorch — Hiba" "\n  exit $TORCH_EC\n  Index: $PYTORCH_INDEX\n  Log: $LOGFILE_AI" 12
    else
      TORCH_VER=$("$VENV_PY" -c "import torch; print(torch.__version__)" 2>/dev/null || echo "?")
      ((OK++)); log "OK" "PyTorch: $TORCH_VER ($PYTORCH_INDEX)"
      infra_state_set "INST_TORCH_VER" "$TORCH_VER"
      dialog_msg "✓ PyTorch — Telepítve" "
  ✓  $TORCH_VER (${PYTORCH_INDEX})
  CUDA ellenőrzés REBOOT UTÁN:
    python -c 'import torch; print(torch.cuda.is_available())'" 14
    fi
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 11 — 7/7: PROJEKT TEMPLATE  ██
# =============================================================================

_tmpl_needs_install=false
[ "${COMP_STATUS[template]}" != "ok" ] && _tmpl_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _tmpl_needs_install=true
[ "${RUN_MODE:-install}" = "update" ] && _tmpl_needs_install=true

if $_tmpl_needs_install; then
  dialog_yesno "7/7 — Projekt template" "
  Hely: $TEMPLATE_DIR/
  Tartalom: pyproject.toml | .env.example | .cursorrules
            .vscode/settings.json | .pre-commit-config.yaml
  Folytatjuk?" 14 || { ((SKIP++)); goto_end=false; }

  if [ "${goto_end:-true}" = "true" ]; then
    mkdir -p "$TEMPLATE_DIR/.vscode"
    chown -R "$_REAL_USER:$_REAL_USER" "$_REAL_HOME/templates" 2>/dev/null || true

    cat > "$TEMPLATE_DIR/pyproject.toml" << 'TOML_EOF'
[project]
name = "ai-project"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = []

[tool.black]
line-length = 100
target-version = ["py312"]

[tool.ruff]
line-length = 100
target-version = "py312"

[tool.ruff.lint]
select = ["E", "F", "I", "N", "UP", "B", "ANN", "ASYNC"]
ignore = ["ANN101", "ANN102", "B008"]

[tool.ruff.lint.isort]
known-first-party = ["src"]

[tool.isort]
profile = "black"
line_length = 100

[tool.mypy]
python_version = "3.12"
strict = true
ignore_missing_imports = true

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
addopts = ["-v", "--tb=short", "--cov=src", "--cov-report=term-missing"]
TOML_EOF

    cat > "$TEMPLATE_DIR/.env.example" << 'ENV_EOF'
ANTHROPIC_API_KEY=sk-ant-api03-...
OPENAI_API_KEY=sk-proj-...
HUGGINGFACE_TOKEN=hf_...
OLLAMA_HOST=http://localhost:11434
CUDA_HOME=/usr/local/cuda
CUDA_VISIBLE_DEVICES=0
LOG_LEVEL=INFO
ENV_EOF

    cat > "$TEMPLATE_DIR/.cursorrules" << CURSOR_EOF
# .cursorrules — AI pair programming v6.5
# Stack: Python 3.12 + PyTorch ${PYTORCH_INDEX} + LangChain + HuggingFace + FastAPI

You are an expert Python developer specializing in AI/ML engineering.

## Stack
- PyTorch 2.x (CUDA ${PYTORCH_INDEX}), FastAPI + Pydantic v2, LangChain/LangGraph
- HuggingFace (transformers, datasets, safetensors), uv package manager

## Rules
- Type hints everywhere, Google-style docstrings, 100 char line length
- pathlib.Path not os.path, loguru not print, no bare except
- bfloat16 on Blackwell/Ampere, safetensors (not pickle) for models
- API keys from python-dotenv only, httpx for async HTTP
CURSOR_EOF

    cat > "$TEMPLATE_DIR/.vscode/settings.json" << VSCODE_EOF
{
  "python.defaultInterpreterPath": "${_REAL_HOME}/AI-VIBE/venvs/ai/bin/python",
  "editor.formatOnSave": true,
  "editor.rulers": [100],
  "[python]": {
    "editor.defaultFormatter": "ms-python.black-formatter",
    "editor.codeActionsOnSave": { "source.organizeImports": "explicit" }
  },
  "ruff.lint.args": ["--line-length=100"],
  "black-formatter.args": ["--line-length", "100"],
  "mypy-type-checker.args": ["--strict", "--ignore-missing-imports"],
  "python.testing.pytestEnabled": true
}
VSCODE_EOF

    cat > "$TEMPLATE_DIR/.pre-commit-config.yaml" << 'PRECOMMIT_EOF'
repos:
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.4.10
    hooks:
      - id: ruff
        args: ["--fix"]
      - id: ruff-format
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-added-large-files
        args: ["--maxkb=10240"]
PRECOMMIT_EOF

    chown -R "$_REAL_USER:$_REAL_USER" "$TEMPLATE_DIR" 2>/dev/null || true
    ((OK++)); log "OK" "Projekt template létrehozva: $TEMPLATE_DIR"
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 12 — LEZÁRÁS: STATE + LOG + ÖSSZEFOGLALÁS  ██
# =============================================================================

# ── INFRA state frissítés ─────────────────────────────────────────────────────
# [BUG 3 FIX] MOD_03_DONE — 01a v6.11 BUG 4 FIX mintájára:
# PROBLÉMA: v6.4-ben 'if FAIL==0 OR OK>0' feltétel → FAIL=2 esetén is true!
#   Következmény: 02/06 szálak azt hitték a stack kész, de FastAPI/LangChain/
#   HuggingFace/Jupyter hiányzott (a zsh globbing miatt nem települt).
#
# FIX: MOD_03_DONE=true CSAK HA FAIL==0 (01a v6.11 BUG 4 FIX azonos logika)
#   FAIL>0 esetén: MOD_03_DONE="" törlés — ha volt korábbi true, reszeteljük.
#   Ez biztosítja hogy a következő futás újra megpróbálja a sikertelen lépéseket.
#   Kivétel: ha OK>0 de FAIL>0 (részleges siker) → szintén nem írunk true-t!
if [ "${FAIL:-0}" -eq 0 ]; then
  infra_state_set "MOD_03_DONE" "true"
  log "STATE" "MOD_03_DONE=true — 02_local_ai_stack.sh futtatható"
else
  log "WARN" "FAIL=${FAIL} → MOD_03_DONE NEM kerül true-ra (01a BUG 4 FIX minta)"
  log "WARN" "Következő futás újra megpróbálja a hibás lépéseket"
  infra_state_set "MOD_03_DONE" ""   # törlés, ha volt korábbi true (pl. reinstall előző sikeres futásból)
fi

# [NEW] INST_03_TS csoportos timestamp — 01a/01b konzisztencia
# Az infra_state_show() "── [03 — Python/AI-ML] ──" szekciója akkor mutat
# timestampot, ha INST_03_TS jelen van (infra_state_group_ts() írja).
# A 01a INST_01A_TS-t és a 01b INST_01B_TS-t ír — a 03-nak is kell.
if [ "${FAIL:-0}" -eq 0 ] || [ "${OK:-0}" -gt 0 ]; then
  infra_state_group_ts "INST_03"
  log "STATE" "INST_03_TS írva — state szekció timestamp"
fi

# ── Végeredmény összesítő ─────────────────────────────────────────────────────
show_result "$OK" "$SKIP" "$FAIL"

# =============================================================================
# ██  SZEKCIÓ 13 — POST-INSTALL COMP STATE RE-CHECK  ██
# =============================================================================

if [[ "${RUN_MODE:-install}" =~ ^(install|update|fix|reinstall)$ ]]; then
  log "COMP" "Post-install re-check (mód: $RUN_MODE)..."

  _build_deps_ok=true
  for pkg in liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev \
             libbz2-dev libffi-dev libssl-dev; do
    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || { _build_deps_ok=false; break; }
  done
  $_build_deps_ok && COMP_STATUS[build_deps]="ok" || COMP_STATUS[build_deps]="missing"

  if command -v pyenv &>/dev/null || [ -x "$PYENV_ROOT/bin/pyenv" ]; then
    COMP_STATUS[pyenv]="ok"
    COMP_VER[pyenv]="$(pyenv --version 2>/dev/null | grep -oP '[\d.]+' | head -1)"
  else
    COMP_STATUS[pyenv]="missing"; COMP_VER[pyenv]=""
  fi

  comp_check_python "$PY_VER" "$PYENV_ROOT"

  if [ -x "$PY_BIN" ] && "$PY_BIN" -c "import lzma, bz2, readline" 2>/dev/null; then
    COMP_STATUS[lzma_ok]="ok"
  else
    COMP_STATUS[lzma_ok]="missing"
  fi

  comp_check_uv "${MIN_VER[uv]}" "$VENV_UV"

  if [ -d "$VENV_DIR" ] && [ -x "$VENV_PY" ]; then
    COMP_STATUS[venv]="ok"
  else
    COMP_STATUS[venv]="missing"
  fi

  comp_check_torch "" "$VENV_PY"

  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import fastapi" 2>/dev/null; then
    COMP_STATUS[fastapi]="ok"
  else
    COMP_STATUS[fastapi]="missing"
  fi

  if [ -x "$VENV_DIR/bin/jupyter" ]; then
    COMP_STATUS[jupyter]="ok"
    COMP_VER[jupyter]="$("$VENV_DIR/bin/jupyter" --version 2>/dev/null | head -1)"
  else
    COMP_STATUS[jupyter]="missing"; COMP_VER[jupyter]=""
  fi

  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import langchain" 2>/dev/null; then
    COMP_STATUS[langchain]="ok"
  else
    COMP_STATUS[langchain]="missing"
  fi

  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import huggingface_hub" 2>/dev/null; then
    COMP_STATUS[huggingface_hub]="ok"
  else
    COMP_STATUS[huggingface_hub]="missing"
  fi

  if [ -f "$TEMPLATE_DIR/pyproject.toml" ] && [ -f "$TEMPLATE_DIR/.cursorrules" ]; then
    COMP_STATUS[template]="ok"
  else
    COMP_STATUS[template]="missing"
  fi

  comp_save_state "$INFRA_NUM"
  log "COMP" "Post-install COMP state mentve: COMP_03_*"
fi

# ── Log chmod végső ───────────────────────────────────────────────────────────
chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
log "OK" "Log jogosultságok: 644 / ${_REAL_USER}"

# ── Összefoglalás ─────────────────────────────────────────────────────────────
dialog_msg "[$INFRA_NAME] — Következő lépések" "
  ── Venv aktiválás ─────────────────────────────────────
  source $VENV_DIR/bin/activate

  ── PyTorch GPU ellenőrzés (REBOOT UTÁN!) ──────────────
  python -c 'import torch; print(torch.cuda.is_available())'

  ── JupyterLab ─────────────────────────────────────────
  jupyter lab --no-browser --port 8888

  ── Teszt ──────────────────────────────────────────────
  python -c 'import langchain, fastapi, transformers; print(\"OK\")'

  ── PyTorch index: $PYTORCH_INDEX | CUDA: $CUDA_VER
  ── Log: $LOGFILE_AI" 26

log "MASTER" "INFRA 03 befejezve: OK=${OK} SKIP=${SKIP} FAIL=${FAIL}"
