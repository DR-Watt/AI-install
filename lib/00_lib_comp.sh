#!/bin/bash
# ============================================================================
# 00_lib_comp.sh — Vibe Coding Workspace lib v6.4
#
# LEÍRÁS: Komponens ellenőrzők: version_ok, comp_check_*, comp_line
# BETÖLTÉS: source-olja a 00_lib.sh master loader
# NE futtasd közvetlenül!
# ============================================================================

# SZEKCIÓ 7 — VERZIÓ KEZELÉS
# =============================================================================

# version_ok: két verziószám összehasonlítása (szemantikus).
# Visszatér: 0 ha current >= minimum, 1 ha current < minimum
# Példa: version_ok "12.6" "12.4" → 0 (ok)
version_ok() {
  local current="$1" minimum="$2"
  [ -z "$current" ] && return 1
  # sort -V: Version sort, az alacsonyabb jön először
  printf '%s\n%s\n' "$minimum" "$current" \
    | sort -V | head -1 | grep -qx "$minimum"
}

# =============================================================================
# SZEKCIÓ 8 — KOMPONENS ELLENŐRZŐ RENDSZER
# =============================================================================

# A COMP_STATUS és COMP_VER tömbök tárolják az ellenőrzési eredményeket.
# Értékek: "ok" | "old" | "missing"
declare -A COMP_STATUS
declare -A COMP_VER

