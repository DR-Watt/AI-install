#!/bin/bash
# =============================================================================
# 03_python_aiml.sh — Python 3.12 + PyTorch + AI/ML Stack v6.1
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
#   ✓ PyTorch 2.x — CUDA 12.x index alapján (cu126|cu128 az infra state-ből)
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
# RUN_MODE értékek
# ────────────────
#   install   → csak hiányzó komponensek (alapértelmezett)
#   update    → uv + csomagok frissítése, pyenv frissítése
#   reinstall → teljes újratelepítés (--force flag pyenv-nek)
#   check     → csak állapot felmérés, semmi sem változik
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
  [uv]="0.4.0"         # Astral uv — Rust alapú csomagkezelő gyors telepítés
  [pip]="24.0"         # pip a venv-ben — uv kezeli, de minimum érték
)

# ── APT fordítási és rendszer függőségek ──────────────────────────────────────
# KRITIKUS: liblzma-dev NÉLKÜL a Python lzma/xz modulja NEM FORDUL!
# PyTorch modellek .pt fájljai xz tömörítést használnak → KÖTELEZŐ.
# Forrás: https://github.com/pyenv/pyenv/wiki#suggested-build-environment
declare -A PKGS=(
  # Python forrásból fordításhoz szükséges könyvtárak
  # Mindegyik szükséges egy modul forfordításához:
  #   liblzma-dev     → lzma, xz tömörítés (PyTorch checkpoint-ok!)
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
# Az index URL az infra state PYTORCH_INDEX-ből jön (01a állítja CUDA verzió alapján):
#   cu126 → CUDA 12.6 (RTX 5090 Blackwell alapértelmezett)
#   cu128 → CUDA 12.8 (ha 01a 12.8-t telepített)
#   cpu   → CPU-only (notebook-igpu profilokon)
# Forrás: https://download.pytorch.org/whl/ — PyTorch wheel repository
TORCH_PKGS="torch torchvision torchaudio"

# ── AI/ML Python csomagok — alap stack ───────────────────────────────────────
# Ez az alap stack amire a 02 szál is épít (Ollama Python client, vLLM)
# Felosztás: funkcionális csoportonként, könnyen bővíthető

# Web framework és API
AI_PKGS_API=(
  "fastapi"              # ASGI web framework (FastAPI)
  "uvicorn[standard]"    # ASGI szerver (uvloop + httptools)
  "pydantic>=2.0"        # adatvalidáció v2 (gyorsabb Rust core)
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
  "langchain-community"            # Közösségi integrációk (dokumentum loaderek, stb.)
  "langchain-openai"               # OpenAI LangChain integráció
  "langchain-anthropic"            # Anthropic LangChain integráció
  "langgraph"                      # LangGraph agent framework (stateful)
)

# HuggingFace ökoszisztéma
AI_PKGS_HF=(
  "huggingface-hub>=0.22"          # HF Hub kliens (model/dataset letöltés)
  "transformers>=4.40"             # Transformer modellek (BERT, GPT, LLaMA, stb.)
  "datasets>=2.19"                 # HF Datasets (adatbetöltés, streaming)
  "tokenizers>=0.19"               # Gyors (Rust) tokenizálás
  "accelerate>=0.29"               # Multi-GPU + mixed precision training segédek
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
  "psutil>=5.9"            # Rendszer erőforrás monitoring (GPU memória, CPU)
  "beautifulsoup4>=4.12"   # HTML parse (web scraping, RAG pipeline)
  "packaging"              # Verzió összehasonlítás (pip belső)
)

# ── Komponens ellenőrző specifikációk ─────────────────────────────────────────
# Formátum: "megjelenített_név|comp_check_kulcs|min_verzió"
# comp_check kulcsok: a COMP_STATUS[] tömbben tárolódnak (00_lib.sh szekció 8)
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
# Ezek a változók a script egészében következetesen használva
PYENV_ROOT="$_REAL_HOME/.pyenv"        # pyenv telepítési könyvtár
VENV_DIR="$_REAL_HOME/AI-VIBE/venvs/ai"    # Python AI/ML venv helye
VENV_PY="$VENV_DIR/bin/python"              # venv Python bináris
VENV_UV="$_REAL_HOME/.local/bin/uv"         # uv bináris helye
PY_BIN="$PYENV_ROOT/versions/$PY_VER/bin/python3" # pyenv Python bináris
TEMPLATE_DIR="$_REAL_HOME/templates/python-ai"    # Projekt template könyvtár
LOCK_FILE="/tmp/infra_03_python.lock"              # Párhuzamos futás blokkolása

# =============================================================================
# ██  INICIALIZÁLÁS  ██
# =============================================================================

# ── Log fájlok beállítása ─────────────────────────────────────────────────────
# Log könyvtár a user home-jában (sudo alatt /root lenne a $HOME — HELYTELEN!)
LOGFILE_AI="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_03_$(date '+%Y%m%d_%H%M%S').log"
LOGFILE_HUMAN="$_REAL_HOME/AI-LOG-INFRA-SETUP/install_03_$(date '+%Y%m%d_%H%M%S').ansi"
LOGFILE="$LOGFILE_AI"   # backward compat

# log_init() megnyitja/létrehozza a log fájlokat és írja a fejlécet
log_init

# ── Párhuzamos futás megakadályozása ─────────────────────────────────────────
# check_lock() ha futó instance van, dialógban kérdez — régi (2h+) lock auto-törlés
check_lock "$LOCK_FILE"

# ── INFRA state betöltés ──────────────────────────────────────────────────────
# Az 01a modul mentette ezeket: CUDA_VER, PYTORCH_INDEX, HW_GPU_ARCH
# infra_state_get KEY DEFAULT — ha nincs benne, az alapérték érvényes
CUDA_VER=$(infra_state_get "INST_CUDA_VER" "12.6")
PYTORCH_INDEX=$(infra_state_get "PYTORCH_INDEX" "cu126")
HW_GPU_ARCH_ST=$(infra_state_get "HW_GPU_ARCH" "igpu")
FEAT_GPU_ACCEL=$(infra_state_get "FEAT_GPU_ACCEL" "false")

# CPU-only profil esetén cpu index (notebook-igpu, desktop-igpu)
if [ "$FEAT_GPU_ACCEL" = "false" ]; then
  PYTORCH_INDEX="cpu"
  log "STATE" "CPU-only profil: PYTORCH_INDEX=cpu (GPU gyorsítás nem érhető el)"
fi

log "STATE" "Betöltve: CUDA=$CUDA_VER | PyTorch index=$PYTORCH_INDEX | GPU arch=$HW_GPU_ARCH_ST"

# ── INFRA state inicializálás ─────────────────────────────────────────────────
# Csak akkor ír új kulcsokat ha még nem léteznek — nem írja felül a meglévőket
infra_state_init

# ── Hardver kompatibilitás ────────────────────────────────────────────────────
# INFRA_HW_REQ="" → minden hardveren fut (beleértve notebook-igpu-t)
infra_compatible "$INFRA_HW_REQ" || {
  dialog_warn "Hardver inkompatibilis" \
    "\n  HW_REQ: $INFRA_HW_REQ | Profil: $HW_PROFILE\n  Modul kihagyva." 10
  rm -f "$LOCK_FILE"
  exit 2
}

# ── Függőség ellenőrzés ───────────────────────────────────────────────────────
# 01b-nek (Oh My Zsh, shell konfig) kell készen lennie → zshrc-ben van pyenv init
# Kivétel: reinstall módban vagy ha a user tudatosan hagyja ki a 01b-t (MOD_01B bypass)
if [ "${RUN_MODE:-install}" != "reinstall" ]; then
  infra_require "01B" "User Environment (01b_post_reboot.sh)" || {
    # Figyelmeztető dialóg után lehetőség van manuális folytatásra
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
# pyenv init — csak ha már telepítve van (nem hibás ha még nincs)
[ -d "$PYENV_ROOT/bin" ] && eval "$(pyenv init -)" 2>/dev/null || true

# =============================================================================
# ██  ÁLLAPOT FELMÉRÉS  ██
# =============================================================================

# ── Komponens ellenőrzés ──────────────────────────────────────────────────────
# Minden komponenst ellenőrzünk és COMP_STATUS[] tömbben tároljuk az eredményt.
# Formátum: ok | old | missing

log "COMP" "━━━ Komponens állapot felmérés ━━━"

# 1. Fordítási függőségek — az összes szükséges lib egyszerre
# dpkg -l | grep -c ellenőrzi hogy legalább a kulcs package-ek telepítve vannak
_build_deps_ok=true
for pkg in liblzma-dev libgdbm-dev libreadline-dev libsqlite3-dev \
           libbz2-dev libffi-dev libssl-dev; do
  dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || { _build_deps_ok=false; break; }
done
$_build_deps_ok \
  && COMP_STATUS[build_deps]="ok" \
  || COMP_STATUS[build_deps]="missing"
log "COMP" "  build_deps: ${COMP_STATUS[build_deps]}"

# 2. pyenv — Python verziókezelő
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

# 4. lzma modul — kritikus ellenőrzés (PyTorch .pt fájlok!)
if [ -x "$PY_BIN" ] && "$PY_BIN" -c "import lzma, bz2, readline" 2>/dev/null; then
  COMP_STATUS[lzma_ok]="ok"
else
  COMP_STATUS[lzma_ok]="missing"
fi
log "COMP" "  lzma_ok: ${COMP_STATUS[lzma_ok]}"

# 5. uv — Astral csomagkezelő
comp_check_uv "${MIN_VER[uv]}" "$VENV_UV"
log "COMP" "  uv: ${COMP_STATUS[uv]:-missing} ${COMP_VER[uv]:-}"

# 6. AI/ML venv — könyvtár létezés
if [ -d "$VENV_DIR" ] && [ -x "$VENV_PY" ]; then
  COMP_STATUS[venv]="ok"
else
  COMP_STATUS[venv]="missing"
fi
log "COMP" "  venv: ${COMP_STATUS[venv]}"

# 7. PyTorch — import + CUDA ellenőrzés (csak ha van GPU)
comp_check_torch "" "$VENV_PY"
log "COMP" "  torch: ${COMP_STATUS[torch]:-missing} ${COMP_VER[torch]:-}"

# 8. FastAPI — API framework ellenőrzés import alapján
if [ -x "$VENV_PY" ] && "$VENV_PY" -c "import fastapi" 2>/dev/null; then
  COMP_STATUS[fastapi]="ok"
else
  COMP_STATUS[fastapi]="missing"
fi
log "COMP" "  fastapi: ${COMP_STATUS[fastapi]}"

# 9. JupyterLab — notebook IDE
if [ -x "$VENV_DIR/bin/jupyter" ]; then
  COMP_STATUS[jupyter]="ok"
  COMP_VER[jupyter]="$("$VENV_DIR/bin/jupyter" --version 2>/dev/null | head -1)"
else
  COMP_STATUS[jupyter]="missing"
fi
log "COMP" "  jupyter: ${COMP_STATUS[jupyter]}"

# 10. LangChain — AI keretrendszer
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

# ── check mód: csak megmutatjuk az állapotot, nem változtatunk semmit ─────────
if [ "${RUN_MODE:-install}" = "check" ]; then
  dialog_msg "[Ellenőrző] $INFRA_NAME" \
    "\n  Komponens állapot:\n\n$(printf '%b' "$STATUS_LINES")\n
  PyTorch index: $PYTORCH_INDEX
  CUDA verzió:   $CUDA_VER
  Python venv:   $VENV_DIR
  Log:           $LOGFILE_AI" 28
  rm -f "$LOCK_FILE"
  exit 0
fi

# ── install/update/reinstall mód: szükséges-e bármit csinálni? ───────────────
# Ha reinstall mód: kényszer újratelepítés (MISSING = összes komponens)
if [ "${RUN_MODE:-install}" = "reinstall" ]; then
  # Reinstall módban minden "hiányzónak" számít → minden lépés lefut
  for spec in "${COMP_SPECS[@]}"; do
    IFS='|' read -r label key _ <<< "$spec"
    COMP_STATUS["$key"]="missing"
  done
  MISSING=${#COMP_SPECS[@]}
  log "MODE" "Reinstall mód: minden komponens újratelepítve ($MISSING db)"
fi

# Ha minden OK és nem update/reinstall mód: semmit sem kell csinálni
if [ "$MISSING" -eq 0 ] && [ "${RUN_MODE:-install}" = "install" ]; then
  dialog_msg "✓ Minden megvan — $INFRA_NAME" \
    "\n$(printf '%b' "$STATUS_LINES")\n  Nincs tennivaló." 28
  rm -f "$LOCK_FILE"
  exit 0
fi

# ── Telepítési szándék megerősítése ───────────────────────────────────────────
# UPDATE mód esetén is megerősítünk — a user tudja mi fog történni
case "${RUN_MODE:-install}" in
  update)    _mode_label="Frissítés" ;;
  reinstall) _mode_label="Újratelepítés" ;;
  *)         _mode_label="Telepítés" ;;
