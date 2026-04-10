#!/bin/bash
# =============================================================================
# 03_python_aiml.sh — Python 3.12 + PyTorch + AI/ML Stack v6.2
#
# Szerepe a INFRA rendszerben
# ───────────────────────────
# Ez a modul az 01b_post_reboot.sh UTÁN futtatandó.
# A teljes Python AI/ML fejlesztői infrastruktúrát telepíti:
#
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
# RUN_MODE értékek (00_master.sh v6.4.2)
# ────────────────────────────────────────
#   install   → csak hiányzó komponensek felrakása (alapértelmezett)
#   update    → uv + csomagok frissítése, pyenv frissítése
#   reinstall → teljes újratelepítés (--force flag pyenv-nek)
#   check     → csak állapot felmérés, semmi sem változik
#   fix       → hiányzó komponensek pótlása reboot nélkül (≈ install)
#               infra_require NEM blokkol fix módban (lib kezeli)
#               REBOOT_NEEDED NEM propagálódik (master kezeli)
#
# Változtatások v6.2 (v6.4.2 CORE rendszer integráció)
# ─────────────────────────────────────────────────────
#   - fix mód: kezeli a masterből kapott "fix" RUN_MODE-ot (≈ install)
#     fix módban: infra_require("01b") nem blokkol (lib/00_lib_state.sh kezeli)
#     fix módban: REBOOT_NEEDED nem propagálódik (00_master.sh kezeli)
#   - infra_require "01b" → lowercase (case-insensitive lib kompatibilitás)
#     infra_require() a lib-ben auto-uppercase-el: "01b" → MOD_01B_DONE
#   - PYTORCH_INDEX validáció: cuda_pytorch_index() segédfüggvény meghívása
#     ha az infra state-ből olvasott index inkonzisztens a CUDA verzióval
#   - lib split kompatibilitás: comp_check_torch() a lib/00_lib_comp.sh-ban él
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
#   lib/00_lib_comp.sh   — comp_check_*, version_ok, cuda_pytorch_index
#   lib/00_lib_apt.sh    — apt_install_*, run_with_progress
LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" \
  || { echo "HIBA: 00_lib.sh hiányzik! Elvárt helye: $LIB"; exit 1; }

# =============================================================================
# ██  KONFIGURÁCIÓ  ── minden érték itt, kódban nincs magic string  ██
# =============================================================================

# ── Modul azonosítók ──────────────────────────────────────────────────────────
INFRA_NUM="03"
INFRA_NAME="Python 3.12 + PyTorch + AI/ML Stack"
INFRA_HW_REQ=""   # Hardverfüggetlen — CPU-only PyTorch is telepíthető

# ── Python verzió ─────────────────────────────────────────────────────────────
# pyenv install ennyi verziót fordít — PY_VER változtatásával frissíthető
# Forrás: https://docs.python.org/3.12/ — stable release
PY_VER="3.12.9"

# ── pyenv fordítási konfiguráció ──────────────────────────────────────────────
# --enable-optimizations: PGO (Profile-Guided Optimization) + LTO (Link-Time Optimization)
# Eredmény: ~10-15% gyorsabb Python interpreter
# Forrás: https://docs.python.org/3.12/using/configure.html#performance-options
PY_CONFIGURE_OPTS="--enable-optimizations"

# ── Minimum elfogadható verziók ───────────────────────────────────────────────
declare -A MIN_VER=(
  [python]="3.12.0"    # pyenv által fordított Python — PY_VER-rel ellenőrzött
  [uv]="0.4.0"         # Astral uv — Rust alapú csomagkezelő
)

# ── APT fordítási és rendszer függőségek ──────────────────────────────────────
# KRITIKUS: liblzma-dev NÉLKÜL a Python lzma/xz modulja NEM FORDUL!
# PyTorch modellek .pt fájljai xz tömörítést használnak → KÖTELEZŐ.
# Forrás: https://github.com/pyenv/pyenv/wiki#suggested-build-environment
declare -A PKGS=(
  # Python forrásból fordításhoz szükséges könyvtárak:
  #   liblzma-dev     → lzma, xz tömörítés (PyTorch checkpoint-ok! KRITIKUS!)
  #   libgdbm-dev     → dbm adatbázis modul
  #   libreadline-dev → readline (interaktív REPL élmény)
  #   libsqlite3-dev  → sqlite3 beépített DB
  #   libbz2-dev      → bz2 tömörítés
  #   zlib1g-dev      → zlib (általános tömörítés)
  #   libffi-dev      → ctypes, cffi C interfész
  #   tk-dev          → tkinter GUI (matplotlib backend)
  #   uuid-dev        → uuid generálás
  #   libncurses-dev  → curses TUI könyvtár
  #   xz-utils        → xz CLI eszközök (runtime)
  #   libxml2-dev     → XML feldolgozás
  #   libxmlsec1-dev  → XML aláírás (JWT, SAML)
  #   libssl-dev      → ssl modul (HTTPS API hívások, Anthropic SDK)
  #   libnss3-dev     → NSS (TLS, Firefox kompatibilis cert kezelés)
  [python_build]="liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev
                  libbz2-dev zlib1g-dev libffi-dev tk-dev uuid-dev
                  libncurses-dev xz-utils libxml2-dev libxmlsec1-dev
                  libssl-dev libnss3-dev"
)

