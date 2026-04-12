#!/bin/bash
# ============================================================================
# 00_lib_state.sh — Vibe Coding Workspace lib v6.5
#
# LEÍRÁS: INFRA state kezelés: init/set/get/validate, infra_require, detect_run_mode
#
# VÁLTOZTATÁSOK v6.5 (csoportos megjelenítés + timestamp rendszer):
#   - infra_state_show(): prefix alapján csoportosított megjelenítés
#     [HW] [MOD] [REBOOT] [01a] [01b] [02] [03] [COMP/xx] csoportok
#     Minden csoport fejlécén timestamp ha az INST_XX_TS / HW_TS jelen van
#   - infra_state_group_ts(group): csoportos timestamp beírása
#     Szálak hívják: infra_state_group_ts "INST_01A" — état INST_01A_TS beírja
#   - infra_state_init(): HW_TS + HW_OS_CODENAME/VERSION hozzáadva
#   - Séma: 01a v6.11 alapján aktualizálva
#     Új kulcsok: HW_OS_CODENAME, HW_OS_VERSION, INST_NVIDIA_CTK_VER
#     FEAT_* → 01a v6.11 NEM írja (csak 01a régebbi verziók írták)
#
# VÁLTOZTATÁSOK v6.4.5 (lazy init — stack-specifikus kulcsok kiszedve):
#   - infra_state_init(): csak HW_* + MOD_* + REBOOT_* kulcsok (MINDIG jelen lévők)
#     Stack-specifikus kulcsok (INST_*, FEAT_*, GPU_MODE, stb.) az adott szál írja
#     → friss state fájl nem tartalmaz üres placeholder kulcsokat
#     → infra_state_get() default értékkel kezeli a hiányzókat (validate biztonságos)
#   - Séma dokumentáció megújítva: ki mit ír, mikor jelenik meg
# BETÖLTÉS: source-olja a 00_lib.sh master loader
# NE futtasd közvetlenül!
# ============================================================================

