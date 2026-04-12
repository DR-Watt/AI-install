#!/bin/bash
# =============================================================================
# 09_ai_model_wrapper.sh — Vibe Coding Workspace — AI Model Manager
#
# TARTALOM:
#   Ollama model kezelés (lista, betöltés/eltávolítás VRAM-ból, letöltés)
#   vLLM szerver indítás/leállítás + RTX 5090 Blackwell SM_120 optimalizálás
#   TurboQuant integráció (GGUF kvantálás + Ollama Modelfile létrehozás)
#   CLINE + Continue.dev backend konfiguráció automatikus frissítése
#   GPU memória állapot megjelenítés
#
# KETTŐS ÜZEMMÓD:
#   INFRA mód (RUN_MODE=install|check|update|fix):
#     - Telepíti az ai-model-ctl wrapper szkriptet ~/bin/-be
#     - Létrehozza az alapértelmezett CLINE/Continue konfigot (Ollama)
#     - Létrehozza a vLLM systemd user service fájlját
#     - Menti a COMP_09_* state értékeket
#   Manage/standalone mód (RUN_MODE="" vagy RUN_MODE=manage):
#     - Interaktív YAD/whiptail menü: model, backend, TQ, IDE konfig
#     - Elérhető ai-model-ctl parancsként is telepítés után
#
# BETÖLTÉS:
#   source 00_lib.sh → betölti a lib/ split modulokat:
#     lib/00_lib_core.sh   — log, sudo, user, utility
#     lib/00_lib_compat.sh — GPU/OS/Driver/CUDA mátrix
#     lib/00_lib_hw.sh     — hardver detektálás
#     lib/00_lib_ui.sh     — YAD/whiptail dialógok
#     lib/00_lib_state.sh  — infra_state_*, infra_require, detect_run_mode
#     lib/00_lib_comp.sh   — comp_check_*, comp_save_state
#     lib/00_lib_apt.sh    — apt_install_*, run_with_progress
#
# FÜGGŐSÉG:
#   infra_require "02" — Ollama + vLLM + TurboQuant telepítve (02_local_ai_stack)
#   infra_require "06" — VS Code + CLINE + Continue.dev telepítve (06_editors)
#
# FUTTATÁS:
#   sudo bash 09_ai_model_wrapper.sh          → önállóan (manage mód)
#   RUN_MODE=install sudo bash 09_...         → INFRA telepítő mód
#   RUN_MODE=check   sudo bash 09_...         → komponens ellenőrzés
#   RUN_MODE=update  sudo bash 09_...         → frissítő mód
#   ai-model-ctl                              → parancssori alias (telepítés után)
#
# HIVATKOZOTT DOKUMENTÁCIÓK (DOCS.md alapján, hivatalos forrás):
#   Ollama API: https://ollama.readthedocs.io/en/api/
#     - GET  /api/tags          — telepített modellek listája
#     - GET  /api/ps            — VRAM-ban lévő modellek
#     - POST /api/generate      — model betöltés/eltávolítás (keep_alive)
#     - POST /api/pull          — model letöltés
#   vLLM CLI:  https://docs.vllm.ai/en/stable/cli/serve/
#     - vllm serve MODEL --dtype bfloat16 --gpu-memory-utilization 0.90
#     - Blackwell SM_120: CUDA 12.8+ kötelező, bfloat16 ajánlott
#   TurboQuant: https://github.com/0xSero/turboquant
#     - Python CLI: python -m turboquant.quantize --model ... --bits 3
#     - Ollama Modelfile: FROM /path/to/quantized.gguf
#   VS Code API: https://code.visualstudio.com/docs/configure/settings
#     - settings.json: ~/.config/Code/User/settings.json
#   Continue.dev: https://docs.continue.dev (DOCS.md nem listázza, de szükséges)
#     - ~/.continue/config.json (provider, model, apiBase)
#   CLINE: https://github.com/cline/cline (extension settings.json kulcsok)
#     - cline.apiProvider / cline.ollamaBaseUrl / cline.openAiBaseUrl stb.
#
# VERZIÓ: v1.0 (lib v6.5 kompatibilis)
# =============================================================================

# =============================================================================
# ALAP BETÖLTÉS
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 00_lib.sh: master loader — betölti az összes lib/ komponenst sorban:
#   core → compat → hw → ui → state → comp → apt
LIB="$SCRIPT_DIR/00_lib.sh"
[ -f "$LIB" ] && source "$LIB" || {
  echo "HIBA: 00_lib.sh hiányzik: $LIB"
  exit 1
}

# =============================================================================
# KONFIGURÁCIÓ — MINDEN PARAMÉTER ITT, A SCRIPT TETEJÉN
# =============================================================================
# Architektúra szabály: minden verziószám, URL, elérési út, portszám
# itt deklarált — a logika csak ezeket olvassa. Verziófrissítés = csak itt.

# ── Modul azonosítók ──────────────────────────────────────────────────────────
readonly MOD_ID="09"
readonly MOD_NAME="AI Model Manager"
readonly MOD_VERSION="1.0"
# Lib minimum verzió (00_lib.sh LIB_VERSION) — compat check
readonly MOD_LIB_MIN="6.5"

# ── Ollama konfiguráció ───────────────────────────────────────────────────────
# Forrás: https://ollama.readthedocs.io/en/api/ (official)
readonly OLLAMA_HOST="http://localhost:11434"
readonly OLLAMA_KEEP_ALIVE_LOAD="-1"   # keep_alive=-1 → modell a VRAM-ban marad
readonly OLLAMA_KEEP_ALIVE_UNLOAD="0"  # keep_alive=0  → azonnal kiejti VRAM-ból
# Ajánlott kódolás modellek (CLINE/Continue alapértelmezettje)
readonly OLLAMA_DEFAULT_CODE_MODEL="qwen2.5-coder:7b"
readonly OLLAMA_DEFAULT_CHAT_MODEL="qwen2.5:7b"
readonly OLLAMA_DEFAULT_EMBED_MODEL="nomic-embed-text"
readonly OLLAMA_DEFAULT_AUTOCOMPLETE="qwen2.5-coder:1.5b"

# ── vLLM konfiguráció ─────────────────────────────────────────────────────────
# Forrás: https://docs.vllm.ai/en/stable/cli/serve/ (official)
# RTX 5090 Blackwell SM_120: bfloat16 ajánlott (fp16 is OK, fp32 OOM)
# CUDA 12.8 minimum Blackwell-hez (docs.vllm.ai GPU install guide)
readonly VLLM_HOST="0.0.0.0"
readonly VLLM_PORT=8000
readonly VLLM_DTYPE="bfloat16"         # Blackwell SM_120 optimális
readonly VLLM_GPU_MEM_UTIL="0.90"      # 90% VRAM → RTX 5090 32GB-ból ~28.8GB
readonly VLLM_MAX_MODEL_LEN=16384      # context length (csökkentsd ha OOM)
readonly VLLM_SWAP_SPACE=4             # CPU swap GiB vLLM preemption-hoz
readonly VLLM_ENABLE_PREFIX_CACHE=1    # --enable-prefix-caching flag
# PID fájl: ki/bekapcsoláshoz
readonly VLLM_PID_FILE="/tmp/vllm-rtx5090.pid"
readonly VLLM_LOG_FILE="/tmp/vllm-rtx5090.log"

# ── TurboQuant konfiguráció ───────────────────────────────────────────────────
# Forrás: https://github.com/0xSero/turboquant (official reference impl)
# https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/
# Kvanálás: PolarQuant + QJL algoritmus, 3-bit KV cache tömörítés
readonly TQ_DIR="${_REAL_HOME}/src/turboquant"
readonly TQ_QUANTIZED_DIR="${_REAL_HOME}/.ollama/turboquant"  # GGUF kimenetek
readonly TQ_DEFAULT_BITS=4             # 4-bit súly kvantálás (3 is OK de lassabb)
readonly TQ_DEFAULT_GROUP_SIZE=128     # group size súly kvantáláshoz

# ── IDE elérési utak ──────────────────────────────────────────────────────────
# VS Code settings.json — sudo alatt _REAL_HOME kell (nem $HOME!)
# Forrás: https://code.visualstudio.com/docs/configure/settings (official)
readonly VSCODE_SETTINGS_FILE="${_REAL_HOME}/.config/Code/User/settings.json"
# Continue.dev konfiguráció
# Forrás: Continue.dev docs (DOCS.md-ben nincs listing, de ez a standard útvonal)
readonly CONTINUE_CONFIG_DIR="${_REAL_HOME}/.continue"
readonly CONTINUE_CONFIG_FILE="${CONTINUE_CONFIG_DIR}/config.json"
# CLINE API provider kulcs neve a settings.json-ban
# Forrás: CLINE extension README / settings schema (github.com/cline/cline)
readonly CLINE_PROVIDER_KEY="cline.apiProvider"
readonly CLINE_OLLAMA_URL_KEY="cline.ollamaBaseUrl"
readonly CLINE_OPENAI_URL_KEY="cline.openAiBaseUrl"
readonly CLINE_OPENAI_KEY_KEY="cline.openAiApiKey"
readonly CLINE_OPENAI_MODEL_KEY="cline.openAiModelId"
readonly CLINE_OLLAMA_MODEL_KEY="cline.apiModelId"

