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
# VERZIÓ: v1.0 (lib v6.4+ kompatibilis)
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
readonly MOD_LIB_MIN="6.4"

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
# NOTA: --swap-space eltávolítva — vLLM 0.19.0-ban nem létezik ez a flag
readonly VLLM_ENABLE_PREFIX_CACHE=1    # --enable-prefix-caching flag
# PID fájl: /tmp marad — process tracking, rövid életű
readonly VLLM_PID_FILE="/tmp/vllm-rtx5090.pid"
# Log fájl: SCRIPT_DIR — INFRA konvenció (wrapper_ prefix, nem /tmp!)
# Megj: nem dátum-stampelt, mert vLLM hosszú életű service
VLLM_LOG_FILE="${SCRIPT_DIR}/wrapper_vllm.log"

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
# INFRA konvenció: log a script indítási könyvtárba kerül, prefix: "wrapper_"
# Így minden futás naplója ott marad ahol a scriptet futtatják
LOGFILE="${SCRIPT_DIR}/wrapper_$(date +%Y%m%d_%H%M%S).log"

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

# _ollama_pull_model: model letöltése az Ollama REST API-n keresztül, progress gauge-zal
# Forrás: POST /api/pull stream=true — https://ollama.readthedocs.io/en/api/ (official)
# A streaming JSON sorok: {"status":"pulling","total":N,"completed":M}
# curl háttérben letölt → log fájlba → Python parse → whiptail gauge frissítés
# Paraméter: $1=model neve (pl. "llama3.3:70b")
_ollama_pull_model() {
  local model="$1"
  [ -z "$model" ] && return 1
  log "INFO" "Ollama pull indítás: $model"

  # Pull log a script könyvtárba (wrapper_ prefix, INFRA konvenció)
  local pull_log="${SCRIPT_DIR}/wrapper_pull_${model//[:\/]/_}_$(date +%H%M%S).log"

  # REST API streaming pull — curl háttérben
  # Streaming JSON sorok: {"status":"pulling","digest":"...","total":N,"completed":M}
  curl -s -N -X POST "${OLLAMA_HOST}/api/pull" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${model}\",\"stream\":true}" \
    > "$pull_log" 2>&1 &
  local pull_pid=$!

  # whiptail gauge feeder: 2 másodpercenként frissíti a progress-t
  (
    local prev_pct=0
    while kill -0 "$pull_pid" 2>/dev/null; do

      # "success" sor → letöltés kész
      if grep -q '"success"' "$pull_log" 2>/dev/null; then
        printf 'XXX\n100\n✓ Letöltés kész: %s\nXXX\n' "$model"
        sleep 1; echo 100; break
      fi

      # JSON sorok parse: completed/total → %
      local parsed
      parsed=$(python3 - "$pull_log" 2>/dev/null << 'PYEOF'
import json, sys, os
path = sys.argv[1]
pct, txt = 0, "csatlakozás Ollama-hoz..."
try:
  lines = open(path).readlines()
  for line in reversed(lines):
    line = line.strip()
    if not line: continue
    try:
      d = json.loads(line)
      total  = d.get("total", 0)
      done   = d.get("completed", 0)
      status = d.get("status", "")
      if total and total > 0:
        pct = int(done * 100 / total)
        txt = f"{status}  {done/1e9:.2f} / {total/1e9:.2f} GB"
        break
      elif status:
        txt = status
        break
    except:
      continue
except:
  pass
print(f"{pct}|{txt}")
PYEOF
)
      local pct="${parsed%%|*}"
      local txt="${parsed#*|}"
      [[ ! "$pct" =~ ^[0-9]+$ ]] && pct="$prev_pct"
      [ "$pct" -gt 99 ] && pct=99  # 100% csak "success" után
      prev_pct="$pct"

      printf 'XXX\n%d\n%s\nXXX\n' "$pct" "${txt:-(várakozás...)}"
      sleep 2
    done
    echo 100
  ) | whiptail --title "Ollama pull — ${model}" \
      --gauge "$(printf 'Modell: %s\nLog:    %s\n\nESC = háttérbe küldés (letöltés folytatódik)' \
        "$model" "$pull_log")" \
      12 76 0

  # Megvárjuk a curl befejezését (gauge ESC esetén is fut tovább)
  wait "$pull_pid" 2>/dev/null
  # Log mentése a fő logba
  cat "$pull_log" >> "$LOGFILE" 2>/dev/null
  log "INFO" "Ollama pull befejezve: $model (log: $pull_log)"
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
    "--trust-remote-code"                             # HuggingFace modelleknél szükséges
    # --swap-space ELTÁVOLÍTVA: vLLM 0.19.0-ban nem létező flag → "unrecognized arguments" hiba
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

  # Blackwell SM_120 PyTorch kompatibilitás ellenőrzés
  # Ha a venv PyTorch cu126-ról van telepítve → sm_120 nem támogatott → crash
  # Forrás: pytorch.org/get-started/locally (cu128 szükséges SM_120-hoz)
  if ! _vllm_check_pytorch_blackwell; then
    log "ERR" "PyTorch inkompatibilis: RTX 5090 SM_120 nem támogatott a jelenlegi cu126 wheel-lel"
    local fix_choice
    fix_choice=$(whiptail --title "PyTorch Blackwell inkompatibilitás" \
      --menu "⚠ A jelenlegi PyTorch NEM támogatja az RTX 5090 (SM_120) GPU-t!\n\nA telepített PyTorch cu126 indexről van → max sm_90 (Ada Lovelace).\nBlackwell SM_120-hoz cu128 PyTorch wheel szükséges.\n\nHiba: CUDA error: no kernel image for device\n\nMit szeretnél tenni?" \
      20 76 3 \
      "1" "PyTorch Blackwell fix futtatása (cu128 reinstall, ~10 perc)" \
      "2" "Folytatás mindenképpen (vLLM valószínűleg crashel)" \
      "0" "Mégse" \
      3>&1 1>&2 2>&3) || return 1
    case "$fix_choice" in
      1) _vllm_fix_pytorch_blackwell; return 1 ;;  # fix után újra kell indítani
      2) log "WARN" "Felhasználó döntése: inkompatibilis PyTorch-csal folytatja" ;;
      0) return 1 ;;
    esac
  fi

  # FONTOS: vLLM először LETÖLTI a modellt (~GB-ok), majd BETÖLTI VRAM-ba.
  # Qwen2.5-7B: ~14GB letöltés + ~8GB VRAM → 2-10 perc lehet az első indításnál.
  # A script HÁTTÉRBEN indítja — ne várakozzon a felhasználó.
  # Ellenőrzés: 'vLLM állapot' menü vagy tail -f /tmp/vllm-rtx5090.log
  log "INFO" "vLLM indítás: model=$model, port=$VLLM_PORT, dtype=$VLLM_DTYPE"
  log "INFO" "GPU mem util: ${VLLM_GPU_MEM_UTIL}, max_len: ${VLLM_MAX_MODEL_LEN}"

  # vLLM indítás háttérben — felhasználó kontextusában, venv-ből
  # Forrás: docs.vllm.ai/en/stable/cli/serve/ (official)
  # NOTA: a process PID-jét mentsük EL A SUBSHELL-BEN, ne a szülőben
  sudo -u "$_REAL_USER" bash -c "
    source '${AI_VENV_DIR}/bin/activate'
    nohup ${VENV_VLLM} $(IFS=' '; echo "$(_vllm_build_args "$model")") \
      >> '${VLLM_LOG_FILE}' 2>&1 &
    echo \$! > '${VLLM_PID_FILE}'
    echo \"vLLM PID: \$!\" >&2
  " 2>> "$LOGFILE"

  # Rövid várakozás: ellenőrizzük hogy a process tényleg elindult-e (nem crashelt azonnal)
  # NEM várjuk a port megnyílását — az 1-10 percig is tarthat modell letöltéssel
  sleep 2

  local pid
  pid=$(cat "$VLLM_PID_FILE" 2>/dev/null)
  if [ -z "$pid" ]; then
    log "ERR" "vLLM PID fájl üres — indítás sikertelen. Log: $VLLM_LOG_FILE"
    return 1
  fi

  if ! kill -0 "$pid" 2>/dev/null; then
    log "ERR" "vLLM process (PID $pid) azonnal kilépett. Log: $VLLM_LOG_FILE"
    log "ERR" "Utolsó logsorok: $(tail -5 "$VLLM_LOG_FILE" 2>/dev/null)"
    return 1
  fi

  # Process él → sikeres háttérindítás (port még nem nyílt meg, modell tölt)
  log "INFO" "vLLM process elindult (PID: $pid) — modell betöltés folyamatban..."
  log "INFO" "Ellenőrzés: tail -f $VLLM_LOG_FILE"
  log "INFO" "Port megnyílás után API: http://localhost:${VLLM_PORT}/v1"
  return 0
}

