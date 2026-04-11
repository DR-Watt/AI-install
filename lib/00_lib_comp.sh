#!/bin/bash
# ============================================================================
# 00_lib_comp.sh — Vibe Coding Workspace lib v6.5
#
# LEÍRÁS: Komponens ellenőrzők: version_ok, comp_check_*, comp_line
# BETÖLTÉS: source-olja a 00_lib.sh master loader
# NE futtasd közvetlenül!
#
# VÁLTOZTATÁSOK v6.5 (2026-04-11 logok alapján):
#   - comp_check_cuda(): CUDA 13.x dpkg fallback hozzáadva
#     Bug: csak cuda-toolkit-12-* mintát nézett → 13.x "missing"-ként jelent meg
#     Fix: 3-szintű keresés: nvcc → dpkg 13.x → dpkg 12.x
#   - comp_save_state(): V_ kulcs törlése ha status=missing
#     Bug: COMP_01A_V_NVIDIA_DRIVER=580.126.09 maradt missing státusz mellett
#     Fix: ha status=missing → infra_state_set V_="" (explicit üresítés)
#
# VÁLTOZTATÁSOK v6.4.2 (részletes COMP STATE log + comp_log_source):
#   - comp_load_state(): ok/missing/old/broken számok betöltés után
#   - comp_log_source(): felmérés forrásának logolása child scriptekhez
#
# VÁLTOZTATÁSOK v6.4.1 (comp_check_vscode PATH fix):
#   - comp_check_vscode(): explicit PATH="/usr/bin:/usr/local/bin:$PATH"
# ============================================================================

# SZEKCIÓ 7 — VERZIÓ KEZELÉS
# =============================================================================

version_ok() {
  local current="$1" minimum="$2"
  [ -z "$current" ] && return 1
  printf '%s\n%s\n' "$minimum" "$current" \
    | sort -V | head -1 | grep -qx "$minimum"
}

# =============================================================================
# SZEKCIÓ 8 — KOMPONENS ELLENŐRZŐ RENDSZER
# =============================================================================

declare -A COMP_STATUS
declare -A COMP_VER

check_component() {
  local name="$1" ver_cmd="$2" min_ver="${3:-}"
  local ver

  ver=$(eval "$ver_cmd" 2>/dev/null | grep -oP '\d+[\d.]*\d' | head -1)
  if [ -z "$ver" ]; then
    if eval "$ver_cmd" &>/dev/null 2>&1; then
      ver="ok"
    else
      COMP_STATUS["$name"]="missing"
      COMP_VER["$name"]=""
      return 1
    fi
  fi

  if [ -n "$min_ver" ] && [ "$ver" != "ok" ] && ! version_ok "$ver" "$min_ver"; then
    COMP_STATUS["$name"]="old"
    COMP_VER["$name"]="$ver"
    return 2
  fi

  COMP_STATUS["$name"]="ok"
  COMP_VER["$name"]="${ver}"
  return 0
}

# ── Dedikált komponens ellenőrzők ─────────────────────────────────────────────