# ── Telepítési célok ──────────────────────────────────────────────────────────
# ai-model-ctl wrapper → a felhasználó PATH-jában elérhető helyre
readonly TOOL_INSTALL_DIR="${_REAL_HOME}/bin"
readonly TOOL_NAME="ai-model-ctl"
readonly TOOL_TARGET="${TOOL_INSTALL_DIR}/${TOOL_NAME}"
# vLLM systemd user service
readonly SYSTEMD_USER_DIR="${_REAL_HOME}/.config/systemd/user"
readonly VLLM_SERVICE_FILE="${SYSTEMD_USER_DIR}/vllm-rtx5090.service"
# vLLM venv elérési útja (02_local_ai_stack által létrehozva)
readonly AI_VENV_DIR="${_REAL_HOME}/venvs/ai"
readonly VENV_PYTHON="${AI_VENV_DIR}/bin/python3"
readonly VENV_VLLM="${AI_VENV_DIR}/bin/vllm"

# ── Logfájl ───────────────────────────────────────────────────────────────────
readonly LOG_PREFIX="09_ai_wrapper"
LOGFILE="${_REAL_HOME}/.infra-logs/${LOG_PREFIX}_$(date +%Y%m%d_%H%M%S).log"

# =============================================================================
# BELSŐ SEGÉDFÜGGVÉNYEK
# =============================================================================

# _is_ollama_running: Ollama systemd service fut-e?
# Visszatér: 0=fut, 1=nem fut
_is_ollama_running() {
  systemctl is-active --quiet ollama 2>/dev/null
}

# _is_vllm_running: vLLM szerver fut-e a konfigurált porton?
# Ellenőrzés: PID fájl + port foglaltság
# Forrás: ss(8) man oldal — socket statistics
_is_vllm_running() {
  if [ -f "$VLLM_PID_FILE" ]; then
    local pid
    pid="$(cat "$VLLM_PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  fi
  # Fallback: port check
  ss -tlnp 2>/dev/null | grep -q ":${VLLM_PORT}\b"
}

# _ollama_api: Ollama REST API hívás curl-lel
# Paraméterek: $1=HTTP metódus, $2=endpoint (pl. "/api/tags"), $3=JSON body
# Forrás: https://ollama.readthedocs.io/en/api/ (official)
_ollama_api() {
  local method="${1:-GET}" endpoint="${2:-/}" body="${3:-}"
  local url="${OLLAMA_HOST}${endpoint}"
  if [ -n "$body" ]; then
    curl -s --connect-timeout 5 -X "$method" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "$url" 2>/dev/null
  else
    curl -s --connect-timeout 5 -X "$method" "$url" 2>/dev/null
  fi
}

# _python3_user: python3 futtatása a felhasználó kontextusában
# A venv python-t használja ha elérhető, különben a rendszer python3-at
_python3_user() {
  if [ -x "$VENV_PYTHON" ]; then
    sudo -u "$_REAL_USER" -E "$VENV_PYTHON" "$@"
  else
    sudo -u "$_REAL_USER" python3 "$@"
  fi
}

# _json_field: egyszerű JSON mező kinyerés python3-mal
# Paraméterek: $1=JSON string, $2=mező neve (pl. "models")
_json_field() {
  local json="$1" field="$2"
  echo "$json" | python3 -c \
    "import json,sys; data=json.load(sys.stdin); print(data.get('$field',''))" \
    2>/dev/null
}

# =============================================================================
# KOMPONENS ELLENŐRZŐ FÜGGVÉNYEK
# =============================================================================