# ── URL-ek ────────────────────────────────────────────────────────────────────
declare -A URLS=(
  # pyenv telepítő script — bash futtatja, PATH-ba rak, init-et beállít
  # Forrás: https://github.com/pyenv/pyenv#automatic-installer
  [pyenv_install]="https://pyenv.run"

  # uv installáló script — curl | sh minta (Astral dokumentált módszer)
  # Forrás: https://docs.astral.sh/uv/getting-started/installation/
  [uv_install]="https://astral.sh/uv/install.sh"
)

# ── PyTorch csomagok ──────────────────────────────────────────────────────────
# Az index URL az infra state PYTORCH_INDEX-ből jön:
#   cu126 → CUDA 12.6 (RTX 5090 Blackwell alapértelmezett)
#   cu128 → CUDA 12.8, vagy CUDA 13.x esetén (ABI kompatibilis)
#   cpu   → CPU-only (notebook-igpu / desktop-igpu profilokon)
# Forrás: https://download.pytorch.org/whl/ — PyTorch wheel repository
# Megjegyzés: cuda_pytorch_index() (lib/00_lib_comp.sh) állítja elő az indexet
TORCH_PKGS="torch torchvision torchaudio"

# ── AI/ML Python csomagok — funkcionális csoportok ───────────────────────────
# 7 csoport a könnyű karbantartáshoz — csoportonként hozzáadható/eltávolítható

# Web framework és API réteg
AI_PKGS_API=(
  "fastapi"              # ASGI web framework
  "uvicorn[standard]"    # ASGI szerver (uvloop + httptools)
  "pydantic>=2.0"        # adatvalidáció v2 (Rust core, gyorsabb)
  "pydantic-settings"    # .env és settings kezelés Pydantichoz
  "sqlmodel"             # SQLAlchemy + Pydantic egységes ORM
  "httpx"                # async HTTP kliens (requests helyett, FastAPI-kompatibilis)
  "aiohttp"              # async HTTP (vLLM és Ollama Python SDK igényli)
  "requests"             # szinkron HTTP (legacy és CLI kompatibilitás)
  "aiofiles"             # async fájl I/O
  "websockets"           # WebSocket kliens/szerver
)

# AI / LLM kliensek és keretrendszerek
AI_PKGS_LLM=(
  "openai>=1.0"                    # OpenAI Python SDK v1+ (ChatGPT, GPT-4o)
  "anthropic>=0.25"                # Anthropic Claude Python SDK
  "langchain>=0.2"                 # LangChain keretrendszer
  "langchain-core"                 # LangChain alap absztrakciók (LCEL)
  "langchain-community"            # Közösségi integrációk (dokumentum loaderek)
  "langchain-openai"               # OpenAI LangChain integráció
  "langchain-anthropic"            # Anthropic LangChain integráció
  "langgraph"                      # LangGraph agent framework (stateful)
)

# HuggingFace ökoszisztéma
AI_PKGS_HF=(
  "huggingface-hub>=0.22"          # HF Hub kliens (model/dataset letöltés)
  "transformers>=4.40"             # Transformer modellek (BERT, GPT, LLaMA stb.)
  "datasets>=2.19"                 # HF Datasets (adatbetöltés, streaming)
  "tokenizers>=0.19"               # Gyors (Rust) tokenizálás
  "accelerate>=0.29"               # Multi-GPU + mixed precision training
  "safetensors>=0.4"               # Biztonságos model serialization (pickle helyett!)
  "peft>=0.10"                     # Parameter-Efficient Fine-Tuning (LoRA, QLoRA)
  "sentence-transformers"          # Szöveg embeddings (RAG pipeline-hoz)
  "einops"                         # Tensor dimenzió műveletek (transformer kód)
  "tiktoken"                       # OpenAI BPE tokenizer (token számolás)
)

# Adattudomány és ML
AI_PKGS_DATA=(
  "numpy>=1.26"                    # NumPy (alap tenzor műveletek, PyTorch bridge)
  "pandas>=2.0"                    # Pandas adatkezelés
  "polars>=0.20"                   # Polars (Rust alapú, gyorsabb Pandas alternatíva)
  "scipy>=1.12"                    # SciPy (tudományos számítások)
  "scikit-learn>=1.4"              # Scikit-learn (klasszikus ML algoritmusok)
  "matplotlib>=3.8"                # Matplotlib vizualizáció
  "seaborn>=0.13"                  # Seaborn statisztikai vizualizáció
  "plotly>=5.18"                   # Plotly interaktív diagramok (JupyterLab)
  "pillow>=10.0"                   # PIL/Pillow kép feldolgozás
)

# Fejlesztői eszközök és produktivitás
AI_PKGS_DEV=(
  "ruff>=0.4"              # Ruff linter (Rust alapú, flake8+isort+pyupgrade)
  "black>=24.0"            # Black kód formázó
  "isort>=5.13"            # Import rendezés
  "mypy>=1.9"              # Statikus típusellenőrzés
  "pytest>=8.0"            # Teszt keretrendszer
  "pytest-asyncio>=0.23"   # Async teszt support (FastAPI tesztekhez)
  "pytest-cov>=5.0"        # Coverage riport
  "pre-commit>=3.7"        # Git hook manager (commit előtti ellenőrzések)
  "ipython>=8.22"          # Fejlett Python REPL (JupyterLab kernel)
)

# JupyterLab notebook IDE
AI_PKGS_JUPYTER=(
  "jupyter>=1.0"           # Jupyter meta-csomag
  "jupyterlab>=4.0"        # JupyterLab 4.x IDE
  "notebook>=7.0"          # Klasszikus Notebook kompatibilitás
  "ipywidgets>=8.0"        # Interaktív widget-ek JupyterLab-ban
  "ipykernel>=6.29"        # IPython kernel (ai névvel regisztrálódik)
)