comp_check_nvidia_driver() {
  local min="${1:-570.0}"
  local ver
  ver=$(nvidia-smi --query-gpu=driver_version \
        --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')

  if [ -n "$ver" ] && ! echo "$ver" | grep -qE '^[0-9][0-9.]+$'; then
    COMP_STATUS[nvidia_driver]="broken"
    COMP_VER[nvidia_driver]="(kernel modul nem fut — MOK enrollment szükséges?)"
    return 1
  fi

  [ -z "$ver" ] && {
    COMP_STATUS[nvidia_driver]="missing"
    COMP_VER[nvidia_driver]=""
    return 1
  }
  COMP_VER[nvidia_driver]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[nvidia_driver]="ok" \
    || COMP_STATUS[nvidia_driver]="old"
}

# comp_check_cuda: nvcc --version + dpkg fallback (12.x és 13.x)
# Forrás: CUDA Installation Guide Linux §11.2.2 Verify Installation
#
# v6.5 javítás: háromszintű keresés:
#   1. nvcc --version (legmegbízhatóbb, explicit CUDA PATH-szal)
#   2. dpkg cuda-toolkit-13-* (CUDA 13.x detektálás — korábban hiányzott!)
#   3. dpkg cuda-toolkit-12-* (CUDA 12.x fallback)
#
# MIÉRT kellett a 13.x dpkg ág?
#   Bug: 2026-04-11 log — driver 590 (CUDA 13.1 natív) után CUDA upgrade ajánlat
#   nem jelent meg, mert a comp_check_cuda "missing"-t adott 13.x esetén ha
#   nvcc nem volt PATH-ban, és csak 12-* dpkg-t nézett.
#
# FONTOS: nvidia-smi "CUDA Version" ≠ telepített toolkit verzió!
#   nvidia-smi: a driver max. CUDA API támogatása (pl. 13.1)
#   tényleges toolkit: nvcc vagy dpkg (pl. 12.6 vagy 13.1)
comp_check_cuda() {
  local min="${1:-12.4}"
  local ver

  # 1. Próba: nvcc explicit CUDA PATH-szal (legmegbízhatóbb)
  ver=$(PATH="/usr/local/cuda/bin:$PATH" nvcc --version 2>/dev/null \
        | grep -oP 'release \K[\d.]+' | head -1)

  # 2. Fallback: dpkg CUDA 13.x (driver 590+ esetén natív toolkit verzió)
  # FONTOS: a 13-* mintát nézni ELŐBB kell mint a 12-*-t, hogy a magasabb
  # verziót találjuk meg ha mindkettő telepítve van egyszerre.
  if [ -z "$ver" ]; then
    ver=$(dpkg -l 'cuda-toolkit-13-*' 2>/dev/null \
          | awk '/^ii/{print $3}' \
          | grep -oP '^\d+\.\d+' \
          | sort -V | tail -1)
  fi

  # 3. Fallback: dpkg CUDA 12.x
  if [ -z "$ver" ]; then
    ver=$(dpkg -l 'cuda-toolkit-12-*' 2>/dev/null \
          | awk '/^ii/{print $3}' \
          | grep -oP '^\d+\.\d+' \
          | sort -V | tail -1)
  fi

  [ -z "$ver" ] && {
    COMP_STATUS[cuda]="missing"
    COMP_VER[cuda]=""
    return 1
  }
  COMP_VER[cuda]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[cuda]="ok" \
    || COMP_STATUS[cuda]="old"
}

comp_check_cudnn() {
  local min="${1:-9.0}"
  local ver
  ver=$(dpkg -l 'libcudnn9-cuda-12' 2>/dev/null \
        | awk '/^ii/{print $3}' \
        | grep -oP '^\d+[\d.]+' | head -1)
  [ -z "$ver" ] && {
    COMP_STATUS[cudnn]="missing"
    COMP_VER[cudnn]=""
    return 1
  }
  COMP_VER[cudnn]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[cudnn]="ok" \
    || COMP_STATUS[cudnn]="old"
}

comp_check_docker() {
  local min="${1:-24.0}"
  local ver
  ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
  [ -z "$ver" ] && {
    COMP_STATUS[docker]="missing"
    COMP_VER[docker]=""
    return 1
  }
  COMP_VER[docker]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[docker]="ok" \
    || COMP_STATUS[docker]="old"
}

comp_check_nvidia_ctk() {
  local min="${1:-0.1}"
  local ver
  ver=$(nvidia-ctk --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  [ -z "$ver" ] && {
    COMP_STATUS[nvidia_ctk]="missing"
    COMP_VER[nvidia_ctk]=""
    return 1
  }
  COMP_VER[nvidia_ctk]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[nvidia_ctk]="ok" \
    || COMP_STATUS[nvidia_ctk]="old"
}

comp_check_zsh() {
  local min="${1:-5.8}"
  local ver
  ver=$(zsh --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  [ -z "$ver" ] && {
    COMP_STATUS[zsh]="missing"
    COMP_VER[zsh]=""
    return 1
  }
  COMP_VER[zsh]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[zsh]="ok" \
    || COMP_STATUS[zsh]="old"
}

comp_check_ohmyzsh() {
  local zsh_dir="${1:-$_REAL_HOME/.oh-my-zsh}"
  if [ ! -d "$zsh_dir" ]; then
    COMP_STATUS[ohmyzsh]="missing"
    COMP_VER[ohmyzsh]=""
    return 1
  fi
  local ver
  ver=$(git -C "$zsh_dir" log --oneline -1 2>/dev/null | cut -c1-7)
  COMP_VER[ohmyzsh]="${ver:-telepítve}"
  COMP_STATUS[ohmyzsh]="ok"
}

comp_check_python() {
  local ver_target="${1:-3.12.9}"
  local pyenv_root="${2:-$_REAL_HOME/.pyenv}"
  local pybin="$pyenv_root/versions/$ver_target/bin/python3"

  if [ ! -x "$pybin" ]; then
    COMP_STATUS[python]="missing"
    COMP_VER[python]=""
    return 1
  fi
  local ver
  ver=$("$pybin" --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  COMP_VER[python]="${ver:-$ver_target}"
  COMP_STATUS[python]="ok"
}

comp_check_uv() {
  local min="${1:-0.1}"
  local uv_bin="${2:-$_REAL_HOME/.local/bin/uv}"
  local ver

  ver=$("$uv_bin" --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  [ -z "$ver" ] && ver=$(uv --version 2>/dev/null | grep -oP '[\d.]+' | head -1)

  [ -z "$ver" ] && {
    COMP_STATUS[uv]="missing"
    COMP_VER[uv]=""
    return 1
  }
  COMP_VER[uv]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[uv]="ok" \
    || COMP_STATUS[uv]="old"
}

comp_check_nodejs() {
  local min="${1:-22.0}"
  local ver
  ver=$(node --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  [ -z "$ver" ] && {
    COMP_STATUS[nodejs]="missing"
    COMP_VER[nodejs]=""
    return 1
  }
  COMP_VER[nodejs]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[nodejs]="ok" \
    || COMP_STATUS[nodejs]="old"
}

comp_check_pwsh() {
  local min="${1:-7.0}"
  local ver
  ver=$(pwsh --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  [ -z "$ver" ] && {
    COMP_STATUS[pwsh]="missing"
    COMP_VER[pwsh]=""
    return 1
  }
  COMP_VER[pwsh]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[pwsh]="ok" \
    || COMP_STATUS[pwsh]="old"
}

comp_check_ollama() {
  local min="${1:-0.1}"
  local ver
  ver=$(ollama version 2>/dev/null | grep -oP '[\d.]+' | head -1)
  [ -z "$ver" ] && {
    COMP_STATUS[ollama]="missing"
    COMP_VER[ollama]=""
    return 1
  }
  COMP_VER[ollama]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[ollama]="ok" \
    || COMP_STATUS[ollama]="old"
}

comp_check_vllm() {
  local min="${1:-0.4}"
  local py="${2:-python3}"

  local ver
  ver=$("$py" -c "import vllm; print(vllm.__version__)" 2>/dev/null | grep -oP '[\d.]+' | head -1)

  [ -z "$ver" ] && {
    COMP_STATUS[vllm]="missing"
    COMP_VER[vllm]=""
    return 1
  }
  COMP_VER[vllm]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[vllm]="ok" \
    || COMP_STATUS[vllm]="old"
}

comp_check_torch() {
  local min="${1:-}"
  local py="${2:-python3}"

  local ver
  ver=$("$py" -c "import torch; print(torch.__version__)" 2>/dev/null \
        | grep -oP '[\d.]+' | head -1)

  if [ -z "$ver" ]; then
    COMP_STATUS[torch]="missing"
    COMP_VER[torch]=""
    return 1
  fi

  local cuda_avail
  cuda_avail=$("$py" -c "import torch; print(torch.cuda.is_available())" 2>/dev/null)
  log "COMP" "  torch: $ver | cuda.is_available()=$cuda_avail"

  COMP_VER[torch]="$ver (cuda=$cuda_avail)"

  if [ -n "$min" ]; then
    version_ok "$ver" "$min" \
      && COMP_STATUS[torch]="ok" \
      || COMP_STATUS[torch]="old"
  else
    COMP_STATUS[torch]="ok"
  fi
}

comp_check_vscode() {
  local min="${1:-1.85}"
  local real_user="${2:-${_REAL_USER:-$USER}}"
  local real_home="${3:-${_REAL_HOME:-$HOME}}"
  local ver="" code_bin=""

  for _cb in "/usr/bin/code" "/snap/bin/code" "/usr/local/bin/code"; do
    [ -x "$_cb" ] && { code_bin="$_cb"; break; }
  done

  if [ -n "$code_bin" ]; then
    ver=$(HOME="$real_home" sudo -u "$real_user" \
          "$code_bin" --version 2>/dev/null \
          | head -1 | grep -oP "[\d.]+")
    [ -z "$ver" ] && ver=$(dpkg -l code 2>/dev/null \
      | awk "/^ii/{print \$3}" | grep -oP "\d+\.\d+\.\d+" | head -1)
    [ -z "$ver" ] && ver=$(snap list code 2>/dev/null \
      | awk "NR>1 && \$1==\"code\"{print \$2}" | head -1)
    [ -z "$ver" ] && ver="installed"
  else
    if dpkg -l code 2>/dev/null | grep -q "^ii"; then
      ver=$(dpkg -l code 2>/dev/null \
        | awk "/^ii/{print \$3}" | grep -oP "\d+\.\d+\.\d+" | head -1)
      [ -z "$ver" ] && ver="installed"
    fi
  fi

  [ -z "$ver" ] && {
    COMP_STATUS[vscode]="missing"
    COMP_VER[vscode]=""
    return 1
  }
  COMP_VER[vscode]="$ver"
  if [ "$ver" = "installed" ]; then
    COMP_STATUS[vscode]="ok"
  else
    version_ok "$ver" "$min" \
      && COMP_STATUS[vscode]="ok" \
      || COMP_STATUS[vscode]="old"
  fi
}

# ── Megjelenítő segédek ───────────────────────────────────────────────────────

comp_line() {
  local name="$1" label="${2:-$1}" min="${3:-}"
  local min_txt
  [ -n "$min" ] && min_txt=" (min: $min)" || min_txt=""
  case "${COMP_STATUS[$name]:-missing}" in
    ok)      printf '  ✓  %-22s %s\n'       "$label" "${COMP_VER[$name]}" ;;
    old)     printf '  ⚠  %-22s %s%s\n'     "$label" "${COMP_VER[$name]}" "$min_txt" ;;
    missing) printf '  ✗  %-22s hiányzik\n' "$label" ;;
    broken)  printf '  ⚡  %-22s %s\n'      "$label" "${COMP_VER[$name]}" ;;
  esac
}

comp_summary() {
  local -n _names=$1
  local out=""
  for name in "${_names[@]}"; do
    out+="$(comp_line "$name")"$'\n'
  done
  echo "$out"
}

# =============================================================================
# SZEKCIÓ 8b — NVIDIA ÉS CUDA HELPER FÜGGVÉNYEK
# =============================================================================

nvidia_driver_purge() {
  local logfile="${1:-/dev/null}"

  local old_pkgs
  old_pkgs=$(dpkg -l 2>/dev/null \
    | grep -E "^(ii|iF|iU|rc)\s+(nvidia|libnvidia)" \
    | awk '{print $2}' | tr '\n' ' ')

  if [ -n "$old_pkgs" ]; then
    log "APT" "NVIDIA purge: $old_pkgs"
    DEBIAN_FRONTEND=noninteractive dpkg --purge --force-all $old_pkgs \
      >> "$logfile" 2>&1 || true
  fi

  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq \
    >> "$logfile" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get clean >> "$logfile" 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    >> "$logfile" 2>&1 || true
}

nvidia_mok_status() {
  local mok_cert="/var/lib/shim-signed/mok/MOK.der"
  [ ! -f "$mok_cert" ] && { echo "no_cert"; return; }

  local cn
  cn=$(openssl x509 -in "$mok_cert" -noout -subject 2>/dev/null \
       | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 || echo "DKMS")

  local enrolled_count
  enrolled_count=$(mokutil --list-enrolled 2>/dev/null \
                   | grep -i "CN=" | grep -ci "$cn" 2>/dev/null || echo 0)
  [ "${enrolled_count:-0}" -gt 0 ] && { echo "enrolled"; return; }

  local pending_count
  pending_count=$(mokutil --list-new 2>/dev/null \
                  | grep -c "Subject:" 2>/dev/null || echo 0)
  [ "${pending_count:-0}" -gt 0 ] && { echo "pending"; return; }

  echo "not_enrolled"
}

nvidia_mok_enroll() {
  local mok_cert="/var/lib/shim-signed/mok/MOK.der"
  [ ! -f "$mok_cert" ] && {
    log "WARN" "nvidia_mok_enroll: MOK.der hiányzik ($mok_cert)"
    return 2
  }

  local status
  status=$(nvidia_mok_status)
  log "INFO" "MOK állapot: $status"

  case "$status" in
    enrolled)
      log "OK" "MOK kulcs már enrolled az UEFI-ben — nincs teendő"
      infra_state_set "MOK_ENROLL_PENDING" "false"
      return 0
      ;;
    pending)
      local existing_pass
      existing_pass="$(infra_state_get "MOK_ENROLL_PASS" "")"
      log "OK" "MOK enrollment pending (korábbi futásból)"
      [ -n "$existing_pass" ] && \
        log "INFO" "MOK jelszó a state-ben: $existing_pass"
      return 0
      ;;
    not_enrolled)
      local pass
      pass="mok-$(openssl rand -hex 3 2>/dev/null || date +%s | tail -c 6)"
      printf '%s\n%s\n' "$pass" "$pass" | \
        mokutil --import "$mok_cert" >> "${LOGFILE_AI:-/dev/null}" 2>&1
      local ec=$?
      if [ $ec -eq 0 ]; then
        infra_state_set "MOK_ENROLL_PENDING" "true"
        infra_state_set "MOK_ENROLL_PASS"    "$pass"
        log "OK" "MOK enrollment bejegyezve — jelszó: $pass"
        return 0
      else
        log "FAIL" "mokutil --import sikertelen (exit $ec)"
        return 1
      fi
      ;;
    no_cert)
      log "WARN" "MOK.der nem létezik — dkms autoinstall szükséges"
      return 2
      ;;
  esac
}

