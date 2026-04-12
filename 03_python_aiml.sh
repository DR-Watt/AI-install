#!/bin/bash
# =============================================================================
# 03_python_aiml.sh — Python 3.12 + PyTorch + AI/ML Stack v6.4
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
# Változtatások v6.4 (CORE v6.5 szinkronizáció + bugfix)
# ────────────────────────────────────────────────────────
#   [FIX] PYTORCH_INDEX=cpu tévesen — FEAT_GPU_ACCEL az új state formátumban
#     nincs FEAT_GPU_ACCEL kulcs a [01a] szekciós state-ben →
#     infra_state_get visszad "false" → cpu index → de van NVIDIA GPU!
#     Javítás: hw_has_nvidia() használata a state kulcs helyett
#     hw_has_nvidia() az exportált HW_PROFILE alapján dönt (master futtatja)
#   [NEW] detect_run_mode integráció — 02 v6.5 mintájára
#     Ha minden komponens OK és RUN_MODE=install → detect_run_mode() felajánlja
#     a skip/update/reinstall opciókat (a képernyőkép ezt mutatja)
#     skip mód: MOD_03_DONE=true írás + azonnali kilépés
#   [NEW] Log chmod — 02 v6.5 mintájára
#     sudo alatt root:root log → chown + chmod 644 azonnal és futás végén
#   [FIX] 03 infra_require "01b" — manuális bypass dialóg csak install módban
#     check és fix módban a lib már kezeli (nem blokkol), nincs dupla dialóg
#
# Változtatások v6.3 (COMP STATE implementáció)
# ─────────────────────────────────────────────
#   - COMP STATE rendszer: comp_save_state/comp_load_state/comp_state_exists
#   - check mód: comp_save_state a felmérés VÉGÉN (pre=post állapot)
#   - install/update/fix/reinstall: post-install re-check + comp_save_state
#
# Változtatások v6.2 (v6.4.2 CORE rendszer integráció)
# ─────────────────────────────────────────────────────
#   - fix mód kezelése; infra_require "01b" lowercase; cuda_pytorch_index()
#
# Dokumentáció referenciák
# ────────────────────────
#   Python 3.12:   https://docs.python.org/3.12/
#   pyenv:         https://github.com/pyenv/pyenv#installation
#   uv:            https://docs.astral.sh/uv/
#   PyTorch:       https://docs.pytorch.org/docs/stable/index.html
#   LangChain:     https://python.langchain.com/docs/get_started/
#   HuggingFace:   https://huggingface.co/docs/transformers/
#   safetensors:   https://github.com/huggingface/safetensors
# =============================================================================

# ── Script könyvtár (szimlink-biztos) ─────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Közös függvénytár betöltése ───────────────────────────────────────────────
# v6.4: 00_lib.sh master loader — betölti a lib/ alkönyvtár komponenseit:
#   lib/00_lib_core.sh   — log, sudo, user, utility
#   lib/00_lib_hw.sh     — hw_detect, hw_show, hw_has_nvidia
#   lib/00_lib_ui.sh     — dialog_*, progress_*
#   lib/00_lib_state.sh  — infra_state_*, infra_require, detect_run_mode
#   lib/00_lib_comp.sh   — comp_check_*, version_ok, cuda_pytorch_index,
#                          comp_save_state, comp_load_state, comp_state_exists
#   lib/00_lib_apt.sh    — apt_install_*, run_with_progress
LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" \
  || { echo "HIBA: 00_lib.sh hiányzik! Elvárt helye: $LIB"; exit 1; }

# =============================================================================
# ██  SZEKCIÓ 1 — KONFIGURÁCIÓ  ── minden érték itt, kódban nincs magic string  ██
# =============================================================================

# ── Modul azonosítók ──────────────────────────────────────────────────────────
INFRA_NUM="03"
INFRA_NAME="Python 3.12 + PyTorch + AI/ML Stack"
INFRA_HW_REQ=""   # Hardverfüggetlen — CPU-only PyTorch is telepíthető

# ── Python verzió ─────────────────────────────────────────────────────────────
# Forrás: https://docs.python.org/3.12/ — stable release
PY_VER="3.12.9"

# ── pyenv fordítási konfiguráció ──────────────────────────────────────────────
# --enable-optimizations: PGO + LTO, ~10-15% gyorsabb interpreter
# Forrás: https://docs.python.org/3.12/using/configure.html#performance-options
PY_CONFIGURE_OPTS="--enable-optimizations"

# ── Minimum elfogadható verziók ───────────────────────────────────────────────
declare -A MIN_VER=(
  [python]="3.12.0"    # pyenv által fordított Python
  [uv]="0.4.0"         # Astral uv — Rust alapú csomagkezelő
)

# ── APT fordítási és rendszer függőségek ──────────────────────────────────────
# KRITIKUS: liblzma-dev NÉLKÜL a Python lzma/xz modulja NEM FORDUL!
# PyTorch modellek .pt fájljai xz tömörítést használnak → KÖTELEZŐ.
# Forrás: https://github.com/pyenv/pyenv/wiki#suggested-build-environment
declare -A PKGS=(
  [python_build]="liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev
                  libbz2-dev zlib1g-dev libffi-dev tk-dev uuid-dev
                  libncurses-dev xz-utils libxml2-dev libxmlsec1-dev
                  libssl-dev libnss3-dev"
)

# ── URL-ek ────────────────────────────────────────────────────────────────────
declare -A URLS=(
  # Forrás: https://github.com/pyenv/pyenv#automatic-installer
  [pyenv_install]="https://pyenv.run"
  # Forrás: https://docs.astral.sh/uv/getting-started/installation/
  [uv_install]="https://astral.sh/uv/install.sh"
)

# ── PyTorch csomagok ──────────────────────────────────────────────────────────
# Index URL az infra state PYTORCH_INDEX-ből (cu126|cu128|cpu)
# Forrás: https://download.pytorch.org/whl/
TORCH_PKGS="torch torchvision torchaudio"

# ── AI/ML Python csomagok — 7 funkcionális csoport ───────────────────────────
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

# ── Komponens ellenőrző specifikációk ─────────────────────────────────────────
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