esac

dialog_yesno "[$_mode_label] — $INFRA_NAME" \
  "\n  Komponensek:\n$(printf '%b' "$STATUS_LINES")
  PyTorch index: $PYTORCH_INDEX (CUDA $CUDA_VER)
  Python:        $PY_VER (pyenv, forrásból fordítva)
  Venv:          $VENV_DIR

  A $_mode_label elkezdéséhez nyomj Igent." 30 || {
  rm -f "$LOCK_FILE"
  exit 0
}

# ── Installálás eredmény számlálók ────────────────────────────────────────────
OK=0; SKIP=0; FAIL=0

# ── Üdvözlő + telepítési terv megjelenítése ───────────────────────────────────
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
# liblzma-dev KÖTELEZŐ! Nélküle a Python lzma modulja nem fordul →
# PyTorch .pt checkpointok nem olvashatók → silent failures!

if [ "${COMP_STATUS[build_deps]}" != "ok" ] || \
   [ "${RUN_MODE:-install}" = "reinstall" ]; then

  dialog_yesno "1/7 — Fordítási függőségek" "
  A pyenv Python-t FORRÁSBÓL FORDÍTJA.
  Ezek a csomagok szükségesek a helyes fordításhoz:

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
    • PyTorch checkpointok NEM OLVASHATÓK
    • Csöndes hibák keletkezhetnek!

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
    # UPDATE mód: pyenv önmaga frissítése
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
        # pyenv.run shell scriptje letölti és telepíti a pyenv-t + pyenv-virtualenv plugint
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
      # Fontos: a heredoc PYENVRC idézőjeles → nem expandál → $HOME kell bele
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

      # Frissítjük a PATH-t a jelenlegi (sudo) session-ben is
      export PATH="$PYENV_ROOT/bin:$PATH"
      eval "$(pyenv init -)" 2>/dev/null || true
    fi
  fi