# cuda_best_available: legjobb elérhető CUDA toolkit verziót adja vissza
# Forrás: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/
cuda_best_available() {
  for _cv in "13-2" "13-1" "13-0" "12-8" "12-6"; do
    apt-cache show "cuda-toolkit-${_cv}" &>/dev/null && \
      { echo "${_cv/-/.}"; return 0; }
  done
  echo ""; return 1
}

# cuda_pytorch_index: CUDA verziószámból PyTorch cu-index string
# Forrás: https://docs.pytorch.org/docs/stable/index.html
#
# Leképezés (2026-04-11 aktuális PyTorch wheel elérhetőség alapján):
#   CUDA 13.x → cu128  (nincs cu13x wheel, cu128 forward-compatible)
#   CUDA 12.8 → cu128
#   CUDA 12.6 → cu126
#   CUDA 12.4 → cu124
#   CUDA 12.x (x<4) → cu12x (régi, nem ajánlott)
cuda_pytorch_index() {
  local ver="${1:-12.6}"
  local major minor
  major=$(echo "$ver" | cut -d. -f1)
  minor=$(echo "$ver" | cut -d. -f2)

  if [ "${major:-0}" -ge 13 ] 2>/dev/null; then
    # CUDA 13.x — nincs cu13x PyTorch wheel, cu128 a legjobb elérhető
    echo "cu128"
  elif [ "${major:-0}" -eq 12 ] && [ "${minor:-0}" -ge 8 ] 2>/dev/null; then
    # CUDA 12.8+ → cu128
    echo "cu128"
  else
    # CUDA 12.7 és alatta: cu126, cu124, cu121...
    echo "cu$(echo "$ver" | cut -d. -f1-2 | tr -d .)"
  fi
}