# Utility és rendszer csomagok
AI_PKGS_UTIL=(
  "tqdm>=4.66"             # Progress bar (training loop-okhoz)
  "rich>=13.7"             # Gazdag terminál output (fa, táblázat, log)
  "python-dotenv>=1.0"     # .env fájl betöltés (API kulcsok)
  "pyyaml>=6.0"            # YAML fájl parse/dump (config fájlok)
  "toml>=0.10"             # TOML parse (pyproject.toml olvasás)
  "typer>=0.12"            # CLI builder (Click wrapper, FastAPI stílus)
  "loguru>=0.7"            # Modern Python logging (log rotation, színezés)
  "tenacity>=8.2"          # Retry dekorátor (API hívásokhoz)
  "psutil>=5.9"            # Rendszer erőforrás monitoring
  "beautifulsoup4>=4.12"   # HTML parse (web scraping, RAG pipeline)
  "packaging"              # Verzió összehasonlítás
)

# ── Komponens ellenőrző specifikációk ─────────────────────────────────────────
# Formátum: "megjelenített_név|comp_check_kulcs|min_verzió"
# comp_check kulcsok: a COMP_STATUS[] tömbben tárolódnak (lib/00_lib_comp.sh)
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
PYENV_ROOT="$_REAL_HOME/.pyenv"              # pyenv telepítési könyvtár
VENV_DIR="$_REAL_HOME/AI-VIBE/venvs/ai"     # Python AI/ML venv helye
VENV_PY="$VENV_DIR/bin/python"              # venv Python bináris
VENV_UV="$_REAL_HOME/.local/bin/uv"          # uv bináris helye
PY_BIN="$PYENV_ROOT/versions/$PY_VER/bin/python3"  # pyenv Python bináris
TEMPLATE_DIR="$_REAL_HOME/templates/python-ai"      # Projekt template könyvtár
LOCK_FILE="/tmp/infra_03_python.lock"               # Párhuzamos futás blokkolása

# =============================================================================
# ██  INICIALIZÁLÁS  ██
# =============================================================================

# ── Log fájlok beállítása ─────────────────────────────────────────────────────
# Log könyvtár a user home-jában (sudo alatt /root lenne a $HOME — HELYTELEN!)
LOGFILE_AI="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_03_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_03_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="$LOGFILE_AI"   # backward compat

log_init

# ── Párhuzamos futás megakadályozása ─────────────────────────────────────────
check_lock "$LOCK_FILE"

# ── INFRA state betöltés ──────────────────────────────────────────────────────
# Az 01a modul mentette: INST_CUDA_VER, PYTORCH_INDEX, HW_GPU_ARCH
CUDA_VER=$(infra_state_get "INST_CUDA_VER" "12.6")
PYTORCH_INDEX=$(infra_state_get "PYTORCH_INDEX" "cu126")
HW_GPU_ARCH_ST=$(infra_state_get "HW_GPU_ARCH" "igpu")
FEAT_GPU_ACCEL=$(infra_state_get "FEAT_GPU_ACCEL" "false")

# CPU-only profil esetén cpu index (notebook-igpu, desktop-igpu)
# Egyébként cuda_pytorch_index() segédfüggvénnyel ellenőrzük az index helyességét
# Forrás: cuda_pytorch_index() a lib/00_lib_comp.sh-ban (v6.4)
if [ "$FEAT_GPU_ACCEL" = "false" ]; then
  PYTORCH_INDEX="cpu"
  log "STATE" "CPU-only profil: PYTORCH_INDEX=cpu (GPU gyorsítás nem érhető el)"
else
  # Validáció: cuda_pytorch_index() kiszámítja az elvárt indexet a CUDA verzióból
  # Ez kezeli a CUDA 13.x → cu128 fallback esetet is
  _expected_idx="$(cuda_pytorch_index "$CUDA_VER" 2>/dev/null || echo "")"
  if [ -n "$_expected_idx" ] && [ "$PYTORCH_INDEX" != "$_expected_idx" ]; then
    log "WARN" "PYTORCH_INDEX mismatch: state=$PYTORCH_INDEX, várható=$_expected_idx (CUDA $CUDA_VER)"
    log "WARN" "Automatikus korrekció: PYTORCH_INDEX=$_expected_idx"
    PYTORCH_INDEX="$_expected_idx"
    infra_state_set "PYTORCH_INDEX" "$_expected_idx"
  fi
fi

log "STATE" "Betöltve: CUDA=$CUDA_VER | PyTorch index=$PYTORCH_INDEX | GPU arch=$HW_GPU_ARCH_ST"

# ── INFRA state inicializálás ─────────────────────────────────────────────────
infra_state_init

# ── Hardver kompatibilitás ────────────────────────────────────────────────────
# INFRA_HW_REQ="" → minden hardveren fut
infra_compatible "$INFRA_HW_REQ" || {
  dialog_warn "Hardver inkompatibilis" \
    "\n  HW_REQ: $INFRA_HW_REQ | Profil: $HW_PROFILE\n  Modul kihagyva." 10
  rm -f "$LOCK_FILE"
  exit 2
}