# SZEKCIÓ 9 — INFRA STATE RENDSZER
# =============================================================================
#
# CÉLJA: szálak közötti (chat-to-chat) és script-to-script adatátadás.
# HELYE: ~/.infra-state (user home, nem /etc, nem /root)
# FORMÁTUM: KEY=VALUE (sima szöveg, egy kulcs/sor)
#
# SÉMA — összes lehetséges kulcs és jelentése:
# ─────────────────────────────────────────────────────────────────────────────
#  CSOPORTONKÉNT — ki írja, mikor jelenik meg:
#
#  ════ GLOBÁLIS — MINDIG jelen van, infra_state_init() tölti be ═════════════
#
#  [HW] Hardver detektálás — hw_detect() eredménye (infra_state_init hívja)
#    HW_TS             ISO 8601 timestamp — mikor futott hw_detect
#    HW_PROFILE        pl. "desktop-rtx" | "notebook-igpu"
#    HW_GPU_ARCH       pl. "blackwell" | "ada" | "ampere" | "turing"
#    HW_GPU_NAME       pl. "NVIDIA GeForce RTX 5090 (Blackwell SM_120)"
#    HW_CUDA_ARCH      pl. "120" (SM compute capability)
#    HW_VLLM_OK        "true" | "false"  — SM_70+ szükséges vLLM-hez
#    HW_NVIDIA_PKG     pl. "nvidia-driver-580-open"  — dpkg detektált
#    HW_IS_NOTEBOOK    "true" | "false"
#    HW_OS_CODENAME    pl. "noble" | "plucky"  — Ubuntu kódnév (01a v6.11+)
#    HW_OS_VERSION     pl. "24.04" | "26.04"    — Ubuntu verzió (01a v6.11+)
#
#  [MOD] Modul completion flag-ek — üres alapértékkel, az adott szál "true"-ra
#    MOD_01A_DONE      "true" | ""  — 01a kész REBOOT előtt (csak ha FAIL==0)
#    MOD_01A_REBOOTED  "true" | ""  — REBOOT megtörtént (01b ellenőrzi)
#    MOD_01B_DONE      "true" | ""  — 01b kész → 03/02/06 előfeltétel
#    MOD_02_DONE       "true" | ""  — 02 kész (Ollama/vLLM/TQ)
#    MOD_03_DONE       "true" | ""  — 03 kész → 02/06 előfeltétel
#
#  [REBOOT] Reboot koordináció — 01a állítja, master olvassa
#    REBOOT_NEEDED     "true" | "false"
#    REBOOT_REASON     pl. "NVIDIA 580-open driver + initramfs"
#    REBOOT_BY_INFRA   pl. "01a"
#
#  ════ STACK-SPECIFIKUS — az adott szál futása UTÁN jelenik meg ═════════════
#
#  [01a] — 01a_system_foundation.sh v6.11+ írja telepítés/update után
#    INST_01A_TS         ISO 8601 timestamp — mikor írta 01a az INST_* kulcsait
#    INST_DRIVER_VER     pl. "580.126.09"   — dpkg-query verzió install után
#    INST_CUDA_VER       pl. "12.6"          — nvcc release major.minor
#    INST_CUDNN_VER      pl. "9.20.0.48"
#    INST_DOCKER_VER     pl. "29.4.0"
#    INST_NVIDIA_CTK_VER pl. "1.19.0"        — nvidia-ctk --version
#    PYTORCH_INDEX       pl. "cu126" | "cu128" | "cu130" — compat mátrix alapján
#    GPU_MODE            "hybrid" | "dedicated"  — xorg.conf konfig
#    HW_NVIDIA_OPEN      "true" | "false"     — open kernel module aktív-e
#    MOK_ENROLL_PENDING  "true" | "false"     — UEFI MOK enrollment vár-e
#
#    MEGJEGYZÉS v6.11: FEAT_GPU_ACCEL, FEAT_DOCKER_GPU, FEAT_VLLM
#    NINCSEN BEÍRVA 01a v6.11-ben — ezek detektálhatók HW_VLLM_OK és
#    infra_state_get-ből. Ha régebbi 01a írta őket, a kulcsok megtartva.
#
#    LEGACY kulcsok (01a v6.11 még írja, kanonikus INST_* mellett):
#    CUDA_VER            → lásd INST_CUDA_VER
#    DOCKER_VER          → lásd INST_DOCKER_VER
#    NVIDIA_CTK_VER      → lásd INST_NVIDIA_CTK_VER
#    NVIDIA_DRIVER_PKG, NVIDIA_DRIVER_SERIES  → driver azonosításhoz
#
#  [01b] — 01b_post_reboot.sh írja
#    INST_01B_TS         ISO 8601 timestamp
#    INST_ZSH_VER        pl. "5.9"
#    INST_OMZ_COMMIT     pl. "7c10d98"
#    FEAT_SHELL_ZSH      "true" | "false"
#
#  [02] — 02_local_ai_stack.sh írja
#    INST_02_TS          ISO 8601 timestamp
#    INST_OLLAMA_VER     pl. "0.20.5"
#    INST_VLLM_VER       pl. "0.5.0"
#    FEAT_TURBOQUANT     "true" | "false"
#    FEAT_OLLAMA_GPU     "true" | "false"
#    TURBOQUANT_BUILD_MODE "cpu" | "gpu89" | "gpu120"
#
#  [03] — 03_python_aiml.sh írja
#    INST_03_TS          ISO 8601 timestamp
#    INST_PYTHON_VER     pl. "3.12.9"
#    INST_UV_VER         pl. "0.11.3"
#    INST_TORCH_VER      pl. "2.10.0+cu126"
#
#  [COMP] — 00_lib_comp.sh comp_save_state() írja, az adott szál hívja
#    COMP_01A_TS, COMP_01A_S_*, COMP_01A_V_*  — 01a komponens check cache
#    COMP_01B_TS, COMP_02_TS, COMP_03_TS, COMP_06_TS stb.
# ─────────────────────────────────────────────────────────────────────────────

