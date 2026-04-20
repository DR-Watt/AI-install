# AI Model Manager — Fejlesztői Dokumentáció

**Fájl:** `09_ai_model_wrapper.sh`  
**Verzió:** v2.8  
**Lib verzió minimum:** 6.4  
**Projekt:** DR-Watt/AI-install · `main` branch  
**Fejlesztési környezet:** Ubuntu 24.04 LTS · RTX 5090 Blackwell SM_120

---

## Tartalomjegyzék

1. [A program célja](#1-a-program-célja)
2. [Operációs rendszer](#2-operációs-rendszer)
3. [Hardver követelmények](#3-hardver-követelmények)
4. [Fájlstruktúra és függőségek](#4-fájlstruktúra-és-függőségek)
5. [Futtatás és üzemmódok](#5-futtatás-és-üzemmódok)
6. [Fő funkciók](#6-fő-funkciók)
7. [Menütérkép](#7-menütérkép)
8. [Menüpontok részletes leírása](#8-menüpontok-részletes-leírása)
9. [Modell adatbázis](#9-modell-adatbázis)
10. [User Interface — alapépítőelemek](#10-user-interface--alapépítőelemek)
11. [UI működési szabályok](#11-ui-működési-szabályok)
12. [Konfigurációs konstansok](#12-konfigurációs-konstansok)
13. [State és log rendszer](#13-state-és-log-rendszer)
14. [Ismert hibák és megoldásaik](#14-ismert-hibák-és-megoldásaik)
15. [Fejlesztési előzmények](#15-fejlesztési-előzmények)

---

## 1. A program célja

Az `09_ai_model_wrapper.sh` az INFRA rendszer 9-es modulja. Feladata az **Vibe Coding Workspace** AI modell infrastruktúrájának interaktív kezelése: Ollama modellek letöltése és VRAM-kezelése, vLLM OpenAI-compatible szerver indítása, TurboQuant KV cache compression informatív kezelése (v2.6-ban aktív vLLM integráció), valamint a CLINE és Continue.dev IDE bővítmények backend konfigurációjának automatikus frissítése.

A program kettős üzemmódban működik:

- **INFRA mód** (`RUN_MODE=install|check|update|fix`): a master installer hívja, automatikus, nem interaktív
- **Manage mód** (`RUN_MODE=manage`): önállóan futtatható, teljes whiptail TUI menürendszerrel

A végfelhasználó szempontjából egy **egyablakos AI management tool**, amely a VS Code + CLINE + Continue.dev munkafolyamathoz szükséges összes AI infrastruktúra-feladatot lefedi.

---

## 2. Operációs rendszer

| Követelmény | Érték |
|---|---|
| OS | Ubuntu 24.04 LTS (Noble Numbat) |
| Shell | Bash 5.2+ |
| Python | 3.12.x (pyenv-ből: `~/.pyenv/versions/3.12.9`) |
| Kernel | 6.8+ (GPU driver kompatibilitáshoz) |

A program Ubuntu 24.04 LTS-re van optimalizálva. Más Debian-alapú disztribúción futhat, de a systemd user service kezelés és a driver telepítés Ubuntu-specifikus.

---

## 3. Hardver követelmények

### Célhardver (fejlesztési referencia)

| Komponens | Specifikáció |
|---|---|
| CPU | Intel Core i7-12700K |
| GPU | ASUS RTX 5090 LC OC (Blackwell, SM_120, PCI ID `10de:2b85`) |
| VRAM | 32 GB GDDR7 |
| RAM | 64 GB DDR4 |
| Tárhely | 4 TB NVMe Gen4 |
| Monitor | Dual 4K |

### GPU kompatibilitási mátrix

| GPU architektúra | CUDA képesség | PyTorch index | Támogatott |
|---|---|---|---|
| Blackwell (RTX 5090) | SM_120 | `cu128` | ✅ (fix szükséges) |
| Ada Lovelace (RTX 40xx) | SM_89 | `cu126` | ✅ |
| Ampere (RTX 30xx) | SM_86 | `cu126` | ✅ |

> **Kritikus megjegyzés:** Az RTX 5090 SM_120 Blackwell GPU nem kompatibilis a `cu126` PyTorch wheel-lel. A `cu126` csak SM_50–SM_90-ig tartalmaz lefordított CUDA kerneleket. Blackwell-hez `cu128` szükséges (`pytorch.org/get-started/locally`). A fix automatizált, részletesen lásd [14. fejezet](#14-ismert-hibák-és-megoldásaik).

### Minimális követelmény (CPU-only Ollama)

- NVIDIA GPU nélkül is futtatható, de vLLM és TurboQuant nem elérhető
- A program figyelmeztetést ad CPU-only módban

---

## 4. Fájlstruktúra és függőségek

### 4.1 Fájlstruktúra

```
<SCRIPT_DIR>/
├── 09_ai_model_wrapper.sh       # Főscript (v2.8, ~2663 sor)
├── 00_lib.sh                    # INFRA master lib loader
├── 00_registry.sh               # Modul registry (HW_REQ, DEFAULT, stb.)
├── lib/
│   ├── 00_lib_core.sh           # log(), sudo, _REAL_USER, _REAL_HOME
│   ├── 00_lib_compat.sh         # GPU/OS/Driver/CUDA kompatibilitás mátrix
│   ├── 00_lib_hw.sh             # Hardver detektálás (GPU, PCI ID)
│   ├── 00_lib_ui.sh             # YAD/whiptail dialóg wrapperek
│   ├── 00_lib_state.sh          # infra_state_*, infra_require, detect_run_mode
│   ├── 00_lib_comp.sh           # comp_save_state, comp_state_exists
│   ├── 00_lib_apt.sh            # apt_install_*, run_with_progress
│   ├── 09_lib_models.sh         # Modell adatbázis (_init_model_db, _MDB_* tömbök)
│   └── 09_lib_browse.sh         # Browse UI (_model_catalog_browse, radiolisták)
```

**Lib betöltési sorrend:**
```
00_lib.sh → core → compat → hw → ui → state → comp → apt
         → lib/09_lib_models.sh
         → lib/09_lib_browse.sh
```

### 4.2 INFRA lib rendszer

A `lib/00_lib_*.sh` fájlok az INFRA projekt összes modulja számára közös függvénykészletet biztosítanak. A 09-es modul szempontjából a legfontosabbak:

**`00_lib_core.sh`**
- `log "LEVEL" "üzenet"` — kétszintű naplózás (LOGFILE + stdout ccze-vel)
- `_REAL_USER` — a tényleges felhasználó neve (sudo alatt sem root)
- `_REAL_HOME` — a tényleges felhasználó home könyvtára

**`00_lib_state.sh`**
- `infra_state_set KEY VALUE` — `~/.infra-state` fájlba ír
- `infra_state_get KEY` — state fájlból olvas
- `infra_require "XX"` — module függőség ellenőrzés

**`00_lib_comp.sh`**
- `comp_save_state MOD_ID` — COMP_XX_* state mentés
- `comp_state_exists MOD_ID` — van-e már mentett state

**`lib/09_lib_models.sh`**  
Globális tömbök (lazy-init, `_init_model_db()` tölti be):
- `_MDB_OLLAMA[]` — Ollama pull neve (pl. `qwen2.5-coder:7b`)
- `_MDB_HF[]` — HuggingFace model ID (pl. `Qwen/Qwen2.5-Coder-7B-Instruct`)
- `_MDB_TASK[]` — HF TASK kategória (`code|chat|reason|embed|vision|agent|asr`)
- `_MDB_SIZE[]` — letöltési méret GB-ban
- `_MDB_VRAM[]` — szükséges VRAM GB-ban
- `_MDB_DESC[]` — rövid leírás
- `_MDB_OLLAMA_OK[]` — Ollama-val letölthető (`true/false`)
- `_MDB_VLLM_OK[]` — vLLM-mel futtatható (`true/false`)

**`lib/09_lib_browse.sh`**  
Browse UI függvények:
- `_ollama_model_radiolist title prompt` — telepített Ollama modellek radiolist-je méretekkel
- `_model_catalog_browse backend filter` — egységes modell katalógus böngésző
- `_popular_model_browse [filter]` — Ollama wrapper (`_model_catalog_browse "ollama"`)
- `_vllm_model_browse [filter]` — vLLM wrapper (`_model_catalog_browse "vllm"`)

### 4.3 Külső függőségek

#### GUI framework

| Eszköz | Csomag | Szerep |
|---|---|---|
| **whiptail** | `whiptail` (libnewt) | Fő TUI dialóg — menük, listák, progress |
| YAD | `yad` | Alternatív GUI (jelenleg whiptail-only) |

> **Megjegyzés:** A YAD integráció a `lib/00_lib_ui.sh`-ban van előkészítve, de a 09-es modul kizárólag `whiptail`-t használ az Ubuntu 24.04 terminál-kompatibilitás miatt.

#### AI futtatókörnyezetek

| Komponens | Telepítő | Elérési út | Megjegyzés |
|---|---|---|---|
| **Ollama** | `02_local_ai_stack.sh` | `/usr/local/bin/ollama` | REST API: `localhost:11434` |
| **vLLM** | `02_local_ai_stack.sh` | `~/venvs/ai/bin/vllm` | OpenAI-compatible: `localhost:8000/v1` |
| **PyTorch** | `02_local_ai_stack.sh` + fix | `~/venvs/ai/lib/.../torch` | cu128 szükséges RTX 5090-hez |
| **TurboQuant** | `02_local_ai_stack.sh` | `~/src/turboquant` | KV cache compression (vLLM runtime, v2.6 target) |

#### Python venv

```
~/venvs/ai/          # Python 3.12.9 virtual environment
  bin/python3        # venv Python
  bin/vllm           # vLLM belépési pont
  lib/python3.12/
    site-packages/
      torch/         # PyTorch (cu128 szükséges RTX 5090-hez!)
      vllm/          # vLLM (PyTorch-csal ABI-kompatibilis verziót igényel)
```

#### IDE integráció

| Komponens | Konfig fájl | Kulcsok |
|---|---|---|
| **VS Code** | `~/.config/Code/User/settings.json` | `cline.apiProvider`, `cline.ollamaBaseUrl`, stb. |
| **CLINE** | VS Code `settings.json` | `cline.apiProvider`, `cline.apiModelId` |
| **Continue.dev** | `~/.continue/config.yaml` | `models[].roles[]`, `context[]` (v1 YAML séma, v2.7.1+) |

#### Rendszereszközök

| Eszköz | Csomag | Használat |
|---|---|---|
| `uv` | `~/.local/bin/uv` (01b telepíti) | Python csomag telepítés (pip helyett) |
| `curl` | rendszer | Ollama REST API hívások |
| `nvidia-smi` | NVIDIA driver | GPU VRAM állapot |
| `ss` | `iproute2` | Port ellenőrzés (`vLLM fut-e`) |
| `systemctl` | systemd | vLLM user service kezelés |
| `python3` | rendszer / venv | JSON parse, PyTorch compat check |
| `tput` | `ncurses` | Terminál méret lekérdezés (dinamikus ablak) |
| `ccze` | `ccze` | Színes log kimenet |

### 4.4 INFRA modul előfeltételek

A 09-es modul install módban fut-e az alábbi ellenőrzéseket végzi `~/.infra-state`-ből:

```
MOD_02_DONE=true   # 02_local_ai_stack.sh: Ollama + vLLM + TurboQuant
MOD_06_DONE=true   # 06_editors.sh: VS Code + CLINE + Continue.dev
```

> **Fontos:** Az ellenőrzés direkt `grep`-pel történik a state fájlban, NEM `infra_require()`-val. Ennek oka: önálló futásnál a `00_registry.sh` nincs source-olva, ezért az `INFRA_NAME[]` tömb üres, és az `infra_require()` hamis hibát dobna.

---

## 5. Futtatás és üzemmódok

### 5.1 Indítási parancsok

```bash
# Interaktív menü (AJÁNLOTT — mindig explicit RUN_MODE)
sudo RUN_MODE=manage bash 09_ai_model_wrapper.sh

# INFRA install mód (master installer hívja)
RUN_MODE=install sudo bash 09_ai_model_wrapper.sh

# Komponens ellenőrzés
RUN_MODE=check sudo bash 09_ai_model_wrapper.sh

# Frissítés (meglévő konfig megőrzése)
RUN_MODE=update sudo bash 09_ai_model_wrapper.sh

# Újratelepítés (konfig visszaírással)
RUN_MODE=fix sudo bash 09_ai_model_wrapper.sh

# ai-model-ctl wrapper (install után elérhető)
ai-model-ctl                    # → interaktív menü
ai-model-ctl status             # → komponens check
ai-model-ctl start-vllm MODEL  # → vLLM indítás
ai-model-ctl stop-vllm         # → vLLM leállítás
```

### 5.2 RUN_MODE öröklési probléma

**Kritikus ismert probléma:** ha korábban `RUN_MODE=install` volt exportálva a shellben, a következő futásnál is telepítési módba kerül a script.

```bash
# Ellenőrzés
echo $RUN_MODE

# Megoldás
unset RUN_MODE
sudo RUN_MODE=manage bash 09_ai_model_wrapper.sh
```

### 5.3 RUN_MODE dispatch táblázat

| `RUN_MODE` | Funkció |
|---|---|
| `manage` (vagy üres) | Interaktív whiptail TUI menü |
| `install` | Telepítés: ai-model-ctl, vLLM service, kezdeti IDE konfig |
| `check` | Komponens állapot felmérés + COMP_09_* state mentés |
| `update` | Frissítés, tool újragenerálás, daemon-reload |
| `fix` / `reinstall` | Újratelepítés, IDE konfig felülírás |
| `start_vllm` | CLI vLLM indítás (`MODEL=` env változóval) |
| `stop_vllm` | CLI vLLM leállítás |

---

## 6. Fő funkciók

### 6.1 Ollama modell kezelés

Az Ollama REST API-n (`localhost:11434`) keresztül:

- **Model lista:** `GET /api/tags` → telepített modellek neve + mérete GB-ban
- **VRAM betöltés:** `POST /api/generate` `keep_alive=-1` → modell VRAM-ban marad
- **VRAM eltávolítás:** `POST /api/generate` `keep_alive=0` → azonnali VRAM felszabadítás
- **Model letöltés:** `POST /api/pull stream=true` → streaming JSON sorok, progress gauge-zal
- **VRAM státusz:** `GET /api/ps` → aktuálisan betöltött modellek + VRAM foglalás

Forrás: [https://ollama.readthedocs.io/en/api/](https://ollama.readthedocs.io/en/api/)

### 6.2 vLLM szerver irányítás

Az RTX 5090 Blackwell SM_120 GPU-ra optimalizált `vllm serve` parancs:

```bash
vllm serve MODEL \
  --host 0.0.0.0 \
  --port 8000 \
  --dtype bfloat16 \              # Blackwell SM_120 optimális
  --gpu-memory-utilization 0.90 \ # ~28.8 GB a 32 GB-ból
  --max-model-len 16384 \         # Token context
  --trust-remote-code \           # HF modelleknél szükséges
  --enable-prefix-caching         # KV cache újrahasználat
```

> **Eltávolítva:** `--swap-space` — vLLM 0.19.0-ban nem létező flag, `unrecognized arguments` hibát okoz.

**Indítási folyamat:**
1. PyTorch Blackwell kompatibilitás ellenőrzés (`get_arch_list()` → `sm_120` jelenléte)
2. Ha inkompatibilis: fix felajánlás vagy kényszer-folytatás
3. Log timestamp írás (`wrapper_vllm.log` append módban)
4. Háttérindítás (`nohup`, PID mentés `/tmp/vllm-rtx5090.pid`-be)
5. 2 másodperces process-életben-maradás ellenőrzés
6. Progress gauge (`_vllm_wait_progress`) a log tqdm kimenetéből

**API endpoint (ha elindul):**
```
http://localhost:8000/v1/chat/completions
http://localhost:8000/v1/models
```

### 6.3 PyTorch + vLLM Blackwell fix

Az RTX 5090 SM_120 GPU-hoz két lépéses fix szükséges:

**Lépés 1 — PyTorch cu128 reinstall:**
```bash
uv pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu128 \
  --reinstall
```
Forrás: [https://pytorch.org/get-started/locally/](https://pytorch.org/get-started/locally/)

**Lépés 2 — vLLM ABI reinstall (automatikus, ha PyTorch fix sikeres):**
```bash
uv pip install vllm --reinstall
```

> **Gyökérok:** `cu126` PyTorch csak SM_50–SM_90-ig tartalmaz CUDA kerneleket. A `cu128` PyTorch más C++ ABI-t exportál, amellyel a régi `vllm/_C.abi3.so` inkompatibilis (`ImportError: undefined symbol: _ZN3c1013MessageLoggerC1EPKciib`).

**Előfeltétel:** `chown -R $USER ~/venvs/ai/` szükséges a fix előtt, mert korábbi `sudo pip` futtatások root-tulajdonba tehették a `__pycache__` könyvtárakat (`Permission denied`, `os error 13`).

### 6.4 TurboQuant integráció

**⚠ v2.5 H5 FIX**: a TurboQuant **NEM modell kvantáló**, hanem **KV cache compression runtime** vLLM-hez. A korábbi `_tq_quantize_model` téves CLI feltevéssel készült és soha nem működött a valóságban.

**Valós funkció** (forrás: [github.com/0xSero/turboquant](https://github.com/0xSero/turboquant) README):

- **Algoritmus:** random orthogonal rotation + Lloyd-Max scalar quantization + QJL projection + group quantization + bit-packing
- **Integráció:** vLLM attention backend monkey-patch (Triton fused kernelekkel)
- **Hatás inference közben:** KV cache 3-bit key + 2-bit value → ~4.4× tömörítés full-attention rétegeken

**Benchmark (RTX 5090 32GB, Qwen3.5-27B-AWQ, vLLM 0.18.0, 30k context):**

| Metrika | Baseline (bf16 KV) | TurboQuant (3b key / 2b val) |
|---|---|---|
| Prefill tok/s | 1,804 | 1,907 (+5.7%) |
| Decode tok/s | 1.264 | 1.303 (+3.1%) |
| KV cache freed | — | 30.0 GB |
| Max token capacity | 457,072 | 914,144 (**2.0×**) |

**v2.5 státusz:** a `_tq_quantize_model` `return 1` early exit-tel disabled, a `_menu_turboquant` informatív menü (Mi ez? / Benchmark / v2.6 terv). A tényleges vLLM monkey-patch integráció v2.6 target.

**v2.6 tervezett workflow:**
```bash
pip install -e ~/src/turboquant       # TurboQuant telepítés (vLLM-et monkey-patch-eli)
export VLLM_ATTENTION_BACKEND=TURBOQUANT  # runtime KV compression aktiválás
vllm serve MODEL ...                   # ugyanaz a parancs, TQ runtime alatt
```

### 6.5 IDE backend konfiguráció

**CLINE beállítás** (`~/.config/Code/User/settings.json`):

| Backend | Kulcsok |
|---|---|
| Ollama | `cline.apiProvider=ollama`, `cline.ollamaBaseUrl`, `cline.apiModelId` |
| vLLM | `cline.apiProvider=openai`, `cline.openAiBaseUrl=http://localhost:8000/v1`, `cline.openAiModelId` |

**Continue.dev beállítás** (`~/.continue/config.yaml`, v1 YAML séma):

A Continue.dev 2025 Q1-től `config.yaml`-t használ (v1 séma, roles-alapú modell definíciók). A wrapper v2.7.1-től YAML-t generál. Legacy JSON (`config.json`) detektálás: `_check_all_components` → `old` státusz.

Forrás: `github.com/continuedev/continue` — `packages/config-yaml/src/schemas/`

| Mező | Leírás |
|---|---|
| `name` | Workspace név (top-level, kötelező) |
| `version` | Konfig verzió (pl. `0.0.1`) |
| `models[]` | Modell definíciók: `name`, `provider`, `model`, `apiBase`, `roles[]` |
| `models[].roles[]` | `[chat, edit, apply]`, `[autocomplete]`, `[embed]` stb. |
| `context[]` | Kontextus provider-ek (régi `contextProviders[]`) |

**Viselkedés-változás (v2.7.1):**
- autocomplete **mindig Ollama** (1.5B coder, gyorsabb mint vLLM-en)
- embed **mindig Ollama** (`nomic-embed-text`)
- A régi `tabAutocompleteModel` és `embeddingsProvider` top-level mezők nem használtak a v1 sémában

A backend váltó egyszerre frissíti a CLINE + Continue.dev konfigot (`_ide_switch_backend()`).

---

## 7. Menütérkép

```
AI Model Manager v2.7.1 — RTX 5090 Blackwell
│
├── 1. Ollama model kezelés
│   ├── 1. Modell betöltés VRAM-ba (radiolist méretekkel)
│   ├── 2. Modell kiürítés VRAM-ból (radiolist méretekkel)
│   ├── 3. Új modell letöltése
│   │   ├── 1. Katalógusból (HF TASK szűrővel)
│   │   └── 2. Kézi bevitel
│   └── 4. Letöltött modellek listája (ollama list)
│
├── 2. Backend váltás (Ollama ↔ vLLM)
│   ├── 1. → Ollama backend
│   │   ├── 1. Telepített modellek radiolist
│   │   ├── 2. Katalógus
│   │   └── 3. Kézi bevitel
│   ├── 2. → vLLM backend
│   ├── 3. Ollama modell kiválasztása
│   └── 4. vLLM modell megadása
│
├── 3. vLLM szerver irányítás
│   ├── 1. Modell kiválasztás + szerver indítás
│   │   ├── 1. Katalógusból (HF TASK szűrővel)
│   │   └── 2. Kézi HF ID
│   ├── 2. Szerver leállítás
│   ├── 3. Állapot + log megtekintése
│   ├── 4. Service konfiguráció (boot-on-start)
│   ├── 5. Konfigurált paraméterek
│   ├── 6. ⚠ PyTorch + vLLM Blackwell fix (cu128)
│   ├── 7. Modell kezelés →
│   │   ├── 1. Katalógusból kiválasztás + [újra]indítás
│   │   ├── 2. Kézi HF ID + [újra]indítás
│   │   ├── 3. HuggingFace cache megtekintése
│   │   └── 4. Service fájl MODEL_ID módosítása
│   └── 0. ← Vissza
│
├── 4. TurboQuant KV cache compression (v2.5: informatív, v2.6: aktív)
│   ├── 1. Mi a TurboQuant? (részletes info)
│   ├── 2. Benchmark eredmények (RTX 5090)
│   └── 3. Tervezett v2.6 integráció (vLLM env változó)
│
├── 5. GPU memória állapot
│
├── 6. Komponens állapot
│
└── 0. Kilépés
```

### HF TASK szűrő (minden katalógus browse-ban)

```
Modell katalógus — HuggingFace TASK szűrő
├── 1. Összes modell (minden TASK)
├── 2. [CODE]   Kódgenerálás — CLINE/Continue kód asszisztens
├── 3. [CHAT]   Általános chat — text-generation
├── 4. [REASON] Érvelő modellek — chain-of-thought
├── 5. [EMBED]  Embedding / RAG — feature-extraction
├── 6. [VISION] Vision + Language — image-text-to-text
├── 7. [AGENT]  Agentic / Tool-use — function calling
└── 8. [ASR]    Beszédfelismerés — automatic-speech-recognition
```

---

## 8. Menüpontok részletes leírása

### 8.1 Ollama model kezelés

#### 8.1.1 Modell betöltés VRAM-ba

`_ollama_load_model(model)` → `POST /api/generate keep_alive=-1`

A modell neve a `_ollama_model_radiolist()` függvénnyel kerül kiválasztásra: `GET /api/tags` alapján kétoszlopos lista (név + GB méret). A megjelenítő függvény a `_REAL_USER` kontextusában fut. A keep_alive=-1 azt jelenti, hogy a modell a VRAM-ban marad az Ollama leállításáig.

#### 8.1.2 Modell kiürítés VRAM-ból

`_ollama_unload_model(model)` → `POST /api/generate keep_alive=0`

A VRAM-ban lévő modellek a `GET /api/ps` endpoint-ból töltődnek be, a lista tartalmazza az egyes modellek aktuális VRAM-foglalását is.

#### 8.1.3 Új modell letöltése

**Katalógusból:** `_popular_model_browse()` → `_model_catalog_browse "ollama" filter`  
Ld. [9. fejezet](#9-modell-adatbázis) a teljes modell listáért.

**Pull folyamat:** `_ollama_pull_model(model)` → `POST /api/pull stream=true`  
- curl háttérfolyamat streaming JSON sorokat ír log fájlba
- Python parser `{"status":..., "total":N, "completed":M}` sorokból számítja a %-ot
- Whiptail gauge 2 másodperces frissítéssel
- ESC = gauge bezárul, letöltés folytatódik háttérben

#### 8.1.4 Letöltött modellek listája

`ollama list` CLI kimenet, whiptail scrolltext msgbox-ban.

---

### 8.2 Backend váltás

`_ide_switch_backend(backend, model)` egyszerre frissíti a CLINE és Continue.dev konfigurációt.

**Ollama → vLLM váltásnál:** a vLLM-nek futnia kell; az aktuálisan kiszolgált modell automatikusan detektálódik a `/v1/models` endpoint-ból.

**VS Code újraindítás szükséges** minden backend váltás után, hogy a CLINE és Continue.dev bővítmények felvegyék az új konfigurációt.

---

### 8.3 vLLM szerver irányítás

#### 8.3.1 Modell kiválasztás + szerver indítás

1. Katalógus browse VAGY kézi HF ID megadás
2. `_vllm_start(model)` hívás:
   - PyTorch Blackwell compat check
   - Timestamp írás a log fájlba
   - Háttérindítás nohup-pal, PID fájl írás
   - 2 mp-es életbenmaradás ellenőrzés
3. `_vllm_wait_progress()` gauge:
   - Log fájl tqdm kimenetéből parse-olja a %-ot
   - Fázis detektálás: `Downloading` / `Loading weights` / `warming up`
   - Port `:8000` megnyíláskor 100% és visszatér
   - ESC = gauge bezárul, vLLM fut tovább

#### 8.3.2 Szerver leállítás

`_vllm_stop()`:  
1. SIGTERM a PID fájlból
2. 3 mp várakozás
3. Ha él: SIGKILL
4. PID fájl törlése
5. Timestamp a log fájlba (`[STOP]`)

#### 8.3.3 Állapot + log

- `_vllm_status_text()`: PID, port, `/v1/models` lekérdezés
- Utolsó 15 log sor, ANSI escape kódok szűrésével
- whiptail `--scrolltext --msgbox`

#### 8.3.4 Service konfiguráció

`systemctl --user enable/disable vllm-rtx5090`

**DBUS probléma:** sudo-ból hívott `systemctl --user` nem éri el a session bus-t. Megoldás:
```bash
XDG_RUNTIME_DIR=/run/user/$(id -u $REAL_USER) \
  sudo -u $REAL_USER systemctl --user is-enabled vllm-rtx5090
```

A dialog megmutatja az aktuális státuszt (`BE / KI`) és a várható műveletet, mielőtt végrehajtja.

#### 8.3.5 PyTorch + vLLM Blackwell fix (6. menüpont)

Ld. részletesen [6.3 fejezet](#63-pytorch--vllm-blackwell-fix).

**Folyamat:**
1. `yesno` jóváhagyás (ESC = kilépés, nem indul el!)
2. `chown -R $USER ~/venvs/ai/` (Permission denied megelőzés)
3. `uv pip install torch torchvision torchaudio --index-url .../cu128 --reinstall`
   - Kimenete csak log fájlba kerül (`> log 2>&1`), nem szórja szét a terminált
   - Progress gauge a log utolsó sorát mutatja
   - ESC = gauge bezárul, install tovább fut háttérben → yesno: vár vagy háttérben hagyja
4. Sikeres PyTorch fix után: `yesno` vLLM reinstall felajánlás
5. `uv pip install vllm --reinstall` (ABI sync)

#### 8.3.6 Modell kezelés almenü (7. menüpont)

Külön `_menu_vllm_model()` almenü:
- Katalógus vagy kézi HF ID → ha vLLM fut, yesno leállítás + újraindítás
- HF cache lista: `~/.cache/huggingface/hub/models--*` könyvtárak
- Service fájl modell módosítása: `sed -i` a `MODEL_ID=` sorban + `daemon-reload`

---

### 8.4 TurboQuant KV cache compression (v2.5 informatív menü)

**v2.5 státusz (H5 FIX):** a menü 3 almenüpontból áll, mindegyik csak információt jelenít meg. A `_tq_quantize_model` `return 1` early exit-tel disabled (a régi hamis CLI workflow kommentezve megőrizve a v2.6 átdolgozáshoz).

- **1. Mi a TurboQuant?** — részletes algoritmus ismertetés, workflow, mit csinál és mit NEM (nem modell kvantáló!)
- **2. Benchmark eredmények** — RTX 5090-en Qwen3.5-27B-AWQ mérések: +5.7% prefill, 30 GB KV freed, 2× token kapacitás
- **3. v2.6 integráció terv** — pip install + VLLM_ATTENTION_BACKEND env változó

**v2.6 tervezett `_tq_integrate_vllm()` függvény:**
1. `pip install -e $TQ_DIR` (monkey-patch vLLM attention backend)
2. vLLM szerver indítás `VLLM_ATTENTION_BACKEND=TURBOQUANT` env változóval
3. Triton fused kernel runtime KV compresszió (nincs külön kvantálási lépés)
4. Ollama integráció NINCS (TurboQuant csak vLLM-mel működik)

---

### 8.5 GPU memória állapot

`nvidia-smi --query-gpu=...` CSV kimenet Python parse-olással:
- GPU név, driver verzió, hőmérséklet, utilization
- VRAM bar grafikon (30 karakter: `█░`)
- Ollama VRAM foglalás (`GET /api/ps`)
- vLLM szerver státusz

---

## 9. Modell adatbázis

### 9.1 Adatbázis struktúra

Fájl: `lib/09_lib_models.sh`  
Függvény: `_init_model_db()`  
Lazy-init: automatikusan hívódik, ha `_MDB_OLLAMA[]` üres.

Bejegyzés formátum (pipe-szeparált):
```
"ollama_neve|hf_id|task|meret_gb|vram_gb|ollama_ok|vllm_ok|leiras"
```

### 9.2 Modell lista (47 modell, 7 TASK kategória)

#### CODE — text-generation (coding)

| Ollama neve | HF ID | Méret | VRAM | Leírás |
|---|---|---|---|---|
| `qwen2.5-coder:1.5b` | Qwen/Qwen2.5-Coder-1.5B-Instruct | 1.0 GB | 2 GB | Tab autocomplete, CLINE inline |
| `qwen2.5-coder:7b` | Qwen/Qwen2.5-Coder-7B-Instruct | 4.7 GB | 8 GB | Ajánlott CLINE kód asszisztens |
| `qwen2.5-coder:14b` | Qwen/Qwen2.5-Coder-14B-Instruct | 9.0 GB | 14 GB | Erős kódgenerálás |
| `qwen2.5-coder:32b` | Qwen/Qwen2.5-Coder-32B-Instruct | 19.0 GB | 25 GB | SOTA, RTX 5090 teljes kihasználás |
| `deepseek-coder-v2:16b` | deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct | 8.9 GB | 12 GB | MoE, fill-in-middle |
| `codestral:22b` | mistralai/Codestral-22B-v0.1 | 13.0 GB | 18 GB | Mistral fill-in-middle |
| `starcoder2:15b` | bigcode/starcoder2-15b-instruct-v0.1 | 9.1 GB | 13 GB | BigCode |
| `granite-code:20b` | ibm-granite/granite-20b-code-instruct-8k | 12.0 GB | 16 GB | IBM Granite |

#### CHAT — text-generation (general)

| Ollama neve | HF ID | Méret | VRAM | Leírás |
|---|---|---|---|---|
| `qwen2.5:7b` | Qwen/Qwen2.5-7B-Instruct | 4.7 GB | 8 GB | Gyors általános chat |
| `qwen2.5:14b` | Qwen/Qwen2.5-14B-Instruct | 9.0 GB | 14 GB | Erős asszisztens |
| `qwen2.5:32b` | Qwen/Qwen2.5-32B-Instruct | 19.0 GB | 25 GB | Nagy általános |
| `llama3.3:70b` | meta-llama/Llama-3.3-70B-Instruct | 42.0 GB | 48 GB | Meta flagship |
| `mistral:7b` | mistralai/Mistral-7B-Instruct-v0.3 | 4.1 GB | 6 GB | Gyors baseline |
| `gemma3:12b` | google/gemma-3-12b-it | 8.1 GB | 12 GB | Google, multimodal |
| `phi4:14b` | microsoft/phi-4 | 9.1 GB | 14 GB | Microsoft, kis VRAM |
| `command-r:35b` | CohereForAI/c4ai-command-r-08-2024 | 20.0 GB | 26 GB | RAG-optimalizált |
| `aya-expanse:32b` | CohereForAI/aya-expanse-32b | 20.0 GB | 26 GB | Multilingual |
| `glm4:9b` | THUDM/glm-4-9b-chat | 5.5 GB | 9 GB | THUDM GLM-4 |

#### REASON — text-generation (reasoning/thinking)

| Ollama neve | HF ID | Méret | VRAM | Leírás |
|---|---|---|---|---|
| `deepseek-r1:7b` | deepseek-ai/DeepSeek-R1-Distill-Qwen-7B | 4.7 GB | 8 GB | Chain-of-thought |
| `deepseek-r1:14b` | deepseek-ai/DeepSeek-R1-Distill-Qwen-14B | 9.0 GB | 14 GB | Erős érvelő |
| `deepseek-r1:32b` | deepseek-ai/DeepSeek-R1-Distill-Qwen-32B | 19.0 GB | 25 GB | SOTA reasoning |
| `qwq:32b` | Qwen/QwQ-32B | 20.0 GB | 26 GB | Hosszú gondolkodás |
| `marco-o1:7b` | AIDC-AI/Marco-o1 | 4.7 GB | 8 GB | Marco-o1 |
| `deepseek-r1:70b` | deepseek-ai/DeepSeek-R1-Distill-Llama-70B | 42.0 GB | 48 GB | 70B Llama distil |

#### EMBED — feature-extraction, sentence-similarity

| Ollama neve | HF ID | Méret | VRAM | Leírás |
|---|---|---|---|---|
| `nomic-embed-text` | nomic-ai/nomic-embed-text-v1 | 0.3 GB | 1 GB | RAG + Continue.dev |
| `mxbai-embed-large` | mixedbread-ai/mxbai-embed-large-v1 | 0.7 GB | 2 GB | Nagy dimenzió |
| `bge-m3` | BAAI/bge-m3 | 1.2 GB | 2 GB | Multilingual, 8192 ctx |
| `snowflake-arctic-embed2` | Snowflake/snowflake-arctic-embed-v2.0 | 0.6 GB | 1 GB | Arctic v2 |
| `all-minilm` | sentence-transformers/all-MiniLM-L6-v2 | 0.1 GB | 1 GB | Gyors, kis embed |
| `bge-large-en-v1.5` | BAAI/bge-large-en-v1.5 | 1.3 GB | 2 GB | BGE Large MTEB |

#### VISION — image-text-to-text

| Ollama neve | HF ID | Méret | VRAM | Leírás |
|---|---|---|---|---|
| `llava:13b` | llava-hf/llava-1.5-13b-hf | 8.0 GB | 12 GB | LLaVA 1.5 |
| `qwen2.5-vl:7b` | Qwen/Qwen2.5-VL-7B-Instruct | 5.0 GB | 9 GB | Qwen Vision 7B |
| `qwen2.5-vl:72b` | Qwen/Qwen2.5-VL-72B-Instruct | 43.0 GB | 50 GB | Qwen Vision 72B |
| `minicpm-v` | openbmb/MiniCPM-o-2_6 | 5.5 GB | 9 GB | MiniCPM-o 2.6 |
| `moondream2` | vikhyatk/moondream2 | 1.8 GB | 3 GB | Kis, gyors vision |
| `llava-phi3:mini` | microsoft/Phi-3.5-vision-instruct | 2.2 GB | 4 GB | Phi-3.5 Vision |
| `gemma3:12b` | google/gemma-3-12b-it | 8.1 GB | 12 GB | Gemma 3 multimodal |

#### AGENT — text-generation (tool-use, function calling)

| Ollama neve | HF ID | Méret | VRAM | Leírás |
|---|---|---|---|---|
| `glm5.1` | zai-org/GLM-5.1 | 45.0 GB | 50 GB | SWE-Bench SOTA |
| `hermes3:8b` | NousResearch/Hermes-3-Llama-3.1-8B | 4.9 GB | 8 GB | Tool-use, function calling |
| `hermes3:70b` | NousResearch/Hermes-3-Llama-3.1-70B | 42.0 GB | 48 GB | Hermes 70B agentic |
| `qwen2.5:7b-instruct` | Qwen/Qwen2.5-7B-Instruct | 4.7 GB | 8 GB | Function calling |
| `mistral-nemo:12b` | mistralai/Mistral-Nemo-Instruct-2407 | 7.1 GB | 11 GB | Mistral Nemo |
| `firefunction-v2` | fireworks-ai/firefunction-v2 | 8.0 GB | 12 GB | Fireworks FC v2 |

#### ASR — automatic-speech-recognition

> ⚠ ASR modellek sem Ollama-val, sem vLLM-mel nem futtathatók közvetlenül. A katalógusban megjelennek, de külön eszközzel (Faster-Whisper, Whisper.cpp) futtatandók.

| HF ID | Méret | VRAM | Leírás |
|---|---|---|---|
| openai/whisper-large-v3 | 3.1 GB | 5 GB | Whisper Large v3 |
| openai/whisper-large-v3-turbo | 1.6 GB | 3 GB | Gyors Turbo verzió |
| distil-whisper/distil-large-v3 | 1.5 GB | 3 GB | 2× gyorsabb |
| openai/whisper-medium | 1.5 GB | 3 GB | Kompromisszum |

---

## 10. User Interface — alapépítőelemek

A program kizárólag `whiptail` dialógokat használ. A `lib/00_lib_ui.sh` wrappereket biztosít, de a 09-es modul közvetlen `whiptail` hívásokat alkalmaz a teljes kontroll érdekében.

### 10.1 Dialóg típusok

#### `--menu` — navigációs menü

```bash
whiptail --title "Cím" \
  --menu "Fejléc szöveg" \
  <magasság> <szélesség> <listahossz> \
  "1" "Első elem" \
  "2" "Második elem" \
  "0" "← Vissza" \
  3>&1 1>&2 2>&3
```

- Nyilakkal navigálható
- ENTER = kiválasztás, ESC = kilépés (visszatérési kód ≠ 0)
- Az `|| return` minta: ESC esetén visszatér a szülő menübe

#### `--radiolist` — egyszeres kiválasztás lista

```bash
whiptail --title "Cím" \
  --radiolist "Prompt" \
  <magasság> <szélesség> <listahossz> \
  "1" "Label szöveg" "OFF" \
  "2" "Másik elem" "OFF" \
  3>&1 1>&2 2>&3
```

- SPACE = jelölés (csak egy lehet ON)
- ENTER = OK, ESC = Cancel (üres string visszaadás)
- A `"OFF"` kötelező boolean állapot oszlop (YAD-tól eltérő!)

#### `--checklist` — többszörös kiválasztás

```bash
whiptail --checklist "Prompt" <h> <w> <l> \
  "1" "Label" "OFF" \
  3>&1 1>&2 2>&3
```

#### `--msgbox` — információs ablak

```bash
whiptail --title "Cím" --msgbox "Üzenet" <magasság> <szélesség>
```

- Egyetlen `<Ok>` gomb
- ESC = OK-val egyenértékű
- **Nem használható ott ahol ESC-pel ki kell lépni!**

#### `--yesno` — kétgombos megerősítés

```bash
whiptail --title "Cím" --yesno "Kérdés" <magasság> <szélesség>
```

- Visszatérési kód: `0` = Igen, `1` = Nem/ESC
- **Kötelező minden destruktív vagy hosszú művelet előtt**

#### `--inputbox` — szövegbevitel

```bash
whiptail --title "Cím" \
  --inputbox "Prompt" <magasság> <szélesség> \
  "alapértelmezett érték" \
  3>&1 1>&2 2>&3
```

#### `--gauge` — folyamatjelző

```bash
# Feeder subshell → gauge stdin:
(
  printf 'XXX\n%d\n%s\nXXX\n' "$pct" "$label"
  sleep 1
  echo 100
) | whiptail --title "Cím" \
    --gauge "Fejléc szöveg" <magasság> <szélesség> 0
```

Formátum: `XXX\n<0-100>\n<szöveg>\nXXX\n`  
ESC = gauge bezárul, a háttérfolyamat tovább fut.

#### `--scrolltext --msgbox` — görgetős szöveges ablak

```bash
whiptail --title "Cím" --scrolltext \
  --msgbox "$tartalom" <magasság> <szélesség>
```

Hosszú log vagy lista megjelenítésére.

---

## 11. UI működési szabályok

### 11.1 ESC és visszalépés szabály

> **Általános szabály: ESC mindig a szülő menübe lép vissza.**

Implementáció minden menüben:
```bash
choice=$(whiptail ... 3>&1 1>&2 2>&3) || return  # → szülő függvénybe visszatér
```

Catalog browse-ban:
```bash
model=$(_model_catalog_browse "ollama" "all")
[ "$model" = "CANCEL" ] && continue   # → while ciklus tetejére ugrik
[ -z "$model" ] && continue
```

**Tilos:** ESC → automatikus fallback kézi bevitelre. Ez volt az egyik leggyakrabban visszajövő bug.

### 11.2 Katalógus browse szabályok

#### Visszaadott értékek

| Backend | Visszaadott érték |
|---|---|
| `ollama` | Ollama neve (`qwen2.5-coder:7b`) |
| `vllm` | HuggingFace ID (`Qwen/Qwen2.5-Coder-7B-Instruct`) |

Ha a felhasználó ESC-vel lép ki: `echo "CANCEL"; return 1`

#### ✓ jelölés megjelenítése

- **Ollama:** `GET /api/tags` válaszból az `installed_set` pipe-szeparált stringben keres
- **vLLM:** `~/.cache/huggingface/hub/models--<owner>--<repo>/` könyvtár létezése

#### TASK szűrő megjelenítési szabály

A TASK kategória szűrő menü **kizárólag** akkor jelenik meg, ha `filter="all"` paraméterrel hívják a browse függvényt. Ha a hívó már megadott szűrőt (pl. `_popular_model_browse "code"`), a szűrő menü nem jelenik meg újra.

### 11.3 Dialógok kezelőgombjai

| Gomb | whiptail kulcsszó | Viselkedés |
|---|---|---|
| OK / Igen | `<Ok>` / `<Yes>` | Elfogad, kilép visszatérési kód 0 |
| Mégse / Nem | `<Cancel>` / `<No>` | Visszalép, visszatérési kód 1 |
| ESC billentyű | — | `<Cancel>`/`<No>`-val egyenértékű |

> **Megjegyzés:** Ubuntu 24.04-en a YAD stock item nevek (`yad-ok`, `yad-yes`) literal szövegként jelennek meg, ezért a 09-es modul plain text labeleket (`<Ok>`, `<Yes>`) használ.

### 11.4 Ablak statikus és dinamikus méretezés

#### Statikus méretek (egyszerű dialógok)

Az egyszerű `--msgbox`, `--yesno`, `--inputbox` ablakok rögzített méreteket kapnak, amelyek az adott tartalom méretéhez igazodnak, de a sorok/oszlopok manuálisan vannak beállítva:

```bash
whiptail --msgbox "Rövid üzenet" 8 50      # 8 sor, 50 karakter
whiptail --yesno  "Kérdés"      12 65      # 12 sor, 65 karakter
```

#### Dinamikus méretek (browse/radiolist ablakok)

A modell katalógus és Ollama radiolist ablakok `tput`-alapú dinamikus méretezést alkalmaznak:

```bash
term_cols=$(tput cols 2>/dev/null || echo 120)
term_rows=$(tput lines 2>/dev/null || echo 40)

win_w=$(( term_cols * 95 / 100 ))   # 95% szélesség
[ "$win_w" -lt 90  ] && win_w=90    # minimum
[ "$win_w" -gt 220 ] && win_w=220   # maximum

list_h="${#result_ids[@]}"           # lista elemek száma
win_h=$(( list_h + 9 ))             # + header + border + prompt
[ "$win_h" -gt $(( term_rows - 2 )) ] && win_h=$(( term_rows - 2 ))
[ "$list_h" -gt $(( win_h - 9 ))   ] && list_h=$(( win_h - 9 ))
[ "$list_h" -lt 5 ] && list_h=5     # minimum listahossz

label_max=$(( win_w - 10 ))         # label levágás szélességhez
```

> **Megjegyzés:** whiptail nem tud horizontálisan scrollozni, ezért a labelek `${label:0:label_max}` stringcel kerülnek levágásra, ha nem férnek el.

### 11.5 Label formátum a katalógus browse-ban

```
[TASK  ] result_id                        (XGB, VRAM~YGB) leírás ✓
```

Például:
```
[CODE  ] qwen2.5-coder:7b                 (4.7GB, VRAM~8GB) Ajánlott CLINE kód asszisztens ✓
[CHAT  ] llama3.3:70b                     (42.0GB, VRAM~48GB) Meta flagship
[REASON] deepseek-r1:32b                  (19.0GB, VRAM~25GB) SOTA reasoning RTX 5090
```

Formátum (printf):
```bash
printf '[%-6s] %-38s (%sGB, VRAM~%sGB) %s%s' \
  "$task_tag" "$result_id" \
  "${_MDB_SIZE[$i]}" "${_MDB_VRAM[$i]}" \
  "${_MDB_DESC[$i]}" "$marker"
```

### 11.6 Menü fejléc (állapotinformáció)

A menü szövegmezőbe (`--menu` második argumentuma) kerül az aktuális állapot:

```bash
# Fő menü fejléce:
"Ollama: ${ollama_st}  vLLM: ${vllm_st}  CLINE backend: ${current_backend}"

# vLLM szerver menü fejléce:
"Állapot: ✅ Fut — Qwen/Qwen2.5-Coder-7B-Instruct
dtype: bfloat16  gpu-mem: 0.90  max-len: 16384"
```

Az `✅` / `⛔` emoji státuszjelzők minden almenü fejlécében megjelennek.

### 11.7 Progress gauge szabályok

- A `uv pip install` és a vLLM indítás progress gauge-ai **háttérben futnak** (a feeder subshell a tényleges folyamattól független)
- ESC = gauge bezárul, a folyamat fut tovább
- A `uv pip` kimenet kizárólag log fájlba kerül (`> log 2>&1`), soha nem a terminálra — megakadályozza a gauge szétírását
- A gauge szövege az utolsó log sor ANSI-szűrt, max 60 karakterre vágott változata

---

## 12. Konfigurációs konstansok

Minden paraméter a script tetején `readonly` változókban van deklarálva. Verziófrissítés csak ezeket érinti, a logika nem változik.

```bash
# Modul
MOD_ID="09"
MOD_VERSION="2.8"
MOD_LIB_MIN="6.4"

# Ollama
OLLAMA_HOST="http://localhost:11434"
OLLAMA_KEEP_ALIVE_LOAD="-1"    # VRAM-ban marad
OLLAMA_KEEP_ALIVE_UNLOAD="0"   # Azonnal kiejti
OLLAMA_DEFAULT_CODE_MODEL="qwen2.5-coder:7b"
OLLAMA_DEFAULT_CHAT_MODEL="qwen2.5:7b"
OLLAMA_DEFAULT_EMBED_MODEL="nomic-embed-text"
OLLAMA_DEFAULT_AUTOCOMPLETE="qwen2.5-coder:1.5b"

# vLLM
VLLM_HOST="0.0.0.0"
VLLM_PORT=8000
VLLM_DTYPE="bfloat16"           # Blackwell SM_120
VLLM_GPU_MEM_UTIL="0.90"        # ~28.8 GB / 32 GB
VLLM_MAX_MODEL_LEN=16384        # Token context
VLLM_ENABLE_PREFIX_CACHE=1
VLLM_PID_FILE="/tmp/vllm-rtx5090.pid"
VLLM_LOG_FILE="${SCRIPT_DIR}/wrapper_vllm.log"  # append mód, timestamp-elt

# TurboQuant
TQ_DIR="${HOME}/src/turboquant"
TQ_QUANTIZED_DIR="${HOME}/.ollama/turboquant"
TQ_DEFAULT_BITS=4
TQ_DEFAULT_GROUP_SIZE=128

# IDE
VSCODE_SETTINGS_FILE="${HOME}/.config/Code/User/settings.json"
CONTINUE_CONFIG_FILE="${HOME}/.continue/config.yaml"
CONTINUE_CONFIG_FILE_LEGACY="${HOME}/.continue/config.json"

# Telepítési célok
TOOL_INSTALL_DIR="${HOME}/bin"
TOOL_NAME="ai-model-ctl"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
VLLM_SERVICE_FILE="${SYSTEMD_USER_DIR}/vllm-rtx5090.service"
AI_VENV_DIR="${HOME}/venvs/ai"
VENV_PYTHON="${AI_VENV_DIR}/bin/python3"
VENV_VLLM="${AI_VENV_DIR}/bin/vllm"
```

---

## 13. State és log rendszer

### 13.1 `~/.infra-state` — globális INFRA state

A `09_ai_model_wrapper.sh` a következő kulcsokat írja:

```bash
MOD_09_DONE=true
COMP_09_TS=2026-04-15T08:35:00
COMP_09_S_OLLAMA=ok|old|missing
COMP_09_V_OLLAMA=0.5.x
COMP_09_S_VLLM=ok|old|missing
COMP_09_V_VLLM=0.19.0
COMP_09_S_TURBOQUANT=ok|old|missing
COMP_09_S_CLINE_CFG=ok|missing
COMP_09_V_CLINE_CFG=ollama|openai
COMP_09_S_CONTINUE_CFG=ok|old|missing
COMP_09_S_TOOL=ok|missing
PYTORCH_INDEX=cu128             # Fix sikeres esetén
```

### 13.2 Log fájlok

| Fájl | Elérési út | Tartalom |
|---|---|---|
| `wrapper_YYYYMMDD_HHMMSS.log` | `$SCRIPT_DIR/` | Fő futási napló |
| `wrapper_vllm.log` | `$SCRIPT_DIR/` | vLLM indítás/leállítás, append mód, timestampelt |
| `wrapper_pull_<model>_HHMMSS.log` | `$SCRIPT_DIR/` | Ollama pull folyamat |
| `wrapper_pytorch_fix_HHMMSS.log` | `$SCRIPT_DIR/` | PyTorch reinstall |
| `wrapper_vllm_reinstall_HHMMSS.log` | `$SCRIPT_DIR/` | vLLM ABI reinstall |

**vLLM log timestamp formátum:**
```
═══════════════════════════════════════════════════
2026-04-14 08:35:17 [START] vLLM indítás
  Modell:  Qwen/Qwen2.5-Coder-7B-Instruct
  Port:    8000  dtype: bfloat16  gpu-mem: 0.90
═══════════════════════════════════════════════════
[vLLM futási kimenet...]
2026-04-14 09:12:44 [STOP] vLLM leállítva
```

---

## 14. Ismert hibák és megoldásaik

### 14.1 `--swap-space 4` — unrecognized argument

**Hibaüzenet:**
```
vllm: error: unrecognized arguments: --swap-space 4
```

**Ok:** vLLM 0.19.0-ban a `--swap-space` flag nem létezik.  
**Megoldás:** Eltávolítva a `_vllm_build_args()` függvényből. Ne add vissza.

---

### 14.2 PyTorch SM_120 inkompatibilitás

**Hibaüzenet:**
```
torch.AcceleratorError: CUDA error: no kernel image is available for execution on the device
NVIDIA GeForce RTX 5090 with CUDA capability sm_120 is NOT compatible
```

**Ok:** `cu126` PyTorch csak SM_50–SM_90-ig.  
**Megoldás:** vLLM szerver menü → 6. PyTorch + vLLM Blackwell fix

---

### 14.3 vLLM C++ ABI inkompatibilitás

**Hibaüzenet:**
```
ImportError: vllm/_C.abi3.so: undefined symbol: _ZN3c1013MessageLoggerC1EPKciib
```

**Ok:** PyTorch cu128 reinstall UTÁN a régi vLLM C++ kiterjesztések inkompatibilisek.  
**Megoldás:** A PyTorch fix automatikusan felajánlja a vLLM reinstall-t. Manuálisan: `uv pip install vllm --reinstall`

---

### 14.4 Permission denied venv-ben

**Hibaüzenet:**
```
error: failed to remove directory .../numpy/typing/__pycache__: Permission denied (os error 13)
```

**Ok:** Korábbi `sudo pip install` root tulajdonba tette a `__pycache__` könyvtárakat.  
**Megoldás:** A PyTorch fix automatikusan futtat `chown -R $USER ~/venvs/ai/` a telepítés előtt.

---

### 14.5 RUN_MODE örökléses bug

**Tünet:** A script nem a manage menüt nyitja, hanem telepítési módba kerül.  
**Ok:** Az előző futás `RUN_MODE=install`-ja exportálva maradt a shellben.  
**Megoldás:**
```bash
unset RUN_MODE
sudo RUN_MODE=manage bash 09_ai_model_wrapper.sh
```

---

### 14.6 systemctl --user DBUS hiba

**Tünet:** `systemctl --user is-enabled vllm-rtx5090` nem ad visszatérési értéket sudo-ból.  
**Ok:** Sudo kontextusban nincs hozzáférés a user session bus-hoz.  
**Megoldás:**
```bash
XDG_RUNTIME_DIR="/run/user/$(id -u $REAL_USER)" \
  sudo -u $REAL_USER systemctl --user is-enabled vllm-rtx5090
```

---

### 14.7 Browse ESC → kézi fallback (visszatérő bug)

**Tünet:** Katalógusból ESC nyomásra kézi inputbox nyílik meg.  
**Ok:** A vLLM indítás menüpont 1-es ágában maradt a régi `CANCEL → inputbox` fallback kód.  
**Megoldás:** Minden `CANCEL` visszatérési érték után `continue` (nem inputbox), nincs fallback.

---

## 15. Fejlesztési előzmények

| Verzió | Főbb változások |
|---|---|
| v1.0 | Alap Ollama + vLLM kezelés, whiptail menü |
| v1.4 | `--swap-space` eltávolítva |
| v1.5 | PyTorch Blackwell SM_120 compat check + fix (`_vllm_check_pytorch_blackwell`, `_vllm_fix_pytorch_blackwell`) |
| v1.6 | `pip` → `uv pip` (CORE konvenció), `--force-reinstall` → `--reinstall`, PATH fix sudo-hoz |
| v2.0 | Egységes `_model_catalog_browse()` + `_init_model_db()`, 30 modell, 5 TASK; header futtatás dokumentáció; gauge ESC fix |
| v2.1 | Browse ablak dinamikus méretezés (`tput`), `chown -R` PyTorch fix előtt |
| v2.2 | 4 regressed bug fix: PyTorch fix yesno, uv stdout elnyomás, service státusz display + XDG fix, CANCEL → continue |
| v2.3 | Lib split: `lib/09_lib_models.sh` + `lib/09_lib_browse.sh`; HF TASK bővítés 7 kategóriára (47 modell); ESC szabály egységesítés |
| v2.4 | vLLM log timestamp; PyTorch fix után automatikus vLLM ABI reinstall; vLLM menü split (`_menu_vllm_control` + `_menu_vllm_model` + `_menu_vllm_start_with_model`) |
| v2.5 | **SÚLYOS hibajavítás kör (H1–H6):** H1 ESC regresszió javítás (explicit `if/continue`), H2 JSON/Python injection védelem (env var), H3 `_do_update` ténylegesen újragenerálja az `ai-model-ctl`-t (`_generate_ai_model_ctl()` közös függvény), H4 vLLM systemd `StartLimitIntervalSec`+`StartLimitBurst`, **H5 TurboQuant valós funkció = KV cache compression** (menü + `_tq_quantize_model` átírva), H6 `set -o pipefail` a subshell-ben |
| v2.6 | **KÖZEPES funkcionális kör (K1, K3, K4, K5, K6, K8):** K1 `_log_system_info` olvassa a state változókat `~/.infra-state`-ből (manage mód self-contained), K3 `_ollama_pull_model` detektálja a `"error"` JSON-t és whiptail-ben megjeleníti (korábban végtelen ciklus hibánál), K4 `_ide_update_settings` JSON parse hiba explicit log (nem néma elnyelés), **K5 `ollama_svc` 3-állapotú** (ok/old/missing — `list-unit-files` check, leállított ≠ hiányzó), **K6 `_vllm_start` `printf %q` escape** model name + args számára (space/aposztróf védelem), **K8 vLLM service enable után yesno start felajánlás** (+ `systemctl --user start` + 2s state check) |
| v2.7 | **KÖZEPES polish/biztonság kör (K2, K9, K10, K11, K12):** K2 `COMP_STATUS`/`COMP_VER` explicit `declare -gA` (standalone futás robusztusság), K9 `_do_install` `chown -R` a `mkdir -p` mellé (régi root-tulajdonú directory fallback), **K10 `/tmp/continue_config_new.json` → `mktemp`** (symlink attack védelem — fix path /tmp-ben kihasználható volt), K11 Continue.dev `.bak` fájlok cleanup (max 5 legfrissebb marad, korábbi: soha nem törlődött), **K12 `_manage_main_menu` kilépés yesno confirm** (véletlen `0`/ESC védelem) |
| v2.7.1 | **K7 Continue.dev JSON → YAML v1 séma:** `config.json` → `config.yaml` (roles-alapú modell definíciók), legacy JSON fallback detektálás (`old` státusz), `tabAutocompleteModel`/`embeddingsProvider` → `models[].roles[]`, autocomplete mindig Ollama (1.5B coder), `contextProviders[]` → `context[]`, `yaml.safe_load` a check függvényben. Forrás: `continuedev/continue` repo `packages/config-yaml/src/schemas/` |
| v2.8 | **ALACSONY prioritás javítások (A1–A10):** A1 log fájlnév dátum-stamp egységesítés (`%H%M%S` → `%Y%m%d_%H%M%S`), A2 `_is_ollama_running` curl REST API fallback (manuálisan indított Ollama detektálás), A3 GPU `bar_pct` clamp `max(0, min(30, ...))`, A5 `VLLM_MAX_MODEL_LEN` komment bővítés (modell-függő), A8 vLLM service fájl komment (menü hivatkozás + sed példa), **A9 `_cleanup_old_logs()`** (max 20 wrapper + 10 pull log, K11 mintájára), **A10 `_menu_gpu_status` while+yesno frissítés** (korábban egyetlen statikus snapshot). A4 arxiv link validálva (OK). A6/A7 skip. |

---

## Hivatkozások

| Forrás | URL |
|---|---|
| Ollama API | https://ollama.readthedocs.io/en/api/ |
| vLLM CLI serve | https://docs.vllm.ai/en/stable/cli/serve/ |
| PyTorch CUDA install | https://pytorch.org/get-started/locally/ |
| uv dokumentáció | https://docs.astral.sh/uv/ |
| TurboQuant GitHub | https://github.com/0xSero/turboquant |
| TurboQuant papír | https://arxiv.org/pdf/2504.19874 |
| VS Code settings | https://code.visualstudio.com/docs/configure/settings |
| Continue.dev docs | https://docs.continue.dev |
| CLINE GitHub | https://github.com/cline/cline |
| HuggingFace Tasks | https://huggingface.co/tasks |
| NVIDIA CUDA types | https://docs.nvidia.com/cuda/cuda-runtime-api/group__CUDART__TYPES.html |

---

*Dokumentáció verziója: 2026-04-20 · DR-Watt/AI-install · `09_ai_model_wrapper.sh` v2.8*