# ── Függőség ellenőrzés ───────────────────────────────────────────────────────
# 01b (Oh My Zsh, shell konfig) előfeltétele — zshrc-ben van pyenv init
# v6.2: "01b" lowercase — infra_require() auto-uppercase-el: MOD_01B_DONE
# check és fix módban: infra_require() NEM blokkol (lib/00_lib_state.sh kezeli)
# reinstall módban: bypass — a user tudatos döntése az újratelepítés
if [[ "${RUN_MODE:-install}" != "reinstall" ]]; then
  infra_require "01b" "User Environment (01b_post_reboot.sh)" || {
    # install módban: bypass lehetősége (manuális override)
    dialog_yesno "Függőség figyelmeztető" \
      "\n  MOD_01B_DONE nincs beállítva.\n\n  A 01b (Zsh, shell setup) fut le ELŐTTE.\n\n  Ennek ellenére folytatjuk?" 14 || {
      rm -f "$LOCK_FILE"
      exit 1
    }
    log "WARN" "01b függőség manuálisan bypass-olva — user döntése"
  }
fi

# ── PATH előkészítés ──────────────────────────────────────────────────────────
# pyenv és uv binárisok nem biztos hogy PATH-ban vannak sudo kontextusban
export PYENV_ROOT
export PATH="$PYENV_ROOT/bin:$_REAL_HOME/.local/bin:$PATH"
[ -d "$PYENV_ROOT/bin" ] && eval "$(pyenv init -)" 2>/dev/null || true

# =============================================================================
# ██  ÁLLAPOT FELMÉRÉS  ██
# =============================================================================

log "COMP" "━━━ Komponens állapot felmérés ━━━"

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

# 2. pyenv
if command -v pyenv &>/dev/null || [ -x "$PYENV_ROOT/bin/pyenv" ]; then
  COMP_STATUS[pyenv]="ok"
  COMP_VER[pyenv]="$(pyenv --version 2>/dev/null | grep -oP '[\d.]+' | head -1)"
else
  COMP_STATUS[pyenv]="missing"
fi
log "COMP" "  pyenv: ${COMP_STATUS[pyenv]} ${COMP_VER[pyenv]:-}"

# 3. Python 3.12.x — pyenv által fordított bináris
# comp_check_python: lib/00_lib_comp.sh
comp_check_python "$PY_VER" "$PYENV_ROOT"
log "COMP" "  python: ${COMP_STATUS[python]:-missing} ${COMP_VER[python]:-}"

# 4. lzma modul — KRITIKUS! (PyTorch .pt fájlok xz tömörítése)
if [ -x "$PY_BIN" ] && "$PY_BIN" -c "import lzma, bz2, readline" 2>/dev/null; then
  COMP_STATUS[lzma_ok]="ok"
else
  COMP_STATUS[lzma_ok]="missing"
fi
log "COMP" "  lzma_ok: ${COMP_STATUS[lzma_ok]}"

# 5. uv — Astral csomagkezelő
# comp_check_uv: lib/00_lib_comp.sh
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
# comp_check_torch: lib/00_lib_comp.sh (v6.4 — logol: cuda.is_available())
# FONTOS: REBOOT előtt cuda=False normális (NVIDIA kernel modul nem aktív)
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

# =============================================================================
# ██  RUN MODE KEZELÉS  ██
# =============================================================================

# ── check mód: csak megmutatjuk az állapotot ─────────────────────────────────
if [ "${RUN_MODE:-install}" = "check" ]; then
  dialog_msg "[Ellenőrző] $INFRA_NAME" \
    "\n  Komponens állapot:\n\n$(printf '%b' "$STATUS_LINES")
  PyTorch index: $PYTORCH_INDEX
  CUDA verzió:   $CUDA_VER
  Python venv:   $VENV_DIR
  Log:           $LOGFILE_AI" 28
  rm -f "$LOCK_FILE"
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

# ── install / fix mód: minden megvan → nincs tennivaló ───────────────────────
# fix mód = install, de infra_require nem blokkol és REBOOT_NEEDED nem propagál
if [ "$MISSING" -eq 0 ] && [[ "${RUN_MODE:-install}" =~ ^(install|fix)$ ]]; then
  dialog_msg "✓ Minden megvan — $INFRA_NAME" \
    "\n$(printf '%b' "$STATUS_LINES")\n  Nincs tennivaló." 28
  rm -f "$LOCK_FILE"
  exit 0
fi

# ── Mód felirat meghatározása ─────────────────────────────────────────────────
case "${RUN_MODE:-install}" in
  update)    _mode_label="Frissítés" ;;
  reinstall) _mode_label="Újratelepítés" ;;
  fix)       _mode_label="Javítás" ;;
  *)         _mode_label="Telepítés" ;;
esac

# ── Telepítési szándék megerősítése ───────────────────────────────────────────
dialog_yesno "[$_mode_label] — $INFRA_NAME" \
  "\n  Komponensek:\n$(printf '%b' "$STATUS_LINES")
  PyTorch index: $PYTORCH_INDEX (CUDA $CUDA_VER)
  Python:        $PY_VER (pyenv, forrásból fordítva)
  Venv:          $VENV_DIR

  A $_mode_label elkezdéséhez nyomj Igent." 30 || {
  rm -f "$LOCK_FILE"
  exit 0
}

OK=0; SKIP=0; FAIL=0

# ── Telepítési fejléc logba ───────────────────────────────────────────────────
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

# =============================================================================
# ██  1. FORDÍTÁSI FÜGGŐSÉGEK  ██
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
# ██  2. PYENV — PYTHON VERZIÓKEZELŐ  ██
# =============================================================================

_pyenv_needs_install=false
[ "${COMP_STATUS[pyenv]}" != "ok" ] && _pyenv_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _pyenv_needs_install=true