# ── Könyvtár útvonalak ────────────────────────────────────────────────────────
PYENV_ROOT="$_REAL_HOME/.pyenv"
VENV_DIR="$_REAL_HOME/AI-VIBE/venvs/ai"
VENV_PY="$VENV_DIR/bin/python"
VENV_UV="$_REAL_HOME/.local/bin/uv"
PY_BIN="$PYENV_ROOT/versions/$PY_VER/bin/python3"
TEMPLATE_DIR="$_REAL_HOME/templates/python-ai"
LOCK_FILE="/tmp/infra_03_python.lock"

# =============================================================================
# ██  SZEKCIÓ 2 — INICIALIZÁLÁS  ██
# =============================================================================

# ── Log fájlok beállítása ─────────────────────────────────────────────────────
LOGFILE_AI="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_03_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_03_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="$LOGFILE_AI"
log_init

# ── Log chmod — sudo alatt root:root log, azonnal javítjuk ───────────────────
# [v6.4] 02 v6.5 mintájára: sudo futtatáskor a log fájlok root:root tulajdonosú
# lennének → nem húzható Claude-ba elemzésre. Megelőzés: chown + chmod azonnal.
chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true

# ── Párhuzamos futás megakadályozása ─────────────────────────────────────────
check_lock "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT   # cleanup bármely kilépési okra

# ── INFRA state betöltés ──────────────────────────────────────────────────────
# Az 01a modul mentette: INST_CUDA_VER, PYTORCH_INDEX
# MEGJEGYZÉS: FEAT_GPU_ACCEL az új state formátumban nincs [01a] szekciós kulcsként
# → infra_state_get visszaadna "false" alapértéket → tévesen cpu indexet kapnánk.
# A GPU elérhetőséget HW_PROFILE alapján döntjük el (hw_detect() exportálja).
CUDA_VER=$(infra_state_get "INST_CUDA_VER" "12.6")
PYTORCH_INDEX=$(infra_state_get "PYTORCH_INDEX" "cu126")
HW_GPU_ARCH_ST=$(infra_state_get "HW_GPU_ARCH" "igpu")

# ── [FIX v6.4] PYTORCH_INDEX meghatározása — hw_has_nvidia() alapján ─────────
# HIBA v6.3: FEAT_GPU_ACCEL state kulcs az új szekciós formátumban nem elérhető
#   → infra_state_get visszaad "false" → PYTORCH_INDEX=cpu → GPU van de cpu index!
# JAVÍTÁS: hw_has_nvidia() az exportált HW_PROFILE-t nézi (master beállítja):
#   desktop-rtx / desktop-rtx-old / notebook-rtx → true → cu12x index marad
#   notebook-igpu / desktop-igpu → false → cpu index
if ! hw_has_nvidia; then
  # CPU-only profil — iGPU vagy nincs NVIDIA
  PYTORCH_INDEX="cpu"
  log "STATE" "CPU-only profil: PYTORCH_INDEX=cpu (hw_has_nvidia=false, profil: ${HW_PROFILE})"
else
  # GPU elérhető — cuda_pytorch_index() validálja az indexet
  # CUDA 13.x → cu128 fallback (ABI kompatibilis)
  _expected_idx="$(cuda_pytorch_index "$CUDA_VER" 2>/dev/null || echo "")"
  if [ -n "$_expected_idx" ] && [ "$PYTORCH_INDEX" != "$_expected_idx" ]; then
    log "WARN" "PYTORCH_INDEX mismatch: state=$PYTORCH_INDEX, várható=$_expected_idx (CUDA $CUDA_VER)"
    log "WARN" "Automatikus korrekció: PYTORCH_INDEX=$_expected_idx"
    PYTORCH_INDEX="$_expected_idx"
    infra_state_set "PYTORCH_INDEX" "$_expected_idx"
  fi
fi

log "STATE" "Betöltve: CUDA=$CUDA_VER | PyTorch index=$PYTORCH_INDEX | GPU arch=$HW_GPU_ARCH_ST | profil=$HW_PROFILE"

# ── INFRA state inicializálás ─────────────────────────────────────────────────
infra_state_init

# ── Hardver kompatibilitás ────────────────────────────────────────────────────
# INFRA_HW_REQ="" → minden hardveren fut (CPU-only PyTorch is telepíthető)
infra_compatible "$INFRA_HW_REQ" || {
  dialog_warn "Hardver inkompatibilis" \
    "\n  HW_REQ: $INFRA_HW_REQ | Profil: $HW_PROFILE\n  Modul kihagyva." 10
  exit 2
}

# ── Függőség ellenőrzés ───────────────────────────────────────────────────────
# 01b (Oh My Zsh, shell konfig) előfeltétele — zshrc-ben van pyenv init.
# infra_require() a lib-ben: check és fix módban NEM blokkol (csak logol).
# reinstall módban: bypass — user tudatos döntése az újratelepítés.
if [[ "${RUN_MODE:-install}" != "reinstall" ]]; then
  infra_require "01b" "User Environment (01b_post_reboot.sh)" || {
    # install módban: bypass lehetősége — check/fix módban ide nem jutunk el
    # (a lib infra_require() már return 0-val tért vissza)
    dialog_yesno "Függőség figyelmeztető" \
      "\n  MOD_01B_DONE nincs beállítva.\n\n  A 01b (Zsh, shell setup) fut le ELŐTTE.\n\n  Ennek ellenére folytatjuk?" 14 || exit 1
    log "WARN" "01b függőség manuálisan bypass-olva — user döntése"
  }
fi

# ── PATH előkészítés ──────────────────────────────────────────────────────────
export PYENV_ROOT
export PATH="$PYENV_ROOT/bin:$_REAL_HOME/.local/bin:$PATH"
[ -d "$PYENV_ROOT/bin" ] && eval "$(pyenv init -)" 2>/dev/null || true

# =============================================================================
# ██  SZEKCIÓ 3 — KOMPONENS FELMÉRÉS  ██
# =============================================================================
#
# COMP STATE LOGIKA (mód-tudatos gyorsítótár):
#   COMP_USE_CACHED=true + comp_state_exists → cached load (nincs friss check)
#   Egyéb esetben: friss check futtatása
#
#   check mód     → comp_save_state a felmérés VÉGÉN (semmi sem változik)
#   install/update/fix/reinstall → comp_save_state a script VÉGÉN,
#     post-install re-check UTÁN (valódi telepítés utáni állapot)