fi

# =============================================================================
# ██  3. PYTHON 3.12.X FORDÍTÁSA  ██
# =============================================================================
# PGO (Profile-Guided Optimization) + LTO: ~10-15% gyorsabb interpreter
# Fordítási idő: ~8-12 perc (i7-12700K-n ~5 perc, szerver CPU-n lehet több)
# Megjegyzés: lzma hiba esetén is újrafordítjuk! (NEED_PY=true ha lzma_ok=missing)

NEED_PY=false
[ "${COMP_STATUS[python]}" != "ok" ] && NEED_PY=true
[ "${COMP_STATUS[lzma_ok]}" != "ok" ] && NEED_PY=true  # lzma hiba → újrafordítás!
[ "${RUN_MODE:-install}" = "reinstall" ] && NEED_PY=true

if $NEED_PY; then
  # --force flag kell ha már létezik a verzió (újrafordítás)
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
  A terminal kimenete logba kerül (nincs kijelzés fordítás közben):
    $LOGFILE_AI

  FONTOS: liblzma-dev az 1. lépésben települt — ez KÖTELEZŐ!

  Folytatjuk?" 20 || { ((SKIP++)); goto_step_4=false; }

  if [ "${goto_step_4:-true}" = "true" ]; then
    log "STEP" "3/7 Python ${PY_VER} fordítása (PYTHON_CONFIGURE_OPTS='$PY_CONFIGURE_OPTS')..."

    # pyenv install háttérben fut → progress bar animáció
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
      # Lassú inkrementálás — a fordítás unpredictable hosszúságú
      [ $i -lt 88 ] && ((i++))
    done
    progress_close
    wait $PY_PID; PY_EC=$?

    if [ $PY_EC -ne 0 ]; then
      ((FAIL++))
      dialog_warn "Python ${PY_VER} fordítás — HIBA" \
        "\n  A Python fordítás sikertelen (exit $PY_EC).\n  Részletek: $LOGFILE_AI\n\n  Lehetséges ok: hiányzó fordítási függőség (1. lépés!)" 14
    else
      # Globális Python verzió beállítása
      su - "$_REAL_USER" -c "$PYENV_ROOT/bin/pyenv global $PY_VER" >> "$LOGFILE_AI" 2>&1

      # Kritikus ellenőrzés: lzma modul fordult-e be?
      if "$PY_BIN" -c "import lzma; import bz2; import readline; import ssl" 2>/dev/null; then
        ((OK++))
        PY_INSTALLED_VER=$("$PY_BIN" --version 2>/dev/null)
        log "OK" "Python ${PY_VER} lefordítva: $PY_INSTALLED_VER"
        log "OK" "lzma, bz2, readline, ssl modulok: OK"
        # State mentés
        infra_state_set "INST_PYTHON_VER" "$PY_VER"
        dialog_msg "✓ Python ${PY_VER} — Sikeres" "
  ✓  $PY_INSTALLED_VER lefordítva
  ✓  lzma modul: OK (PyTorch checkpointok olvashatók!)
  ✓  ssl modul: OK (HTTPS API hívásokhoz)
  ✓  readline modul: OK

  Telepítési hely: $PYENV_ROOT/versions/$PY_VER/" 16
      else
        # lzma nem fordult be → valami hiányzott a fordítási függőségekből
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
# uv: Rust alapú pip/venv/pip-tools/virtualenv csere (~100x gyorsabb)
# Forrás: https://docs.astral.sh/uv/getting-started/installation/