# infra_state_init: GLOBÁLIS kulcsok beírása HA MÉG NINCS BENNE.
# Meglévő értékeket NEM írja felül — biztonságosan hívható többször.
#
# ELVEK (v6.4.5):
#   - CSAK globális kulcsok kerülnek be: HW_* (detektált), MOD_* (completion), REBOOT_*
#   - Stack-specifikus kulcsok NEM kerülnek be az init-ben — az adott szál írja:
#       01a: INST_DRIVER_VER, INST_CUDA/CUDNN/DOCKER_VER, PYTORCH_INDEX,
#            FEAT_GPU_ACCEL, FEAT_DOCKER_GPU, FEAT_VLLM, GPU_MODE, HW_NVIDIA_OPEN
#       01b: INST_ZSH_VER, INST_OMZ_COMMIT, FEAT_SHELL_ZSH
#       02:  INST_OLLAMA_VER, INST_VLLM_VER, FEAT_TURBOQUANT, FEAT_OLLAMA_GPU,
#            TURBOQUANT_BUILD_MODE
#       03:  INST_PYTHON_VER, INST_UV_VER, INST_TORCH_VER
#       nvidia_mok_enroll (lib): MOK_ENROLL_PENDING
#   - infra_state_get() default értékkel kezeli a hiányzó kulcsokat → validate() biztonságos
#   - Eredmény: tiszta friss state fájl csak a valóban ismert/szükséges adatokkal
infra_state_init() {
  mkdir -p "$(dirname "$INFRA_STATE_FILE")"

  # Segéd: csak akkor ír, ha a kulcs még nem létezik a state fájlban.
  # Meglévő kulcsokat NEM írja felül (idempotens).
  local _init_key
  _init_key() {
    local k="$1" v="$2"
    grep -q "^${k}=" "$INFRA_STATE_FILE" 2>/dev/null \
      || printf '%s=%s\n' "$k" "$v" >> "$INFRA_STATE_FILE"
  }

  # ── [HW] Hardver detektálás eredménye ────────────────────────────────────────
  # hw_detect() (00_lib_hw.sh) már beállítja ezeket bash változóként,
  # itt csak a state fájlba írjuk be ha még nincs ott.
  # HW_TS: timestamp amikor a hw_detect lefutott (az init minden futáskor frissíti)
  infra_state_set "HW_TS" "$(date '+%Y-%m-%dT%H:%M:%S')"
  _init_key "HW_PROFILE"      "${HW_PROFILE:-unknown}"
  _init_key "HW_GPU_ARCH"     "${HW_GPU_ARCH:-unknown}"
  _init_key "HW_GPU_NAME"     "${HW_GPU_NAME:-}"
  _init_key "HW_CUDA_ARCH"    "${HW_CUDA_ARCH:-}"
  _init_key "HW_VLLM_OK"      "${HW_VLLM_OK:-false}"
  _init_key "HW_NVIDIA_PKG"   "${HW_NVIDIA_PKG:-}"
  _init_key "HW_IS_NOTEBOOK"  "${HW_IS_NOTEBOOK:-false}"
  # HW_OS_CODENAME + HW_OS_VERSION: 01a v6.11+ írja, de init is beállítja
  # ha a hw_lib már detektálta (lsb_release alapján)
  _init_key "HW_OS_CODENAME"  "${HW_OS_CODENAME:-$(lsb_release -cs 2>/dev/null || echo 'unknown')}"
  _init_key "HW_OS_VERSION"   "${HW_OS_VERSION:-$(lsb_release -rs 2>/dev/null || echo '0.0')}"

  # ── [MOD] Modul completion flag-ek ───────────────────────────────────────────
  # Alapértelmezés: üres (nem kész). Az adott szál írja "true"-ra ha kész.
  # Más szálak infra_require() hívással ellenőrzik ezeket.
  _init_key "MOD_01A_DONE"     ""   # 01a_system_foundation.sh írja
  _init_key "MOD_01A_REBOOTED" ""   # 01b ellenőrzi nvidia-smi-val a REBOOT után
  _init_key "MOD_01B_DONE"     ""   # 01b_post_reboot.sh → 03/02/06 előfeltétel
  _init_key "MOD_02_DONE"      ""   # 02_local_ai_stack.sh (Ollama/vLLM/TQ)
  _init_key "MOD_03_DONE"      ""   # 03_python_aiml.sh → 02/06 előfeltétel

  # ── [REBOOT] Reboot koordináció ──────────────────────────────────────────────
  # 01a írja REBOOT_NEEDED=true ha driver/initramfs változott.
  # 00_master.sh olvassa és kínálja fel az azonnali rebootot.
  _init_key "REBOOT_NEEDED"   "false"
  _init_key "REBOOT_REASON"   ""
  _init_key "REBOOT_BY_INFRA" ""

  # Tulajdonos visszaállítása — sudo alatt root:root lett volna
  chown "${_REAL_UID:-$(id -u)}:${_REAL_GID:-$(id -g)}" "$INFRA_STATE_FILE" 2>/dev/null || true
  chmod 644 "$INFRA_STATE_FILE" 2>/dev/null || true

  log "STATE" "State fájl inicializálva: $INFRA_STATE_FILE"
}