# _check_all_components: minden komponens állapotának felmérése
# Kimenet: COMP_STATUS / COMP_VER tömb feltöltése (lib/00_lib_comp.sh sémája)
_check_all_components() {
  # ── Ollama ───────────────────────────────────────────────────────────────
  # Forrás: https://ollama.readthedocs.io/en/api/ — 'ollama version' a CLI
  local ollama_ver
  ollama_ver=$(ollama version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  if [ -z "$ollama_ver" ]; then
    ollama_ver=$(ollama --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  fi
  if [ -z "$ollama_ver" ]; then
    COMP_STATUS[ollama]="missing"; COMP_VER[ollama]=""
  else
    COMP_STATUS[ollama]="ok"; COMP_VER[ollama]="$ollama_ver"
  fi

  # ── Ollama service állapot ────────────────────────────────────────────────
  if _is_ollama_running; then
    COMP_STATUS[ollama_svc]="ok"; COMP_VER[ollama_svc]="running"
  else
    COMP_STATUS[ollama_svc]="missing"; COMP_VER[ollama_svc]="stopped"
  fi

  # ── vLLM ─────────────────────────────────────────────────────────────────
  # Forrás: vllm --version CLI (docs.vllm.ai CLI reference, official)
  local vllm_ver=""
  if [ -x "$VENV_VLLM" ]; then
    vllm_ver=$(sudo -u "$_REAL_USER" "$VENV_VLLM" --version 2>/dev/null \
      | grep -oP '[\d.]+' | head -1)
  fi
  if [ -z "$vllm_ver" ]; then
    vllm_ver=$(sudo -u "$_REAL_USER" \
      "$VENV_PYTHON" -c "import vllm; print(vllm.__version__)" 2>/dev/null)
  fi
  if [ -z "$vllm_ver" ]; then
    COMP_STATUS[vllm]="missing"; COMP_VER[vllm]=""
  else
    COMP_STATUS[vllm]="ok"; COMP_VER[vllm]="$vllm_ver"
  fi

  # ── vLLM szerver állapot ──────────────────────────────────────────────────
  if _is_vllm_running; then
    COMP_STATUS[vllm_svc]="ok"; COMP_VER[vllm_svc]="port ${VLLM_PORT}"
  else
    COMP_STATUS[vllm_svc]="missing"; COMP_VER[vllm_svc]="stopped"
  fi

  # ── TurboQuant ───────────────────────────────────────────────────────────
  # Forrás: https://github.com/0xSero/turboquant (official ref impl)
  # Detektálás: Python csomag importálhatósága + forráskönyvtár meglétele
  local tq_ok=0
  if [ -d "$TQ_DIR" ]; then
    if _python3_user -c "import turboquant" 2>/dev/null; then
      tq_ok=1; COMP_STATUS[turboquant]="ok"; COMP_VER[turboquant]="src+pip"
    else
      tq_ok=1; COMP_STATUS[turboquant]="old"; COMP_VER[turboquant]="src-only"
    fi
  else
    COMP_STATUS[turboquant]="missing"; COMP_VER[turboquant]=""
  fi

  # ── CLINE konfig ─────────────────────────────────────────────────────────
  # Ellenőrzi hogy a settings.json-ban van-e cline.apiProvider kulcs
  if [ -f "$VSCODE_SETTINGS_FILE" ] && \
     grep -q "$CLINE_PROVIDER_KEY" "$VSCODE_SETTINGS_FILE" 2>/dev/null; then
    local current_provider
    current_provider=$(python3 -c "
import json, sys
try:
  d = json.load(open('$VSCODE_SETTINGS_FILE'))
  print(d.get('$CLINE_PROVIDER_KEY', ''))
except:
  print('')
" 2>/dev/null)
    COMP_STATUS[cline_cfg]="ok"
    COMP_VER[cline_cfg]="${current_provider:-?}"
  else
    COMP_STATUS[cline_cfg]="missing"; COMP_VER[cline_cfg]=""
  fi

  # ── Continue.dev konfig ───────────────────────────────────────────────────
  if [ -f "$CONTINUE_CONFIG_FILE" ]; then
    COMP_STATUS[continue_cfg]="ok"
    # Aktív provider kinyerése a konfig első modelljéből
    local cont_provider
    cont_provider=$(python3 -c "
import json, sys
try:
  d = json.load(open('$CONTINUE_CONFIG_FILE'))
  models = d.get('models', [])
  print(models[0].get('provider','?') if models else '?')
except:
  print('?')
" 2>/dev/null)
    COMP_VER[continue_cfg]="${cont_provider:-?}"
  else
    COMP_STATUS[continue_cfg]="missing"; COMP_VER[continue_cfg]=""
  fi

  # ── ai-model-ctl tool ─────────────────────────────────────────────────────
  if [ -f "$TOOL_TARGET" ] && [ -x "$TOOL_TARGET" ]; then
    COMP_STATUS[tool]="ok"; COMP_VER[tool]="$TOOL_NAME"
  else
    COMP_STATUS[tool]="missing"; COMP_VER[tool]=""
  fi
}

# _show_component_status: komponens állapot megjelenítése (whiptail / stdout)
_show_component_status() {
  local lines=()
  lines+=("$(comp_line "ollama"       "Ollama"              "0.5")")
  lines+=("$(comp_line "ollama_svc"   "Ollama service"      ""   )")
  lines+=("$(comp_line "vllm"         "vLLM"                "0.8")")
  lines+=("$(comp_line "vllm_svc"     "vLLM szerver"        ""   )")
  lines+=("$(comp_line "turboquant"   "TurboQuant"          ""   )")
  lines+=("$(comp_line "cline_cfg"    "CLINE konfig"        ""   )")
  lines+=("$(comp_line "continue_cfg" "Continue.dev konfig" ""   )")
  lines+=("$(comp_line "tool"         "ai-model-ctl"        ""   )")
  printf '%s\n' "${lines[@]}"
}

# =============================================================================
# OLLAMA MODEL KEZELŐ FÜGGVÉNYEK
# =============================================================================

# _ollama_list_installed: telepített modellek listája tömb formában
# Forrás: GET /api/tags — https://ollama.readthedocs.io/en/api/ (official)
_ollama_list_installed() {
  local response
  response=$(_ollama_api GET "/api/tags")
  if [ -z "$response" ]; then
    log "WARN" "Ollama API nem elérhető (fut-e az ollama service?)"
    echo ""
    return 1
  fi
  # Python JSON parse: models[].name tömb
  echo "$response" | python3 -c "
import json, sys
try:
  data = json.load(sys.stdin)
  for m in data.get('models', []):
    sz = m.get('size', 0)
    sz_gb = sz / 1e9
    print(f\"{m['name']}  ({sz_gb:.1f} GB)\")
except Exception as e:
  print(f'HIBA: {e}', file=sys.stderr)
" 2>/dev/null
}

# _ollama_list_running: VRAM-ban betöltött modellek
# Forrás: GET /api/ps — https://ollama.readthedocs.io/en/api/ (official)
_ollama_list_running() {
  local response
  response=$(_ollama_api GET "/api/ps")
  echo "$response" | python3 -c "
import json, sys
try:
  data = json.load(sys.stdin)
  models = data.get('models', [])
  if not models:
    print('(nincs betöltött modell)')
  for m in models:
    vram = m.get('size_vram', 0)
    vram_gb = vram / 1e9
    print(f\"{m['name']}  VRAM: {vram_gb:.1f} GB\")
except:
  print('(API hiba)')
" 2>/dev/null
}

# _ollama_load_model: modell betöltése VRAM-ba (keep_alive=-1)
# Forrás: POST /api/generate keep_alive=-1 — https://ollama.readthedocs.io/en/faq/ (official)
# Paraméter: $1=model neve (pl. "qwen2.5-coder:7b")
_ollama_load_model() {
  local model="$1"
  [ -z "$model" ] && { log "ERR" "model neve szükséges"; return 1; }
  log "INFO" "Ollama model betöltés: $model → VRAM (keep_alive=-1)"
  _ollama_api POST "/api/generate" \
    "{\"model\":\"${model}\",\"keep_alive\":${OLLAMA_KEEP_ALIVE_LOAD},\"stream\":false}" \
    > /dev/null
  log "INFO" "Betöltés kész: $model"
}

# _ollama_unload_model: modell kiürítése VRAM-ból (keep_alive=0)
# Forrás: POST /api/generate keep_alive=0 — https://ollama.readthedocs.io/en/faq/ (official)
# Paraméter: $1=model neve
_ollama_unload_model() {
  local model="$1"
  [ -z "$model" ] && { log "ERR" "model neve szükséges"; return 1; }
  log "INFO" "Ollama model eltávolítás VRAM-ból: $model (keep_alive=0)"
  _ollama_api POST "/api/generate" \
    "{\"model\":\"${model}\",\"keep_alive\":${OLLAMA_KEEP_ALIVE_UNLOAD},\"stream\":false}" \
    > /dev/null
  log "INFO" "VRAM-ból eltávolítva: $model"
}

# _ollama_pull_model: model letöltése az Ollama registry-ből
# Forrás: POST /api/pull — https://ollama.readthedocs.io/en/api/ (official)
# Paraméter: $1=model neve (pl. "llama3.3:70b")
_ollama_pull_model() {
  local model="$1"
  [ -z "$model" ] && return 1
  log "INFO" "Ollama pull: $model"
  # Streaming=false → egy JSON válasz jön vissza (könnyebb parse-olni)
  sudo -u "$_REAL_USER" ollama pull "$model" 2>&1 | \
    tee -a "$LOGFILE" | \
    dialog_progress "Ollama letöltés" "Model letöltése: $model" 20
}

# =============================================================================
# vLLM SZERVER KEZELŐ FÜGGVÉNYEK
# =============================================================================

# _vllm_build_args: vLLM szerver argumentumlista összeállítása
# RTX 5090 Blackwell SM_120 optimalizált beállítások
# Forrás: https://docs.vllm.ai/en/stable/cli/serve/ (official)
# Paraméterek: $1=model (HuggingFace model ID vagy lokális út)
_vllm_build_args() {
  local model="$1"
  local args=(
    "serve" "$model"
    "--host"                    "$VLLM_HOST"
    "--port"                    "$VLLM_PORT"
    "--dtype"                   "$VLLM_DTYPE"          # bfloat16 → Blackwell SM_120 optimális
    "--gpu-memory-utilization"  "$VLLM_GPU_MEM_UTIL"  # 0.90 → 90% VRAM
    "--max-model-len"           "$VLLM_MAX_MODEL_LEN" # 16384 token context
    "--swap-space"              "$VLLM_SWAP_SPACE"    # 4 GiB CPU swap
    "--trust-remote-code"                             # HuggingFace modelleknél szükséges
  )
  # Prefix caching: KV cache újrahasználat → gyorsabb CLINE/Continue válaszok
  [ "$VLLM_ENABLE_PREFIX_CACHE" = "1" ] && args+=("--enable-prefix-caching")
  echo "${args[@]}"
}

# _vllm_start: vLLM OpenAI-compatible szerver indítása háttérben
# Forrás: https://docs.vllm.ai/en/stable/cli/serve/ (official)
# Paraméter: $1=model ID/path
_vllm_start() {
  local model="$1"
  [ -z "$model" ] && { dialog_warn "vLLM" "Model neve szükséges!"; return 1; }

  if _is_vllm_running; then
    dialog_warn "vLLM" "vLLM már fut (port: ${VLLM_PORT})\nÁllítsd le előbb!"
    return 1
  fi

  if [ ! -x "$VENV_VLLM" ]; then
    dialog_warn "vLLM" "vLLM nem található: $VENV_VLLM\nFuttasd előbb a 02-es modult!"
    return 1
  fi

  log "INFO" "vLLM indítás: model=$model, port=$VLLM_PORT, dtype=$VLLM_DTYPE"
  log "INFO" "GPU mem util: ${VLLM_GPU_MEM_UTIL}, max_len: ${VLLM_MAX_MODEL_LEN}"

  # vLLM indítás: a felhasználó kontextusában, venv-ből, háttérben
  # Forrás: GPU install guide — Blackwell SM_120 = CUDA 12.8+ szükséges
  sudo -u "$_REAL_USER" bash -c "
    source '${AI_VENV_DIR}/bin/activate'
    nohup ${VENV_VLLM} $(IFS=' '; echo "$(_vllm_build_args "$model")") \
      >> '${VLLM_LOG_FILE}' 2>&1 &
    echo \$! > '${VLLM_PID_FILE}'
  "
  sleep 3  # Rövid várakozás: szerver inicializálás kezdete

  if _is_vllm_running; then
    log "INFO" "vLLM szerver elindult (PID: $(cat "$VLLM_PID_FILE" 2>/dev/null))"
    log "INFO" "API endpoint: http://localhost:${VLLM_PORT}/v1"
    return 0
  else
    log "ERR" "vLLM indítás sikertelen — log: $VLLM_LOG_FILE"
    return 1
  fi
}

# _vllm_stop: vLLM szerver leállítása
_vllm_stop() {
  if ! _is_vllm_running; then
    log "INFO" "vLLM már leállított"
    return 0
  fi
  local pid
  pid=$(cat "$VLLM_PID_FILE" 2>/dev/null)
  if [ -n "$pid" ]; then
    log "INFO" "vLLM leállítás: SIGTERM → PID $pid"
    kill -TERM "$pid" 2>/dev/null
    sleep 3
    # Ha még fut, SIGKILL
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    rm -f "$VLLM_PID_FILE"
  else
    # PID fájl hiányzik → port alapján keresés
    local found_pid
    found_pid=$(ss -tlnp 2>/dev/null | grep ":${VLLM_PORT}\b" | \
      grep -oP 'pid=\K\d+' | head -1)
    [ -n "$found_pid" ] && kill -TERM "$found_pid" 2>/dev/null
  fi
  log "INFO" "vLLM leállítva"
}

# _vllm_status_text: vLLM szerver állapot szöveges összefoglaló
_vllm_status_text() {
  if _is_vllm_running; then
    local pid
    pid=$(cat "$VLLM_PID_FILE" 2>/dev/null)
    echo "✓  vLLM fut   PID: ${pid:-?}   Port: ${VLLM_PORT}"
    # OpenAI-compatible /v1/models endpoint query
    local models_resp
    models_resp=$(curl -s --connect-timeout 3 \
      "http://localhost:${VLLM_PORT}/v1/models" 2>/dev/null)
    if [ -n "$models_resp" ]; then
      local served_model
      served_model=$(echo "$models_resp" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  models=[m['id'] for m in d.get('data',[])]
  print('  Model(ek): ' + ', '.join(models))
except: pass
" 2>/dev/null)
      [ -n "$served_model" ] && echo "$served_model"
    fi
  else
    echo "✗  vLLM leállított (port: ${VLLM_PORT} szabad)"
  fi
}

# =============================================================================
# TURBOQUANT INTEGRÁCIÓ
# =============================================================================
# Forrás: https://github.com/0xSero/turboquant (official reference implementation)
# https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/
#
# TurboQuant flow Ollama integrációhoz:
#   1. Python CLI: python -m turboquant.quantize --model X --bits N → .gguf fájl
#   2. Ollama Modelfile: FROM /path/to/output.gguf
#   3. ollama create <model-name>-tq4 -f Modelfile
#   4. ollama run <model-name>-tq4 → RTX 5090-en közvetlen GPU inference

# _tq_list_quantized: korábban kvantált modellek listája
_tq_list_quantized() {
  if [ ! -d "$TQ_QUANTIZED_DIR" ]; then
    echo "(nincs kvantált modell)"
    return
  fi
  find "$TQ_QUANTIZED_DIR" -name "*.gguf" -printf "%f  (%s bytes)\n" 2>/dev/null \
    | sort || echo "(üres könyvtár)"
}

# _tq_quantize_model: modell kvantálása TurboQuant-tal
# Paraméterek: $1=forrás modell (Ollama neve v. HF path), $2=bit mélység
# Kimenet: $TQ_QUANTIZED_DIR/<model>-tq${bits}.gguf
_tq_quantize_model() {
  local src_model="$1"
  local bits="${2:-$TQ_DEFAULT_BITS}"
  local safe_name
  safe_name=$(echo "$src_model" | tr '/:' '-')
  local out_gguf="${TQ_QUANTIZED_DIR}/${safe_name}-tq${bits}.gguf"
  local tq_log="${_REAL_HOME}/.infra-logs/tq_${safe_name}_$(date +%Y%m%d_%H%M%S).log"

  mkdir -p "$TQ_QUANTIZED_DIR"
  mkdir -p "$(dirname "$tq_log")"

  log "INFO" "TurboQuant kvantálás: $src_model → ${bits}-bit"
  log "INFO" "Kimenet: $out_gguf"
  log "INFO" "Log: $tq_log"

  # TurboQuant Python CLI hívás — venv Python-nal, user kontextusban
  # Forrás: github.com/0xSero/turboquant README (official usage)
  if ! sudo -u "$_REAL_USER" bash -c "
    source '${AI_VENV_DIR}/bin/activate'
    python3 -m turboquant.quantize \
      --model '${src_model}' \
      --bits ${bits} \
      --group-size ${TQ_DEFAULT_GROUP_SIZE} \
      --output '${out_gguf}' \
      2>&1 | tee '${tq_log}'
  "; then
    log "ERR" "TurboQuant kvantálás sikertelen — log: $tq_log"
    return 1
  fi

  # Ellenőrzés: GGUF fájl létrejött-e?
  if [ ! -f "$out_gguf" ]; then
    log "ERR" "GGUF kimenet nem jött létre: $out_gguf"
    return 1
  fi

  log "INFO" "TurboQuant kvantálás kész: $out_gguf"

  # Ollama Modelfile létrehozása a kvantált GGUF-hoz
  # Ollama Modelfile szintaxis: https://ollama.readthedocs.io/en/ (official)
  local modelfile="${TQ_QUANTIZED_DIR}/${safe_name}-tq${bits}.Modelfile"
  cat > "$modelfile" << MODELFILE_EOF
# TurboQuant ${bits}-bit kvantált modell Modelfile
# Forrás: ${src_model}
# Kvantálva: $(date '+%Y-%m-%d %H:%M')
# Algoritmus: PolarQuant + QJL (TurboQuant ICLR 2026)
# Célhardver: RTX 5090 Blackwell SM_120

FROM ${out_gguf}

PARAMETER num_gpu 99
PARAMETER num_thread 16

SYSTEM "TurboQuant ${bits}-bit kvantált modell (RTX 5090 optimalizált)"
MODELFILE_EOF

  chown "$_REAL_USER:$_REAL_USER" "$modelfile" "$out_gguf"

  log "INFO" "Modelfile: $modelfile"

  # Ollama modell regisztráció a Modelfile alapján
  local ollama_model_name="${safe_name}-tq${bits}"
  log "INFO" "Ollama modell létrehozás: $ollama_model_name"
  sudo -u "$_REAL_USER" ollama create "$ollama_model_name" -f "$modelfile" \
    >> "$tq_log" 2>&1

  if sudo -u "$_REAL_USER" ollama list 2>/dev/null | grep -q "$ollama_model_name"; then
    log "INFO" "Ollama modell regisztrálva: $ollama_model_name"
    echo "$ollama_model_name"  # visszaadjuk a nevet (IDE config-hoz)
  else
    log "WARN" "Ollama modell regisztráció sikertelen (manuálisan: ollama create $ollama_model_name -f $modelfile)"
    echo ""
    return 1
  fi
}

# =============================================================================
# IDE KONFIGURÁCIÓ FÜGGVÉNYEK
# =============================================================================
# CLINE és Continue.dev backend konfigurációja frissítése JSON merge-del

# _ide_update_settings: VS Code settings.json kulcs-érték beállítása (merge)
# Paraméterek: kulcs-érték párok asszociatív tömbből
# _REAL_HOME kell, mert sudo alatt $HOME=/root
_ide_update_settings() {
  local -n _settings_ref="$1"  # asszociatív tömb referencia
  local settings_file="$VSCODE_SETTINGS_FILE"

  # settings.json könyvtár létrehozása ha hiányzik
  sudo -u "$_REAL_USER" mkdir -p "$(dirname "$settings_file")"

  # Meglévő settings.json betöltése (ha nincs, üres dict-tel kezdünk)
  local existing="{}"
  [ -f "$settings_file" ] && existing=$(cat "$settings_file" 2>/dev/null)

  # Python merge: meglévő beállítások + új kulcsok
  # A többi kulcs (nem CLINE) érintetlen marad
  local update_json="{}"
  for key in "${!_settings_ref[@]}"; do
    local val="${_settings_ref[$key]}"
    update_json=$(echo "$update_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
d['$key'] = '$val'
print(json.dumps(d))
" 2>/dev/null)
  done

  # Merge: update_json beleolvad a meglévő settings-be
  local merged
  merged=$(python3 -c "
import json
existing = json.loads('''$existing''')
update   = json.loads('''$update_json''')
existing.update(update)
print(json.dumps(existing, indent=2, ensure_ascii=False))
" 2>/dev/null)

  if [ -z "$merged" ]; then
    log "ERR" "settings.json merge sikertelen"
    return 1
  fi

  # Írás a felhasználó kontextusában
  echo "$merged" | sudo -u "$_REAL_USER" tee "$settings_file" > /dev/null
  log "INFO" "settings.json frissítve: $settings_file"
}

# _ide_config_cline_ollama: CLINE → Ollama backend konfiguráció
# Forrás: CLINE extension settings schema (github.com/cline/cline)
# Paraméter: $1=Ollama model neve
_ide_config_cline_ollama() {
  local model="${1:-$OLLAMA_DEFAULT_CODE_MODEL}"
  log "INFO" "CLINE konfig → Ollama: $model"

  declare -A settings=(
    ["$CLINE_PROVIDER_KEY"]="ollama"
    ["$CLINE_OLLAMA_URL_KEY"]="$OLLAMA_HOST"
    ["$CLINE_OLLAMA_MODEL_KEY"]="$model"
  )
  _ide_update_settings settings
}

# _ide_config_cline_vllm: CLINE → vLLM (OpenAI-compatible) backend konfiguráció
# vLLM nyújt /v1/chat/completions OpenAI-compatible endpointot
# Forrás: CLINE settings schema — apiProvider="openai" + openAiBaseUrl
# Paraméter: $1=model neve (vLLM-ben kiszolgált model ID)
_ide_config_cline_vllm() {
  local model="${1:-}"
  log "INFO" "CLINE konfig → vLLM (OpenAI-compatible): port $VLLM_PORT"

  declare -A settings=(
    ["$CLINE_PROVIDER_KEY"]="openai"
    ["$CLINE_OPENAI_URL_KEY"]="http://localhost:${VLLM_PORT}/v1"
    ["$CLINE_OPENAI_KEY_KEY"]="dummy"       # vLLM nem igényel API key-t
    ["$CLINE_OPENAI_MODEL_KEY"]="${model}"
  )
  _ide_update_settings settings
}

# _ide_config_continue: Continue.dev config.json frissítése
# Forrás: Continue.dev docs — ~/.continue/config.json schema
# Paraméterek: $1=backend ("ollama"|"vllm"), $2=chat model, $3=autocomplete model
_ide_config_continue() {
  local backend="${1:-ollama}"
  local chat_model="${2:-$OLLAMA_DEFAULT_CODE_MODEL}"
  local autocomplete_model="${3:-$OLLAMA_DEFAULT_AUTOCOMPLETE}"
  local embed_model="$OLLAMA_DEFAULT_EMBED_MODEL"

  log "INFO" "Continue.dev konfig → $backend: chat=$chat_model, ac=$autocomplete_model"

  sudo -u "$_REAL_USER" mkdir -p "$CONTINUE_CONFIG_DIR"

  local provider api_base chat_provider

  if [ "$backend" = "vllm" ]; then
    # vLLM: OpenAI-compatible endpoint
    # Forrás: Continue.dev provider="openai" + apiBase (official docs)
    provider="openai"
    api_base="http://localhost:${VLLM_PORT}/v1"
    chat_provider="openai"
  else
    # Ollama: natív Ollama provider
    # Forrás: Continue.dev provider="ollama" (official docs)
    provider="ollama"
    api_base="$OLLAMA_HOST"
    chat_provider="ollama"
  fi

  # Continue.dev config.json generálás
  # Struktúra: models[] + tabAutocompleteModel + embeddingsProvider
  cat > /tmp/continue_config_new.json << CONTINUE_EOF
{
  "models": [
    {
      "title": "Kód (${backend}) — ${chat_model}",
      "provider": "${provider}",
      "model": "${chat_model}",
      "apiBase": "${api_base}",
      "apiKey": "dummy"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Tab autocomplete — ${autocomplete_model}",
    "provider": "${chat_provider}",
    "model": "${autocomplete_model}",
    "apiBase": "${api_base}",
    "apiKey": "dummy"
  },
  "embeddingsProvider": {
    "provider": "ollama",
    "model": "${embed_model}",
    "apiBase": "${OLLAMA_HOST}"
  },
  "contextProviders": [
    { "name": "code" },
    { "name": "docs" },
    { "name": "diff" },
    { "name": "terminal" },
    { "name": "open" }
  ],
  "slashCommands": [
    { "name": "share", "description": "Export current chat session" },
    { "name": "cmd",   "description": "Generate shell command" }
  ]
}
CONTINUE_EOF

  # Biztonsági mentés a meglévő konfigból
  if [ -f "$CONTINUE_CONFIG_FILE" ]; then
    cp "$CONTINUE_CONFIG_FILE" "${CONTINUE_CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
  fi

  sudo -u "$_REAL_USER" cp /tmp/continue_config_new.json "$CONTINUE_CONFIG_FILE"
  chown "$_REAL_USER:$_REAL_USER" "$CONTINUE_CONFIG_FILE"
  rm -f /tmp/continue_config_new.json
  log "INFO" "Continue.dev konfig írva: $CONTINUE_CONFIG_FILE"
}

# _ide_switch_backend: egyszerre váltja a CLINE + Continue.dev backend-et
# Paraméterek: $1=backend ("ollama"|"vllm"), $2=model neve
_ide_switch_backend() {
  local backend="$1"
  local model="$2"

  if [ "$backend" = "vllm" ]; then
    [ -z "$model" ] && {
      # Ha nincs modell megadva, kérdezzük le a vLLM-től
      model=$(curl -s --connect-timeout 3 \
        "http://localhost:${VLLM_PORT}/v1/models" 2>/dev/null | \
        python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  models=[m['id'] for m in d.get('data',[])]
  print(models[0] if models else '')
except: print('')
" 2>/dev/null)
    }
    _ide_config_cline_vllm "$model"
    _ide_config_continue "vllm" "$model"
    log "INFO" "IDE backend váltva: vLLM (${VLLM_PORT}), model: $model"
  else
    _ide_config_cline_ollama "$model"
    _ide_config_continue "ollama" "$model"
    log "INFO" "IDE backend váltva: Ollama (11434), model: $model"
  fi
}

# =============================================================================
# GPU ÁLLAPOT FÜGGVÉNY
# =============================================================================

# _gpu_status_text: RTX 5090 VRAM állapot + Ollama/vLLM foglalás
# nvidia-smi: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/ (official)
_gpu_status_text() {
  local nvsmi_out
  nvsmi_out=$(nvidia-smi \
    --query-gpu=name,driver_version,memory.used,memory.free,memory.total,temperature.gpu,utilization.gpu \
    --format=csv,noheader,nounits 2>/dev/null)

  if [ -z "$nvsmi_out" ]; then
    echo "HIBA: nvidia-smi nem elérhető"
    return 1
  fi

  # CSV parse: name, driver, used_mb, free_mb, total_mb, temp, util
  echo "$nvsmi_out" | python3 -c "
import sys
for line in sys.stdin:
  parts = [p.strip() for p in line.split(',')]
  if len(parts) >= 7:
    name, drv, used, free, total, temp, util = parts[:7]
    used_gb  = float(used)  / 1024
    free_gb  = float(free)  / 1024
    total_gb = float(total) / 1024
    bar_pct  = int(float(used) / float(total) * 30) if float(total) > 0 else 0
    bar      = '█' * bar_pct + '░' * (30 - bar_pct)
    print(f'GPU:    {name}')
    print(f'Driver: {drv}')
    print(f'Hőm.:   {temp}°C   Utilization: {util}%')
    print(f'VRAM:   [{bar}]')
    print(f'        Használt: {used_gb:.1f} GB / {total_gb:.1f} GB  (Szabad: {free_gb:.1f} GB)')
" 2>/dev/null

  # Betöltött Ollama modellek VRAM foglalása
  echo ""
  echo "── Ollama betöltött modellek ──"
  _ollama_list_running

  echo ""
  echo "── vLLM szerver ──"
  _vllm_status_text
}

# =============================================================================
# MENÜ RENDSZER
# =============================================================================

# _menu_model_manager: Ollama modell kezelő almenü
_menu_model_manager() {
  while true; do
    # Telepített modellek lista
    local installed_list
    installed_list=$(_ollama_list_installed 2>/dev/null)
    local running_list
    running_list=$(_ollama_list_running 2>/dev/null)

    local choice
    choice=$(whiptail --title "AI Model Manager — Ollama modellek" \
      --menu "Telepített modellek:\n${installed_list}\n\nBetöltve (VRAM):\n${running_list}" \
      22 76 7 \
      "1" "Modell betöltés VRAM-ba" \
      "2" "Modell kiürítés VRAM-ból" \
      "3" "Új modell letöltése (ollama pull)" \
      "4" "Modellek részletes listája" \
      "0" "← Vissza" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      1)
        # Betöltendő modell választás
        local model_list
        mapfile -t model_list < <(_ollama_list_installed 2>/dev/null | awk '{print $1}')
        if [ ${#model_list[@]} -eq 0 ]; then
          whiptail --msgbox "Nincs telepített modell!\nHasználd a 'Letöltés' opciót." 10 50
          continue
        fi
        # Whiptail radiolist a modellek közül
        local menu_items=()
        local i=1
        for m in "${model_list[@]}"; do
          menu_items+=("$i" "$m" "OFF")
          ((i++))
        done
        local sel_idx
        sel_idx=$(whiptail --title "Modell betöltés" \
          --radiolist "Válaszd a betöltendő modellt (SPACE = jelöl, ENTER = OK):" \
          20 70 "${#model_list[@]}" \
          "${menu_items[@]}" \
          3>&1 1>&2 2>&3) || continue
        local sel_model="${model_list[$((sel_idx-1))]}"
        _ollama_load_model "$sel_model"
        whiptail --msgbox "Betöltve: ${sel_model}\n\nA modell a VRAM-ban marad (keep_alive=-1)." 10 60
        ;;
      2)
        local running_models
        mapfile -t running_models < <(
          _ollama_api GET "/api/ps" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  for m in d.get('models',[]): print(m['name'])
except: pass
" 2>/dev/null)
        if [ ${#running_models[@]} -eq 0 ]; then
          whiptail --msgbox "Nincs VRAM-ban lévő modell." 8 50
          continue
        fi
        local menu_items=()
        local i=1
        for m in "${running_models[@]}"; do
          menu_items+=("$i" "$m" "OFF")
          ((i++))
        done
        local sel_idx
        sel_idx=$(whiptail --title "VRAM ürítés" \
          --radiolist "Válaszd az eltávolítandó modellt:" \
          16 70 "${#running_models[@]}" \
          "${menu_items[@]}" \
          3>&1 1>&2 2>&3) || continue
        local sel_model="${running_models[$((sel_idx-1))]}"
        _ollama_unload_model "$sel_model"
        whiptail --msgbox "VRAM-ból eltávolítva: ${sel_model}" 8 60
        ;;
      3)
        local model_name
        model_name=$(whiptail --title "Ollama pull" \
          --inputbox "Modell neve (pl. qwen2.5-coder:7b, llama3.3:70b):" \
          10 60 "" 3>&1 1>&2 2>&3) || continue
        [ -z "$model_name" ] && continue
        _ollama_pull_model "$model_name"
        ;;
      4)
        local full_list
        full_list=$(sudo -u "$_REAL_USER" ollama list 2>/dev/null || echo "Hiba")
        whiptail --title "Ollama modellek" \
          --scrolltext --msgbox "$full_list" 20 76
        ;;
      0) return ;;
    esac
  done
}

# _menu_backend_switch: IDE backend váltó almenü
_menu_backend_switch() {
  while true; do
    # Jelenlegi állapot megjelenítés
    local current_cline="?"
    [ -f "$VSCODE_SETTINGS_FILE" ] && \
      current_cline=$(python3 -c "
import json
try:
  d=json.load(open('$VSCODE_SETTINGS_FILE'))
  print(d.get('$CLINE_PROVIDER_KEY','?'))
except: print('?')
" 2>/dev/null)

    local vllm_status="leállított"
    _is_vllm_running && vllm_status="FUT (port: ${VLLM_PORT})"
    local ollama_status="leállított"
    _is_ollama_running && ollama_status="FUT (port: 11434)"

    local choice
    choice=$(whiptail --title "Backend váltó" \
      --menu "Jelenlegi CLINE backend: ${current_cline}\nOllama: ${ollama_status}\nvLLM:   ${vllm_status}" \
      18 70 5 \
      "1" "→ Ollama backend (CLINE + Continue)" \
      "2" "→ vLLM backend (CLINE + Continue)" \
      "3" "Ollama modell kiválasztása" \
      "4" "vLLM modell megadása" \
      "0" "← Vissza" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      1)
        local model
        model=$(whiptail --title "Ollama modell" \
          --inputbox "Ollama modell neve:" 10 60 \
          "$OLLAMA_DEFAULT_CODE_MODEL" 3>&1 1>&2 2>&3) || continue
        _ide_switch_backend "ollama" "$model"
        whiptail --msgbox "CLINE + Continue.dev → Ollama backend\nModell: $model\n\nIndítsd újra a VS Code-ot!" 12 60
        ;;
      2)
        if ! _is_vllm_running; then
          whiptail --msgbox "vLLM nem fut!\nIndítsd el előbb a vLLM szerver almenüből." 10 55
          continue
        fi
        local model
        model=$(whiptail --title "vLLM modell" \
          --inputbox "vLLM szerver model ID-ja:" 10 60 "" 3>&1 1>&2 2>&3) || continue
        _ide_switch_backend "vllm" "$model"
        whiptail --msgbox "CLINE + Continue.dev → vLLM backend\nEndpoint: http://localhost:${VLLM_PORT}/v1\n\nIndítsd újra a VS Code-ot!" 12 60
        ;;
      3)
        # Gyors Ollama model váltás (csak CLINE)
        local model
        model=$(whiptail --title "CLINE Ollama modell" \
          --inputbox "Új Ollama kód modell:" 10 60 \
          "$OLLAMA_DEFAULT_CODE_MODEL" 3>&1 1>&2 2>&3) || continue
        _ide_config_cline_ollama "$model"
        whiptail --msgbox "CLINE modell frissítve: $model\n(VS Code újraindítás szükséges)" 10 55
        ;;
      4)
        local model
        model=$(whiptail --title "vLLM modell" \
          --inputbox "vLLM model ID (HF formátum):" 10 60 "" 3>&1 1>&2 2>&3) || continue
        _ide_config_cline_vllm "$model"
        whiptail --msgbox "CLINE → vLLM backend, modell: $model\n(VS Code újraindítás szükséges)" 10 55
        ;;
      0) return ;;
    esac
  done
}

# _menu_vllm_control: vLLM szerver irányítás almenü
_menu_vllm_control() {
  while true; do
    local vllm_running_label="⛔ Leállítva"
    _is_vllm_running && vllm_running_label="✅ Fut (port: ${VLLM_PORT})"

    local choice
    choice=$(whiptail --title "vLLM szerver — RTX 5090 Blackwell" \
      --menu "Állapot: ${vllm_running_label}\ndtype: ${VLLM_DTYPE}  gpu-mem: ${VLLM_GPU_MEM_UTIL}  max-len: ${VLLM_MAX_MODEL_LEN}" \
      18 76 6 \
      "1" "vLLM indítás (model megadással)" \
      "2" "vLLM leállítás" \
      "3" "vLLM állapot + logok megtekintése" \
      "4" "systemd service engedélyezés/tiltás" \
      "5" "Konfigurált paraméterek" \
      "0" "← Vissza" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      1)
        local model
        model=$(whiptail --title "vLLM modell" \
          --inputbox "HuggingFace model ID vagy lokális útvonal:\n(pl. Qwen/Qwen2.5-Coder-7B-Instruct)" \
          12 72 "" 3>&1 1>&2 2>&3) || continue
        [ -z "$model" ] && continue
        if _vllm_start "$model"; then
          whiptail --msgbox "vLLM elindult!\nAPI: http://localhost:${VLLM_PORT}/v1\n\nCLINE/Continue konfig frissítéséhez\nhasználd a 'Backend váltó' menüt!" 14 60
        else
          whiptail --msgbox "vLLM indítás SIKERTELEN\nLog: ${VLLM_LOG_FILE}\n\n$(tail -5 "$VLLM_LOG_FILE" 2>/dev/null)" 16 72
        fi
        ;;
      2)
        _vllm_stop
        whiptail --msgbox "vLLM leállítva." 8 40
        ;;
      3)
        local status_txt
        status_txt=$(_vllm_status_text)
        local log_tail=""
        [ -f "$VLLM_LOG_FILE" ] && \
          log_tail=$(echo -e "\n── Utolsó 10 log sor ──\n$(tail -10 "$VLLM_LOG_FILE")")
        whiptail --title "vLLM állapot" --scrolltext \
          --msgbox "${status_txt}${log_tail}" 24 78
        ;;
      4)
        # systemd user service engedélyezés/tiltás (boot-on-start)
        if [ ! -f "$VLLM_SERVICE_FILE" ]; then
          whiptail --msgbox "vLLM service fájl hiányzik!\nFuttasd install módban a 09-es modult!" 10 55
          continue
        fi
        local svc_status
        svc_status=$(sudo -u "$_REAL_USER" systemctl --user is-enabled vllm-rtx5090 2>/dev/null)
        if [ "$svc_status" = "enabled" ]; then
          sudo -u "$_REAL_USER" systemctl --user disable vllm-rtx5090 2>/dev/null
          whiptail --msgbox "vLLM service letiltva (boot-on-start OFF)" 8 50
        else
          sudo -u "$_REAL_USER" systemctl --user enable vllm-rtx5090 2>/dev/null
          whiptail --msgbox "vLLM service engedélyezve (boot-on-start ON)\nModell: a service fájlban megadott model!" 10 55
        fi
        ;;
      5)
        whiptail --title "vLLM paraméterek" --msgbox "
  Host:              ${VLLM_HOST}
  Port:              ${VLLM_PORT}
  dtype:             ${VLLM_DTYPE}      (Blackwell SM_120 optimális)
  GPU mem utiliz.:   ${VLLM_GPU_MEM_UTIL}   (RTX 5090: ~28.8 GB)
  Max model len:     ${VLLM_MAX_MODEL_LEN} token
  CPU swap:          ${VLLM_SWAP_SPACE} GiB
  Prefix caching:    $([ "$VLLM_ENABLE_PREFIX_CACHE" = "1" ] && echo ON || echo OFF)

  PID fájl:   ${VLLM_PID_FILE}
  Log fájl:   ${VLLM_LOG_FILE}
  vLLM bin:   ${VENV_VLLM}

  API: http://localhost:${VLLM_PORT}/v1/chat/completions
       http://localhost:${VLLM_PORT}/v1/models
" 26 72
        ;;
      0) return ;;
    esac
  done
}

# _menu_turboquant: TurboQuant kvantálás almenü
_menu_turboquant() {
  while true; do
    local tq_available="⛔ Nem telepített"
    [ -d "$TQ_DIR" ] && tq_available="✅ Elérhető (${TQ_DIR})"

    local choice
    choice=$(whiptail --title "TurboQuant — RTX 5090 KV cache kvantálás" \
      --menu "TurboQuant: ${tq_available}\nKimenet: ${TQ_QUANTIZED_DIR}" \
      18 76 5 \
      "1" "Modell kvantálása (TurboQuant)" \
      "2" "Kvantált modellek listája" \
      "3" "TurboQuant info + papír link" \
      "0" "← Vissza" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      1)
        if [ ! -d "$TQ_DIR" ]; then
          whiptail --msgbox "TurboQuant nem telepített!\nFuttasd előbb a 02-es modult (Lokális AI stack)." 10 60
          continue
        fi
        local src_model
        src_model=$(whiptail --title "TurboQuant forrás modell" \
          --inputbox "Ollama modell neve vagy HF ID:\n(pl. qwen2.5-coder:7b)" \
          12 65 "" 3>&1 1>&2 2>&3) || continue
        [ -z "$src_model" ] && continue

        local bits
        bits=$(whiptail --title "Bit mélység" \
          --radiolist "Kvantálási bit mélység:" 14 55 4 \
          "3" "3-bit (legkisebb, lassabb)" "OFF" \
          "4" "4-bit (ajánlott, egyensúly)" "ON" \
          "8" "8-bit (legnagyobb, leggyorsabb)" "OFF" \
          3>&1 1>&2 2>&3) || continue

        if whiptail --yesno "Kvantálás indítása?\n\nForrás:    $src_model\nBit:       ${bits}-bit\nKimenet:   ${TQ_QUANTIZED_DIR}/${src_model}-tq${bits}.gguf\n\nEz több percig tarthat!" 16 65; then
          local result
          result=$(_tq_quantize_model "$src_model" "$bits")
          if [ -n "$result" ]; then
            whiptail --msgbox "TurboQuant kvantálás kész!\n\nOllama modell neve: ${result}\n\nHasználat:\n  ollama run ${result}" 14 65
          else
            whiptail --msgbox "Kvantálás SIKERTELEN\nEllenőrizd a log fájlt!" 10 50
          fi
        fi
        ;;
      2)
        local tq_list
        tq_list=$(_tq_list_quantized)
        whiptail --title "Kvantált modellek" --scrolltext \
          --msgbox "$tq_list" 20 72
        ;;
      3)
        whiptail --title "TurboQuant info" --msgbox "
  TurboQuant — ICLR 2026 (Google Research)
  Algoritmus: PolarQuant + QJL

  RTX 5090-en:
    +35% decode sebesség
    6x kisebb KV cache (3-bitre tömörít)
    Tréning nélkül, veszteségmentes pontosság

  Papír: https://arxiv.org/pdf/2504.19874
  Blog:  https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/
  Kód:   https://github.com/0xSero/turboquant

  Folyamat:
    1. python -m turboquant.quantize --model X --bits N → .gguf
    2. ollama create model-tq4 -f Modelfile
    3. ollama run model-tq4  (automatikus)
" 26 72
        ;;
      0) return ;;
    esac
  done
}

# _menu_gpu_status: GPU állapot almenü
_menu_gpu_status() {
  local status_txt
  status_txt=$(_gpu_status_text 2>/dev/null || echo "GPU adat nem elérhető")
  whiptail --title "GPU állapot — RTX 5090 Blackwell SM_120" \
    --scrolltext --msgbox "$status_txt" 24 78
}

# _manage_main_menu: fő interaktív menü (manage mód)
_manage_main_menu() {
  # Fő ciklus
  while true; do
    # Állapot összefoglaló a menü fejlécébe
    local ollama_st="⛔"
    _is_ollama_running && ollama_st="✅"
    local vllm_st="⛔"
    _is_vllm_running && vllm_st="✅"
    local current_backend="?"
    [ -f "$VSCODE_SETTINGS_FILE" ] && \
      current_backend=$(python3 -c "
import json
try:
  d=json.load(open('$VSCODE_SETTINGS_FILE'))
  print(d.get('cline.apiProvider','?'))
except: print('?')
" 2>/dev/null)

    local choice
    choice=$(whiptail --title "AI Model Manager v${MOD_VERSION} — RTX 5090 Blackwell" \
      --menu "Ollama: ${ollama_st}  vLLM: ${vllm_st}  CLINE backend: ${current_backend}" \
      20 72 7 \
      "1" "Ollama model kezelés (betöltés/eltávolítás/pull)" \
      "2" "Backend váltás (Ollama ↔ vLLM)" \
      "3" "vLLM szerver irányítás" \
      "4" "TurboQuant kvantálás" \
      "5" "GPU memória állapot" \
      "6" "Komponens állapot" \
      "0" "Kilépés" \
      3>&1 1>&2 2>&3) || break

    case "$choice" in
      1) _menu_model_manager    ;;
      2) _menu_backend_switch   ;;
      3) _menu_vllm_control     ;;
      4) _menu_turboquant       ;;
      5) _menu_gpu_status       ;;
      6)
        _check_all_components
        local status_txt
        status_txt=$(_show_component_status)
        whiptail --title "Komponens állapot" --msgbox "$status_txt" 18 65
        ;;
      0) break ;;
    esac
  done
}