log "COMP" "━━━ Komponens állapot felmérés ━━━"

if [ "${COMP_USE_CACHED:-false}" = "true" ] && comp_state_exists "$INFRA_NUM"; then
  # ── Mentett eredmény betöltése ─────────────────────────────────────────────
  comp_load_state "$INFRA_NUM"
  _state_age=$(comp_state_age_hours "$INFRA_NUM")
  log "COMP" "Mentett check eredmény betöltve — INFRA $INFRA_NUM (${_state_age} óra)"
else
  # ── Friss komponens ellenőrzés ─────────────────────────────────────────────

  # 1. Fordítási függőségek
  _build_deps_ok=true
  for pkg in liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev \
             libbz2-dev libffi-dev libssl-dev; do
    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || { _build_deps_ok=false; break; }
  done
  $_build_deps_ok \
    && COMP_STATUS[build_deps]="ok" \
    || COMP_STATUS[build_deps]="missing"
  log "COMP" "  build_deps: ${COMP_STATUS[build_deps]}"

  # 2. pyenv — explicit PATH (sudo alatt ~/.pyenv/bin nem biztos PATH-ban)
  if command -v pyenv &>/dev/null || [ -x "$PYENV_ROOT/bin/pyenv" ]; then
    COMP_STATUS[pyenv]="ok"
    COMP_VER[pyenv]="$(pyenv --version 2>/dev/null | grep -oP '[\d.]+' | head -1)"
  else
    COMP_STATUS[pyenv]="missing"
  fi
  log "COMP" "  pyenv: ${COMP_STATUS[pyenv]} ${COMP_VER[pyenv]:-}"

  # 3. Python 3.12.x — pyenv által fordított bináris
  comp_check_python "$PY_VER" "$PYENV_ROOT"
  log "COMP" "  python: ${COMP_STATUS[python]:-missing} ${COMP_VER[python]:-}"

  # 4. lzma modul — KRITIKUS! PyTorch .pt xz tömörítés
  if [ -x "$PY_BIN" ] && "$PY_BIN" -c "import lzma, bz2, readline" 2>/dev/null; then
    COMP_STATUS[lzma_ok]="ok"
  else
    COMP_STATUS[lzma_ok]="missing"
  fi
  log "COMP" "  lzma_ok: ${COMP_STATUS[lzma_ok]}"

  # 5. uv — Astral csomagkezelő
  comp_check_uv "${MIN_VER[uv]}" "$VENV_UV"
  log "COMP" "  uv: ${COMP_STATUS[uv]:-missing} ${COMP_VER[uv]:-}"

  # 6. AI/ML venv
  if [ -d "$VENV_DIR" ] && [ -x "$VENV_PY" ]; then
    COMP_STATUS[venv]="ok"
  else
    COMP_STATUS[venv]="missing"
  fi
  log "COMP" "  venv: ${COMP_STATUS[venv]}"

  # 7. PyTorch — import + CUDA elérhetőség
  # comp_check_torch: lib/00_lib_comp.sh — REBOOT előtt cuda=False normális!
  comp_check_torch "" "$VENV_PY"
  log "COMP" "  torch: ${COMP_STATUS[torch]:-missing} ${COMP_VER[torch]:-}"

  # 8. FastAPI
  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import fastapi" 2>/dev/null; then
    COMP_STATUS[fastapi]="ok"
  else
    COMP_STATUS[fastapi]="missing"
  fi
  log "COMP" "  fastapi: ${COMP_STATUS[fastapi]}"

  # 9. JupyterLab
  if [ -x "$VENV_DIR/bin/jupyter" ]; then
    COMP_STATUS[jupyter]="ok"
    COMP_VER[jupyter]="$("$VENV_DIR/bin/jupyter" --version 2>/dev/null | head -1)"
  else
    COMP_STATUS[jupyter]="missing"
  fi
  log "COMP" "  jupyter: ${COMP_STATUS[jupyter]}"

  # 10. LangChain
  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import langchain" 2>/dev/null; then
    COMP_STATUS[langchain]="ok"
  else
    COMP_STATUS[langchain]="missing"
  fi
  log "COMP" "  langchain: ${COMP_STATUS[langchain]}"

  # 11. HuggingFace Hub
  if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import huggingface_hub" 2>/dev/null; then
    COMP_STATUS[huggingface_hub]="ok"
  else
    COMP_STATUS[huggingface_hub]="missing"
  fi
  log "COMP" "  huggingface_hub: ${COMP_STATUS[huggingface_hub]}"

  # 12. Projekt template
  if [ -f "$TEMPLATE_DIR/pyproject.toml" ] && \
     [ -f "$TEMPLATE_DIR/.cursorrules" ]; then
    COMP_STATUS[template]="ok"
  else
    COMP_STATUS[template]="missing"
  fi
  log "COMP" "  template: ${COMP_STATUS[template]}"

  # ── COMP STATE mentés — CHECK módban az elején ─────────────────────────────
  if [ "${RUN_MODE:-install}" = "check" ]; then
    comp_save_state "$INFRA_NUM"
    log "COMP" "Check mód: COMP state mentve (INFRA $INFRA_NUM)"
  fi
fi

# ── Összesítés ────────────────────────────────────────────────────────────────
MISSING=0
STATUS_LINES=""
for spec in "${COMP_SPECS[@]}"; do
  IFS='|' read -r label key min_v <<< "$spec"
  st="${COMP_STATUS[$key]:-missing}"
  ver="${COMP_VER[$key]:-}"
  if [ "$st" = "missing" ]; then
    ((MISSING++))
    STATUS_LINES+="  ✗  $label\n"
    log "COMP" "  ✗  $label — hiányzik"
  elif [ "$st" = "old" ]; then
    ((MISSING++))
    STATUS_LINES+="  ⚠  $label — $ver (elavult, min: $min_v)\n"
    log "COMP" "  ⚠  $label — $ver elavult"
  else
    STATUS_LINES+="  ✓  $label — $ver\n"
    log "COMP" "  ✓  $label — $ver"
  fi
