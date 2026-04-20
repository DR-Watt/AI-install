#!/bin/bash
# =============================================================================
# lib/09_lib_models.sh — AI Model Manager modell adatbázis v1.1
#
# TARTALOM:
#   _init_model_db() — modell adatbázis betöltése globális tömbökbe
#   Teljes HuggingFace TASK rendszer lefedése helyi futtatáshoz:
#     CODE    — text-generation (coding, fill-in-middle)
#     CHAT    — text-generation (általános, instruction-following)
#     REASON  — text-generation (reasoning, chain-of-thought)
#     EMBED   — feature-extraction, sentence-similarity
#     VISION  — image-text-to-text (vision language models)
#     AGENT   — text-generation (tool-use, function calling, agentic)
#     ASR     — automatic-speech-recognition (Whisper)
#
# BETÖLTÉS:
#   source lib/09_lib_models.sh
#   (a 09_ai_model_wrapper.sh hívja a 00_lib.sh után)
#
# GLOBÁLIS TÖMBÖK (lazy-init: _init_model_db() tölti be):
#   _MDB_OLLAMA[]   — Display ID (Ollama pull neve ha elérhető, egyedi azonosító
#                     ha nem — pl. ASR modellek: whisper-large-v3 NEM Ollama pull)
#                     L1 FIX (v1.1): korábban megtévesztő "Ollama pull neve" leírás
#   _MDB_HF[]       — HuggingFace ID (pl. "Qwen/Qwen2.5-Coder-7B-Instruct")
#   _MDB_TASK[]     — TASK kategória (code|chat|reason|embed|vision|agent|asr)
#   _MDB_SIZE[]     — modell mérete GB-ban (letöltési méret)
#   _MDB_VRAM[]     — szükséges VRAM GB-ban (futtatáshoz)
#   _MDB_DESC[]     — rövid leírás
#   _MDB_OLLAMA_OK[] — Ollama pull-lal elérhető (true/false)
#   _MDB_VLLM_OK[]  — vLLM serve-vel futtatható (true/false)
#
# HuggingFace TASK leképezés (huggingface.co/tasks):
#   CODE   → text-generation (coding)
#   CHAT   → text-generation (general)
#   REASON → text-generation (reasoning)
#   EMBED  → feature-extraction, sentence-similarity
#   VISION → image-text-to-text
#   AGENT  → text-generation (tool-use/agentic)
#   ASR    → automatic-speech-recognition
#
# FORRÁS: ollama.com/library (Ollama ID-k)
#         huggingface.co (HF ID-k, TASK metaadat)
#
# VERZIÓ: v1.1
# =============================================================================

# Globális tömbök deklarálása (source-olásnál egyszer fut le)
declare -ga _MDB_OLLAMA _MDB_HF _MDB_TASK _MDB_SIZE _MDB_VRAM _MDB_DESC
declare -ga _MDB_OLLAMA_OK _MDB_VLLM_OK