# =============================================================================
# INFRA INSTALL / CHECK / UPDATE MÓDOK
# =============================================================================

# _do_check: komponens állapot felmérés + COMP_09_* state mentés
# Mód-tudatos sablon (lib/00_lib_comp.sh comp_save_state alapján):
#   check mód: az elején ment (COMP_USE_CACHED=false esetén re-check + ment)
_do_check() {
  log "INFO" "[$MOD_ID] Komponens ellenőrzés..."

  # Ha COMP_USE_CACHED=true (master check-all hívásakor), korábbi state visszaad
  if [ "${COMP_USE_CACHED:-false}" = "true" ] && \
     comp_state_exists "$MOD_ID" 2>/dev/null; then
    log "INFO" "[$MOD_ID] Gyorsítótárból (COMP_USE_CACHED=true)"
    return 0
  fi

  _check_all_components

  # COMP_09_* state mentés lib/00_lib_comp.sh comp_save_state API-val
  # Kulcsok: COMP_09_S_<COMP>=ok|old|missing, COMP_09_V_<COMP>=verzió
  infra_state_set "COMP_09_TS"              "$(date '+%Y-%m-%dT%H:%M:%S')"
  infra_state_set "COMP_09_S_OLLAMA"        "${COMP_STATUS[ollama]:-missing}"
  infra_state_set "COMP_09_V_OLLAMA"        "${COMP_VER[ollama]:-}"
  infra_state_set "COMP_09_S_OLLAMA_SVC"    "${COMP_STATUS[ollama_svc]:-missing}"
  infra_state_set "COMP_09_S_VLLM"          "${COMP_STATUS[vllm]:-missing}"
  infra_state_set "COMP_09_V_VLLM"          "${COMP_VER[vllm]:-}"
  infra_state_set "COMP_09_S_VLLM_SVC"      "${COMP_STATUS[vllm_svc]:-missing}"
  infra_state_set "COMP_09_S_TURBOQUANT"    "${COMP_STATUS[turboquant]:-missing}"
  infra_state_set "COMP_09_S_CLINE_CFG"     "${COMP_STATUS[cline_cfg]:-missing}"
  infra_state_set "COMP_09_V_CLINE_CFG"     "${COMP_VER[cline_cfg]:-}"
  infra_state_set "COMP_09_S_CONTINUE_CFG"  "${COMP_STATUS[continue_cfg]:-missing}"
  infra_state_set "COMP_09_S_TOOL"          "${COMP_STATUS[tool]:-missing}"

  log "INFO" "[$MOD_ID] Komponens state mentve"
}