done
log "COMP" "━━━ Összesítés: ${MISSING} hiányzó/elavult ━━━"

# Komponens kulcsok tömbje — detect_run_mode() nameref-ként kapja
declare -a COMP_KEYS=(build_deps pyenv python lzma_ok uv venv torch fastapi jupyter langchain huggingface_hub template)

# =============================================================================
# ██  SZEKCIÓ 4 — INFRA FEJLÉC + FUTTATÁSI MÓD DÖNTÉS  ██
# =============================================================================

# ── Infra header logba ────────────────────────────────────────────────────────
log_infra_header "   • pyenv — Python verziókezelő
   • Python ${PY_VER} — forrásból (PGO optimalizálás, ~8-12 perc)
   • uv — Rust-alapú csomagkezelő (~100x gyorsabb mint pip)
   • AI/ML venv + teljes stack:
       PyTorch ${PYTORCH_INDEX} + LangChain + HuggingFace + FastAPI + JupyterLab
   • Fejlesztői eszközök: ruff, mypy, pytest, pre-commit
   • Projekt template: pyproject.toml, .cursorrules, .vscode/settings.json"
log_install_paths "   $PYENV_ROOT            — pyenv + Python ${PY_VER}
   $_REAL_HOME/.local/bin/uv    — uv csomagkezelő
   $VENV_DIR — AI/ML venv
   $TEMPLATE_DIR — projekt template"

# ── check mód: EARLY EXIT ────────────────────────────────────────────────────
# check módban SEMMI sem változik — azonnali kilépés a státusz megjelenítés után.
# A COMP state mentés már megtörtént a felmérés végén (feljebb).
if [ "${RUN_MODE:-install}" = "check" ]; then
  log "MODE" "check mód — read-only, csak státusz"
  if [ "$MISSING" -gt 0 ]; then
    dialog_warn "[Ellenőrző] $INFRA_NAME" \
      "\n  Komponens állapot:\n\n$(printf '%b' "$STATUS_LINES")
  PyTorch index: $PYTORCH_INDEX | CUDA: $CUDA_VER
  Python venv:   $VENV_DIR
  Log:           $LOGFILE_AI

  $MISSING hiányzó komponens — telepítéshez install/fix módot válassz." 32
  else
    dialog_msg "[Ellenőrző] $INFRA_NAME ✓" \
      "\n  Minden komponens telepítve és elérhető.\n\n$(printf '%b' "$STATUS_LINES")
  PyTorch index: $PYTORCH_INDEX | CUDA: $CUDA_VER
  Log: $LOGFILE_AI" 28
  fi
  log "MODE" "check mód befejezve"
  exit 0
fi

# ── reinstall mód: minden komponens kényszer-újratelepítése ──────────────────
if [ "${RUN_MODE:-install}" = "reinstall" ]; then
  for spec in "${COMP_SPECS[@]}"; do
    IFS='|' read -r label key _ <<< "$spec"
    COMP_STATUS["$key"]="missing"
  done
  MISSING=${#COMP_SPECS[@]}
  log "MODE" "Reinstall mód: minden komponens újratelepítve ($MISSING db)"
fi

# ── [NEW v6.4] detect_run_mode — 02 v6.5 mintájára ──────────────────────────
# Ha minden komponens OK és RUN_MODE=install → felajánlja a skip/update/reinstall
# opciókat (lásd screenshot: "Minden komponens megvan" dialóg).
# fix és reinstall módban nem hívjuk meg — azok mindig aktívan futnak.
if [ "$MISSING" -eq 0 ] && \
   [ "${RUN_MODE:-install}" != "fix" ] && \
   [ "${RUN_MODE:-install}" != "reinstall" ]; then
  detect_run_mode COMP_KEYS   # módosítja RUN_MODE: skip | update | reinstall
  log "MODE" "detect_run_mode eredmény: RUN_MODE=$RUN_MODE"
fi

# ── Skip mód: minden naprakész, kilépünk ─────────────────────────────────────
if [ "${RUN_MODE:-install}" = "skip" ]; then
  dialog_msg "[03] ✓ Minden naprakész" \
    "\n$(printf '%b' "$STATUS_LINES")\n  Semmi sem változik.\n  MOD_03_DONE state írva." 28
  infra_state_set "MOD_03_DONE" "true"
  # Log jogosultság rendezés
  chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
  chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
  exit 0
fi

# ── Mód felirat ───────────────────────────────────────────────────────────────
case "${RUN_MODE:-install}" in
  update)    _mode_label="Frissítés" ;;
  reinstall) _mode_label="Újratelepítés" ;;
  fix)       _mode_label="Javítás" ;;
  *)         _mode_label="Telepítés" ;;
esac

# ── Telepítési terv megerősítése ──────────────────────────────────────────────
dialog_yesno "[$_mode_label] — $INFRA_NAME" \
  "\n  Komponensek:\n$(printf '%b' "$STATUS_LINES")
  PyTorch index: $PYTORCH_INDEX (CUDA $CUDA_VER)
  Python:        $PY_VER (pyenv, forrásból fordítva)
  Venv:          $VENV_DIR

  A $_mode_label elkezdéséhez nyomj Igent." 30 || exit 0

OK=0; SKIP=0; FAIL=0

# =============================================================================
# ██  SZEKCIÓ 5 — 1. FORDÍTÁSI FÜGGŐSÉGEK  ██
# =============================================================================