# _init_model_db: modell adatbázis betöltése
# Hívás: automatikus (lazy-init) a browse függvényekből, ha a tömb üres
# Formátum: "display_id|hf_id|task|meret_gb|vram_gb|ollama_ok|vllm_ok|leiras"
#   display_id: Ollama pull neve ha ollama_ok=true, egyébként egyedi azonosító
#   ollama_ok: "true" ha ollama pull-lal letölthető és futtatható
#   vllm_ok:   "true" ha vllm serve HF ID-val futtatható
_init_model_db() {
  # Törlés ha már volt betöltve (újratöltés esetére)
  _MDB_OLLAMA=(); _MDB_HF=();    _MDB_TASK=()
  _MDB_SIZE=();   _MDB_VRAM=();  _MDB_DESC=()
  _MDB_OLLAMA_OK=(); _MDB_VLLM_OK=()

  local -a _entries=(

    # ==========================================================================
    # CODE — kódgenerálás, fill-in-middle, code completion
    # HF TASK: text-generation (coding specialty)
    # Forrás: ollama.com/library, huggingface.co
    # ==========================================================================
    "qwen2.5-coder:1.5b|Qwen/Qwen2.5-Coder-1.5B-Instruct|code|1.0|2|true|true|Tab autocomplete, gyors, CLINE inline kód"
    "qwen2.5-coder:7b|Qwen/Qwen2.5-Coder-7B-Instruct|code|4.7|8|true|true|Ajánlott CLINE kód asszisztens"
    "qwen2.5-coder:14b|Qwen/Qwen2.5-Coder-14B-Instruct|code|9.0|14|true|true|Erős kódgenerálás + hosszú context"
    "qwen2.5-coder:32b|Qwen/Qwen2.5-Coder-32B-Instruct|code|19.0|25|true|true|SOTA kód, RTX 5090 teljesen kihasználja"
    "deepseek-coder-v2:16b|deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct|code|8.9|12|true|true|MoE architektúra, gyors, fill-in-middle"
    "codestral:22b|mistralai/Codestral-22B-v0.1|code|13.0|18|true|true|Mistral kódmodell, fill-in-middle"
    "starcoder2:15b|bigcode/starcoder2-15b-instruct-v0.1|code|9.1|13|true|true|BigCode StarCoder2 15B"
    "granite-code:20b|ibm-granite/granite-20b-code-instruct-8k|code|12.0|16|true|true|IBM Granite kód 20B"

    # ==========================================================================
    # CHAT — általános szöveggenerálás, instruction following
    # HF TASK: text-generation (general)
    # ==========================================================================
    "qwen2.5:7b|Qwen/Qwen2.5-7B-Instruct|chat|4.7|8|true|true|Általános chat, gyors válaszidő"
    "qwen2.5:14b|Qwen/Qwen2.5-14B-Instruct|chat|9.0|14|true|true|Erős általános asszisztens"
    "qwen2.5:32b|Qwen/Qwen2.5-32B-Instruct|chat|19.0|25|true|true|Nagy általános modell"
    "llama3.3:70b|meta-llama/Llama-3.3-70B-Instruct|chat|42.0|48|true|true|Meta flagship, RTX 5090 teli VRAM"
    "mistral:7b|mistralai/Mistral-7B-Instruct-v0.3|chat|4.1|6|true|true|Gyors, megbízható baseline"
    "gemma3:12b|google/gemma-3-12b-it|chat|8.1|12|true|true|Google Gemma 3, hatékony"
    "phi4:14b|microsoft/phi-4|chat|9.1|14|true|true|Microsoft Phi-4, kis VRAM igény"
    "command-r:35b|CohereForAI/c4ai-command-r-08-2024|chat|20.0|26|true|true|Cohere RAG-optimalizált"
    "aya-expanse:32b|CohereForAI/aya-expanse-32b|chat|20.0|26|true|true|Cohere multilingual 32B"
    "glm4:9b|THUDM/glm-4-9b-chat|chat|5.5|9|true|true|THUDM GLM-4 9B chat"

    # ==========================================================================
    # REASON — lánc-gondolkodás, matemaikia, érvelés
    # HF TASK: text-generation (reasoning/thinking)
    # ==========================================================================
    "deepseek-r1:7b|deepseek-ai/DeepSeek-R1-Distill-Qwen-7B|reason|4.7|8|true|true|Chain-of-thought, gyors érvelés"
    "deepseek-r1:14b|deepseek-ai/DeepSeek-R1-Distill-Qwen-14B|reason|9.0|14|true|true|Erős érvelő modell"
    "deepseek-r1:32b|deepseek-ai/DeepSeek-R1-Distill-Qwen-32B|reason|19.0|25|true|true|SOTA reasoning RTX 5090"
    "qwq:32b|Qwen/QwQ-32B|reason|20.0|26|true|true|Qwen QwQ — hosszú gondolkodás"
    "marco-o1:7b|AIDC-AI/Marco-o1|reason|4.7|8|true|true|Marco-o1 reasoning 7B"
    "deepseek-r1:70b|deepseek-ai/DeepSeek-R1-Distill-Llama-70B|reason|42.0|48|true|true|DeepSeek R1 70B Llama distil"

    # ==========================================================================
    # EMBED — beágyazás, RAG, szemantikus keresés
    # HF TASK: feature-extraction, sentence-similarity
    # ==========================================================================
    "nomic-embed-text|nomic-ai/nomic-embed-text-v1|embed|0.3|1|true|false|RAG + Continue.dev embed, 8192 ctx"
    "mxbai-embed-large|mixedbread-ai/mxbai-embed-large-v1|embed|0.7|2|true|false|RAG nagy dimenzió (1024d)"
    "bge-m3|BAAI/bge-m3|embed|1.2|2|true|false|Multilingual RAG, 8192 ctx"
    "snowflake-arctic-embed2|Snowflake/snowflake-arctic-embed-v2.0|embed|0.6|1|true|false|Arctic Embed v2"
    "all-minilm|sentence-transformers/all-MiniLM-L6-v2|embed|0.1|1|true|false|Gyors, kis méretű embed"
    "bge-large-en-v1.5|BAAI/bge-large-en-v1.5|embed|1.3|2|true|false|BGE Large EN v1.5 MTEB"

    # ==========================================================================
    # VISION — vision language models, kép + szöveg
    # HF TASK: image-text-to-text
    # ==========================================================================
    "llava:13b|llava-hf/llava-1.5-13b-hf|vision|8.0|12|true|true|LLaVA 1.5 13B vision"
    "qwen2.5-vl:7b|Qwen/Qwen2.5-VL-7B-Instruct|vision|5.0|9|true|true|Qwen2.5 Vision 7B"
    "qwen2.5-vl:72b|Qwen/Qwen2.5-VL-72B-Instruct|vision|43.0|50|true|true|Qwen2.5 Vision 72B — RTX 5090 teli"
    "minicpm-v|openbmb/MiniCPM-o-2_6|vision|5.5|9|true|true|MiniCPM-o 2.6 Vision"
    "moondream2|vikhyatk/moondream2|vision|1.8|3|true|false|Kis vision modell, gyors"
    "llava-phi3:mini|microsoft/Phi-3.5-vision-instruct|vision|2.2|4|true|true|Phi-3.5 Vision mini"
    "gemma3:12b|google/gemma-3-12b-it|vision|8.1|12|true|true|Google Gemma 3 12B multimodal"

    # ==========================================================================
    # AGENT — agentic modellek, tool-use, function calling
    # HF TASK: text-generation (tool-use/agentic specialization)
    # Ezek kiemelten jók CLINE/Continue agentic task-okhoz
    # ==========================================================================
    "glm5.1|zai-org/GLM-5.1|agent|45.0|50|false|true|GLM-5.1 agentic engineering, SWE-Bench SOTA"
    "hermes3:8b|NousResearch/Hermes-3-Llama-3.1-8B|agent|4.9|8|true|true|Hermes-3 tool-use, function calling"
    "hermes3:70b|NousResearch/Hermes-3-Llama-3.1-70B|agent|42.0|48|true|true|Hermes-3 70B agentic"
    "qwen2.5:7b-instruct|Qwen/Qwen2.5-7B-Instruct|agent|4.7|8|true|true|Qwen2.5 7B tool-use (function calling)"
    "mistral-nemo:12b|mistralai/Mistral-Nemo-Instruct-2407|agent|7.1|11|true|true|Mistral Nemo 12B function calling"
    "firefunction-v2|fireworks-ai/firefunction-v2|agent|8.0|12|false|true|Fireworks function calling v2"

    # ==========================================================================
    # ASR — automatikus beszédfelismerés
    # HF TASK: automatic-speech-recognition
    # Ollama nem támogatja → vLLM sem natívan, de Faster-Whisper önálló
    # Megjegyzés: ezek külön eszközzel futnak (nem vLLM/Ollama)
    # ==========================================================================
    "whisper-large-v3|openai/whisper-large-v3|asr|3.1|5|false|false|OpenAI Whisper Large v3 STT"
    "whisper-large-v3-turbo|openai/whisper-large-v3-turbo|asr|1.6|3|false|false|Whisper Large v3 Turbo (gyors)"
    "distil-whisper-large-v3|distil-whisper/distil-large-v3|asr|1.5|3|false|false|Distil-Whisper Large v3 (2x gyors)"
    "whisper-medium|openai/whisper-medium|asr|1.5|3|false|false|Whisper Medium (kompromisszum)"

  )

  # Adatbázis feltöltése a tömbökbe
  for _entry in "${_entries[@]}"; do
    IFS='|' read -r _ol _hf _task _sz _vr _ook _vok _desc <<< "$_entry"
    _MDB_OLLAMA+=("$_ol");    _MDB_HF+=("$_hf")
    _MDB_TASK+=("$_task");    _MDB_SIZE+=("$_sz");  _MDB_VRAM+=("$_vr")
    _MDB_OLLAMA_OK+=("$_ook"); _MDB_VLLM_OK+=("$_vok")
    _MDB_DESC+=("$_desc")
  done

  log "INFO" "[09-models] Adatbázis betöltve: ${#_MDB_OLLAMA[@]} modell"
}