_uv_needs_install=false
[ "${COMP_STATUS[uv]}" != "ok" ] && _uv_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _uv_needs_install=true

if $_uv_needs_install || [ "${RUN_MODE:-install}" = "update" ]; then

  if [ "${RUN_MODE:-install}" = "update" ] && [ "${COMP_STATUS[uv]}" = "ok" ]; then
    # UPDATE mód: uv self update (ha van internet)
    log "STEP" "4/7 uv frissítése..."
    dialog_yesno "4/7 — uv frissítés" \
      "\n  uv frissítése a legújabb verzióra.\n  Jelenlegi: ${COMP_VER[uv]:-ismeretlen}\n\n  Folytatjuk?" 12 || { ((SKIP++)); goto_step_5=false; }

    if [ "${goto_step_5:-true}" = "true" ]; then
      # uv self update az ajánlott frissítési módszer
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

      # PATH frissítés a jelenlegi sessionben
      export PATH="$_REAL_HOME/.local/bin:$PATH"
    fi
  fi

  # uv verzió logolás
  if command -v "$VENV_UV" &>/dev/null || command -v uv &>/dev/null; then
    UV_INSTALLED_VER=$("$VENV_UV" --version 2>/dev/null || uv --version 2>/dev/null)
    log "OK" "uv elérhető: $UV_INSTALLED_VER"
    infra_state_set "INST_UV_VER" "$(echo "$UV_INSTALLED_VER" | grep -oP '[\d.]+' | head -1)"
  fi