# =============================================================================
# SZEKCIÓ 8c — COMP STATE: MENTETT CHECK EREDMÉNYEK KEZELÉSE
# =============================================================================

# comp_save_state: COMP_STATUS[] és COMP_VER[] tömbök mentése az infra state-be.
# Paraméterek: $1=infra_num (pl. "06", "01a")
#
# v6.5 javítás: V_ kulcs explicit törlése ha status=missing
# Bug: COMP_01A_V_NVIDIA_DRIVER=580.126.09 maradt a state-ben missing után
# Fix: ha COMP_STATUS["x"]="missing" → infra_state_set V_X ""
#      Ez biztosítja hogy a következő comp_load_state ne töltse be a stale verziót
comp_save_state() {
  local infra_num="$1"
  local pfx="COMP_$(printf '%s' "$infra_num" | tr '[:lower:]' '[:upper:]')"

  infra_state_set "${pfx}_TS" "$(date '+%Y-%m-%dT%H:%M:%S')"

  local comp_name key
  for comp_name in "${!COMP_STATUS[@]}"; do
    key="$(printf '%s' "$comp_name" | tr '[:lower:]' '[:upper:]')"
    infra_state_set "${pfx}_S_${key}" "${COMP_STATUS[$comp_name]:-missing}"

    # V_ kulcs kezelése:
    #   - missing státusz → explicit üresítés (stale verzió törlése)
    #   - van verzió → mentés
    #   - nincs verzió és nem missing → nem írjuk (marad a korábbi)
    if [ "${COMP_STATUS[$comp_name]:-missing}" = "missing" ]; then
      # Explicit üresítés: stale verzió (pl. "580.126.09") ne maradjon missing mellett
      infra_state_set "${pfx}_V_${key}" ""
    elif [ -n "${COMP_VER[$comp_name]:-}" ]; then
      infra_state_set "${pfx}_V_${key}" "${COMP_VER[$comp_name]}"
    fi
  done

  log "STATE" "Komponens állapot mentve: ${pfx}_* (${#COMP_STATUS[@]} komponens)"
}

