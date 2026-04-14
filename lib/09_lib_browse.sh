#!/bin/bash
# =============================================================================
# lib/09_lib_browse.sh — AI Model Manager böngésző UI v1.0
#
# TARTALOM:
#   _ollama_model_radiolist()  — telepített Ollama modellek radiolist-je
#   _model_catalog_browse()    — egységes modell katalógus böngésző
#   _popular_model_browse()    — Ollama wrapper (visszafelé-kompatibilis)
#   _vllm_model_browse()       — vLLM wrapper (visszafelé-kompatibilis)
#
# FÜGGŐSÉGEK (a főscript definiálja):
#   _is_ollama_running()  — Ollama service fut-e
#   _ollama_api()         — REST API hívás
#   _MDB_* tömbök         — 09_lib_models.sh _init_model_db() tölti be
#   _REAL_HOME, _REAL_USER — lib/00_lib_core.sh
#   log()                 — lib/00_lib_core.sh
#
# BETÖLTÉS:
#   source lib/09_lib_browse.sh
#   (09_ai_model_wrapper.sh hívja 09_lib_models.sh UTÁN)
#
# MENÜ SZABÁLY: ESC / Cancel → MINDIG a szülő menübe lép vissza
#   Nincs fallback inputbox ha valaki kilép a katalógusból!
#   Minden CANCEL visszatér: echo "CANCEL"; return 1
#
# VERZIÓ: v1.0
# =============================================================================