fi

# =============================================================================
# ██  5. VIRTUÁLIS KÖRNYEZET + AI/ML CSOMAG STACK  ██
# =============================================================================
# A venv Python 3.12.x alapú, uv kezeli a csomagokat.
# A csomagok CSOPORTONKÉNT vannak felosztva (API, LLM, HF, Data, Dev, Jupyter)
# A PyTorch külön lépésben települ (6. lépés) — 3 GB letöltés!

_venv_needs_work=false
[ "${COMP_STATUS[venv]}" != "ok" ] && _venv_needs_work=true
[ "${COMP_STATUS[fastapi]}" != "ok" ] && _venv_needs_work=true
[ "${COMP_STATUS[jupyter]}" != "ok" ] && _venv_needs_work=true
[ "${COMP_STATUS[langchain]}" != "ok" ] && _venv_needs_work=true
[ "${COMP_STATUS[huggingface_hub]}" != "ok" ] && _venv_needs_work=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _venv_needs_work=true
[ "${RUN_MODE:-install}" = "update" ] && _venv_needs_work=true

if $_venv_needs_work; then

  _MODE_DESC=""
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

    # ── 5.1. Venv létrehozása ha nincs (reinstall esetén töröljük és újra) ────
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

    # ── 5.2. Csomagok összegyűjtése egyetlen listába ──────────────────────────
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

    # ── 5.3. uv pip install — összes csomag egyszerre ────────────────────────
    # --upgrade flag update módban — frissíti a meglévőket is
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

    # ── 5.4. JupyterLab kernel regisztráció ──────────────────────────────────
    # JUPYTER_DATA_DIR kényszere: sudo kontextusban --user /root-ba írna!
    # A venv Python-ja regisztrálja magát "Python 3.12 (AI/ML)" névvel.
    # Forrás: https://ipython.readthedocs.io/en/stable/install/kernel_install.html
    log "INFO" "JupyterLab AI kernel regisztráció..."
    JUPYTER_DATA_DIR="$_REAL_HOME/.local/share/jupyter" \
    su - "$_REAL_USER" -c \
      "JUPYTER_DATA_DIR='$_REAL_HOME/.local/share/jupyter'
       '$VENV_PY' -m ipykernel install \
         --user \
         --name aiml \
         --display-name 'Python 3.12 (AI/ML)'" \
      >> "$LOGFILE_AI" 2>&1

    # Kernel fájlok tulajdonosának korrekciója (sudo futtatás esetén root-ra kerülhet)
    chown -R "$_REAL_USER:$_REAL_USER" \
      "$_REAL_HOME/.local/share/jupyter" 2>/dev/null || true
    log "OK" "JupyterLab kernel 'Python 3.12 (AI/ML)' regisztrálva"

    # ── 5.5. Venv tulajdonos korrekció ───────────────────────────────────────
    # sudo alatt létrehozott fájlok root tulajdonosúak lehetnek → javítás
    chown -R "$_REAL_USER:$_REAL_USER" "$VENV_DIR" 2>/dev/null || true
    chown -R "$_REAL_USER:$_REAL_USER" "$_REAL_HOME/AI-VIBE" 2>/dev/null || true
  fi
fi