# _vllm_check_pytorch_blackwell: ellenőrzi hogy a venv PyTorch-ja ismeri-e sm_120-t
# Gyökérok: cu126 PyTorch csak sm_90-ig van fordítva (Ada Lovelace)
# RTX 5090 Blackwell SM_120-hoz cu128+ PyTorch szükséges
# Forrás: https://pytorch.org/get-started/locally/ (official)
# Visszatér: 0=kompatibilis, 1=inkompatibilis (cu128 reinstall szükséges)
_vllm_check_pytorch_blackwell() {
  # Csak Blackwell GPU esetén releváns
  [ "${HW_CUDA_ARCH:-0}" -lt 120 ] 2>/dev/null && return 0
  [ "${HW_GPU_ARCH:-}" != "blackwell" ] && return 0

  if [ ! -x "$VENV_PYTHON" ]; then
    log "WARN" "venv python nem elérhető: $VENV_PYTHON"
    return 1
  fi

  local compat
  compat=$(sudo -u "$_REAL_USER" "$VENV_PYTHON" -c "
import sys
try:
  import torch
  if not torch.cuda.is_available():
    print('no_cuda')
    sys.exit(0)
  # get_arch_list(): sm_50, sm_60, ..., sm_90 — ha sm_12x hiányzik → inkompatibilis
  caps = torch.cuda.get_arch_list()
  has_blackwell = any(
    c.replace('sm_','').isdigit() and int(c.replace('sm_','')) >= 120
    for c in caps if c.startswith('sm_')
  )
  print('ok' if has_blackwell else 'incompatible')
  # Torch verziót és CUDA index-et is logoljuk
  import sys
  print(f'torch={torch.__version__}', file=sys.stderr)
  print(f'cuda={torch.version.cuda}', file=sys.stderr)
  print(f'caps={caps}', file=sys.stderr)
except ImportError:
  print('no_torch')
except Exception as e:
  print(f'error:{e}')
" 2>> "$LOGFILE")

  log "INFO" "PyTorch Blackwell compat check: $compat"
  [ "$compat" = "ok" ]
}

# _vllm_fix_pytorch_blackwell: PyTorch újratelepítése cu128 index-ről
# Forrás: https://pytorch.org/get-started/locally/ (official)
#   RTX 5090 SM_120 → cu128 vagy nightly szükséges
# FIGYELEM: ~2-4 GB letöltés, 5-15 perc
_vllm_fix_pytorch_blackwell() {
  log "INFO" "PyTorch Blackwell fix indítás: cu128 wheel reinstall"

  # cu128 PyTorch index — Blackwell sm_120 kernelekkel
  local torch_index="https://download.pytorch.org/whl/cu128"
  local fix_log="${SCRIPT_DIR}/wrapper_pytorch_fix_$(date +%H%M%S).log"

  whiptail --msgbox "PyTorch Blackwell (SM_120) fix indítása\n\nA jelenlegi PyTorch csak sm_90-ig (Ada Lovelace) támogatott.\nRTX 5090 SM_120-hoz cu128 wheel kell.\n\nIndex: ${torch_index}\nLetöltés: ~2-4 GB\nIdő:  5-15 perc\n\nLog: ${fix_log}\n\nOK = indítás" 18 72

  # Reinstall PyTorch cu128-cal — venv-ben, user kontextusban
  # pip --force-reinstall: meglévő cu126 csomagok felülírása
  sudo -u "$_REAL_USER" bash -c "
    source '${AI_VENV_DIR}/bin/activate'
    pip install torch torchvision torchaudio \
      --index-url '${torch_index}' \
      --force-reinstall \
      2>&1 | tee '${fix_log}'
  " &
  local fix_pid=$!

  # Progress gauge — pip output figyelés
  (
    local elapsed=0
    while kill -0 "$fix_pid" 2>/dev/null; do
      local pct last_line
      last_line=$(tail -1 "$fix_log" 2>/dev/null | cut -c1-65)
      # pip download progress: "  X%" formátum
      pct=$(tail -5 "$fix_log" 2>/dev/null | grep -oP '\d+(?=%)' | tail -1)
      [ -z "$pct" ] && pct=$(( elapsed * 60 / 600 ))
      [ "$pct" -gt 95 ] && pct=95
      printf 'XXX\n%d\n%dm%02ds  |  %s\nXXX\n' \
        "$pct" "$(( elapsed/60 ))" "$(( elapsed%60 ))" \
        "${last_line:-(várakozás...)}"
      sleep 5; elapsed=$(( elapsed + 5 ))
    done
    echo 100
  ) | whiptail --title "PyTorch Blackwell fix — cu128 reinstall" \
      --gauge "$(printf 'torch + torchvision + torchaudio\nIndex: %s\nLog: %s\n\nESC = háttérbe' \
        "$torch_index" "$fix_log")" \
      12 76 0

  wait "$fix_pid"
  local exit_code=$?
  cat "$fix_log" >> "$LOGFILE" 2>/dev/null

  if [ $exit_code -eq 0 ]; then
    # Ellenőrzés: most már ismeri-e sm_120-t?
    if _vllm_check_pytorch_blackwell; then
      log "INFO" "PyTorch Blackwell fix SIKERES — sm_120 most támogatott"
      whiptail --msgbox "✓ PyTorch Blackwell fix kész!\n\nAz RTX 5090 (SM_120) mostantól kompatibilis.\nvLLM most már indítható." 12 60
      infra_state_set "PYTORCH_INDEX" "cu128" 2>/dev/null || true
    else
      log "WARN" "PyTorch Blackwell fix: telepítés kész, de sm_120 még mindig nem látható"
      whiptail --msgbox "⚠ PyTorch reinstall kész, de sm_120 ellenőrzés sikertelen.\nEllenőrizd a logot:\n  $fix_log\n\nPróbáld: source ~/venvs/ai/bin/activate && python -c \"import torch; print(torch.cuda.get_arch_list())\"" 14 72
    fi
  else
    log "ERR" "PyTorch Blackwell fix SIKERTELEN (exit: $exit_code). Log: $fix_log"
    whiptail --msgbox "✗ PyTorch reinstall sikertelen!\n\nLog: $fix_log\n\nManuálisan:\n  source ~/venvs/ai/bin/activate\n  pip install torch --index-url https://download.pytorch.org/whl/cu128 --force-reinstall" 16 72
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

# _vllm_wait_progress: vLLM betöltés figyelő — whiptail gauge-zal
# Háttérben futó vLLM process logját olvasva mutat progress bar-t.
# A vLLM tqdm kimenetéből parse-olja a %-ot (letöltés + VRAM betöltés).
# ESC = gauge bezárása, vLLM fut tovább háttérben.
#
# Forrás: vLLM tqdm formátum:
#   "Downloading shards: 45%|████..."  → letöltési fázis
#   "Loading weights: 78%|████..."     → VRAM betöltési fázis
#   Port :8000 megnyílt → API kész
#
# Paraméterek: $1=modell neve, $2=process PID, $3=timeout mp (default: 720)
# Visszatér: 0 ha port megnyílt (API kész), 1 ha timeout/kilép/hiba
_vllm_wait_progress() {
  local model="$1"
  local pid="$2"
  local max_wait="${3:-720}"  # 12 perc default (nagy modelleknél hosszabb)

  # Monitoring subshell → whiptail gauge stdin-re ír
  # Formátum: "XXX\nN\nszöveg\nXXX\n" → % + szöveg frissítés
  (
    local elapsed=0
    local display_pct=0
    local phase="inicializálás"

    while [ "$elapsed" -lt "$max_wait" ]; do

      # ── 1. Port megnyílt → API kész ──────────────────────────────────────
      if ss -tlnp 2>/dev/null | grep -q ":${VLLM_PORT}\b"; then
        printf 'XXX\n100\n✓ API kész! http://localhost:%d/v1\nXXX\n' "$VLLM_PORT"
        sleep 1
        echo 100
        return 0
      fi

      # ── 2. Process meghalt → hiba ─────────────────────────────────────────
      if ! kill -0 "$pid" 2>/dev/null; then
        printf 'XXX\n100\n✗ vLLM process leállt — ellenőrizd a logot!\nXXX\n'
        sleep 2
        echo 100
        return 1
      fi

      # ── 3. tqdm % kinyerése a log fájlból ─────────────────────────────────
      # vLLM ANSI escape kódokat ír (\r visszaírással frissíti a sort)
      # sed: ANSI escape + CR eltávolítása, majd % keresés
      local raw_log last_log_line tqdm_pct
      raw_log=$(tail -40 "$VLLM_LOG_FILE" 2>/dev/null)
      last_log_line=$(echo "$raw_log" | \
        sed 's/\x1B\[[0-9;]*[mK]//g; s/\r/\n/g' | \
        grep -v '^$' | tail -1 | cut -c1-65)

      # % keresés: "45%|" vagy "45%" formátum
      tqdm_pct=$(echo "$raw_log" | \
        sed 's/\x1B\[[0-9;]*[mK]//g; s/\r/\n/g' | \
        grep -oP '\b\d{1,3}(?=%)' | \
        awk '$1+0 >= 0 && $1+0 <= 100' | \
        tail -1)

      # Fázis meghatározás a log alapján
      if echo "$raw_log" | grep -qi "downloading"; then
        phase="letöltés"
      elif echo "$raw_log" | grep -qi "loading weights\|loading model"; then
        phase="VRAM betöltés"
      elif echo "$raw_log" | grep -qi "warming up\|initializ"; then
        phase="inicializálás"
      fi

      # Progress % számítás
      if [ -n "$tqdm_pct" ] && [[ "$tqdm_pct" =~ ^[0-9]+$ ]]; then
        display_pct="$tqdm_pct"
        # Ha VRAM betöltés fázisban vagyunk, 50%+tqdm/2 skálázás
        # (letöltés 0-50%, betöltés 50-99%)
        if echo "$raw_log" | grep -qi "loading weights"; then
          display_pct=$(( 50 + tqdm_pct / 2 ))
        fi
      else
        # Fake lineáris progress: 0→45% az első 240s-ban (letöltési fázis)
        display_pct=$(( elapsed * 45 / 240 ))
        [ "$display_pct" -gt 45 ] && display_pct=45
      fi

      # Elapsed idő formázás
      local elapsed_min elapsed_sec
      elapsed_min=$(( elapsed / 60 ))
      elapsed_sec=$(( elapsed % 60 ))

      # Gauge frissítés
      printf 'XXX\n%d\n[%s] %dm%02ds  |  %s\nXXX\n' \
        "$display_pct" \
        "$phase" \
        "$elapsed_min" "$elapsed_sec" \
        "${last_log_line:-(log üres, várakozás...)}"

      sleep 5
      elapsed=$(( elapsed + 5 ))
    done

    # Timeout elérve — process valószínűleg még fut, de nagyon lassú
    printf 'XXX\n90\nTimeout (%ds) — vLLM process él, port még nem nyílt meg.\nXXX\n' \
      "$max_wait"
    sleep 2
    echo 100
    return 1
  ) | whiptail \
      --title "vLLM betöltés — RTX 5090 Blackwell SM_120" \
      --gauge "$(printf 'Modell: %s\nLog:    %s\n\nESC = háttérbe küldés (vLLM fut tovább)\n' \
        "$model" "$VLLM_LOG_FILE")" \
      14 76 0

  # ESC vagy gauge vége → ellenőrzés: nyílt-e meg a port?
  ss -tlnp 2>/dev/null | grep -q ":${VLLM_PORT}\b"
}

# _log_system_info: HW/Ollama/vLLM/TurboQuant/CUDA részletes info logolása
# Manage módban az első futáskor hívódik — teljes kontextus a log fájlban
_log_system_info() {
  log "INFO" "══════════════════════════════════════════════════════"
  log "INFO" "  AI Model Manager v${MOD_VERSION} — Rendszer info"
  log "INFO" "══════════════════════════════════════════════════════"

  # ── Hardver ────────────────────────────────────────────────────────────────
  log "HW" "GPU:    ${HW_GPU_NAME:-ismeretlen}"
  log "HW" "Profil: ${HW_PROFILE:-?}  |  CUDA arch: ${HW_CUDA_ARCH:-?}"
  log "HW" "Driver: ${INST_DRIVER_VER:-?}  |  CUDA ver: ${INST_CUDA_VER:-?}"
  log "HW" "vLLM kompatibilis: ${HW_VLLM_OK:-false}"
  log "HW" "TurboQuant mód: ${TURBOQUANT_BUILD_MODE:-?}"

  # ── nvidia-smi GPU állapot ─────────────────────────────────────────────────
  local nvsmi
  nvsmi=$(nvidia-smi --query-gpu=name,memory.used,memory.free,memory.total,temperature.gpu \
    --format=csv,noheader,nounits 2>/dev/null | head -1)
  if [ -n "$nvsmi" ]; then
    log "HW" "nvidia-smi: $nvsmi"
  else
    log "HW" "nvidia-smi: nem elérhető"
  fi

  # ── CUDA ───────────────────────────────────────────────────────────────────
  local nvcc_ver
  nvcc_ver=$(nvcc --version 2>/dev/null | grep -oP 'release \K[\d.]+' | head -1)
  log "CUDA" "nvcc verzió: ${nvcc_ver:-(nem elérhető)}"
  local cuda_runtime
  cuda_runtime=$(python3 -c "import torch; print(torch.version.cuda)" 2>/dev/null)
  log "CUDA" "PyTorch CUDA runtime: ${cuda_runtime:-(nem elérhető)}"

  # ── Ollama ─────────────────────────────────────────────────────────────────
  local ollama_ver
  ollama_ver=$(ollama version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  log "OLLAMA" "Verzió: ${ollama_ver:-?}"
  local ollama_svc
  ollama_svc=$(systemctl is-active ollama 2>/dev/null)
  log "OLLAMA" "Service: ${ollama_svc:-?}"
  # Telepített modellek
  local model_count
  model_count=$(_ollama_api GET "/api/tags" | python3 -c "
import json,sys
try: print(len(json.load(sys.stdin).get('models',[])))
except: print('?')
" 2>/dev/null)
  log "OLLAMA" "Telepített modellek: ${model_count:-?} db"

  # ── vLLM ───────────────────────────────────────────────────────────────────
  local vllm_ver
  vllm_ver=$([ -x "$VENV_VLLM" ] && "$VENV_VLLM" --version 2>/dev/null | head -1 || echo "?")
  log "VLLM" "Verzió: ${vllm_ver:-?}"
  log "VLLM" "Venv: $AI_VENV_DIR"
  log "VLLM" "Port: ${VLLM_PORT}  dtype: ${VLLM_DTYPE}  gpu-mem: ${VLLM_GPU_MEM_UTIL}"
  if _is_vllm_running; then
    local vllm_pid
    vllm_pid=$(cat "$VLLM_PID_FILE" 2>/dev/null)
    log "VLLM" "Állapot: FUT (PID: ${vllm_pid:-?})"
  else
    log "VLLM" "Állapot: leállított"
  fi

  # ── TurboQuant ─────────────────────────────────────────────────────────────
  if [ -d "$TQ_DIR" ]; then
    local tq_commit
    tq_commit=$(git -C "$TQ_DIR" rev-parse --short HEAD 2>/dev/null)
    log "TQ" "Könyvtár: $TQ_DIR  (commit: ${tq_commit:-?})"
    log "TQ" "Build mód: ${TURBOQUANT_BUILD_MODE:-?}"
    log "TQ" "Kvantált modellek: $(find "$TQ_QUANTIZED_DIR" -name '*.gguf' 2>/dev/null | wc -l) db"
  else
    log "TQ" "TurboQuant könyvtár hiányzik: $TQ_DIR"
  fi

  log "INFO" "Log fájl: $LOGFILE"
  log "INFO" "══════════════════════════════════════════════════════"
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
# MODELL BÖNGÉSZŐ SEGÉDFÜGGVÉNYEK
# =============================================================================

# _ollama_model_radiolist: telepített Ollama modellek radiolist-je MÉRETEKKEL
# A betöltés és VRAM ürítés menükben használja — a felhasználó látja a GB-okat
# Kimenet: stdout-ra írja a kiválasztott modell NEVÉT (méret nélkül)
# Paraméterek: $1=title, $2=prompt
_ollama_model_radiolist() {
  local title="${1:-Modell választás}"
  local prompt="${2:-Válaszd a modellt (SPACE = jelöl, ENTER = OK):}"

  # Modellek lekérése mérettel együtt — GET /api/tags
  # Forrás: https://ollama.readthedocs.io/en/api/ (official)
  local raw_json
  raw_json=$(_ollama_api GET "/api/tags")
  if [ -z "$raw_json" ]; then
    whiptail --msgbox "Ollama API nem elérhető!\n(Fut-e az ollama service?)" 10 50
    echo ""; return 1
  fi

  # Két párhuzamos tömb: clean_names (csak név) + label_names (név + méret)
  local clean_names=() label_names=()
  while IFS=$'\t' read -r name label; do
    clean_names+=("$name")
    label_names+=("$label")
  done < <(echo "$raw_json" | python3 -c "
import json, sys
try:
  data = json.load(sys.stdin)
  for m in data.get('models', []):
    sz_gb = m.get('size', 0) / 1e9
    # Tab-elválasztott: tiszta_név\tcimke
    print(f\"{m['name']}\t{m['name']}  ({sz_gb:.1f} GB)\")
except: pass
" 2>/dev/null)

  if [ ${#clean_names[@]} -eq 0 ]; then
    whiptail --msgbox "Nincs telepített Ollama modell!\nHasználd a 'Letöltés' opciót." 10 50
    echo ""; return 1
  fi

  # Radiolist összeállítás: index "név  (X.X GB)" OFF
  local menu_items=()
  for ((i=0; i<${#clean_names[@]}; i++)); do
    menu_items+=("$((i+1))" "${label_names[$i]}" "OFF")
  done

  local sel_idx
  sel_idx=$(whiptail --title "$title" \
    --radiolist "$prompt" \
    22 72 "${#clean_names[@]}" \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || { echo ""; return 1; }

  # Csak a tiszta nevet adjuk vissza (méret nélkül)
  echo "${clean_names[$((sel_idx-1))]}"
}

# _popular_model_browse: népszerű modellek katalógusa letöltéshez
# Kategóriák: code (kódgenerálás), chat (általános), embed (RAG), reason (érvelés)
# A lista tartalmazza a 2025-2026-ban legelterjedtebb Ollama-kompatibilis modelleket
# Paraméter: $1=szűrő kategória (all|code|chat|embed|reason), alapért.: all
# Kimenet: stdout-ra írja a kiválasztott modell nevét, vagy "" ha cancel/egyedi
_popular_model_browse() {
  local filter="${1:-all}"

  # Kuráló lista: "ollama_name" "leírás" "kategória"
  # Forrás: ollama.com/library (official modell katalógus)
  local -a _cat _name _desc
  _name+=("qwen2.5-coder:1.5b");      _desc+=("[KÓD]   Qwen2.5 Coder 1.5B  — tab-autocomplete, gyors (1.0 GB)");  _cat+=("code")
  _name+=("qwen2.5-coder:7b");        _desc+=("[KÓD]   Qwen2.5 Coder 7B    — ajánlott kódassistens (4.7 GB)");     _cat+=("code")
  _name+=("qwen2.5-coder:14b");       _desc+=("[KÓD]   Qwen2.5 Coder 14B   — erős kódgenerálás (9.0 GB)");         _cat+=("code")
  _name+=("qwen2.5-coder:32b");       _desc+=("[KÓD]   Qwen2.5 Coder 32B   — SOTA kód, RTX 5090 (19 GB)");         _cat+=("code")
  _name+=("deepseek-coder-v2:16b");   _desc+=("[KÓD]   DeepSeek Coder V2 16B — MoE, gyors (8.9 GB)");              _cat+=("code")
  _name+=("codestral:22b");           _desc+=("[KÓD]   Codestral 22B        — Mistral kódmodell (13 GB)");          _cat+=("code")
  _name+=("qwen2.5:7b");              _desc+=("[CHAT]  Qwen2.5 7B            — általános chat (4.7 GB)");            _cat+=("chat")
  _name+=("qwen2.5:14b");             _desc+=("[CHAT]  Qwen2.5 14B           — erős általános (9.0 GB)");            _cat+=("chat")
  _name+=("qwen2.5:32b");             _desc+=("[CHAT]  Qwen2.5 32B           — nagy általános (19 GB)");             _cat+=("chat")
  _name+=("llama3.3:70b");            _desc+=("[CHAT]  Llama 3.3 70B         — Meta flagship (42 GB)");              _cat+=("chat")
  _name+=("mistral:7b");              _desc+=("[CHAT]  Mistral 7B             — gyors, megbízható (4.1 GB)");        _cat+=("chat")
  _name+=("gemma3:12b");              _desc+=("[CHAT]  Gemma 3 12B            — Google, hatékony (8.1 GB)");         _cat+=("chat")
  _name+=("deepseek-r1:7b");          _desc+=("[REASON] DeepSeek R1 7B       — chain-of-thought (4.7 GB)");          _cat+=("reason")
  _name+=("deepseek-r1:14b");         _desc+=("[REASON] DeepSeek R1 14B      — erős érvelő (9.0 GB)");               _cat+=("reason")
  _name+=("deepseek-r1:32b");         _desc+=("[REASON] DeepSeek R1 32B      — SOTA reasoning (19 GB)");             _cat+=("reason")
  _name+=("nomic-embed-text");        _desc+=("[EMBED] Nomic Embed Text       — RAG, Continue.dev (0.3 GB)");        _cat+=("embed")
  _name+=("mxbai-embed-large");       _desc+=("[EMBED] MxBAI Embed Large      — RAG, nagy dimenzió (0.7 GB)");      _cat+=("embed")
  _name+=("bge-m3");                  _desc+=("[EMBED] BGE-M3                 — multilingual RAG (1.2 GB)");        _cat+=("embed")

  # BUGFIX: kategória szűrő menü CSAK akkor jelenik meg, ha filter="all"
  # Korábban: mindig megjelent → rekurzív hívás esetén kétszer mutatta a szűrőt
  # Most: _popular_model_browse "code" hívás esetén AZONNAL a code listát mutatja
  if [ "$filter" = "all" ]; then
    local cat_choice
    cat_choice=$(whiptail --title "Modell katalógus" \
      --menu "Modell kategória szűrő:" 14 65 5 \
      "1" "Összes modell megjelenítése" \
      "2" "Csak kódgenerálás [KÓD]" \
      "3" "Csak chat modellek [CHAT]" \
      "4" "Csak érvelő modellek [REASON]" \
      "5" "Csak embedding modellek [EMBED]" \
      3>&1 1>&2 2>&3) || { echo "CANCEL"; return 1; }

    # Szűrő paraméter beállítása a választás alapján (nem rekurzív hívás!)
    case "$cat_choice" in
      2) filter="code" ;;
      3) filter="chat" ;;
      4) filter="reason" ;;
      5) filter="embed" ;;
      # 1 = összes → filter marad "all"
    esac
  fi

  # Telepített Ollama modellek lekérése ✓ jelöléshez
  # GET /api/tags → name mező → set-be rakjuk a gyors lookup-hoz
  local installed_set=""
  if _is_ollama_running; then
    installed_set=$(_ollama_api GET "/api/tags" | python3 -c "
import json,sys
try:
  data=json.load(sys.stdin)
  for m in data.get('models',[]): print(m['name'])
except: pass
" 2>/dev/null | tr '\n' '|')
  fi

  # Szűrés kategória szerint — a fentebb beállított filter alapján
  # ✓ jelölés: ha a modell neve szerepel a telepítettlista-ban
  local menu_items=() filtered_names=()
  local idx=1
  for ((i=0; i<${#_name[@]}; i++)); do
    [ "$filter" != "all" ] && [ "${_cat[$i]}" != "$filter" ] && continue
    # ✓ marker ha már le van töltve
    local marker=""
    if [[ "$installed_set" == *"|${_name[$i]}|"* ]] || \
       [[ "$installed_set" == "${_name[$i]}|"* ]]; then
      marker=" ✓"
    fi
    menu_items+=("$idx" "${_desc[$i]}${marker}" "OFF")
    filtered_names+=("${_name[$i]}")
    ((idx++))
  done

  if [ ${#filtered_names[@]} -eq 0 ]; then
    whiptail --msgbox "Nincs modell ebben a kategóriában: ${filter}" 8 55
    echo "CANCEL"; return 1
  fi

  # Tényleges modell választó lista
  local sel_idx
  sel_idx=$(whiptail --title "Modell katalógus — ${filter}" \
    --radiolist "Válassz modellt (SPACE=jelöl, ENTER=OK):" \
    24 80 "${#filtered_names[@]}" \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || { echo "CANCEL"; return 1; }

  echo "${filtered_names[$((sel_idx-1))]}"
}

# _vllm_model_browse: vLLM-hez ajánlott HuggingFace modellek katalógusa
# vLLM HuggingFace formátumot vár — ezek az Ollama nevektől eltérhetnek
# A lista a HF Hub model ID-kat tartalmazza (vllm serve MODEL_ID)
_vllm_model_browse() {
  # HuggingFace lokális cache ellenőrzés — letöltött modellek ✓ jelölése
  # HF cache: ~/.cache/huggingface/hub/models--<owner>--<repo>/
  local hf_cache_dir="${_REAL_HOME}/.cache/huggingface/hub"
  _hf_is_cached() {
    local hf_id="$1"
    # Konverzió: "Qwen/Qwen2.5-7B" → "models--Qwen--Qwen2.5-7B"
    local cache_name="models--${hf_id//\//-}"
    [ -d "${hf_cache_dir}/${cache_name}" ]
  }

  # HuggingFace model ID-k és leírások
  local hf_ids=(
    "Qwen/Qwen2.5-Coder-7B-Instruct"
    "Qwen/Qwen2.5-Coder-14B-Instruct"
    "Qwen/Qwen2.5-Coder-32B-Instruct"
    "Qwen/Qwen2.5-7B-Instruct"
    "Qwen/Qwen2.5-14B-Instruct"
    "Qwen/Qwen2.5-32B-Instruct"
    "deepseek-ai/DeepSeek-R1-Distill-Qwen-7B"
    "deepseek-ai/DeepSeek-R1-Distill-Qwen-14B"
    "deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct"
    "mistralai/Mistral-7B-Instruct-v0.3"
    "google/gemma-3-12b-it"
    "meta-llama/Llama-3.3-70B-Instruct"
  )
  local hf_descs=(
    "[KÓD-7B]   Qwen/Qwen2.5-Coder-7B-Instruct     (4.7 GB, VRAM~8GB)"
    "[KÓD-14B]  Qwen/Qwen2.5-Coder-14B-Instruct     (9 GB, VRAM~14GB)"
    "[KÓD-32B]  Qwen/Qwen2.5-Coder-32B-Instruct     (19 GB, VRAM~25GB)"
    "[CHAT-7B]  Qwen/Qwen2.5-7B-Instruct            (4.7 GB, VRAM~8GB)"
    "[CHAT-14B] Qwen/Qwen2.5-14B-Instruct           (9 GB, VRAM~14GB)"
    "[CHAT-32B] Qwen/Qwen2.5-32B-Instruct           (19 GB, VRAM~25GB)"
    "[REASON]   deepseek-ai/DeepSeek-R1-Distill-Qwen-7B  (4.7 GB)"
    "[REASON]   deepseek-ai/DeepSeek-R1-Distill-Qwen-14B (9 GB)"
    "[CODE]     deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct (8.9 GB)"
    "[CHAT]     mistralai/Mistral-7B-Instruct-v0.3  (4.1 GB, VRAM~6GB)"
    "[CHAT]     google/gemma-3-12b-it                (8.1 GB, VRAM~12GB)"
    "[CHAT-70B] meta-llama/Llama-3.3-70B-Instruct   (42 GB — RTX 5090!)"
  )

  # Dinamikus menu_items: HF cache-ben lévő modellek ✓ jelölése
  # HF cache útvonal: ~/.cache/huggingface/hub/models--<owner>--<repo>/
  local menu_items=()
  for ((i=0; i<${#hf_ids[@]}; i++)); do
    local hf_id="${hf_ids[$i]}"
    local cache_name="models--${hf_id//\//-}"
    local marker=""
    [ -d "${hf_cache_dir}/${cache_name}" ] && marker=" ✓"
    menu_items+=("$((i+1))" "${hf_descs[$i]}${marker}" "OFF")
  done

  local sel_idx
  sel_idx=$(whiptail --title "vLLM modell katalógus (HuggingFace)" \
    --radiolist "vLLM HuggingFace modellek — RTX 5090 optimalizált:" \
    24 82 "${#hf_ids[@]}" \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || { echo "CANCEL"; return 1; }

  echo "${hf_ids[$((sel_idx-1))]}"
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
      22 76 5 \
      "1" "Modell betöltés VRAM-ba (méretekkel)" \
      "2" "Modell kiürítés VRAM-ból" \
      "3" "Új modell letöltése (katalógus / kézi)" \
      "4" "Letöltött modellek listája (ollama list)" \
      "0" "← Vissza" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      1)
        # Betöltendő modell választás méretekkel — _ollama_model_radiolist segédfüggvény
        # A függvény GET /api/tags alapján lista + méret GB-ban, csak nevet ad vissza
        local sel_model
        sel_model=$(_ollama_model_radiolist \
          "Modell betöltés VRAM-ba" \
          "Válaszd a betöltendő modellt (SPACE = jelöl, ENTER = OK):")
        [ -z "$sel_model" ] && continue
        _ollama_load_model "$sel_model"
        whiptail --msgbox "Betöltve: ${sel_model}\n\nA modell a VRAM-ban marad (keep_alive=-1)." 10 60
        ;;
      2)
        # VRAM-ban lévő modellek listája méretekkel
        local running_models running_vrams
        mapfile -t running_models < <(
          _ollama_api GET "/api/ps" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  for m in d.get('models',[]): print(m['name'])
except: pass
" 2>/dev/null)
        mapfile -t running_vrams < <(
          _ollama_api GET "/api/ps" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  for m in d.get('models',[]): print(f\"{m['name']}  VRAM: {m.get('size_vram',0)/1e9:.1f} GB\")
except: pass
" 2>/dev/null)
        if [ ${#running_models[@]} -eq 0 ]; then
          whiptail --msgbox "Nincs VRAM-ban lévő modell." 8 50
          continue
        fi
        local menu_items=()
        for ((i=0; i<${#running_models[@]}; i++)); do
          menu_items+=("$((i+1))" "${running_vrams[$i]:-${running_models[$i]}}" "OFF")
        done
        local sel_idx
        sel_idx=$(whiptail --title "VRAM ürítés" \
          --radiolist "Válaszd az eltávolítandó modellt:" \
          18 76 "${#running_models[@]}" \
          "${menu_items[@]}" \
          3>&1 1>&2 2>&3) || continue
        local sel_model="${running_models[$((sel_idx-1))]}"
        _ollama_unload_model "$sel_model"
        whiptail --msgbox "VRAM-ból eltávolítva: ${sel_model}" 8 60
        ;;
      3)
        # Modell letöltése: katalógusból böngészés VAGY kézi bevitel
        local pull_choice
        pull_choice=$(whiptail --title "Modell letöltés" \
          --menu "Hogyan választasz modellt?" 12 65 3 \
          "1" "Katalógusból böngészés (ajánlott modellek)" \
          "2" "Kézi bevitel (ollama modell neve)" \
          "0" "← Vissza" \
          3>&1 1>&2 2>&3) || continue

        local model_name=""
        case "$pull_choice" in
          1)
            # Népszerű modellek katalógusa kategória szűrővel
            # _popular_model_browse: ollama.com/library alapján kuráló lista
            model_name=$(_popular_model_browse "all")
            # ESC / Cancel → vissza a menübe, NEM kézi bevitel (volt a bug)
            if [ "$model_name" = "CANCEL" ] || [ -z "$model_name" ]; then
              continue
            fi
            ;;
          2)
            model_name=$(whiptail --title "Ollama pull — kézi bevitel" \
              --inputbox "Modell neve (pl. qwen2.5-coder:7b, llama3.3:70b):" \
              10 65 "" 3>&1 1>&2 2>&3) || continue
            ;;
          0) continue ;;
        esac
        [ -z "$model_name" ] && continue
        _ollama_pull_model "$model_name"
        ;;
      4)
        # Letöltött modellek részletes listája — 'ollama list' kimenet
        local full_list
        full_list=$(sudo -u "$_REAL_USER" ollama list 2>/dev/null || echo "Hiba: ollama list futtatása sikertelen")
        whiptail --title "Letöltött modellek (ollama list)" \
          --scrolltext --msgbox "$full_list" 22 80
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
        # Ollama backend: telepített modellek radiolistából VAGY katalógusból
        local model
        local src_choice
        src_choice=$(whiptail --title "Ollama modell kiválasztás" \
          --menu "Honnan választasz modellt?" 12 65 3 \
          "1" "Telepített modellek listájából (méretekkel)" \
          "2" "Katalógusból böngészés (ajánlott modellek)" \
          "3" "Kézi bevitel" \
          3>&1 1>&2 2>&3) || continue
        case "$src_choice" in
          1) model=$(_ollama_model_radiolist "Ollama backend modell" \
               "CLINE/Continue modell kiválasztása:") ;;
          2) model=$(_popular_model_browse "code")
             # CANCEL → vissza a menübe
             [ "$model" = "CANCEL" ] && continue
             [ -z "$model" ] && continue ;;
          3) model=$(whiptail --title "Ollama modell" \
               --inputbox "Ollama modell neve:" 10 60 \
               "$OLLAMA_DEFAULT_CODE_MODEL" 3>&1 1>&2 2>&3) || continue ;;
        esac
        [ -z "$model" ] && continue
        _ide_switch_backend "ollama" "$model"
        whiptail --msgbox "CLINE + Continue.dev → Ollama backend\nModell: $model\n\nIndítsd újra a VS Code-ot!" 12 60
        ;;
      2)
        if ! _is_vllm_running; then
          whiptail --msgbox "vLLM nem fut!\nIndítsd el előbb a vLLM szerver almenüből." 10 55
          continue
        fi
        # vLLM backend: futó modellek lekérdezése VAGY manuális megadás
        local model
        local vllm_served
        vllm_served=$(curl -s --connect-timeout 3 \
          "http://localhost:${VLLM_PORT}/v1/models" 2>/dev/null | \
          python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  for m in d.get('data',[]): print(m['id'])
except: pass
" 2>/dev/null)
        if [ -n "$vllm_served" ]; then
          # vLLM fut és van betöltött modell → automatikusan vesszük
          model=$(echo "$vllm_served" | head -1)
          whiptail --msgbox "vLLM futó modell automatikusan detektálva:\n${model}" 10 65
        else
          # Nincs futó modell → browse
          model=$(_vllm_model_browse)
          [ "$model" = "CANCEL" ] || [ -z "$model" ] && \
            model=$(whiptail --title "vLLM modell ID" \
              --inputbox "HuggingFace model ID:" 10 65 "" 3>&1 1>&2 2>&3) || continue
        fi
        [ -z "$model" ] && continue
        _ide_switch_backend "vllm" "$model"
        whiptail --msgbox "CLINE + Continue.dev → vLLM backend\nEndpoint: http://localhost:${VLLM_PORT}/v1\nModell: $model\n\nIndítsd újra a VS Code-ot!" 14 65
        ;;
      3)
        # Gyors CLINE Ollama model frissítés — radiolist + katalógus opció
        local model
        local src_choice
        src_choice=$(whiptail --title "CLINE modell" \
          --menu "Honnan választasz?" 11 60 3 \
          "1" "Telepített modellek (méretekkel)" \
          "2" "Katalógusból" \
          "3" "Kézi bevitel" \
          3>&1 1>&2 2>&3) || continue
        case "$src_choice" in
          1) model=$(_ollama_model_radiolist "CLINE kód modell" "Válaszd a CLINE modellt:") ;;
          2) model=$(_popular_model_browse "code")
             [ "$model" = "CANCEL" ] && continue
             [ -z "$model" ] && continue ;;
          3) model=$(whiptail --title "CLINE modell" --inputbox "Ollama modell neve:" \
               10 60 "$OLLAMA_DEFAULT_CODE_MODEL" 3>&1 1>&2 2>&3) || continue ;;
        esac
        [ -z "$model" ] && continue
        _ide_config_cline_ollama "$model"
        whiptail --msgbox "CLINE modell frissítve: $model\n(VS Code újraindítás szükséges)" 10 60
        ;;
      4)
        # vLLM CLINE modell — browse vagy kézi
        local model
        local src_choice
        src_choice=$(whiptail --title "vLLM modell" \
          --menu "Honnan választasz?" 10 60 2 \
          "1" "vLLM modell katalógus (HuggingFace)" \
          "2" "Kézi HF model ID bevitel" \
          3>&1 1>&2 2>&3) || continue
        case "$src_choice" in
          1) model=$(_vllm_model_browse)
             [ "$model" = "CANCEL" ] && continue
             [ -z "$model" ] && continue ;;
          2) model=$(whiptail --title "vLLM modell ID" \
               --inputbox "HuggingFace model ID (pl. Qwen/Qwen2.5-Coder-7B-Instruct):" \
               10 72 "" 3>&1 1>&2 2>&3) || continue ;;
        esac
        [ -z "$model" ] && continue
        _ide_config_cline_vllm "$model"
        whiptail --msgbox "CLINE → vLLM backend\nModell: $model\n(VS Code újraindítás szükséges)" 11 65
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
      20 76 7 \
      "1" "vLLM indítás (model megadással)" \
      "2" "vLLM leállítás" \
      "3" "vLLM állapot + logok megtekintése" \
      "4" "systemd service engedélyezés/tiltás" \
      "5" "Konfigurált paraméterek" \
      "6" "⚠ PyTorch Blackwell fix (SM_120, cu128 reinstall)" \
      "0" "← Vissza" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      1)
        # vLLM indítás: katalógusból browse VAGY kézi HF ID megadás
        local model src_choice
        src_choice=$(whiptail --title "vLLM modell kiválasztás" \
          --menu "Honnan választasz modellt?" 12 70 3 \
          "1" "vLLM modell katalógus (HuggingFace, ajánlott)" \
          "2" "Kézi HuggingFace model ID bevitel" \
          "0" "← Vissza" \
          3>&1 1>&2 2>&3) || continue
        case "$src_choice" in
          1)
            model=$(_vllm_model_browse)
            # Ha katalógusból cancel → kézi bevitelre felajánlás
            if [ "$model" = "CANCEL" ] || [ -z "$model" ]; then
              model=$(whiptail --title "vLLM modell — kézi bevitel" \
                --inputbox "HuggingFace model ID:\n(pl. Qwen/Qwen2.5-Coder-7B-Instruct)" \
                12 72 "" 3>&1 1>&2 2>&3) || continue
            fi
            ;;
          2)
            model=$(whiptail --title "vLLM modell — kézi bevitel" \
              --inputbox "HuggingFace model ID:\n(pl. Qwen/Qwen2.5-Coder-7B-Instruct)" \
              12 72 "" 3>&1 1>&2 2>&3) || continue
            ;;
          0) continue ;;
        esac
        [ -z "$model" ] && continue
        if _vllm_start "$model"; then
          # vLLM process elindult → progress gauge megjelenítése
          # A gauge a log fájlból olvassa a tqdm %-ot és frissíti magát
          # ESC megnyomásával a gauge bezárul, vLLM fut tovább háttérben
          local vllm_pid
          vllm_pid=$(cat "$VLLM_PID_FILE" 2>/dev/null)
          if _vllm_wait_progress "$model" "$vllm_pid" 720; then
            # Port megnyílt → API kész
            whiptail --msgbox "✓ vLLM API kész!\n\nModell: $model\nEndpoint: http://localhost:${VLLM_PORT}/v1\n\nBackend váltó menüben állítsd be a CLINE/Continue-t." 14 68
          else
            # ESC vagy timeout — process él, API még nem elérhető
            whiptail --msgbox "vLLM process fut, API még nem elérhető.\n\nFolytatódik háttérben. Ellenőrzés:\n  tail -f ${VLLM_LOG_FILE}\n\nvLLM állapot menüpontban látod ha kész." 14 70
          fi
        else
          whiptail --msgbox "vLLM indítás SIKERTELEN!\n\nLog: ${VLLM_LOG_FILE}\n\n$(tail -8 "$VLLM_LOG_FILE" 2>/dev/null)" 20 74
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
  Prefix caching:    $([ "$VLLM_ENABLE_PREFIX_CACHE" = "1" ] && echo ON || echo OFF)

  PID fájl:   ${VLLM_PID_FILE}
  Log fájl:   ${VLLM_LOG_FILE}
  vLLM bin:   ${VENV_VLLM}

  PyTorch SM_120 compat: $(
    _vllm_check_pytorch_blackwell 2>/dev/null && echo "✓ OK" || echo "✗ INKOMPATIBILIS — cu128 fix szükséges!")

  API: http://localhost:${VLLM_PORT}/v1/chat/completions
       http://localhost:${VLLM_PORT}/v1/models
" 28 72
        ;;
      6)
        # PyTorch Blackwell fix — önálló menüponként is elérhető
        # Ugyanaz mint amit _vllm_start() is felajánl inkompatibilitás esetén
        _vllm_fix_pytorch_blackwell
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
  #
  # FONTOS: infra_require() helyett direkt grep a state fájlba!
  # infra_require() az INFRA_NAME["02"] registry tömbből olvassa a modul nevét.
  # Ha a 09-es script önállóan fut (00_registry.sh nincs source-olva),
  # az INFRA_NAME tömb üres → infra_require() "INFRA 02" névvel hibát dob
  # még akkor is, ha MOD_02_DONE=true szerepel a state fájlban.
  # Megoldás: direkt grep a state fájlban — registry függőség nélkül.
  local _prereq_state="${_REAL_HOME}/.infra-state"
  if ! grep -q "^MOD_02_DONE=true" "$_prereq_state" 2>/dev/null; then
    dialog_warn "Függőség hiányzik" \
      "02 modul szükséges: Ollama + vLLM + TurboQuant\n\nFuttasd előbb:\n  RUN_MODE=install sudo bash 02_local_ai_stack.sh" 14
    return 1
  fi
  if ! grep -q "^MOD_06_DONE=true" "$_prereq_state" 2>/dev/null; then
    dialog_warn "Függőség hiányzik" \
      "06 modul szükséges: VS Code + CLINE + Continue.dev\n\nFuttasd előbb:\n  RUN_MODE=install sudo bash 06_editors.sh" 14
    return 1
  fi
  log "INFO" "Előfeltételek OK: MOD_02_DONE=true, MOD_06_DONE=true"

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
      # Rendszer info logolása induláskor (HW/Ollama/vLLM/TQ/CUDA)
      _log_system_info
      _manage_main_menu
      ;;

    *)
      log "WARN" "Ismeretlen RUN_MODE: '${RUN_MODE}' — manage módba esik"
      _manage_main_menu
      ;;
  esac
}

main "$@"