if [ "${COMP_STATUS[build_deps]}" != "ok" ] || \
   [ "${RUN_MODE:-install}" = "reinstall" ]; then

  dialog_yesno "1/7 — Fordítási függőségek" "
  A pyenv Python-t FORRÁSBÓL FORDÍTJA.
  Szükséges csomagok:

    liblzma-dev     — ⚠ KRITIKUS: xz/lzma (PyTorch modellek!)
    libgdbm-dev     — dbm adatbázis modul
    libreadline-dev — readline (Python REPL)
    libsqlite3-dev  — sqlite3 (pandas, sqlmodel)
    libbz2-dev      — bz2 tömörítés
    zlib1g-dev      — zlib
    libffi-dev      — ctypes, cffi
    libssl-dev      — ssl (https, Anthropic API)
    tk-dev          — tkinter (matplotlib)
    + egyéb fordítási könyvtárak

  Ha ezek HIÁNYOZNAK a fordításkor:
    • lzma modul NEM LESZ ELÉRHETŐ
    • PyTorch checkpointok NEM OLVASHATÓK!

  sudo szükséges ehhez a lépéshez.
  Folytatjuk?" 28 || { ((SKIP++)); goto_step_2=false; }

  if [ "${goto_step_2:-true}" = "true" ]; then
    log "STEP" "1/7 Fordítási függőségek telepítése..."
    # shellcheck disable=SC2086
    apt_install_progress "Python fordítási függőségek" \
      "Python build deps telepítése (sudo)..." \
      ${PKGS[python_build]} \
      && ((OK++)) \
      || { ((FAIL++)); log "FAIL" "Fordítási függőségek telepítése sikertelen"; }
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 6 — 2. PYENV — PYTHON VERZIÓKEZELŐ  ██
# =============================================================================

_pyenv_needs_install=false
[ "${COMP_STATUS[pyenv]}" != "ok" ] && _pyenv_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _pyenv_needs_install=true

if $_pyenv_needs_install || [ "${RUN_MODE:-install}" = "update" ]; then

  if [ "${RUN_MODE:-install}" = "update" ] && [ "${COMP_STATUS[pyenv]}" = "ok" ]; then
    if dialog_yesno "2/7 — pyenv frissítés" \
      "\n  pyenv frissítése a legújabb verzióra.\n  Jelenlegi: ${COMP_VER[pyenv]:-ismeretlen}\n\n  Folytatjuk?" 12; then
      run_with_progress "pyenv frissítés" "pyenv update..." \
        su - "$_REAL_USER" -c "pyenv update" \
        && ((OK++)) || ((FAIL++))
    else
      ((SKIP++))
    fi
  elif $_pyenv_needs_install; then
    dialog_yesno "2/7 — pyenv telepítése" "
  pyenv: Python verziókezelő
  Telepítési hely: ~/.pyenv
  Inicializálás: ~/.zshrc + ~/.bashrc + ~/.profile
  Forrás: https://pyenv.run (GitHub/pyenv/pyenv)
  Folytatjuk?" 14 || { ((SKIP++)); goto_step_3=false; }

    if [ "${goto_step_3:-true}" = "true" ]; then
      log "STEP" "2/7 pyenv telepítése..."
      if [ ! -d "$PYENV_ROOT" ]; then
        run_with_progress "pyenv telepítés" "curl pyenv.run | bash..." \
          su - "$_REAL_USER" -c "curl -fsSL ${URLS[pyenv_install]} | bash" \
          && ((OK++)) || ((FAIL++))
      else
        log "INFO" "pyenv könyvtár már létezik: $PYENV_ROOT — frissítés..."
        run_with_progress "pyenv frissítés" "pyenv update..." \
          su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv update" \
          && ((OK++)) || ((FAIL++))
      fi

      # Shell inicializáció (.zshrc, .bashrc, .profile)
      for RC in "$_REAL_HOME/.zshrc" "$_REAL_HOME/.bashrc" "$_REAL_HOME/.profile"; do
        grep -q "PYENV_ROOT" "$RC" 2>/dev/null && continue
        cat >> "$RC" << 'PYENVRC'

# ── pyenv konfiguráció (vibe-coding-infra hozzáadta) ─────────────────────────
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
# ██  SZEKCIÓ 7 — 3. PYTHON 3.12.X FORDÍTÁSA  ██
# =============================================================================
# PGO + LTO: ~10-15% gyorsabb interpreter
# lzma hiba esetén is újrafordítjuk!

NEED_PY=false
[ "${COMP_STATUS[python]}" != "ok" ]   && NEED_PY=true
[ "${COMP_STATUS[lzma_ok]}" != "ok" ]  && NEED_PY=true
[ "${RUN_MODE:-install}" = "reinstall" ] && NEED_PY=true

if $NEED_PY; then
  FORCE_FLAG=""
  [ "${COMP_STATUS[python]}" = "ok" ] && FORCE_FLAG="--force"
  BUILD_MSG="Python ${PY_VER} fordítása forrásból"
  [ -n "$FORCE_FLAG" ] && BUILD_MSG="Python ${PY_VER} ÚJRAFORDÍTÁSA (lzma fix)"

  dialog_yesno "3/7 — $BUILD_MSG" "
  $BUILD_MSG

  Optimalizálás: $PY_CONFIGURE_OPTS (PGO + LTO)
  Fordítási idő: ~8-12 perc

  FONTOS: liblzma-dev az 1. lépésben települt — KÖTELEZŐ!
  Log: $LOGFILE_AI
  Folytatjuk?" 18 || { ((SKIP++)); goto_step_4=false; }

  if [ "${goto_step_4:-true}" = "true" ]; then
    log "STEP" "3/7 Python ${PY_VER} fordítása (PYTHON_CONFIGURE_OPTS='$PY_CONFIGURE_OPTS')..."

    PYTHON_CONFIGURE_OPTS="$PY_CONFIGURE_OPTS" \
      su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv install $FORCE_FLAG $PY_VER" \
      >> "$LOGFILE_AI" 2>&1 &
    PY_PID=$!
    progress_open "Python ${PY_VER} fordítása" \
      "pyenv install $FORCE_FLAG $PY_VER (PGO+LTO)"
    i=2
    while kill -0 $PY_PID 2>/dev/null; do
      progress_set "$i" "Python ${PY_VER} fordítása... (~8-12 perc)"
      sleep 5; [ $i -lt 88 ] && ((i++))
    done
    progress_close
    wait $PY_PID; PY_EC=$?

    if [ $PY_EC -ne 0 ]; then
      ((FAIL++))
      dialog_warn "Python fordítás — HIBA" \
        "\n  Sikertelen (exit $PY_EC)\n  Log: $LOGFILE_AI\n\n  Lehetséges ok: hiányzó fordítási függőség!" 14
    else
      su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv global $PY_VER" >> "$LOGFILE_AI" 2>&1
      if "$PY_BIN" -c "import lzma; import bz2; import readline; import ssl" 2>/dev/null; then
        ((OK++))
        PY_INSTALLED_VER=$("$PY_BIN" --version 2>/dev/null)
        log "OK" "Python ${PY_VER} lefordítva: $PY_INSTALLED_VER | lzma, ssl: OK"
        infra_state_set "INST_PYTHON_VER" "$PY_VER"
        dialog_msg "✓ Python ${PY_VER} — Sikeres" "
  ✓  $PY_INSTALLED_VER
  ✓  lzma: OK (PyTorch checkpointok olvashatók!)
  ✓  ssl: OK | readline: OK" 12
      else
        ((FAIL++))
        dialog_warn "Python — LZMA HIBA" \
          "\n  Python fordítva, DE lzma modul HIÁNYZIK!\n  Telepítsd a fordítási függőségeket (1. lépés)\n  és futtasd újra reinstall módban.\n  Log: $LOGFILE_AI" 14
      fi
    fi
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 8 — 4. UV — ASTRAL CSOMAGKEZELŐ  ██
# =============================================================================