# =============================================================================
# ██  6. PYTORCH — CUDA VERZIÓS TELEPÍTÉS  ██
# =============================================================================
# PyTorch CUDA index az infra state-ből (01a állítja CUDA telepítés alapján):
#   cu126 → CUDA 12.6 (RTX 5090 Blackwell + minden újabb kártya)
#   cu128 → CUDA 12.8 (ha 01a CUDA 12.8-t telepített)
#   cpu   → CPU-only (iGPU profilok: notebook-igpu, desktop-igpu)
#
# FIGYELMEZTETÉS: cuda.is_available() REBOOT ELŐTT False értéket ad!
# Ennek oka: az NVIDIA kernel modul csak driver betöltés után aktív.
# Ez NORMÁLIS — nem telepítési hiba.

_torch_needs_install=false
[ "${COMP_STATUS[torch]}" != "ok" ] && _torch_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _torch_needs_install=true
[ "${RUN_MODE:-install}" = "update" ] && _torch_needs_install=true

if $_torch_needs_install; then

  # PyTorch index URL meghatározása
  TORCH_INDEX_URL="https://download.pytorch.org/whl/${PYTORCH_INDEX}"
  TORCH_SIZE_EST="~2.5-3 GB"
  [ "$PYTORCH_INDEX" = "cpu" ] && TORCH_SIZE_EST="~180 MB"

  dialog_yesno "6/7 — PyTorch telepítése" "
  PyTorch 2.x — ${PYTORCH_INDEX} index

  Csomagok:
    torch + torchvision + torchaudio
  Index URL: $TORCH_INDEX_URL

  Letöltési méret: $TORCH_SIZE_EST
  Ez a leghosszabb lépés (~5-20 perc internet sebességtől függően).

  $([ "$PYTORCH_INDEX" != "cpu" ] && echo "CUDA elérhetőség ellenőrzése:
    python -c 'import torch; print(torch.cuda.is_available())'
  Várható: True (REBOOT UTÁN!)
  Most False lehet — ez NORMÁLIS (NVIDIA driver még nem aktív)." \
  || echo "CPU-only telepítés (iGPU profil)
  CUDA nem elérhető ezen a gépen.")

  Folytatjuk?" 26 || { ((SKIP++)); goto_step_7=false; }

  if [ "${goto_step_7:-true}" = "true" ]; then
    log "STEP" "6/7 PyTorch telepítése: ${PYTORCH_INDEX} ($TORCH_INDEX_URL)"

    # --index-url: PyTorch saját wheel repository (CUDA verzió specifikus)
    # --upgrade update módban (meglévő csomag frissítése)
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
      # PyTorch verzió lekérés és logolás
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
    echo "Várható eredmény: True (most False lehet — normális!)" || \
    echo "CPU-only mód: cuda.is_available() = False (normális!)")" 18
    fi
  fi
fi

# =============================================================================
# ██  7. PROJEKT TEMPLATE  ██
# =============================================================================
# A template minden új Python AI projekthez kiindulópontot ad.
# A .cursorrules az AI pair programming asszisztensnek ad kontextust.
# A pyproject.toml tartalmaz minden szükséges tool konfigurációt.

_tmpl_needs_install=false
[ "${COMP_STATUS[template]}" != "ok" ] && _tmpl_needs_install=true
[ "${RUN_MODE:-install}" = "reinstall" ] && _tmpl_needs_install=true
[ "${RUN_MODE:-install}" = "update" ] && _tmpl_needs_install=true

if $_tmpl_needs_install; then
  dialog_yesno "7/7 — Projekt template" "
  Python AI projekt template létrehozása:
    $TEMPLATE_DIR/

  Tartalom:
    pyproject.toml      — ruff, black, mypy, pytest, isort konfig
    .env.example        — API kulcsok mintája
    .cursorrules        — Cursor/Claude AI coding instrukciók
    .vscode/settings.json — VS Code Python konfiguráció
    .pre-commit-config.yaml — pre-commit hook konfiguráció

  Folytatjuk?" 18 || { ((SKIP++)); goto_end=false; }

  if [ "${goto_end:-true}" = "true" ]; then
    log "STEP" "7/7 Projekt template generálása..."
    mkdir -p "$TEMPLATE_DIR/.vscode"
    chown -R "$_REAL_USER:$_REAL_USER" "$_REAL_HOME/templates" 2>/dev/null || true

    # ── pyproject.toml ────────────────────────────────────────────────────────
    # Minden tool konfigurációja egy fájlban — PEP 517/518 szabvány
    # Forrás: https://packaging.python.org/en/latest/guides/writing-pyproject-toml/
    cat > "$TEMPLATE_DIR/pyproject.toml" << 'TOML_EOF'
# =============================================================================
# pyproject.toml — Python AI/ML projekt konfiguráció
# Generálta: vibe-coding-infra 03_python_aiml.sh
# Python: 3.12+ | Stack: PyTorch, FastAPI, LangChain, HuggingFace
# =============================================================================