if $_pyenv_needs_install || [ "${RUN_MODE:-install}" = "update" ]; then

  if [ "${RUN_MODE:-install}" = "update" ] && [ "${COMP_STATUS[pyenv]}" = "ok" ]; then
    log "STEP" "2/7 pyenv frissítése..."
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
  Több Python verzió párhuzamosan, projekt-szintű pin.

  Telepítési hely: ~/.pyenv
  Inicializálás: ~/.zshrc + ~/.bashrc + ~/.profile

  Forrás: https://pyenv.run (GitHub/pyenv/pyenv)

  Folytatjuk?" 16 || { ((SKIP++)); goto_step_3=false; }

    if [ "${goto_step_3:-true}" = "true" ]; then
      log "STEP" "2/7 pyenv telepítése..."
      if [ ! -d "$PYENV_ROOT" ]; then
        run_with_progress "pyenv telepítés" "curl pyenv.run | bash..." \
          su - "$_REAL_USER" -c "curl -fsSL ${URLS[pyenv_install]} | bash" \
          && ((OK++)) || ((FAIL++))
      else
        log "INFO" "pyenv könyvtár már létezik: $PYENV_ROOT — frissítés próbálkozás"
        run_with_progress "pyenv frissítés" "pyenv update..." \
          su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv update" \
          && ((OK++)) || ((FAIL++))
      fi

      # Shell inicializáció — .zshrc, .bashrc, .profile mindháromba
      # Fontos: heredoc PYENVRC idézőjeles → nem expandál → $HOME kell bele
      for RC in "$_REAL_HOME/.zshrc" "$_REAL_HOME/.bashrc" "$_REAL_HOME/.profile"; do
        grep -q "PYENV_ROOT" "$RC" 2>/dev/null && continue
        cat >> "$RC" << 'PYENVRC'

# ── pyenv konfiguráció (vibe-coding-infra hozzáadta) ─────────────────────────
# Forrás: https://github.com/pyenv/pyenv#set-up-your-shell-environment
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
# ██  3. PYTHON 3.12.X FORDÍTÁSA  ██
# =============================================================================
# PGO + LTO: ~10-15% gyorsabb interpreter
# lzma hiba esetén is újrafordítjuk (NEED_PY=true ha lzma_ok=missing)!

NEED_PY=false
[ "${COMP_STATUS[python]}" != "ok" ] && NEED_PY=true
[ "${COMP_STATUS[lzma_ok]}" != "ok" ] && NEED_PY=true  # lzma hiba → újrafordítás!
[ "${RUN_MODE:-install}" = "reinstall" ] && NEED_PY=true

if $NEED_PY; then
  FORCE_FLAG=""
  [ "${COMP_STATUS[python]}" = "ok" ] && FORCE_FLAG="--force"

  BUILD_MSG="Python ${PY_VER} fordítása forrásból"
  [ -n "$FORCE_FLAG" ] && BUILD_MSG="Python ${PY_VER} ÚJRAFORDÍTÁSA (lzma fix)"

  dialog_yesno "3/7 — $BUILD_MSG" "
  $BUILD_MSG

  Optimalizálás: $PY_CONFIGURE_OPTS
  (PGO: Profile-Guided, LTO: Link-Time Optimization)
  Eredmény: ~10-15% gyorsabb Python interpreter

  Fordítási idő: ~8-12 perc (processzor-függő)
  A terminal kimenete logba kerül:
    $LOGFILE_AI

  FONTOS: liblzma-dev az 1. lépésben települt — ez KÖTELEZŐ!

  Folytatjuk?" 20 || { ((SKIP++)); goto_step_4=false; }

  if [ "${goto_step_4:-true}" = "true" ]; then
    log "STEP" "3/7 Python ${PY_VER} fordítása (PYTHON_CONFIGURE_OPTS='$PY_CONFIGURE_OPTS')..."

    PYTHON_CONFIGURE_OPTS="$PY_CONFIGURE_OPTS" \
      su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv install $FORCE_FLAG $PY_VER" \
      >> "$LOGFILE_AI" 2>&1 &
    PY_PID=$!

    progress_open "Python ${PY_VER} fordítása" \
      "pyenv install $FORCE_FLAG $PY_VER (--enable-optimizations, PGO+LTO)"
    i=2
    while kill -0 $PY_PID 2>/dev/null; do
      progress_set "$i" "Python ${PY_VER} fordítása... (PGO+LTO, ~8-12 perc)"
      sleep 5
      [ $i -lt 88 ] && ((i++))
    done
    progress_close
    wait $PY_PID; PY_EC=$?

    if [ $PY_EC -ne 0 ]; then
      ((FAIL++))
      dialog_warn "Python ${PY_VER} fordítás — HIBA" \
        "\n  A Python fordítás sikertelen (exit $PY_EC).\n  Részletek: $LOGFILE_AI\n\n  Lehetséges ok: hiányzó fordítási függőség (1. lépés!)" 14
    else
      su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv global $PY_VER" >> "$LOGFILE_AI" 2>&1

      # Kritikus ellenőrzés: lzma, bz2, readline, ssl modulok fordultak-e be?
      if "$PY_BIN" -c "import lzma; import bz2; import readline; import ssl" 2>/dev/null; then
        ((OK++))
        PY_INSTALLED_VER=$("$PY_BIN" --version 2>/dev/null)
        log "OK" "Python ${PY_VER} lefordítva: $PY_INSTALLED_VER"
        log "OK" "lzma, bz2, readline, ssl modulok: OK"
        infra_state_set "INST_PYTHON_VER" "$PY_VER"
        dialog_msg "✓ Python ${PY_VER} — Sikeres" "
  ✓  $PY_INSTALLED_VER lefordítva
  ✓  lzma modul: OK (PyTorch checkpointok olvashatók!)
  ✓  ssl modul: OK (HTTPS API hívásokhoz)
  ✓  readline modul: OK

  Telepítési hely: $PYENV_ROOT/versions/$PY_VER/" 16
      else
        ((FAIL++))
        dialog_warn "Python ${PY_VER} — LZMA HIBA" \
          "\n  Python fordítva, DE az lzma modul HIÁNYZIK!\n\n  Ok: liblzma-dev nem volt telepítve fordítás előtt.\n  Megoldás: Telepítsd a fordítási függőségeket (1. lépés)\n  és futtasd újra reinstall módban.\n\n  Részletek: $LOGFILE_AI" 18
      fi
    fi
  fi