_uv_needs_install=false
[ "${COMP_STATUS[uv]}" != "ok" ] && _uv_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _uv_needs_install=true

if $_uv_needs_install || [ "${RUN_MODE:-install}" = "update" ]; then
  if [ "${RUN_MODE:-install}" = "update" ] && [ "${COMP_STATUS[uv]}" = "ok" ]; then
    dialog_yesno "4/7 — uv frissítés" \
      "\n  uv frissítése.\n  Jelenlegi: ${COMP_VER[uv]:-ismeretlen}\n  Folytatjuk?" 12 || { ((SKIP++)); goto_step_5=false; }
    if [ "${goto_step_5:-true}" = "true" ]; then
      run_with_progress "uv self update" "uv self update..." \
        su - "$_REAL_USER" -c "$VENV_UV self update" \
        && ((OK++)) || ((FAIL++))
    fi
  elif $_uv_needs_install; then
    dialog_yesno "4/7 — uv telepítése" "
  uv: Astral ultra-gyors Python csomagkezelő (Rust)
  ~100x gyorsabb mint pip | Parallel download + cache
  Telepítési hely: ~/.local/bin/uv
  Forrás: https://docs.astral.sh/uv/
  Folytatjuk?" 14 || { ((SKIP++)); goto_step_5=false; }

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
    log "OK" "uv elérhető: $UV_INSTALLED_VER"
    infra_state_set "INST_UV_VER" "$(echo "$UV_INSTALLED_VER" | grep -oP '[\d.]+' | head -1)"
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 9 — 5. VIRTUÁLIS KÖRNYEZET + AI/ML CSOMAG STACK  ██
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
  Virtuális környezet: $VENV_DIR
  Python: $PY_VER (pyenv)

  Csomag csoportok:
    API layer:    FastAPI, uvicorn, pydantic v2, sqlmodel, httpx
    LLM kliensek: openai, anthropic, langchain, langgraph
    HuggingFace:  transformers, datasets, safetensors, peft, accelerate
    Adattudomány: numpy, pandas, polars, scipy, sklearn, matplotlib
    Fejlesztő:    ruff, mypy, pytest, pre-commit, ipython
    JupyterLab:   jupyterlab 4.x, ipywidgets, ipykernel (ai kernel)
    Utility:      rich, typer, loguru, tenacity, psutil, pillow

  FONTOS: PyTorch külön lépésben települ (6. lépés, ~3 GB)!
  Becsült idő: ~3-8 perc
  Folytatjuk?" 28 || { ((SKIP++)); goto_step_6=false; }

  if [ "${goto_step_6:-true}" = "true" ]; then
    log "STEP" "5/7 AI/ML venv + csomagok..."

    if [ "${RUN_MODE:-install}" = "reinstall" ] && [ -d "$VENV_DIR" ]; then
      log "INFO" "Reinstall: régi venv törlése"
      rm -rf "$VENV_DIR"
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
    log "INFO" "Összes telepítendő csomag: ${#ALL_PKGS[@]} db"

    UV_FLAGS=""
    [ "${RUN_MODE:-install}" = "update" ] && UV_FLAGS="--upgrade"

    su - "$_REAL_USER" -c \
      "$VENV_UV pip install $UV_FLAGS --python '$VENV_PY' ${ALL_PKGS[*]}" \
      >> "$LOGFILE_AI" 2>&1 &
    UV_PID=$!
    progress_open "AI/ML csomagok telepítése" "uv pip install ${#ALL_PKGS[@]} csomag..."
    i=5
    while kill -0 $UV_PID 2>/dev/null; do
      progress_set "$i" "AI/ML csomagok (${#ALL_PKGS[@]} db, ~3-8 perc)..."
      sleep 2; [ $i -lt 90 ] && ((i+=3))
    done
    progress_close
    wait $UV_PID; PKGS_EC=$?

    [ $PKGS_EC -ne 0 ] \
      && { ((FAIL++)); log "FAIL" "Csomag telepítés sikertelen (exit $PKGS_EC)"; } \
      || { ((OK++)); log "OK" "AI/ML csomag stack telepítve (${#ALL_PKGS[@]} db)"; }

    # JupyterLab kernel regisztráció
    log "INFO" "JupyterLab AI kernel regisztráció..."
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
# ██  SZEKCIÓ 10 — 6. PYTORCH — CUDA VERZIÓS TELEPÍTÉS  ██
# =============================================================================
# PYTORCH_INDEX az infra state-ből + hw_has_nvidia() alapú korrekció (v6.4 fix):
#   cu126 → CUDA 12.6 | cu128 → CUDA 12.8/13.x | cpu → iGPU
#
# FIGYELMEZTETÉS: cuda.is_available() REBOOT ELŐTT False lehet!
# Az NVIDIA kernel modul csak driver betöltés után aktív — ez NORMÁLIS.

_torch_needs_install=false
[ "${COMP_STATUS[torch]}" != "ok" ] && _torch_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _torch_needs_install=true
[ "${RUN_MODE:-install}" = "update" ] && _torch_needs_install=true