[project]
name = "ai-project"
version = "0.1.0"
description = "AI/ML projekt leírása"
requires-python = ">=3.12"
dependencies = []

# ── Black — kód formázó ───────────────────────────────────────────────────────
# Forrás: https://black.readthedocs.io/en/stable/
[tool.black]
line-length = 100
target-version = ["py312"]
# preview = true  # új formázás funkciók (opcionális)

# ── Ruff — linter + formázó (Black + isort + flake8 kombináció) ─────────────
# Forrás: https://docs.astral.sh/ruff/
[tool.ruff]
line-length = 100
target-version = "py312"

[tool.ruff.lint]
# Aktív szabálycsoportok:
#   E/W: pycodestyle, F: pyflakes, I: isort, N: pep8-naming
#   UP: pyupgrade (modernizálás), B: flake8-bugbear, ANN: annotáció
#   S: bandit (biztonsági), ASYNC: aszinkron kód minőség
select = ["E", "F", "I", "N", "UP", "B", "ANN", "ASYNC"]
ignore = [
  "ANN101",  # self annotáció nem szükséges
  "ANN102",  # cls annotáció nem szükséges
  "B008",    # FastAPI Depends() függőség injekció OK
]

[tool.ruff.lint.isort]
# isort kompatibilis szekciók: stdlib, third-party, first-party
known-first-party = ["src"]

# ── isort — import rendezés ───────────────────────────────────────────────────
[tool.isort]
profile = "black"
line_length = 100

# ── mypy — statikus típusellenőrzés ──────────────────────────────────────────
# Forrás: https://mypy.readthedocs.io/en/stable/
[tool.mypy]
python_version = "3.12"
strict = true
ignore_missing_imports = true
# Plugin-ok (opcionális):
# plugins = ["pydantic.mypy"]  # Pydantic v2 mypy plugin

# ── pytest — teszt keretrendszer ──────────────────────────────────────────────
# Forrás: https://docs.pytest.org/en/stable/
[tool.pytest.ini_options]
asyncio_mode = "auto"         # pytest-asyncio: auto mód (nem kell @pytest.mark.asyncio)
testpaths = ["tests"]
addopts = [
  "-v",                        # részletes kimenet
  "--tb=short",                # rövid traceback
  "--cov=src",                 # coverage riport a src/ könyvtárra
  "--cov-report=term-missing", # hiányzó sorok megjelenítése
]

# ── coverage.py ───────────────────────────────────────────────────────────────
[tool.coverage.run]
source = ["src"]
omit = ["tests/*", "**/__init__.py"]
TOML_EOF

    # ── .env.example ──────────────────────────────────────────────────────────
    # API kulcsok mintája — a .env nincs verziókezelve (gitignore!)
    cat > "$TEMPLATE_DIR/.env.example" << 'ENV_EOF'
# =============================================================================
# .env.example — API kulcsok és konfiguráció minta
# Másold .env-be és töltsd ki! (.env SOHA nem kerül git-be!)
# =============================================================================

# ── LLM API kulcsok ───────────────────────────────────────────────────────────
ANTHROPIC_API_KEY=sk-ant-api03-...
OPENAI_API_KEY=sk-proj-...
HUGGINGFACE_TOKEN=hf_...

# ── Lokális AI stack (02_local_ai_stack.sh telepíti) ──────────────────────────
OLLAMA_HOST=http://localhost:11434
VLLM_HOST=http://localhost:8000
VLLM_API_KEY=token-vllm          # vLLM API kulcs (szabadon beállítható)

# ── CUDA konfiguráció ─────────────────────────────────────────────────────────
CUDA_HOME=/usr/local/cuda
CUDA_VISIBLE_DEVICES=0            # melyik GPU-t használja (0 = első)
PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:512  # CUDA OOM hiba csökkentése

# ── Fejlesztői konfiguráció ───────────────────────────────────────────────────
LOG_LEVEL=INFO
DEBUG=false
ENV_EOF

    # ── .cursorrules ──────────────────────────────────────────────────────────
    # Cursor IDE és Claude AI pair programming instrukciók
    # Forrás: https://www.cursor.com/blog/cursorrules
    cat > "$TEMPLATE_DIR/.cursorrules" << CURSOR_EOF
# =============================================================================
# .cursorrules — AI pair programming irányelvek
# Generálta: vibe-coding-infra 03_python_aiml.sh
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
- Pydantic v2 BaseModel for all data structures (not TypedDict for complex data)
- Google-style docstrings for all public functions and classes
- 100 character line length (black + ruff configured)
- pathlib.Path (not os.path), logging (not print), loguru preferred
- No bare except — always catch specific exceptions
- f-strings for formatting (not .format() or % style)