fi

# =============================================================================
# ██  4. UV — ASTRAL CSOMAGKEZELŐ  ██
# =============================================================================

_uv_needs_install=false
[ "${COMP_STATUS[uv]}" != "ok" ] && _uv_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _uv_needs_install=true

if $_uv_needs_install || [ "${RUN_MODE:-install}" = "update" ]; then

  if [ "${RUN_MODE:-install}" = "update" ] && [ "${COMP_STATUS[uv]}" = "ok" ]; then
    log "STEP" "4/7 uv frissítése..."
    dialog_yesno "4/7 — uv frissítés" \
      "\n  uv frissítése a legújabb verzióra.\n  Jelenlegi: ${COMP_VER[uv]:-ismeretlen}\n\n  Folytatjuk?" 12 || { ((SKIP++)); goto_step_5=false; }

    if [ "${goto_step_5:-true}" = "true" ]; then
      run_with_progress "uv self update" "uv self update..." \
        su - "$_REAL_USER" -c "$VENV_UV self update" \
        && ((OK++)) || ((FAIL++))
    fi
  elif $_uv_needs_install; then
    dialog_yesno "4/7 — uv telepítése" "
  uv: Astral ultra-gyors Python csomagkezelő (Rust)
  Helyettesíti: pip, pip-tools, pipx, poetry, virtualenv

    • ~100x gyorsabb mint pip
    • Dependency resolver konzisztens
    • Parallel download + cache

  Telepítési hely: ~/.local/bin/uv
  Forrás: https://docs.astral.sh/uv/
  Folytatjuk?" 18 || { ((SKIP++)); goto_step_5=false; }

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
# ██  5. VIRTUÁLIS KÖRNYEZET + AI/ML CSOMAG STACK  ██
# =============================================================================

_venv_needs_work=false
[ "${COMP_STATUS[venv]}" != "ok" ]           && _venv_needs_work=true
[ "${COMP_STATUS[fastapi]}" != "ok" ]        && _venv_needs_work=true
[ "${COMP_STATUS[jupyter]}" != "ok" ]        && _venv_needs_work=true
[ "${COMP_STATUS[langchain]}" != "ok" ]      && _venv_needs_work=true
[ "${COMP_STATUS[huggingface_hub]}" != "ok" ] && _venv_needs_work=true
[ "${RUN_MODE:-install}" = "reinstall" ]     && _venv_needs_work=true
[ "${RUN_MODE:-install}" = "update" ]        && _venv_needs_work=true