comp_load_state() {
  local infra_num="$1"
  local pfx="COMP_$(printf '%s' "$infra_num" | tr '[:lower:]' '[:upper:]')"

  [ ! -f "$INFRA_STATE_FILE" ] && return 1

  local ts
  ts=$(infra_state_get "${pfx}_TS" "")
  [ -z "$ts" ] && return 1

  local line key val comp_key comp_name
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue

    key="${line%%=*}"
    val="${line#*=}"

    if [[ "$key" == "${pfx}_S_"* ]]; then
      comp_key="${key#${pfx}_S_}"
      comp_name="$(printf '%s' "$comp_key" | tr '[:upper:]' '[:lower:]')"
      COMP_STATUS["$comp_name"]="$val"
    elif [[ "$key" == "${pfx}_V_"* ]]; then
      comp_key="${key#${pfx}_V_}"
      comp_name="$(printf '%s' "$comp_key" | tr '[:upper:]' '[:lower:]')"
      COMP_VER["$comp_name"]="$val"
    fi
  done < "$INFRA_STATE_FILE"

  local _ok=0 _miss=0 _old=0 _brk=0
  for _k in "${!COMP_STATUS[@]}"; do
    case "${COMP_STATUS[$_k]}" in
      ok)      ((_ok++))  ;;
      missing) ((_miss++));;
      old)     ((_old++)) ;;
      broken)  ((_brk++)) ;;
    esac
  done
  local _age
  _age=$(comp_state_age_hours "$infra_num")
  log "COMP" "Mentett állapot betöltve: INFRA ${infra_num} — check: ${ts} (${_age}h ezelőtt)"
  log "COMP" "  Összesítés: ✓ ok=${_ok}  ✗ missing=${_miss}  ⚠ old=${_old}$([ $_brk -gt 0 ] && echo "  ⚡ broken=${_brk}" || echo "")"
  return 0
}