# infra_state_set: kulcs értékének beállítása/frissítése.
# Ha a kulcs már létezik, frissíti. Ha nem, hozzáadja.
# SUDO VÉDELME: sudo alatt a fájl root:root lesz — chown javítja vissza
# a valódi user tulajdonára (_REAL_UID:_REAL_GID, 00_lib_core.sh állítja).
infra_state_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "$INFRA_STATE_FILE")"
  if grep -q "^${key}=" "$INFRA_STATE_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$INFRA_STATE_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$INFRA_STATE_FILE"
  fi
  # Tulajdonos visszaállítása ha sudo alatt futtattuk (chown nem dob hibát ha nincs mit csinálni)
  chown "${_REAL_UID:-$(id -u)}:${_REAL_GID:-$(id -g)}" "$INFRA_STATE_FILE" 2>/dev/null || true
  chmod 644 "$INFRA_STATE_FILE" 2>/dev/null || true
  log "STATE" "${key}=${val}"
}

# infra_state_get: kulcs értékének lekérése, alapértékkel.
# Paraméterek: $1=kulcs, $2=alapérték ha nincs benne
infra_state_get() {
  local key="$1" default="${2:-}"
  if [ -f "$INFRA_STATE_FILE" ]; then
    local val
    val=$(grep "^${key}=" "$INFRA_STATE_FILE" 2>/dev/null | cut -d= -f2-)
    printf '%s' "${val:-$default}"
  else
    printf '%s' "$default"
  fi
}

# infra_state_group_ts: csoport-szintű timestamp beírása.
# CÉLJA: minden stack szál tudja jelölni mikor írta az INST_* kulcsait.
#   Ez lehetővé teszi az infra_state_show() számára a csoportos megjelenítést.
#
# KONVENCIÓ:
#   infra_state_group_ts "HW"       → HW_TS=<timestamp>     (infra_state_init hívja)
#   infra_state_group_ts "INST_01A" → INST_01A_TS=<timestamp> (01a hívja)
#   infra_state_group_ts "INST_01B" → INST_01B_TS=<timestamp> (01b hívja)
#   infra_state_group_ts "INST_02"  → INST_02_TS=<timestamp>  (02 hívja)
#   infra_state_group_ts "INST_03"  → INST_03_TS=<timestamp>  (03 hívja)
#
# Paraméter: $1=csoport neve (pl. "INST_01A", "HW")
# Hívás helye: az adott szálban, közvetlenül az INST_* kulcsok írása UTÁN
infra_state_group_ts() {
  local group="$1"
  [ -z "$group" ] && return 1
  infra_state_set "${group}_TS" "$(date '+%Y-%m-%dT%H:%M:%S')"
}