# _do_install: tool telepítés, kezdeti konfigok, systemd service fájl
_do_install() {
  log "INFO" "[$MOD_ID] Install mód..."

  # Előfeltétel ellenőrzés: 02 (Ollama+vLLM+TQ) + 06 (VSCode+CLINE+Continue)
  # lib/00_lib_state.sh infra_require() — megáll ha hiányzik
  infra_require "02" || return 1
  infra_require "06" || return 1

  # ── ai-model-ctl wrapper script ───────────────────────────────────────────
  # ~/bin/ könyvtár létrehozása (01b_post_reboot.sh PATH-ba teszi)
  sudo -u "$_REAL_USER" mkdir -p "$TOOL_INSTALL_DIR"

  # ai-model-ctl: egyszerű wrapper, ami a 09_ai_model_wrapper.sh-t hívja manage módban
  cat > "$TOOL_TARGET" << WRAPPER_EOF
#!/bin/bash
# ai-model-ctl — AI Model Manager wrapper
# Automatikusan generálva: 09_ai_model_wrapper.sh install módban
# Futtatás: ai-model-ctl [manage|status|start-vllm MODEL|stop-vllm|...]
INFRA_DIR="${SCRIPT_DIR}"
WRAPPER="${SCRIPT_DIR}/09_ai_model_wrapper.sh"

if [ "\$1" = "status" ]; then
  RUN_MODE=check sudo bash "\$WRAPPER"
elif [ "\$1" = "start-vllm" ] && [ -n "\$2" ]; then
  RUN_MODE=start_vllm MODEL="\$2" sudo bash "\$WRAPPER"
elif [ "\$1" = "stop-vllm" ]; then
  RUN_MODE=stop_vllm sudo bash "\$WRAPPER"
else
  # Alap: interaktív manage menü (sudo szükséges)
  if [ "\$EUID" -ne 0 ]; then
    exec sudo bash "\$WRAPPER"
  else
    RUN_MODE=manage bash "\$WRAPPER"
  fi
fi
WRAPPER_EOF

  chown "$_REAL_USER:$_REAL_USER" "$TOOL_TARGET"
  chmod 755 "$TOOL_TARGET"
  log "INFO" "Tool telepítve: $TOOL_TARGET"

  # ── vLLM systemd user service fájl ───────────────────────────────────────
  # A service-t a felhasználó engedélyezi ha boot-on-start kell
  sudo -u "$_REAL_USER" mkdir -p "$SYSTEMD_USER_DIR"

  cat > "$VLLM_SERVICE_FILE" << SERVICE_EOF
# =============================================================================
# vllm-rtx5090.service — vLLM OpenAI-compatible szerver (RTX 5090 Blackwell)
# Generálva: $(date '+%Y-%m-%d') — 09_ai_model_wrapper.sh
#
# Forrás: https://docs.vllm.ai/en/stable/cli/serve/ (official)
# Engedélyezés: systemctl --user enable vllm-rtx5090
# Indítás:      systemctl --user start vllm-rtx5090
# =============================================================================
[Unit]
Description=vLLM OpenAI-compatible szerver (RTX 5090 Blackwell SM_120)
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
WorkingDirectory=${_REAL_HOME}
# MÓDOSÍTSD: az alábbi MODEL_ID-t a kívánt HuggingFace model ID-ra
Environment="MODEL_ID=Qwen/Qwen2.5-Coder-7B-Instruct"
ExecStart=${AI_VENV_DIR}/bin/vllm serve \${MODEL_ID} \
    --host ${VLLM_HOST} \
    --port ${VLLM_PORT} \
    --dtype ${VLLM_DTYPE} \
    --gpu-memory-utilization ${VLLM_GPU_MEM_UTIL} \
    --max-model-len ${VLLM_MAX_MODEL_LEN} \
    --swap-space ${VLLM_SWAP_SPACE} \
    --trust-remote-code \
    --enable-prefix-caching
Restart=on-failure
RestartSec=10
StandardOutput=append:${VLLM_LOG_FILE}
StandardError=append:${VLLM_LOG_FILE}

[Install]
WantedBy=default.target
SERVICE_EOF

  chown "$_REAL_USER:$_REAL_USER" "$VLLM_SERVICE_FILE"
  # systemd user daemon reload (ha fut a session)
  sudo -u "$_REAL_USER" systemctl --user daemon-reload 2>/dev/null || true
  log "INFO" "vLLM service fájl: $VLLM_SERVICE_FILE"

  # ── Kezdeti CLINE konfig (Ollama alapértelmezett) ──────────────────────────
  # Csak akkor írjuk felül, ha nincs még CLINE provider beállítva
  if ! grep -q "$CLINE_PROVIDER_KEY" "$VSCODE_SETTINGS_FILE" 2>/dev/null; then
    log "INFO" "Kezdeti CLINE konfig írása (Ollama backend)"
    _ide_config_cline_ollama "$OLLAMA_DEFAULT_CODE_MODEL"
  else
    log "INFO" "CLINE konfig már létezik — kihagyva"
  fi

  # ── Kezdeti Continue.dev konfig (Ollama alapértelmezett) ──────────────────
  if [ ! -f "$CONTINUE_CONFIG_FILE" ]; then
    log "INFO" "Kezdeti Continue.dev konfig írása (Ollama backend)"
    _ide_config_continue "ollama" \
      "$OLLAMA_DEFAULT_CODE_MODEL" \
      "$OLLAMA_DEFAULT_AUTOCOMPLETE"
  else
    log "INFO" "Continue.dev konfig már létezik — kihagyva"
  fi

  # ── logkönyvtár ───────────────────────────────────────────────────────────
  sudo -u "$_REAL_USER" mkdir -p "${_REAL_HOME}/.infra-logs"
  sudo -u "$_REAL_USER" mkdir -p "$TQ_QUANTIZED_DIR"

  # ── MOD_09_DONE state ─────────────────────────────────────────────────────
  infra_state_set "MOD_09_DONE" "true"
  log "INFO" "[$MOD_ID] Install kész"

  # Post-install check + state mentés
  _do_check
}

