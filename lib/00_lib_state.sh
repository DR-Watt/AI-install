#!/bin/bash
# ============================================================================
# 00_lib_state.sh — Vibe Coding Workspace lib v6.4
#
# LEÍRÁS: INFRA state kezelés: init/set/get/validate, infra_require, detect_run_mode
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
#  CSOPORTONKÉNT:
#
#  [HW] — Hardware, hw_detect() + 01a írja
#    HW_PROFILE        pl. "desktop-rtx"
#    HW_GPU_ARCH       pl. "blackwell"
#    HW_GPU_NAME       pl. "NVIDIA GeForce RTX 5090 (Blackwell SM_120)"
#    HW_CUDA_ARCH      pl. "120"
#    HW_VLLM_OK        "true" | "false"
#    HW_NVIDIA_PKG     pl. "nvidia-driver-570-open"
#    HW_IS_NOTEBOOK    "true" | "false"
#
#  [INST] — Installed versions, az adott szál írja telepítés után
#    INST_DRIVER_VER   pl. "570.211.01"       — 01a írja
#    INST_CUDA_VER     pl. "12.6"              — 01a írja (csak major.minor!)
#    INST_CUDNN_VER    pl. "9.20.0"            — 01a írja
#    INST_DOCKER_VER   pl. "29.3.1"            — 01a írja
#    INST_ZSH_VER      pl. "5.9"               — 01b írja
#    INST_OMZ_COMMIT   pl. "a3b1c2d"           — 01b írja (git commit hash)
#    INST_OLLAMA_VER   pl. "0.6.5"             — 02 írja
#    INST_VLLM_VER     pl. "0.5.0"             — 02 írja
#    INST_PYTHON_VER   pl. "3.12.9"            — 03 írja (pyenv által fordított)
#    INST_UV_VER       pl. "0.4.18"            — 03 írja (Astral uv verzió)
#    INST_TORCH_VER    pl. "2.6.0+cu126"       — 03 írja (PyTorch+CUDA index)
#
#  [FEAT] — Feature flags
#    PYTORCH_INDEX     pl. "cu126" | "cu128"   — 01a írja, PyTorch whl index
#    FEAT_GPU_ACCEL    "true" | "false"         — GPU gyorsítás elérhető-e
#    FEAT_DOCKER_GPU   "true" | "false"         — Docker GPU runtime él-e
#    FEAT_VLLM         "true" | "false"         — vLLM futtatható-e
#    FEAT_SHELL_ZSH    "true" | "false"         — 01b írja, Zsh az aktív shell
#    FEAT_TURBOQUANT   "true" | "false"         — 02 írja, TQ bináris elérhető-e
#    FEAT_OLLAMA_GPU   "true" | "false"         — 02 írja, Ollama GPU módban fut-e
#    TURBOQUANT_BUILD_MODE "cpu"|"gpu89"|"gpu120" — 02 írja, utolsó TQ build mód
#
#  [MOD] — Module completion flags, az adott szál írja
#    MOD_01A_DONE      "true" | ""  — 01a_system_foundation kész (REBOOT előtt)
#    MOD_01A_REBOOTED  "true" | ""  — REBOOT megtörtént (01b ellenőrzi nvidia-smi-val)
#    MOD_01B_DONE      "true" | ""  — 01b_post_reboot kész → 03 előfeltétel
#    MOD_02_DONE       "true" | ""  — 02_local_ai_stack kész (Ollama/vLLM)
#    MOD_03_DONE       "true" | ""  — Python/PyTorch kész → 02, 06 előfeltétel
#                                     (infra_require("03") ellenőrzi)
#
#  [REBOOT] — Reboot koordináció (00_master.sh olvassa)
#    REBOOT_NEEDED     "true" | "false"         — 01a állítja, master olvassa
#    REBOOT_REASON     pl. "NVIDIA driver"       — olvasható indoklás
#    REBOOT_BY_INFRA   pl. "01a"                 — melyik modul kérte
# ─────────────────────────────────────────────────────────────────────────────