# check_component: generikus ellenőrző (ha nincs dedikált függvény).
# Paraméterek: $1=name, $2=version_command, $3=min_ver (opcionális)
# A version_command-nak verziószámot kell kiírnia stdoutra.
check_component() {
  local name="$1" ver_cmd="$2" min_ver="${3:-}"
  local ver

  ver=$(eval "$ver_cmd" 2>/dev/null | grep -oP '\d+[\d.]*\d' | head -1)
  if [ -z "$ver" ]; then
    if eval "$ver_cmd" &>/dev/null 2>&1; then
      ver="ok"  # parancs fut de nem ír verziót (pl. [ -d /path ])
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
# Minden függvény az adott szoftver HIVATALOS lekérdezési módszerét használja.
# Forrás: az adott eszköz dokumentációja (lásd dokumentációs_prompt.md)

# comp_check_nvidia_driver: NVIDIA Management Library (nvidia-smi) alapján.
# Forrás: nvidia-smi --help-query-gpu dokumentáció
comp_check_nvidia_driver() {
  local min="${1:-570.0}"
  local ver
  ver=$(nvidia-smi --query-gpu=driver_version \
        --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')

  # ── v6.4 javítás: broken állapot detektálás ──────────────────────────────
  # Ha a driver csomag telepítve van, de a kernel modul NEM töltődött be
  # (pl. Secure Boot + nem enrollált MOK kulcs), az nvidia-smi STDOUT-ra
  # írja: "No devices were found" → tr -d után: "Nodeviceswerefound"
  # Ez lexikálisan > "570.0" a sort -V alapján → version_ok FALSE POSITIVE!
  # Megoldás: version string validálás — csak [0-9.] karakterek elfogadottak.
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

# comp_check_cuda: nvcc --version (CUDA Compiler Driver) + dpkg fallback.
# Forrás: CUDA Installation Guide Linux §11.2.2 Verify Installation
# FONTOS: nvidia-smi "CUDA Version: X.Y" ≠ telepített CUDA toolkit verzió!
#   - nvidia-smi CUDA verzió: a driver által MAXIMÁLISAN támogatott CUDA API
#   - Tényleges telepített toolkit: nvcc --version / dpkg cuda-toolkit-12-*
#   Példa: nvidia-smi mutat 13.0, de telepített toolkit: 12.6.3-1
# Megjegyzés: sudo kontextusban nvcc nem mindig elérhető PATH-ban
#   → explicit /usr/local/cuda/bin PATH, dpkg fallback ha nem válaszol
comp_check_cuda() {
  local min="${1:-12.4}"
  local ver

  # 1. Próba: nvcc explicit CUDA PATH-szal
  ver=$(PATH="/usr/local/cuda/bin:$PATH" nvcc --version 2>/dev/null \
        | grep -oP 'release \K[\d.]+' | head -1)

  # 2. Fallback: dpkg alapján (sudo kontextusban megbízhatóbb)
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

# comp_check_cudnn: dpkg alapján (cuDNN nincs önálló CLI eszköze).
# Forrás: NVIDIA cuDNN dokumentáció — dpkg az egyetlen hivatalos módszer
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

# comp_check_docker: docker version Server.Version mezőből.
# Forrás: Docker Engine dokumentáció — docker version CLI
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

# comp_check_nvidia_ctk: NVIDIA Container Toolkit saját CLI-je.
# Forrás: NVIDIA Container Toolkit dokumentáció — nvidia-ctk version
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

# comp_check_zsh: Zsh verzió ellenőrzése zsh --version alapján.
# Forrás: https://zsh.sourceforge.io/Doc/ — zsh --version flag
# Megjegyzés: Ubuntu 24.04 LTS alap repóban 5.9 érhető el.
# A 01b_post_reboot.sh ezt hívja a shell állapot felméréséhez.
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

# comp_check_ohmyzsh: könyvtár létezés + git commit hash.
# (Oh My Zsh-nak nincs saját verzió CLI-je — a git log az egyetlen forrás)
# Forrás: https://github.com/ohmyzsh/ohmyzsh/wiki
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

# comp_check_python: pyenv versions könyvtár + python --version.
# Forrás: Python dokumentáció — python3 --version flag
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

# comp_check_uv: uv --version (Astral uv hivatalos CLI).
# Forrás: https://docs.astral.sh/uv/
comp_check_uv() {
  local min="${1:-0.1}"
  local uv_bin="${2:-$_REAL_HOME/.local/bin/uv}"
  local ver

  # Explicit path első, majd PATH-ban keresés
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

# comp_check_nodejs: node --version (Node.js Foundation).
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

# comp_check_pwsh: pwsh --version (Microsoft PowerShell Core).
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

# comp_check_ollama: ollama version (Ollama Inc. CLI).
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

# comp_check_vllm: vLLM importálhatóság ellenőrzése Python import alapján.
# Forrás: https://docs.vllm.ai/en/latest/ — vLLM-nek nincs saját version CLI-je.
# A vllm.__version__ az egyetlen megbízható forrás, dpkg fallback nincs.
# Paraméterek: $1=min_ver (opcionális, pl. "0.4"), $2=python bináris elérési út
comp_check_vllm() {
  local min="${1:-0.4}"
  local py="${2:-python3}"   # caller átadhatja a venv python-ját

  # Elsődleges ellenőrzés: Python import + __version__ attribútum
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

# comp_check_torch: PyTorch telepítettség és CUDA elérhetőség ellenőrzése.
# Forrás: https://docs.pytorch.org/docs/stable/index.html
#   torch.__version__: mindig elérhető ha a csomag telepítve van.
#   torch.cuda.is_available(): REBOOT ELŐTT False lehet (NVIDIA driver nem aktív)!
#     Ez NEM jelent hibát — csak a kernel modul betöltési sorrendjének következménye.
#   torch.cuda.get_device_name(): GPU neve ha CUDA elérhető.
# Paraméterek: $1=min_ver (opcionális, pl. "2.0"), $2=python bináris elérési út
# Visszatér: 0=ok, 1=missing, 2=old
comp_check_torch() {
  local min="${1:-}"           # min_ver opcionális — PyTorch-nak nincs kötelező minimum
  local py="${2:-python3}"    # caller átadja a venv python-ját

  # PyTorch verzió lekérés import alapján (nincs CLI-je)
  local ver
  ver=$("$py" -c "import torch; print(torch.__version__)" 2>/dev/null \
        | grep -oP '[\d.]+' | head -1)

  if [ -z "$ver" ]; then
    COMP_STATUS[torch]="missing"
    COMP_VER[torch]=""
    return 1
  fi

  # CUDA elérhetőség — tájékoztató (nem hiba ha False, REBOOT előtt normális!)
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

# comp_check_vscode: code --version (Microsoft VS Code).
comp_check_vscode() {
  local min="${1:-1.85}"
  local ver
  ver=$(code --version 2>/dev/null | head -1 | grep -oP '[\d.]+')
  [ -z "$ver" ] && {
    COMP_STATUS[vscode]="missing"
    COMP_VER[vscode]=""
    return 1
  }
  COMP_VER[vscode]="$ver"
  version_ok "$ver" "$min" \
    && COMP_STATUS[vscode]="ok" \
    || COMP_STATUS[vscode]="old"
}

# ── Megjelenítő segédek ───────────────────────────────────────────────────────

# comp_line: egy sor státusz szöveg ✓/✗/⚠ szimbólumokkal.
# Paraméterek: $1=name (COMP_STATUS[] kulcs), $2=label, $3=min_ver (opcionális)
comp_line() {
  local name="$1" label="${2:-$1}" min="${3:-}"
  local min_txt
  [ -n "$min" ] && min_txt=" (min: $min)" || min_txt=""
  case "${COMP_STATUS[$name]:-missing}" in
    ok)      printf '  ✓  %-22s %s\n'       "$label" "${COMP_VER[$name]}" ;;
    old)     printf '  ⚠  %-22s %s%s\n'     "$label" "${COMP_VER[$name]}" "$min_txt" ;;
    missing) printf '  ✗  %-22s hiányzik\n' "$label" ;;
    broken)  printf '  ⚡  %-22s %s\n' "$label" "${COMP_VER[$name]}" ;;
  esac
}

# comp_summary: több comp_line egymás után, tömbből.
comp_summary() {
  local -n _names=$1
  local out=""
  for name in "${_names[@]}"; do
    out+="$(comp_line "$name")"$'\n'
  done
  echo "$out"
}

# =============================================================================
# SZEKCIÓ 8b — NVIDIA ÉS CUDA HELPER FÜGGVÉNYEK (v6.5)
# =============================================================================
# Ezek a függvények az 01a_system_foundation.sh-ból kerültek ki a libbe,
# hogy más szálak (01b, 02, 03) is használhassák, és a 01a kód olvashatóbb
# legyen (funkcióhívások inline logika helyett).

# nvidia_driver_purge: minden NVIDIA csomag tiszta eltávolítása
# ─────────────────────────────────────────────────────────────
# DEBIAN_FRONTEND=noninteractive szükséges MINDEN dpkg/apt híváshoz.
# Nélküle debconf Dialog frontend hibát dob ("screen ≥13 lines" hiba).
# Paraméterek: $1=logfile (opcionális, alapértelmezett: /dev/null)
nvidia_driver_purge() {
  local logfile="${1:-/dev/null}"

  # ii=telepítve, iF=félbe, iU=csomagolás hibás, rc=eltávolított de config maradt
  local old_pkgs
  old_pkgs=$(dpkg -l 2>/dev/null \
    | grep -E "^(ii|iF|iU|rc)\s+(nvidia|libnvidia)" \
    | awk '{print $2}' | tr '\n' ' ')

  if [ -n "$old_pkgs" ]; then
    log "APT" "NVIDIA purge: $old_pkgs"
    # DEBIAN_FRONTEND=noninteractive: debconf ne próbáljon Dialog ablakot nyitni
    DEBIAN_FRONTEND=noninteractive dpkg --purge --force-all $old_pkgs \
      >> "$logfile" 2>&1 || true
  fi

  # Árva csomagok eltávolítása (pl. nvidia-firmware-570 "no longer required")
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq \
    >> "$logfile" 2>&1 || true

  # APT cache tisztítása
  DEBIAN_FRONTEND=noninteractive apt-get clean >> "$logfile" 2>&1

  # Félbeszakadt dpkg állapot javítása
  DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y -qq \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    >> "$logfile" 2>&1 || true
}

# nvidia_mok_status: MOK enrollment állapot meghatározása
# ────────────────────────────────────────────────────────
# Output (echo): "enrolled" | "pending" | "not_enrolled" | "no_cert"
# Forrás: mokutil man page — mokutil --list-enrolled, --list-new
nvidia_mok_status() {
  local mok_cert="/var/lib/shim-signed/mok/MOK.der"
  [ ! -f "$mok_cert" ] && { echo "no_cert"; return; }

  # A MOK.der tanúsítványból kinyerjük a CN-t (Common Name)
  # Ez az azonosítója, amit az UEFI megjelenít enrollment/listázáskor
  local cn
  cn=$(openssl x509 -in "$mok_cert" -noout -subject 2>/dev/null \
       | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 || echo "DKMS")

  # Enrolled: az UEFI firmware már ismeri és elfogadja ezt a kulcsot
  local enrolled_count
  enrolled_count=$(mokutil --list-enrolled 2>/dev/null \
                   | grep -i "CN=" | grep -ci "$cn" 2>/dev/null || echo 0)
  [ "${enrolled_count:-0}" -gt 0 ] && { echo "enrolled"; return; }

  # Pending: mokutil --import már lefutott, reboot után az UEFI megkérdezi
  local pending_count
  pending_count=$(mokutil --list-new 2>/dev/null \
                  | grep -c "Subject:" 2>/dev/null || echo 0)
  [ "${pending_count:-0}" -gt 0 ] && { echo "pending"; return; }

  echo "not_enrolled"
}

# nvidia_mok_enroll: MOK enrollment végrehajtása ha szükséges
# ────────────────────────────────────────────────────────────
# Visszatér: 0=sikeres vagy már enrolled/pending, 1=hiba, 2=nincs MOK.der
# Mellékhatás: MOK_ENROLL_PASS és MOK_ENROLL_PENDING infra state-be kerül
# Megjegyzés:
#   - Ha enrolled: semmi teendő, state MOK_ENROLL_PENDING=false
#   - Ha pending: korábban már bejegyezve, jelszó state-ből olvasható
#   - Ha not_enrolled: véletlenszerű jelszóval importál, state-be ment
#   - Ha no_cert: DKMS nem hozta létre a kulcsot, dkms autoinstall szükséges
nvidia_mok_enroll() {
  local mok_cert="/var/lib/shim-signed/mok/MOK.der"
  [ ! -f "$mok_cert" ] && {
    log "WARN" "nvidia_mok_enroll: MOK.der hiányzik ($mok_cert)"
    return 2
  }

  local status
  status=$(nvidia_mok_status)
  log "INFO" "MOK állapot: $status (CN: $(openssl x509 -in "$mok_cert" -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 || echo '?'))"

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
      # Véletlenszerű 6 hex karakteres jelszó
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
# ─────────────────────────────────────────────────────────────────────
# Output (echo): "13.2" | "13.1" | "13.0" | "12.8" | "12.6" | ""
# Prioritási lánc az NVIDIA CUDA repo tartalma alapján (ubuntu2404/x86_64):
#   13.2: 2026-03-16 | 13.1: 2026-01 | 13.0: 2025-11
#   12.8: első SM_120 natív | 12.6: Ada/Ampere stabil LTS
# Forrás: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/
cuda_best_available() {
  for _cv in "13-2" "13-1" "13-0" "12-8" "12-6"; do
    apt-cache show "cuda-toolkit-${_cv}" &>/dev/null && \
      { echo "${_cv/-/.}"; return 0; }
  done
  echo ""; return 1
}

# cuda_pytorch_index: CUDA verziószámból PyTorch cu-index string
# ──────────────────────────────────────────────────────────────
# Példa: "12.6"→"cu126", "12.8"→"cu128", "13.0"→"cu128", "13.2"→"cu128"
# Megjegyzés: CUDA 13.x esetén cu128-at adunk vissza, mert 2026-04-ban
# még nincs cu13x PyTorch wheel — a CUDA 13 ABI backward-kompatibilis cu128-cal.
cuda_pytorch_index() {
  local ver="${1:-12.6}"
  local major
  major=$(echo "$ver" | cut -d. -f1)
  if [ "${major:-0}" -ge 13 ] 2>/dev/null; then
    echo "cu128"
  else
    echo "cu$(echo "$ver" | cut -d. -f1-2 | tr -d .)"
  fi
}
# =============================================================================