if $_venv_needs_work; then

  case "${RUN_MODE:-install}" in
    update)    _MODE_DESC="Csomagok frissítése" ;;
    reinstall) _MODE_DESC="Venv újratelepítése" ;;
    *)         _MODE_DESC="Venv + csomagok telepítése" ;;
  esac

  dialog_yesno "5/7 — $_MODE_DESC" "
  Virtuális környezet: $VENV_DIR
  Python: $PY_VER (pyenv)

  Telepítendő csomag csoportok:
    API layer:       FastAPI, uvicorn, pydantic v2, sqlmodel, httpx
    LLM kliensek:    openai, anthropic, langchain, langgraph
    HuggingFace:     transformers, datasets, safetensors, peft, accelerate
    Adattudomány:    numpy, pandas, polars, scipy, sklearn, matplotlib
    Fejlesztő:       ruff, mypy, pytest, pre-commit, ipython
    JupyterLab:      jupyterlab 4.x, ipywidgets, ipykernel (ai kernel)
    Utility:         rich, typer, loguru, tenacity, psutil, pillow

  FONTOS: PyTorch külön lépésben települ (6. lépés, ~3 GB)!
  Becsült idő: ~3-8 perc

  Folytatjuk?" 30 || { ((SKIP++)); goto_step_6=false; }

  if [ "${goto_step_6:-true}" = "true" ]; then
    log "STEP" "5/7 AI/ML venv + csomagok..."

    # Reinstall esetén töröljük a régi venvet
    if [ "${RUN_MODE:-install}" = "reinstall" ] && [ -d "$VENV_DIR" ]; then
      log "INFO" "Reinstall: régi venv törlése: $VENV_DIR"
      rm -rf "$VENV_DIR"
    fi

    if [ ! -d "$VENV_DIR" ]; then
      log "INFO" "Venv létrehozása: $VENV_DIR (Python $PY_VER)"
      mkdir -p "$(dirname "$VENV_DIR")"
      su - "$_REAL_USER" -c \
        "$VENV_UV venv '$VENV_DIR' --python '$PY_BIN'" \
        >> "$LOGFILE_AI" 2>&1
    fi

    # Összes csomag összegyűjtése
    ALL_PKGS=(
      "${AI_PKGS_API[@]}"
      "${AI_PKGS_LLM[@]}"
      "${AI_PKGS_HF[@]}"
      "${AI_PKGS_DATA[@]}"
      "${AI_PKGS_DEV[@]}"
      "${AI_PKGS_JUPYTER[@]}"
      "${AI_PKGS_UTIL[@]}"
    )
    log "INFO" "Összes telepítendő csomag: ${#ALL_PKGS[@]} db"

    # --upgrade flag update módban
    UV_FLAGS=""
    [ "${RUN_MODE:-install}" = "update" ] && UV_FLAGS="--upgrade"

    su - "$_REAL_USER" -c \
      "$VENV_UV pip install $UV_FLAGS --python '$VENV_PY' ${ALL_PKGS[*]}" \
      >> "$LOGFILE_AI" 2>&1 &
    UV_PID=$!

    progress_open "AI/ML csomagok telepítése" \
      "uv pip install ${#ALL_PKGS[@]} csomag..."
    i=5
    while kill -0 $UV_PID 2>/dev/null; do
      progress_set "$i" "AI/ML csomagok telepítése (${#ALL_PKGS[@]} csomag, ~3-8 perc)..."
      sleep 2
      [ $i -lt 90 ] && ((i+=3))
    done
    progress_close
    wait $UV_PID; PKGS_EC=$?

    if [ $PKGS_EC -ne 0 ]; then
      ((FAIL++))
      log "FAIL" "Csomag telepítés sikertelen (exit $PKGS_EC)"
    else
      ((OK++))
      log "OK" "AI/ML csomag stack telepítve (${#ALL_PKGS[@]} csomag)"
    fi

    # JupyterLab kernel regisztráció
    # JUPYTER_DATA_DIR kényszere: sudo kontextusban --user /root-ba írna!
    # Forrás: https://ipython.readthedocs.io/en/stable/install/kernel_install.html
    log "INFO" "JupyterLab AI kernel regisztráció..."
    su - "$_REAL_USER" -c \
      "JUPYTER_DATA_DIR='$_REAL_HOME/.local/share/jupyter'
       '$VENV_PY' -m ipykernel install \
         --user \
         --name aiml \
         --display-name 'Python 3.12 (AI/ML)'" \
      >> "$LOGFILE_AI" 2>&1

    chown -R "$_REAL_USER:$_REAL_USER" \
      "$_REAL_HOME/.local/share/jupyter" 2>/dev/null || true
    log "OK" "JupyterLab kernel 'Python 3.12 (AI/ML)' regisztrálva"

    # Venv tulajdonos korrekció (sudo futtatás esetén root-ra kerülhet)
    chown -R "$_REAL_USER:$_REAL_USER" "$VENV_DIR" 2>/dev/null || true
    chown -R "$_REAL_USER:$_REAL_USER" "$_REAL_HOME/AI-VIBE" 2>/dev/null || true
  fi
fi