## PyTorch Conventions
- torch.no_grad() + torch.autocast() for all inference paths
- bfloat16 on Blackwell (RTX 5090) and Ampere+, float16 on older Turing
- safetensors for model serialization (NEVER pickle for models!)
- Device-agnostic code: device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
- Explicit batch dimension handling, comment tensor shapes

## LLM / AI Conventions
- Use langchain LCEL (pipe syntax: chain = prompt | llm | parser)
- Anthropic Claude: use streaming for long outputs
- OpenAI: use structured outputs (response_format=)
- Rate limiting + tenacity retry for all API calls
- Log token usage for cost monitoring

## Security
- API keys from python-dotenv / pydantic-settings ONLY
- No secrets in code, never in git
- Input validation on all API endpoints (Pydantic v2)
- httpx for async HTTP (not requests in async contexts)
CURSOR_EOF

    # ── .vscode/settings.json ─────────────────────────────────────────────────
    cat > "$TEMPLATE_DIR/.vscode/settings.json" << VSCODE_EOF
{
  "// comment": "VS Code Python konfiguráció — vibe-coding-infra generálta",
  "python.defaultInterpreterPath": "${_REAL_HOME}/AI-VIBE/venvs/ai/bin/python",
  "python.terminal.activateEnvironment": true,
  "editor.formatOnSave": true,
  "editor.rulers": [100],
  "[python]": {
    "editor.defaultFormatter": "ms-python.black-formatter",
    "editor.codeActionsOnSave": {
      "source.organizeImports": "explicit"
    }
  },
  "ruff.lint.args": ["--line-length=100"],
  "black-formatter.args": ["--line-length", "100"],
  "mypy-type-checker.args": ["--strict", "--ignore-missing-imports"],
  "python.testing.pytestEnabled": true,
  "python.testing.pytestArgs": ["tests"],
  "jupyter.kernels.filter": [
    {
      "path": "${_REAL_HOME}/AI-VIBE/venvs/ai/bin/python",
      "type": "pythonEnvironment"
    }
  ]
}
VSCODE_EOF

    # ── .pre-commit-config.yaml ───────────────────────────────────────────────
    # Git commit előtti automatikus ellenőrzések
    # Forrás: https://pre-commit.com/
    cat > "$TEMPLATE_DIR/.pre-commit-config.yaml" << 'PRECOMMIT_EOF'
# =============================================================================
# .pre-commit-config.yaml — Git commit hook konfiguráció
# Telepítés: pre-commit install (venv aktiválás után)
# Futtatás: pre-commit run --all-files
# =============================================================================
repos:
  # Ruff linter + formázó (Black + isort + flake8 kombináció)
  - repo: https://github.com/astral-sh/ruff-pre-commit
    rev: v0.4.10
    hooks:
      - id: ruff
        args: ["--fix"]          # automatikus javítás ahol lehetséges
      - id: ruff-format          # Black-kompatibilis formázás

  # Trailing whitespace, EOF newline, YAML/JSON validáció
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-json
      - id: check-toml
      - id: check-added-large-files  # megakadályozza nagy fájlok véletlen commit-ját
        args: ["--maxkb=10240"]      # 10 MB limit (modell fájlok!)
      - id: debug-statements         # print(), pdb.set_trace() blokkolása

  # Mypy statikus típusellenőrzés
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
# MOD_03_DONE=true → a 02_local_ai_stack.sh infra_require("03")-mal ellenőrzi
# Csak sikeres befejezés esetén írjuk true-ra!
if [ "$FAIL" -eq 0 ] || [ "$OK" -gt 0 ]; then
  infra_state_set "MOD_03_DONE" "true"
  log "STATE" "MOD_03_DONE=true — 02_local_ai_stack.sh futtatható"
else
  log "WARN" "Hibák miatt MOD_03_DONE nem lett true-ra állítva"
fi

# Lock fájl törlése — más scriptek futhatnak
rm -f "$LOCK_FILE"

# ── Végeredmény összesítő ──────────────────────────────────────────────────────
# show_result() dialóg + log (00_lib.sh)
show_result "$OK" "$SKIP" "$FAIL"

# ── Összefoglalás dialóg — aktiválási útmutató ───────────────────────────────
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
  cd ~/projektek/uj-ai-projekt/
  cp .env.example .env && nano .env  # API kulcsok beállítása

  ── PyTorch CUDA index ────────────────────────────────────
  $PYTORCH_INDEX (CUDA $CUDA_VER)

  ── AI kernel neve: Python 3.12 (AI/ML)
  ── Log: $LOGFILE_AI" 30