# _ollama_model_radiolist: telepített Ollama modellek radiolist-je MÉRETEKKEL
# GET /api/tags → modellek neve + mérete GB-ban
# Forrás: https://ollama.readthedocs.io/en/api/ (official)
#
# Paraméterek: $1=title, $2=prompt szöveg
# Kimenet: stdout → választott modell neve (méret nélkül), vagy "" ha cancel
_ollama_model_radiolist() {
  local title="${1:-Modell választás}"
  local prompt="${2:-Válaszd a modellt (SPACE=jelöl, ENTER=OK):}"

  local raw_json
  raw_json=$(_ollama_api GET "/api/tags")
  if [ -z "$raw_json" ]; then
    whiptail --msgbox "Ollama API nem elérhető!\n(Fut-e az ollama service?)" 10 50
    echo ""; return 1
  fi

  # Két párhuzamos tömb: tiszta név + label (névvel és mérettel)
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
    print(f\"{m['name']}\t{m['name']}  ({sz_gb:.1f} GB)\")
except: pass
" 2>/dev/null)

  if [ ${#clean_names[@]} -eq 0 ]; then
    whiptail --msgbox "Nincs telepített Ollama modell!\nHasználd a 'Letöltés' opciót." 10 50
    echo ""; return 1
  fi

  # Dinamikus ablakméret
  local term_cols term_rows win_w win_h list_h
  term_cols=$(tput cols 2>/dev/null || echo 80)
  term_rows=$(tput lines 2>/dev/null || echo 24)
  win_w=$(( term_cols * 90 / 100 )); [ "$win_w" -lt 70 ] && win_w=70; [ "$win_w" -gt 160 ] && win_w=160
  list_h="${#clean_names[@]}"; win_h=$(( list_h + 8 ))
  [ "$win_h" -gt $(( term_rows - 2 )) ] && win_h=$(( term_rows - 2 ))
  [ "$list_h" -gt $(( win_h - 8 )) ] && list_h=$(( win_h - 8 ))
  [ "$list_h" -lt 4 ] && list_h=4

  local menu_items=()
  for ((i=0; i<${#clean_names[@]}; i++)); do
    menu_items+=("$((i+1))" "${label_names[$i]:0:$(( win_w - 8 ))}" "OFF")
  done

  local sel_idx
  sel_idx=$(whiptail --title "$title" \
    --radiolist "$prompt" \
    "$win_h" "$win_w" "$list_h" \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || { echo ""; return 1; }

  echo "${clean_names[$((sel_idx-1))]}"
}

# _model_catalog_browse: egységes modell katalógus böngésző
#
# Minden browse menüből elérhető — HuggingFace TASK szűrővel, ✓ jelöléssel.
# TASK kategóriák (huggingface.co/tasks alapján):
#   CODE    — text-generation (coding)
#   CHAT    — text-generation (general)
#   REASON  — text-generation (reasoning)
#   EMBED   — feature-extraction, sentence-similarity
#   VISION  — image-text-to-text
#   AGENT   — text-generation (tool-use, agentic)
#   ASR     — automatic-speech-recognition
#
# MENÜ SZABÁLY: ESC → CANCEL visszaadás, NINCS fallback input!
#
# Paraméterek:
#   $1 = backend: "ollama" | "vllm" | "all"
#        ollama → Ollama neve (pl. "qwen2.5-coder:7b")
#        vllm   → HuggingFace ID (pl. "Qwen/Qwen2.5-Coder-7B")
#        all    → mindkét backend kompatibilis modellek
#   $2 = task filter: "all"|"code"|"chat"|"reason"|"embed"|"vision"|"agent"|"asr"
#
# Kimenet: stdout → modell neve/ID, vagy "CANCEL"
_model_catalog_browse() {
  local backend="${1:-ollama}"
  local filter="${2:-all}"

  # Lazy init — ha az adatbázis még nincs betöltve
  [ ${#_MDB_OLLAMA[@]} -eq 0 ] && _init_model_db

  # TASK szűrő menü — csak "all" esetén jelenik meg (nem rekurzív!)
  if [ "$filter" = "all" ]; then
    local cat_choice
    cat_choice=$(whiptail --title "Modell katalógus — HuggingFace TASK szűrő" \
      --menu "Melyik kategóriából választasz?" 22 76 9 \
      "1" "Összes modell (minden TASK)" \
      "2" "[CODE]   Kódgenerálás — CLINE/Continue kód asszisztens" \
      "3" "[CHAT]   Általános chat — text-generation" \
      "4" "[REASON] Érvelő modellek — chain-of-thought" \
      "5" "[EMBED]  Embedding / RAG — feature-extraction" \
      "6" "[VISION] Vision + Language — image-text-to-text" \
      "7" "[AGENT]  Agentic / Tool-use — function calling" \
      "8" "[ASR]    Beszédfelismerés — automatic-speech-recognition" \
      3>&1 1>&2 2>&3) || { echo "CANCEL"; return 1; }
    case "$cat_choice" in
      2) filter="code"   ;;
      3) filter="chat"   ;;
      4) filter="reason" ;;
      5) filter="embed"  ;;
      6) filter="vision" ;;
      7) filter="agent"  ;;
      8) filter="asr"    ;;
      # 1 = összes → filter marad "all"
    esac
  fi

  # ── ✓ jelölés: Ollama telepített modellek ─────────────────────────────────
  local installed_set=""
  if _is_ollama_running; then
    installed_set=$(_ollama_api GET "/api/tags" 2>/dev/null | python3 -c "
import json,sys
try:
  data=json.load(sys.stdin)
  for m in data.get('models',[]): print(m['name'])
except: pass
" 2>/dev/null | tr '\n' '|')
  fi

  # ── ✓ jelölés: HuggingFace lokális cache ──────────────────────────────────
  local hf_cache="${_REAL_HOME}/.cache/huggingface/hub"

  # ── Lista összeállítás ─────────────────────────────────────────────────────
  local menu_items=() result_ids=()
  local idx=1
  for ((i=0; i<${#_MDB_OLLAMA[@]}; i++)); do
    # TASK szűrés
    [ "$filter" != "all" ] && [ "${_MDB_TASK[$i]}" != "$filter" ] && continue

    # Backend kompatibilitás szűrés
    case "$backend" in
      ollama) [ "${_MDB_OLLAMA_OK[$i]}" != "true" ] && continue ;;
      vllm)   [ "${_MDB_VLLM_OK[$i]}"  != "true" ] && continue ;;
      # all → mindkét backend megjelenik, de jelöljük melyik nem kompatibilis
    esac

    # Visszaadott ID (Ollama neve vs HF ID)
    local result_id
    [ "$backend" = "vllm" ] && result_id="${_MDB_HF[$i]}" \
                             || result_id="${_MDB_OLLAMA[$i]}"

    # ✓ jelölés — már letöltve?
    local marker=""
    if [ "$backend" = "ollama" ] || [ "$backend" = "all" ]; then
      local oname="${_MDB_OLLAMA[$i]}"
      if [[ "$installed_set" == *"|${oname}|"* ]] || \
         [[ "$installed_set" == "${oname}|"* ]]; then
        marker=" ✓"
      fi
    fi
    if [ "$backend" = "vllm" ] || [ "$backend" = "all" ]; then
      local cache_name="models--${_MDB_HF[$i]//\//-}"
      [ -d "${hf_cache}/${cache_name}" ] && marker=" ✓"
    fi

    # Kompatibilitás jelölés (all módban)
    local compat_tag=""
    if [ "$backend" = "all" ]; then
      [ "${_MDB_OLLAMA_OK[$i]}" = "true" ] && compat_tag+="O"
      [ "${_MDB_VLLM_OK[$i]}"  = "true" ] && compat_tag+="V"
      compat_tag="[${compat_tag:-?}]"
    fi

    local task_tag="${_MDB_TASK[$i]^^}"
    local label
    label=$(printf '[%-6s]%s %-38s (%sGB VRAM~%sGB) %s%s' \
      "$task_tag" "$compat_tag" "$result_id" \
      "${_MDB_SIZE[$i]}" "${_MDB_VRAM[$i]}" \
      "${_MDB_DESC[$i]}" "$marker")
    menu_items+=("$idx" "$label" "OFF")
    result_ids+=("$result_id")
    ((idx++))
  done

  if [ ${#result_ids[@]} -eq 0 ]; then
    whiptail --msgbox "Nincs modell ebben a kategóriában:\n[${filter^^}] / backend: ${backend}" 10 60
    echo "CANCEL"; return 1
  fi

  # ── Dinamikus ablakméret ───────────────────────────────────────────────────
  local term_cols term_rows win_w win_h list_h label_max
  term_cols=$(tput cols 2>/dev/null || echo 120)
  term_rows=$(tput lines 2>/dev/null || echo 40)
  win_w=$(( term_cols * 95 / 100 ))
  [ "$win_w" -lt 90  ] && win_w=90
  [ "$win_w" -gt 220 ] && win_w=220
  list_h="${#result_ids[@]}"
  win_h=$(( list_h + 9 ))
  [ "$win_h" -gt $(( term_rows - 2 )) ] && win_h=$(( term_rows - 2 ))
  [ "$list_h" -gt $(( win_h - 9 )) ] && list_h=$(( win_h - 9 ))
  [ "$list_h" -lt 5 ] && list_h=5
  label_max=$(( win_w - 10 ))

  # Label-ek levágása az ablakszélességhez
  local menu_items_sized=()
  for ((j=0; j<${#result_ids[@]}; j++)); do
    local orig_label="${menu_items[$((j*3+1))]}"
    menu_items_sized+=("$((j+1))" "${orig_label:0:$label_max}" "OFF")
  done

  # ── Modell választó radiolist ──────────────────────────────────────────────
  local filter_tag="${filter^^}"
  local sel_idx
  sel_idx=$(whiptail --title "Modell katalógus — [${filter_tag}] | ${backend}" \
    --radiolist "SPACE=jelöl, ENTER=OK  |  ✓=letöltve  |  ↑↓=görgetés  |  ESC=vissza" \
    "$win_h" "$win_w" "$list_h" \
    "${menu_items_sized[@]}" \
    3>&1 1>&2 2>&3) || { echo "CANCEL"; return 1; }

  echo "${result_ids[$((sel_idx-1))]}"
}

# _popular_model_browse: Ollama modell katalógus böngésző
# Visszafelé-kompatibilis wrapper → _model_catalog_browse "ollama" "$filter"
# Paraméter: $1=task filter (all|code|chat|reason|embed|vision|agent|asr)
# Kimenet: Ollama modell neve, vagy "CANCEL"
_popular_model_browse() {
  _model_catalog_browse "ollama" "${1:-all}"
}

# _vllm_model_browse: vLLM HuggingFace modell katalógus böngésző
# Visszafelé-kompatibilis wrapper → _model_catalog_browse "vllm" "$filter"
# Paraméter: $1=task filter
# Kimenet: HuggingFace model ID, vagy "CANCEL"
_vllm_model_browse() {
  _model_catalog_browse "vllm" "${1:-all}"
}