# =============================================================================
# ██  6. PYTORCH — CUDA VERZIÓS TELEPÍTÉS  ██
# =============================================================================
# PYTORCH_INDEX az infra state-ből (01a + cuda_pytorch_index() állítja):
#   cu126 → CUDA 12.6 | cu128 → CUDA 12.8 / 13.x | cpu → iGPU
#
# FIGYELMEZTETÉS: cuda.is_available() REBOOT ELŐTT False értéket adhat!
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

  Csomagok: torch + torchvision + torchaudio
  Index URL: $TORCH_INDEX_URL

  Letöltési méret: $TORCH_SIZE_EST
  Ez a leghosszabb lépés (~5-20 perc internet sebességtől függően).

  $([ "$PYTORCH_INDEX" != "cpu" ] && echo "CUDA ellenőrzés REBOOT UTÁN:
    source $VENV_DIR/bin/activate
    python -c 'import torch; print(torch.cuda.is_available())'
  Várható: True (most False lehet — NORMÁLIS!)" \
  || echo "CPU-only telepítés (iGPU profil).")

  Folytatjuk?" 26 || { ((SKIP++)); goto_step_7=false; }

  if [ "${goto_step_7:-true}" = "true" ]; then
    log "STEP" "6/7 PyTorch telepítése: ${PYTORCH_INDEX} ($TORCH_INDEX_URL)"

    UV_FLAGS=""
    [ "${RUN_MODE:-install}" = "update" ] && UV_FLAGS="--upgrade"

    su - "$_REAL_USER" -c \
      "$VENV_UV pip install $UV_FLAGS \
        --python '$VENV_PY' \
        $TORCH_PKGS \
        --index-url '$TORCH_INDEX_URL'" \
      >> "$LOGFILE_AI" 2>&1 &
    TORCH_PID=$!

    progress_open "PyTorch ${PYTORCH_INDEX} telepítése" \
      "torch + torchvision + torchaudio ($TORCH_SIZE_EST)..."
    i=2
    while kill -0 $TORCH_PID 2>/dev/null; do
      progress_set "$i" "PyTorch ${PYTORCH_INDEX} letöltése ($TORCH_SIZE_EST, ~5-20 perc)..."
      sleep 5
      [ $i -lt 88 ] && ((i++))
    done
    progress_close
    wait $TORCH_PID; TORCH_EC=$?

    if [ $TORCH_EC -ne 0 ]; then
      ((FAIL++))
      dialog_warn "PyTorch — Telepítési hiba" \
        "\n  PyTorch telepítés sikertelen (exit $TORCH_EC).\n\n  Részletek: $LOGFILE_AI\n\n  Lehetséges ok:\n  • Internet kapcsolat hiba\n  • Inkompatibilis PYTORCH_INDEX: $PYTORCH_INDEX" 16
    else
      TORCH_VER=$("$VENV_PY" -c \
        "import torch; print(torch.__version__)" 2>/dev/null || echo "ismeretlen")
      ((OK++))
      log "OK" "PyTorch telepítve: $TORCH_VER ($PYTORCH_INDEX)"
      infra_state_set "INST_TORCH_VER" "$TORCH_VER"

      dialog_msg "✓ PyTorch — Telepítve" "
  ✓  PyTorch $TORCH_VER (${PYTORCH_INDEX})

  CUDA ellenőrzés (REBOOT UTÁN futtatandó!):
    source $VENV_DIR/bin/activate
    python -c 'import torch; print(torch.cuda.is_available())'
    python -c 'import torch; print(torch.cuda.get_device_name(0))'

  $([ "$PYTORCH_INDEX" != "cpu" ] && \
    echo "Várható: True (most False lehet — normális!)" || \
    echo "CPU-only mód: cuda.is_available() = False (normális!)")" 18
    fi
  fi
fi

# =============================================================================
# ██  7. PROJEKT TEMPLATE  ██
# =============================================================================

_tmpl_needs_install=false
[ "${COMP_STATUS[template]}" != "ok" ] && _tmpl_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _tmpl_needs_install=true
[ "${RUN_MODE:-install}" = "update" ] && _tmpl_needs_install=true

if $_tmpl_needs_install; then
  dialog_yesno "7/7 — Projekt template" "
  Python AI projekt template létrehozása:
    $TEMPLATE_DIR/

  Tartalom:
    pyproject.toml         — ruff, black, mypy, pytest, isort konfig
    .env.example           — API kulcsok mintája
    .cursorrules           — Cursor/Claude AI coding instrukciók
    .vscode/settings.json  — VS Code Python konfiguráció
    .pre-commit-config.yaml — pre-commit hook konfiguráció

  Folytatjuk?" 18 || { ((SKIP++)); goto_end=false; }

  if [ "${goto_end:-true}" = "true" ]; then
    log "STEP" "7/7 Projekt template generálása..."
    mkdir -p "$TEMPLATE_DIR/.vscode"
    chown -R "$_REAL_USER:$_REAL_USER" "$_REAL_HOME/templates" 2>/dev/null || true

    # ── pyproject.toml ────────────────────────────────────────────────────────
    cat > "$TEMPLATE_DIR/pyproject.toml" << 'TOML_EOF'
# =============================================================================
# pyproject.toml — Python AI/ML projekt konfiguráció
# Generálta: vibe-coding-infra 03_python_aiml.sh v6.2
# Python: 3.12+ | Stack: PyTorch, FastAPI, LangChain, HuggingFace
# =============================================================================

[project]
name = "ai-project"
version = "0.1.0"
description = "AI/ML projekt leírása"
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
ignore = [
  "ANN101",  # self annotáció nem szükséges
  "ANN102",  # cls annotáció nem szükséges
  "B008",    # FastAPI Depends() OK
]

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

    # ── .env.example ──────────────────────────────────────────────────────────
    cat > "$TEMPLATE_DIR/.env.example" << 'ENV_EOF'
# =============================================================================
# .env.example — API kulcsok és konfiguráció minta
# Másold .env-be és töltsd ki! (.env SOHA nem kerül git-be!)
# =============================================================================

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

    # ── .cursorrules ──────────────────────────────────────────────────────────
    cat > "$TEMPLATE_DIR/.cursorrules" << CURSOR_EOF
# =============================================================================
# .cursorrules — AI pair programming irányelvek
# Generálta: vibe-coding-infra 03_python_aiml.sh v6.2
# Stack: Python 3.12 + PyTorch ${PYTORCH_INDEX} + LangChain + HuggingFace + FastAPI
# =============================================================================

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

    # ── .vscode/settings.json ─────────────────────────────────────────────────
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

    # ── .pre-commit-config.yaml ───────────────────────────────────────────────
    cat > "$TEMPLATE_DIR/.pre-commit-config.yaml" << 'PRECOMMIT_EOF'
# pre-commit hook konfiguráció
# Telepítés: pre-commit install (venv aktiválás után)
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
# ██  LEZÁRÁS — STATE, LOCK, ÖSSZEFOGLALÁS  ██
# =============================================================================

# ── INFRA state frissítés ─────────────────────────────────────────────────────
# MOD_03_DONE=true → 02_local_ai_stack.sh infra_require("03") ellenőrzi
# Legalább egy sikeres lépés VAGY nulla hiba esetén true-ra állítjuk.
# fix módban is beállítjuk — a javítás sikeres komponensek esetén érvényes.
if [ "$FAIL" -eq 0 ] || [ "$OK" -gt 0 ]; then
  infra_state_set "MOD_03_DONE" "true"
  log "STATE" "MOD_03_DONE=true — 02_local_ai_stack.sh futtatható"
else
  log "WARN" "Hibák miatt MOD_03_DONE nem lett true-ra állítva (OK=$OK FAIL=$FAIL)"
fi

# Lock fájl törlése
rm -f "$LOCK_FILE"

# ── Végeredmény összesítő ─────────────────────────────────────────────────────
show_result "$OK" "$SKIP" "$FAIL"

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
  ── Log: $LOGFILE_AI" 30