comp_state_exists() {
  local infra_num="$1"
  local pfx="COMP_$(printf '%s' "$infra_num" | tr '[:lower:]' '[:upper:]')"
  local ts
  ts=$(infra_state_get "${pfx}_TS" "")
  [ -n "$ts" ]
}

comp_state_age_hours() {
  local infra_num="$1"
  local pfx="COMP_$(printf '%s' "$infra_num" | tr '[:lower:]' '[:upper:]')"
  local ts
  ts=$(infra_state_get "${pfx}_TS" "")
  [ -z "$ts" ] && { echo "?"; return; }

  local then now
  then=$(date -d "$ts" +%s 2>/dev/null || echo "0")
  now=$(date +%s)
  echo $(( (now - then) / 3600 ))
}

comp_log_source() {
  local infra_num="$1"
  if [ "${COMP_USE_CACHED:-false}" = "true" ]; then
    if comp_state_exists "$infra_num"; then
      local _age
      _age=$(comp_state_age_hours "$infra_num")
      log "COMP" "━━━ Komponens állapot: mentett check betöltve (${_age}h ezelőtt) ━━━"
    else
      log "COMP" "━━━ Komponens állapot: mentett nem elérhető — friss felmérés ━━━"
    fi
  else
    if [ "${RUN_MODE:-install}" = "check" ]; then
      log "COMP" "━━━ Friss komponens felmérés (check mód — eredmény mentésre kerül) ━━━"
    else
      log "COMP" "━━━ Friss komponens felmérés (nem kérte a felhasználó: cache=off) ━━━"
    fi
  fi
}

comp_state_master_summary() {
  local infra_ids=("$@")
  local count=0
  local out=""
  local id pfx ts hours
  for id in "${infra_ids[@]}"; do
    pfx="COMP_$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')"
    ts=$(infra_state_get "${pfx}_TS" "")
    [ -z "$ts" ] && continue
    hours=$(comp_state_age_hours "$id")
    out+="    INFRA ${id}: ${INFRA_NAME[$id]:-?} (${ts}, ${hours}h ezelőtt)\n"
    ((count++))
  done
  echo "$count"
  printf '%b' "$out"
}