if $_torch_needs_install; then
  TORCH_INDEX_URL="https://download.pytorch.org/whl/${PYTORCH_INDEX}"
  TORCH_SIZE_EST="~2.5-3 GB"
  [ "$PYTORCH_INDEX" = "cpu" ] && TORCH_SIZE_EST="~180 MB"

  dialog_yesno "6/7 — PyTorch telepítése" "
  PyTorch 2.x — ${PYTORCH_INDEX} index
  Index URL: $TORCH_INDEX_URL
  Méret: $TORCH_SIZE_EST (~5-20 perc)

  $([ "$PYTORCH_INDEX" != "cpu" ] && echo "CUDA ellenőrzés REBOOT UTÁN:
    python -c 'import torch; print(torch.cuda.is_available())'
  Várható: True (most False lehet — NORMÁLIS!)" \
  || echo "CPU-only telepítés (iGPU profil).")

  Folytatjuk?" 22 || { ((SKIP++)); goto_step_7=false; }

  if [ "${goto_step_7:-true}" = "true" ]; then
    log "STEP" "6/7 PyTorch: ${PYTORCH_INDEX} ($TORCH_INDEX_URL)"

    UV_FLAGS=""
    [ "${RUN_MODE:-install}" = "update" ] && UV_FLAGS="--upgrade"

    su - "$_REAL_USER" -c \
      "$VENV_UV pip install $UV_FLAGS \
        --python '$VENV_PY' $TORCH_PKGS \
        --index-url '$TORCH_INDEX_URL'" \
      >> "$LOGFILE_AI" 2>&1 &
    TORCH_PID=$!
    progress_open "PyTorch ${PYTORCH_INDEX} telepítése" \
      "torch + torchvision + torchaudio ($TORCH_SIZE_EST)..."
    i=2
    while kill -0 $TORCH_PID 2>/dev/null; do
      progress_set "$i" "PyTorch ${PYTORCH_INDEX} letöltése ($TORCH_SIZE_EST)..."
      sleep 5; [ $i -lt 88 ] && ((i++))
    done
    progress_close
    wait $TORCH_PID; TORCH_EC=$?

    if [ $TORCH_EC -ne 0 ]; then
      ((FAIL++))
      dialog_warn "PyTorch — Telepítési hiba" \
        "\n  Sikertelen (exit $TORCH_EC)\n  Index: $PYTORCH_INDEX\n  Log: $LOGFILE_AI" 14
    else
      TORCH_VER=$("$VENV_PY" -c "import torch; print(torch.__version__)" 2>/dev/null || echo "ismeretlen")
      ((OK++))
      log "OK" "PyTorch: $TORCH_VER ($PYTORCH_INDEX)"
      infra_state_set "INST_TORCH_VER" "$TORCH_VER"
      dialog_msg "✓ PyTorch — Telepítve" "
  ✓  PyTorch $TORCH_VER (${PYTORCH_INDEX})

  CUDA ellenőrzés (REBOOT UTÁN!):
    source $VENV_DIR/bin/activate
    python -c 'import torch; print(torch.cuda.is_available())'

  $([ "$PYTORCH_INDEX" != "cpu" ] && \
    echo "Várható: True (most False lehet — normális!)" || \
    echo "CPU-only: cuda.is_available() = False (normális!)")" 16
    fi
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 11 — 7. PROJEKT TEMPLATE  ██
# =============================================================================

_tmpl_needs_install=false
[ "${COMP_STATUS[template]}" != "ok" ] && _tmpl_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _tmpl_needs_install=true
[ "${RUN_MODE:-install}" = "update" ] && _tmpl_needs_install=true

if $_tmpl_needs_install; then
  dialog_yesno "7/7 — Projekt template" "
  Python AI projekt template:
    $TEMPLATE_DIR/

  Tartalom:
    pyproject.toml          — ruff, black, mypy, pytest, isort
    .env.example            — API kulcsok mintája
    .cursorrules            — Cursor/Claude AI instrukciók
    .vscode/settings.json   — VS Code Python konfiguráció
    .pre-commit-config.yaml — pre-commit hook konfiguráció

  Folytatjuk?" 16 || { ((SKIP++)); goto_end=false; }

  if [ "${goto_end:-true}" = "true" ]; then
    log "STEP" "7/7 Projekt template generálása..."
    mkdir -p "$TEMPLATE_DIR/.vscode"
    chown -R "$_REAL_USER:$_REAL_USER" "$_REAL_HOME/templates" 2>/dev/null || true

    cat > "$TEMPLATE_DIR/pyproject.toml" << 'TOML_EOF'
# pyproject.toml — Python AI/ML projekt konfiguráció v6.4
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

[tool.coverage.run]
source = ["src"]
omit = ["tests/*", "**/__init__.py"]
TOML_EOF

    cat > "$TEMPLATE_DIR/.env.example" << 'ENV_EOF'
# .env.example — API kulcsok és konfiguráció
# Másold .env-be! (.env SOHA nem kerül git-be!)

ANTHROPIC_API_KEY=sk-ant-api03-...
OPENAI_API_KEY=sk-proj-...
HUGGINGFACE_TOKEN=hf_...

OLLAMA_HOST=http://localhost:11434
VLLM_HOST=http://localhost:8000
VLLM_API_KEY=token-vllm

CUDA_HOME=/usr/local/cuda
CUDA_VISIBLE_DEVICES=0
PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512

LOG_LEVEL=INFO
DEBUG=false
ENV_EOF

    cat > "$TEMPLATE_DIR/.cursorrules" << CURSOR_EOF
# .cursorrules — AI pair programming irányelvek v6.4
# Stack: Python 3.12 + PyTorch ${PYTORCH_INDEX} + LangChain + HuggingFace + FastAPI

You are an expert Python developer specializing in AI/ML engineering.
Always write production-quality, type-annotated Python 3.12+ code.

## Technology Stack
- Python 3.12+ with PEP 695 type syntax where appropriate
- PyTorch 2.x (CUDA ${PYTORCH_INDEX}) for deep learning
- FastAPI + Pydantic v2 for APIs (never plain dicts)
- LangChain/LangGraph for LLM orchestration
- HuggingFace (transformers, datasets, safetensors) for model management
- uv for dependency management (NOT pip directly)

## Code Quality Rules
- Type hints EVERYWHERE — use \`from __future__ import annotations\` at top
- Pydantic v2 BaseModel for all data structures
- Google-style docstrings for all public functions and classes
- 100 character line length (black + ruff configured)
- pathlib.Path (not os.path), loguru (not print)
- No bare except — always catch specific exceptions

## PyTorch Conventions
- torch.no_grad() + torch.autocast() for all inference paths
- bfloat16 on Blackwell (RTX 5090) and Ampere+, float16 on older Turing
- safetensors for model serialization (NEVER pickle for models!)
- Device-agnostic: device = torch.device("cuda" if torch.cuda.is_available() else "cpu")

## LLM / AI Conventions
- Use langchain LCEL (pipe syntax: chain = prompt | llm | parser)
- Anthropic Claude: use streaming for long outputs
- OpenAI: use structured outputs (response_format=)
- Rate limiting + tenacity retry for all API calls

## Security
- API keys from python-dotenv / pydantic-settings ONLY
- No secrets in code, never in git
- Input validation on all API endpoints (Pydantic v2)
- httpx for async HTTP (not requests in async contexts)
CURSOR_EOF

    cat > "$TEMPLATE_DIR/.vscode/settings.json" << VSCODE_EOF
{
  "python.defaultInterpreterPath": "${_REAL_HOME}/AI-VIBE/venvs/ai/bin/python",
  "python.terminal.activateEnvironment": true,
  "editor.formatOnSave": true,
  "editor.rulers": [100],
  "[python]": {
    "editor.defaultFormatter": "ms-python.black-formatter",
    "editor.codeActionsOnSave": { "source.organizeImports": "explicit" }
  },
  "ruff.lint.args": ["--line-length=100"],
  "black-formatter.args": ["--line-length", "100"],
  "mypy-type-checker.args": ["--strict", "--ignore-missing-imports"],
  "python.testing.pytestEnabled": true,
  "python.testing.pytestArgs": ["tests"]
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
      - id: check-json
      - id: check-toml
      - id: check-added-large-files
        args: ["--maxkb=10240"]
      - id: debug-statements
  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: v1.9.0
    hooks:
      - id: mypy
        additional_dependencies: ["pydantic", "types-PyYAML"]
PRECOMMIT_EOF

    chown -R "$_REAL_USER:$_REAL_USER" "$TEMPLATE_DIR" 2>/dev/null || true
    ((OK++))
    log "OK" "Projekt template létrehozva: $TEMPLATE_DIR"
  fi
fi

# =============================================================================
# ██  SZEKCIÓ 12 — LEZÁRÁS: STATE + LOG + ÖSSZEFOGLALÁS  ██
# =============================================================================

# ── INFRA state frissítés ─────────────────────────────────────────────────────
if [ "$FAIL" -eq 0 ] || [ "$OK" -gt 0 ]; then
  infra_state_set "MOD_03_DONE" "true"
  log "STATE" "MOD_03_DONE=true — 02_local_ai_stack.sh futtatható"
else
  log "WARN" "Hibák miatt MOD_03_DONE nem lett true-ra állítva (OK=$OK FAIL=$FAIL)"
fi

# ── Végeredmény összesítő ─────────────────────────────────────────────────────
show_result "$OK" "$SKIP" "$FAIL"

# =============================================================================
# ██  SZEKCIÓ 13 — POST-INSTALL COMP STATE RE-CHECK + MENTÉS  ██
# =============================================================================
# LOGIKA (sablon: compstate_implementációs_sablon_az_egyes_szálaknak):
#   check mód     → comp_save_state a felmérés VÉGÉN (pre=post, már megtörtént)
#   install/update/fix/reinstall → re-check ITT, a telepítések UTÁN.
#     Ha az elején mentünk volna, a state PRE-install állapotot mutatna
#     (pl. az épp telepített torch "missing"-nek látszana).

if [[ "${RUN_MODE:-install}" =~ ^(install|update|fix|reinstall)$ ]]; then
  log "COMP" "Post-install re-check futtatása (mód: $RUN_MODE)..."

  _build_deps_ok=true
  for pkg in liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev \
             libbz2-dev libffi-dev libssl-dev; do
    dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || { _build_deps_ok=false; break; }
  done
  $_build_deps_ok \
    && COMP_STATUS[build_deps]="ok" || COMP_STATUS[build_deps]="missing"

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
  log "COMP" "Post-install COMP state mentve: COMP_03_* (telepítés utáni valós állapot)"
fi

# ── Log chmod végső — futás során root is írt bele ───────────────────────────
chmod 644 "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
chown "${_REAL_USER}:${_REAL_USER}" "${LOGFILE_AI}" "${LOGFILE_HUMAN}" 2>/dev/null || true
log "OK" "Log jogosultságok: 644 / ${_REAL_USER}"

# ── Összefoglalás dialóg ──────────────────────────────────────────────────────
dialog_msg "[$INFRA_NAME] — Következő lépések" "
  ── Venv aktiválás ────────────────────────────────────────
  source $VENV_DIR/bin/activate

  ── PyTorch GPU ellenőrzés (REBOOT UTÁN!) ─────────────────
  python -c 'import torch; print(torch.cuda.is_available())'
  python -c 'import torch; print(torch.cuda.get_device_name(0))'

  ── JupyterLab indítás ────────────────────────────────────
  jupyter lab --no-browser --port 8888

  ── LangChain Quick Test ──────────────────────────────────
  python -c 'import langchain; print(langchain.__version__)'

  ── Projekt template ──────────────────────────────────────
  cp -r $TEMPLATE_DIR/ ~/projektek/uj-ai-projekt/

  ── PyTorch index: $PYTORCH_INDEX (CUDA $CUDA_VER)
  ── AI kernel neve: Python 3.12 (AI/ML)
  ── Log: $LOGFILE_AI" 28

log "MASTER" "INFRA 03 befejezve: OK=${OK} SKIP=${SKIP} FAIL=${FAIL}"