# infra_state_show: a state fájl tartalmának CSOPORTOSÍTOTT logba írása.
# v6.5: prefix alapján csoportosított megjelenítés timestamp fejlécekkel.
# Hibakereséshez és szál-szinkronizáció ellenőrzéséhez.
infra_state_show() {
  # ── Prefix-alapú csoportosított megjelenítés (v6.5) ────────────────────────
  # Minden csoport fejlécén: timestamp ha az XX_TS kulcs megvan,
  # üres fejléc ha nincs. Üres csoportok kimaradnak a megjelenítésből.
  # A fájl tartalma VÁLTOZATLAN — csak a log kimenet csoportosított.

  if [ ! -f "$INFRA_STATE_FILE" ]; then
    log "STATE" "State fájl nem létezik: $INFRA_STATE_FILE"
    return
  fi
  log "STATE" "━━━ INFRA state ($INFRA_STATE_FILE) ━━━"

  # ── Belső segédfüggvény: egy csoport megjelenítése ──────────────────────────
  # Paraméterek:
  #   $1 = fejléc label (pl. "HW", "01a — System Foundation")
  #   $2 = timestamp kulcs (pl. "HW_TS") — "" ha nincs
  #   $3 = grep -E minta (pl. "^HW_[^T]|^HW_T[^S]" VAGY "^(KULCS1|KULCS2)=")
  # A _TS sorok automatikusan kizárva a tartalomból (csak fejlécben vannak).
  __infra_grp() {
    local _label="$1" _ts_key="$2" _pat="$3"
    local _ts_val="" _lines
    # Timestamp lekérése ha van
    [ -n "$_ts_key" ] && _ts_val=$(grep "^${_ts_key}=" "$INFRA_STATE_FILE" 2>/dev/null \
      | cut -d= -f2- | head -1)
    # Tartalomsorok: pattern match, _TS sorok kizárva
    _lines=$(grep -E "$_pat" "$INFRA_STATE_FILE" 2>/dev/null \
      | grep -v '_TS=' | grep -v '^$')
    [ -z "$_lines" ] && return  # üres csoport → kihagyás
    if [ -n "$_ts_val" ]; then
      log "STATE" "  ── [$_label] $_ts_val ──"
    else
      log "STATE" "  ── [$_label] ──"
    fi
    while IFS= read -r _line; do
      [ -n "$_line" ] && log "STATE" "    $_line"
    done <<< "$_lines"
  }

  # ── [HW] Hardver detektálás ───────────────────────────────────────────────
  # hw_detect() és infra_state_init() írja — MINDIG jelen van
  __infra_grp "HW" "HW_TS" \
    "^HW_(PROFILE|GPU_ARCH|GPU_NAME|CUDA_ARCH|VLLM_OK|NVIDIA_PKG|IS_NOTEBOOK|OS_CODENAME|OS_VERSION)="

  # ── [MOD] Modul completion flag-ek ──────────────────────────────────────────
  # Üres "" alapértékkel, az adott szál állítja "true"-ra
  __infra_grp "MOD" "" "^MOD_"

  # ── [REBOOT] Reboot koordináció ─────────────────────────────────────────────
  # 01a állítja, master olvassa, validate() cleanup-olja ha stale
  __infra_grp "REBOOT" "" "^REBOOT_"

  # ── Stack csoportok (csak ha az adott szál futott + írt adatot) ─────────────
  # Megjelenítési feltétel: bármely matching kulcs jelen van a state fájlban
  # (nem csak a TS). Ez biztosítja hogy régebbi szálak adatai is megjelennek.

  # [01a] — 01a_system_foundation.sh (v6.11+)
  # INST_NVIDIA_CTK_VER: 01a v6.11 még NVIDIA_CTK_VER-t ír (legacy), de
  # a séma kanonikus neve INST_NVIDIA_CTK_VER — mindkettő megjelenik itt
  __infra_grp "01a — System Foundation" "INST_01A_TS" \
    "^(INST_DRIVER_VER|INST_CUDA_VER|INST_CUDNN_VER|INST_DOCKER_VER|INST_NVIDIA_CTK_VER|PYTORCH_INDEX|FEAT_GPU_ACCEL|FEAT_DOCKER_GPU|FEAT_VLLM|GPU_MODE|HW_NVIDIA_OPEN|MOK_ENROLL_PENDING)="

  # [01b] — 01b_post_reboot.sh
  __infra_grp "01b — User Environment" "INST_01B_TS" \
    "^(INST_ZSH_VER|INST_OMZ_COMMIT|FEAT_SHELL_ZSH)="

  # [02] — 02_local_ai_stack.sh
  __infra_grp "02 — AI Stack" "INST_02_TS" \
    "^(INST_OLLAMA_VER|INST_VLLM_VER|FEAT_TURBOQUANT|FEAT_OLLAMA_GPU|TURBOQUANT_BUILD_MODE)="

  # [03] — 03_python_aiml.sh
  __infra_grp "03 — Python/AI-ML" "INST_03_TS" \
    "^(INST_PYTHON_VER|INST_UV_VER|INST_TORCH_VER)="

  # ── COMP_ csoportok (dinamikusan — COMP_XX_TS kulcsok alapján) ──────────────
  # comp_save_state() írja: COMP_01A_TS, COMP_01A_S_*, COMP_01A_V_*
  local _comp_ts_keys
  _comp_ts_keys=$(grep -oE 'COMP_[A-Z0-9]+_TS' "$INFRA_STATE_FILE" 2>/dev/null | sort -u)
  while IFS= read -r _comp_ts_key; do
    [ -z "$_comp_ts_key" ] && continue
    local _comp_pfx="${_comp_ts_key%_TS}"       # pl. "COMP_01A"
    local _mod_lc
    _mod_lc="$(printf '%s' "${_comp_pfx#COMP_}" | tr '[:upper:]' '[:lower:]')"
    __infra_grp "COMP/${_mod_lc}" "${_comp_ts_key}" "^${_comp_pfx}_[SV]_"
  done <<< "$_comp_ts_keys"

  # ── [LEGACY] Régi verziókból maradt kulcsok ─────────────────────────────────
  # 01a v6.11 még írja ezeket az INST_* mellett (backward compat).
  # validate() logol róluk, de nem törli őket.
  __infra_grp "LEGACY" "" \
    "^(CUDA_VER|DOCKER_VER|NVIDIA_CTK_VER|NVIDIA_DRIVER_PKG|NVIDIA_DRIVER_SERIES|GPU_MODE)="
}

# infra_state_validate: keresztellenőrzések a state konzisztenciájáért.
# Hibát jelez ha inkonzisztencia van (pl. CUDA_VER=12.8 de PYTORCH_INDEX=cu126)
infra_state_validate() {
  local errors=0

  local cuda_ver py_idx
  cuda_ver=$(infra_state_get "INST_CUDA_VER" "")
  py_idx=$(infra_state_get "PYTORCH_INDEX" "cu126")

  # Ha van telepített CUDA verzió, a PyTorch index-nek megfelelőnek kell lenni
  if [ -n "$cuda_ver" ]; then
    local expected_idx
    expected_idx="cu$(printf '%s' "$cuda_ver" | cut -d. -f1-2 | tr -d .)"
    if [ "$py_idx" != "$expected_idx" ]; then
      log "WARN" "State inkonzisztencia: CUDA=$cuda_ver de PYTORCH_INDEX=$py_idx (elvárt: $expected_idx)"
      log "WARN" "Automatikus javítás: PYTORCH_INDEX=$expected_idx"
      infra_state_set "PYTORCH_INDEX" "$expected_idx"
      ((errors++))
    fi
  fi

  # GPU gyorsítás és vLLM konzisztencia
  local feat_gpu feat_vllm
  feat_gpu=$(infra_state_get "FEAT_GPU_ACCEL" "false")
  feat_vllm=$(infra_state_get "FEAT_VLLM" "false")

  if [ "$feat_vllm" = "true" ] && [ "$feat_gpu" = "false" ]; then
    log "WARN" "State inkonzisztencia: FEAT_VLLM=true de FEAT_GPU_ACCEL=false"
    infra_state_set "FEAT_VLLM" "false"
    ((errors++))
  fi

  # 01b függőség konzisztencia: ha MOD_01B_DONE=true, MOD_01A_DONE is true kell
  local mod_01a mod_01b
  mod_01a=$(infra_state_get "MOD_01A_DONE" "")
  mod_01b=$(infra_state_get "MOD_01B_DONE" "")
  if [ "$mod_01b" = "true" ] && [ "$mod_01a" != "true" ]; then
    log "WARN" "State inkonzisztencia: MOD_01B_DONE=true de MOD_01A_DONE!=true"
    log "WARN" "Ez szokatlan — valószínűleg manuális futtatás volt. Javítás: MOD_01A_DONE=true"
    infra_state_set "MOD_01A_DONE" "true"
    ((errors++))
  fi

  # 02 konzisztencia: ha FEAT_TURBOQUANT=true, MOD_02_DONE is true kell
  local feat_tq mod_02
  feat_tq=$(infra_state_get "FEAT_TURBOQUANT" "false")
  mod_02=$(infra_state_get "MOD_02_DONE" "")
  if [ "$feat_tq" = "true" ] && [ "$mod_02" != "true" ]; then
    log "WARN" "State inkonzisztencia: FEAT_TURBOQUANT=true de MOD_02_DONE!=true"
    log "WARN" "Javítás: MOD_02_DONE=true (TurboQuant bináris jelen van)"
    infra_state_set "MOD_02_DONE" "true"
    ((errors++))
  fi

  # 03 konzisztencia: ha MOD_03_DONE=true, INST_TORCH_VER-nek nem kellene üresnek lenni
  # Kivétel: CPU-only profil esetén a PyTorch cpu-only index-szel települ, de az is érvényes
  local mod_03 torch_ver
  mod_03=$(infra_state_get "MOD_03_DONE" "")
  torch_ver=$(infra_state_get "INST_TORCH_VER" "")
  if [ "$mod_03" = "true" ] && [ -z "$torch_ver" ]; then
    log "WARN" "State inkonzisztencia: MOD_03_DONE=true de INST_TORCH_VER üres"
    log "WARN" "Lehetséges ok: 03 szál régebbi verzióból futott (pre-v6.1) vagy PyTorch lépés kihagyva"
    # Nem javítjuk automatikusan — a user tudatos döntése lehet a PyTorch kihagyása
    ((errors++))
  fi

  # 03 → 02 függőség: ha MOD_02_DONE=true, MOD_03_DONE is true kell
  # A 02 infra_require("03") ellenőrzi, de state validálóban is rögzítjük
  if [ "$mod_02" = "true" ] && [ "$mod_03" != "true" ]; then
    log "WARN" "State inkonzisztencia: MOD_02_DONE=true de MOD_03_DONE!=true"
    log "WARN" "Ez szokatlan — 02 a 03 előfeltétele (Python/PyTorch szükséges)"
    # Automatikus javítás: ha van telepített Torch, a 03 valószínűleg lefutott
    if [ -n "$torch_ver" ]; then
      log "WARN" "INST_TORCH_VER=$torch_ver alapján: MOD_03_DONE=true (auto-javítás)"
      infra_state_set "MOD_03_DONE" "true"
      ((errors++))
    fi
  fi

  # REBOOT stale cleanup: ha REBOOT_NEEDED=false, de REASON/BY_INFRA nem üres → stale adat
  # Ez azért fordul elő, mert a REBOOT_REASON/BY_INFRA csak REBOOT_NEEDED=true esetén
  # relevánsan, és a master REBOOT_NEEDED=false-ra állít vissza — de a reason megmarad.
  local reboot_needed reboot_reason reboot_by
  reboot_needed=$(infra_state_get "REBOOT_NEEDED" "false")
  reboot_reason=$(infra_state_get "REBOOT_REASON" "")
  reboot_by=$(infra_state_get "REBOOT_BY_INFRA" "")
  if [ "$reboot_needed" = "false" ] &&      { [ -n "$reboot_reason" ] || [ -n "$reboot_by" ]; }; then
    log "STATE" "REBOOT stale cleanup: REBOOT_REASON='$reboot_reason' REBOOT_BY='$reboot_by' → üresítve"
    infra_state_set "REBOOT_REASON"   ""
    infra_state_set "REBOOT_BY_INFRA" ""
    ((errors++))
  fi

  # Legacy kulcs detektálás: CUDA_VER és DOCKER_VER duplikálják az INST_* párjaikat.
  # Ezeket a régi 01a szál írta közvetlenül — az új INST_* prefixes változat a canonical.
  # Logolunk de NEM töröljük (a 01a szál esetleg még írja) — dokumentálás célú.
  local cuda_ver_leg docker_ver_leg
  cuda_ver_leg=$(infra_state_get "CUDA_VER" "")
  docker_ver_leg=$(infra_state_get "DOCKER_VER" "")
  [ -n "$cuda_ver_leg" ] &&     log "STATE" "Legacy kulcs: CUDA_VER=$cuda_ver_leg (kanonikus: INST_CUDA_VER)"
  [ -n "$docker_ver_leg" ] &&     log "STATE" "Legacy kulcs: DOCKER_VER=$docker_ver_leg (kanonikus: INST_DOCKER_VER)"

  [ $errors -eq 0 ] \
    && log "STATE" "Validáció OK — nincs inkonzisztencia" \
    || log "WARN" "Validáció: $errors inkonzisztencia javítva"
}

# infra_require: függőség ellenőrzés modulok között.
# Ellenőrzi hogy az előfeltétel modul sikeresen lefutott-e az infra state-ben.
# Paraméterek: $1=modul azonosító (pl. "01a", "01b", "03"), $2=leírás (opcionális)
# Visszatér: 0 ha OK, 1 ha a modul még nem futott le
# Példák:
#   infra_require "01a"  → MOD_01A_DONE kulcsot keres
#   infra_require "01b"  → MOD_01B_DONE kulcsot keres
#   infra_require "03"   → MOD_03_DONE kulcsot keres
infra_require() {
  # Ellenőrzi hogy az előfeltétel modul sikeresen lefutott-e.
  # Paraméterek: $1=modul azonosító (pl. "01a", "01b", "03"), $2=leírás (opcionális)
  # Visszatér: 0=OK, 1=hiányzik (check módban mindig 0 — csak logol, nem blokkol)
  #
  # FONTOS: a kulcs MINDIG nagybetűs legyen:
  #   infra_require "01a" → MOD_01A_DONE (nem MOD_01a_DONE!)
  #   infra_require "03"  → MOD_03_DONE
  local mod_num="$1"
  local desc="${2:-INFRA $mod_num}"

  # Kulcs: nagybetűsített azonosítóval — "01a" → "MOD_01A_DONE"
  local done_key="MOD_$(printf '%s' "$mod_num" | tr '[:lower:]' '[:upper:]')_DONE"
  local done_val
  done_val=$(infra_state_get "$done_key" "")

  if [ "$done_val" != "true" ]; then
    # Check módban: csak logolunk, NEM blokkoljuk a futást
    # Az ellenőrző módnak mindenképpen le kell futnia függőség nélkül is
    if [ "${RUN_MODE:-install}" = "check" ] ||        [ "${RUN_MODE:-install}" = "fix" ]; then
      log "WARN" "${RUN_MODE} mód: $done_key != true — bypass (nem blokkol)"
      return 0
    fi

    dialog_warn "Függőség hiányzik" \
      "\n  Ez a modul igényli: $desc (INFRA $mod_num)\n\n  Futtasd először az $mod_num-es modult!" 12
    log "FAIL" "Hiányzó függőség: INFRA $mod_num ($done_key != true)"
    log "FAIL" "Előfeltétel hiányzik: $mod_num — kilépés"
    return 1
  fi
  return 0
}

# =============================================================================
# SZEKCIÓ 10 — INFRA PLUGIN RENDSZER
# =============================================================================

# infra_compatible: hardver kompatibilitás ellenőrzés.
# Paraméter: hw_req string a registry-ből ("" | "nvidia" | "vllm" | "desktop")
infra_compatible() {
  local hw_req="$1"
  case "$hw_req" in
    nvidia|cuda)
      hw_has_nvidia && return 0 || return 1 ;;
    vllm|turboquant)
      $HW_VLLM_OK && return 0 || return 1 ;;
    desktop)
      [ "$HW_PROFILE" != "notebook-igpu" ] && return 0 || return 1 ;;
    ""|any)
      return 0 ;;
    *)
      return 0 ;;
  esac
}