# infra_state_init: az összes kulcs alapértékének beírása HA MÉG NINCS BENNE.
# Meglévő értékeket NEM írja felül — biztonságosan hívható többször.
infra_state_init() {
  mkdir -p "$(dirname "$INFRA_STATE_FILE")"

  # Segéd: csak akkor ír, ha a kulcs nem létezik
  local _init_key
  _init_key() {
    local k="$1" v="$2"
    grep -q "^${k}=" "$INFRA_STATE_FILE" 2>/dev/null \
      || printf '%s=%s\n' "$k" "$v" >> "$INFRA_STATE_FILE"
  }

  # [HW] — hw_detect() által ismertek
  _init_key "HW_PROFILE"     "${HW_PROFILE:-unknown}"
  _init_key "HW_GPU_ARCH"    "${HW_GPU_ARCH:-unknown}"
  _init_key "HW_GPU_NAME"    "${HW_GPU_NAME:-}"
  _init_key "HW_CUDA_ARCH"   "${HW_CUDA_ARCH:-}"
  _init_key "HW_VLLM_OK"     "${HW_VLLM_OK:-false}"
  _init_key "HW_NVIDIA_PKG"  "${HW_NVIDIA_PKG:-}"
  _init_key "HW_IS_NOTEBOOK" "${HW_IS_NOTEBOOK:-false}"

  # [INST] — telepítés után töltődnek fel, az adott szál írja
  _init_key "INST_DRIVER_VER" ""   # 01a írja
  _init_key "INST_CUDA_VER"   ""   # 01a írja
  _init_key "INST_CUDNN_VER"  ""   # 01a írja
  _init_key "INST_DOCKER_VER" ""   # 01a írja
  _init_key "INST_ZSH_VER"    ""   # 01b írja
  _init_key "INST_OMZ_COMMIT" ""   # 01b írja
  _init_key "INST_OLLAMA_VER" ""   # 02 írja
  _init_key "INST_VLLM_VER"   ""   # 02 írja
  _init_key "INST_PYTHON_VER" ""   # 03 írja (pyenv Python verzió pl. "3.12.9")
  _init_key "INST_UV_VER"     ""   # 03 írja (Astral uv verzió pl. "0.4.18")
  _init_key "INST_TORCH_VER"  ""   # 03 írja (PyTorch verzió pl. "2.6.0+cu126")

  # [FEAT] — alapértelmezés: amit a HW profilból tudunk
  _init_key "PYTORCH_INDEX"  "cu126"  # 01a pontosítja CUDA telepítés után
  _init_key "FEAT_GPU_ACCEL" "$(hw_has_nvidia && echo true || echo false)"
  _init_key "FEAT_DOCKER_GPU" "false"  # 01a állítja true-ra ha CTK kész
  _init_key "FEAT_VLLM"      "${HW_VLLM_OK:-false}"
  _init_key "FEAT_SHELL_ZSH" "false"  # 01b állítja true-ra ha zsh az aktív shell
  _init_key "FEAT_TURBOQUANT" "false" # 02 állítja true-ra ha TQ bináris kész
  _init_key "FEAT_OLLAMA_GPU" "false" # 02 állítja, Ollama GPU módban fut-e
  _init_key "TURBOQUANT_BUILD_MODE" "" # 02 írja: cpu|gpu89|gpu120

  # [MOD] — alapértelmezés: üres (nem kész)
  # v6.1: MOD_01_DONE/REBOOTED → MOD_01A_DONE/REBOOTED + MOD_01B_DONE
  # v6.2: MOD_02_DONE hozzáadva
  _init_key "MOD_01A_DONE"    ""   # 01a_system_foundation kész
  _init_key "MOD_01A_REBOOTED" ""  # REBOOT megtörtént (01b ellenőrzi)
  _init_key "MOD_01B_DONE"    ""   # 01b_post_reboot kész → 03 előfeltétel
  _init_key "MOD_02_DONE"     ""   # 02_local_ai_stack kész (Ollama/vLLM/TQ)
  _init_key "MOD_03_DONE"     ""   # Python/PyTorch kész → 02, 06 előfeltétel

  # [REBOOT] — reboot koordináció
  _init_key "REBOOT_NEEDED"   "false"
  _init_key "REBOOT_REASON"   ""
  _init_key "REBOOT_BY_INFRA" ""

  log "STATE" "State fájl inicializálva: $INFRA_STATE_FILE"
}