# _do_update: konfig frissítés, tool újragenerálás
_do_update() {
  log "INFO" "[$MOD_ID] Update mód..."

  # ai-model-ctl tool újragenerálása (ha a script frissült)
  if [ -f "$TOOL_TARGET" ]; then
    log "INFO" "ai-model-ctl újragenerálás"
    # Meghívjuk saját _do_install logikánk tool-generáló részét
    # (nem írjuk felül a meglévő konfigokat — csak a tool binárist)
    sudo -u "$_REAL_USER" mkdir -p "$TOOL_INSTALL_DIR"
  fi

  # systemd daemon reload (ha a service fájl frissült)
  sudo -u "$_REAL_USER" systemctl --user daemon-reload 2>/dev/null || true

  # Post-update check + state mentés
  _do_check
  log "INFO" "[$MOD_ID] Update kész"
}

# =============================================================================
# FŐPROGRAM — DISPATCH
# =============================================================================
main() {
  # LIB verzió ellenőrzés — lib/00_lib_core.sh LIB_VERSION változóból
  if declare -p LIB_VERSION &>/dev/null; then
    if ! version_ok "${LIB_VERSION:-0}" "$MOD_LIB_MIN" 2>/dev/null; then
      echo "HIBA: Lib verzió $LIB_VERSION < minimum $MOD_LIB_MIN"
      echo "Frissítsd a lib/ komponenseket!"
      exit 1
    fi
  fi

  # Hardver ellenőrzés: NVIDIA GPU szükséges
  hw_detect 2>/dev/null || true
  if [ "${HW_VLLM_OK:-false}" != "true" ] && \
     ! hw_has_nvidia 2>/dev/null; then
    echo "FIGYELEM: NVIDIA GPU nem detektálható."
    echo "Ollama CPU-only módban fut, vLLM és TurboQuant nem elérhető."
    echo ""
  fi

  # INFRA state inicializálás
  infra_state_init 2>/dev/null || true

  # Log könyvtár
  mkdir -p "$(dirname "$LOGFILE")"
  log "INFO" "[$MOD_ID] $MOD_NAME v$MOD_VERSION indítás — RUN_MODE: ${RUN_MODE:-manage}"

  # RUN_MODE dispatch
  # Forrás: lib/00_lib_state.sh detect_run_mode() alapján, konzisztens logika
  case "${RUN_MODE:-manage}" in

    check)
      # Csak ellenőrzés — install nélkül
      _do_check
      _show_component_status
      ;;

    install)
      # Teljes telepítés
      _do_install
      ;;

    update)
      # Frissítés (meglévő konfig megőrzése)
      _do_update
      ;;

    fix|reinstall)
      # Újratelepítés — konfig visszaírás is
      log "INFO" "[$MOD_ID] Fix/reinstall mód — konfig újraírás"
      _do_install
      # Fix módban a CLINE/Continue konfig felülírásra kerül
      _ide_config_cline_ollama "$OLLAMA_DEFAULT_CODE_MODEL"
      _ide_config_continue "ollama" \
        "$OLLAMA_DEFAULT_CODE_MODEL" \
        "$OLLAMA_DEFAULT_AUTOCOMPLETE"
      ;;

    start_vllm)
      # Parancssoros vLLM indítás (ai-model-ctl start-vllm MODEL hívja)
      local model="${MODEL:-}"
      [ -z "$model" ] && { echo "MODEL= szükséges"; exit 1; }
      _vllm_start "$model"
      ;;

    stop_vllm)
      # Parancssoros vLLM leállítás
      _vllm_stop
      ;;

    manage|"")
      # Interaktív manage menü — standalone vagy ai-model-ctl hívásból
      # Sudo szükséges a state íráshoz és service kezeléshez
      if [ "$EUID" -ne 0 ]; then
        echo "HIBA: sudo szükséges. Használd: sudo ai-model-ctl"
        exit 1
      fi
      _manage_main_menu
      ;;

    *)
      log "WARN" "Ismeretlen RUN_MODE: '${RUN_MODE}' — manage módba esik"
      _manage_main_menu
      ;;
  esac
}

main "$@"