# detect_run_mode: futtatási mód meghatározása a komponens állapot alapján.
# Ha minden OK és friss → felajánljuk a skip/update/reinstall opciókat.
# Paraméter: comp_keys tömb referenciája
detect_run_mode() {
  # Futtatási mód meghatározása a komponens állapot alapján.
  # Paraméter: comp_keys tömb referenciája (nameref)
  #
  # CHECK mód: soha nem változtat RUN_MODE-on (az már "check") — csak olvas
  # INSTALL mód: ha minden OK → felajánlja skip/update/reinstall opciókat
  # Meglévő értékek: skip/update/reinstall esetén nem kérdez újra
  local -n _comp_names=$1
  local missing=0 old=0

  for n in "${_comp_names[@]}"; do
    case "${COMP_STATUS[$n]:-missing}" in
      missing) ((missing++)) ;;
      old)     ((old++)) ;;
    esac
  done

  # Check és fix módban a mód változatlan marad — csak nézünk/javítunk, nem döntünk
  if [ "${RUN_MODE:-install}" = "check" ] ||      [ "${RUN_MODE:-install}" = "fix" ]; then
    export RUN_MODE
    return 0
  fi

  # Ha már be van állítva skip/update/reinstall (pl. master-ből), nem kérdezünk újra
  case "${RUN_MODE:-install}" in
    skip|update|reinstall) export RUN_MODE; return 0 ;;
  esac

  if [ "$missing" -eq 0 ] && [ "$old" -eq 0 ]; then
    # Minden OK és naprakész — felajánljuk a lehetőségeket
    local choice
    choice=$(dialog_menu "Minden komponens megvan" \
      "\n  Minden komponens telepítve és naprakész.\n\n  Mit tegyünk?" \
      14 3 \
      "skip"      "Kihagyás — semmi sem változik" \
      "update"    "Frissítés — verziók frissítése ha van újabb" \
      "reinstall" "Újratelepítés — teljes újratelepítés")
    RUN_MODE="${choice:-skip}"
  elif [ "$missing" -eq 0 ] && [ "$old" -gt 0 ]; then
    # Elavult verzió — frissítés ajánlott
    local choice
    choice=$(dialog_menu "Elavult verziók találhatók" \
      "\n  $old komponens frissítésre szorul.\n\n  Mit tegyünk?" \
      14 3 \
      "update"    "Frissítés — elavult verziók frissítése" \
      "skip"      "Kihagyás — marad ahogy van" \
      "reinstall" "Újratelepítés — mindent újrarakunk")
    RUN_MODE="${choice:-update}"
  else
    # Valami hiányzik → install mód
    RUN_MODE="install"
  fi
  export RUN_MODE
}

# =============================================================================