# infra_state_set: kulcs értékének beállítása/frissítése.
# Ha a kulcs már létezik, frissíti. Ha nem, hozzáadja.
infra_state_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "$INFRA_STATE_FILE")"
  if grep -q "^${key}=" "$INFRA_STATE_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$INFRA_STATE_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$INFRA_STATE_FILE"
  fi
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

# infra_state_show: a teljes state fájl tartalmának logba írása.
# Hibakereséshez és szál-szinkronizáció ellenőrzéséhez.
infra_state_show() {
  if [ ! -f "$INFRA_STATE_FILE" ]; then
    log "STATE" "State fájl nem létezik: $INFRA_STATE_FILE"
    return
  fi
  log "STATE" "━━━ INFRA state ($INFRA_STATE_FILE) ━━━"
  while IFS= read -r line; do
    [ -n "$line" ] && log "STATE" "  $line"
  done < "$INFRA_STATE_FILE"
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
  # [FIX v6.5.1] Gyökérok: 01a v6.11 már NEM írja FEAT_GPU_ACCEL a state-be.
  # A v6.5 validate() "false" default értéket adott hiányzó kulcsnak →
  # FEAT_VLLM=true + FEAT_GPU_ACCEL="" (hiányzó) → hamis inkonzisztencia →
  # FEAT_VLLM=false (helytelen override!)
  # Bizonyíték: install_02_20260412_172834.log 17:36:36 sor:
  #   [STATE] FEAT_VLLM=true → [WARN] inkonzisztencia → [STATE] FEAT_VLLM=false
  #
  # FIX: default "" (üres) → hiányzó kulcs ≠ explicit "false"
  # Kiegészítő ellenőrzés: HW_VLLM_OK=true (SM_70+ GPU) → FEAT_VLLM=true valid
  # Valódi inkonzisztencia CSAK: FEAT_GPU_ACCEL=false (beírva) ÉS HW_VLLM_OK=false
  local feat_gpu feat_vllm hw_vllm_ok
  feat_gpu=$(infra_state_get "FEAT_GPU_ACCEL" "")     # "" = nincs beírva (01a v6.11 nem írja)
  feat_vllm=$(infra_state_get "FEAT_VLLM" "false")
  hw_vllm_ok=$(infra_state_get "HW_VLLM_OK" "false")  # RTX 5090 = "true"

  # Feltétel: FEAT_VLLM=true de FEAT_GPU_ACCEL expliciten "false" beírva
  # ÉS a HW sem mondja GPU-képesnek (HW_VLLM_OK=false)
  # → Valódi inkonzisztencia (pl. CPU-only gépen maradt FEAT_VLLM=true)
  if [ "$feat_vllm" = "true" ] && [ "$feat_gpu" = "false" ] && [ "$hw_vllm_ok" = "false" ]; then
    log "WARN" "State inkonzisztencia: FEAT_VLLM=true de FEAT_GPU_ACCEL=false és HW_VLLM_OK=false"
    log "WARN" "  (Ha HW_VLLM_OK=true, a GPU vLLM-képes → FEAT_VLLM=true helyes)"
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
    if [ "${RUN_MODE:-install}" = "check" ]; then
      log "WARN" "Check mód: $done_key != true — ellenőrzés engedélyezve (nem blokkol)"
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

  # Check módban a mód változatlan marad — csak nézünk, nem döntünk
  if [ "${RUN_MODE:-install}" = "check" ]; then
    export RUN_MODE="check"
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
