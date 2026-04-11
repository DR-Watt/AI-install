#!/bin/bash
# ============================================================================
# 00_lib_comp.sh — Vibe Coding Workspace lib v6.4
#
# LEÍRÁS: Komponens ellenőrzők: version_ok, comp_check_*, comp_line
# BETÖLTÉS: source-olja a 00_lib.sh master loader
# NE futtasd közvetlenül!
#
# VÁLTOZTATÁSOK v6.4.2 (részletes COMP STATE log + comp_log_source):
#   - comp_load_state(): ok/missing/old/broken számok betöltés után
#   - comp_log_source(): felmérés forrásának logolása child scriptekhez
#
# VÁLTOZTATÁSOK v6.4.1 (comp_check_vscode PATH fix):
#   - comp_check_vscode(): explicit PATH="/usr/bin:/usr/local/bin:$PATH"
#     Tünet: sudo alatt root PATH nem tartalmazza /usr/bin-t → code "missing"
#     annak ellenére, hogy a VS Code telepítve van (/usr/bin/code)
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

# comp_check_vscode: VS Code telepítettség + verzió ellenőrzés.
# Forrás: dpkg -l code | snap list code | fájl alapú detektálás
#
# PROBLÉMA: sudo/root kontextusban "code" nem futtatható megbízhatóan:
#   - deb: /usr/bin/code → Electron wrapper, DBUS/display session nélkül kilép
#   - snap: /snap/bin/code → root PATH-ban nincs /snap/bin
#   - dpkg -l code: csak deb csomagot talál, snap-et NEM
#
# MEGOLDÁS: háromszintű ellenőrzés:
#   1. Fájl alapú detektálás (/usr/bin/code, /snap/bin/code) — sudo-safe
#   2. Verzió lekérés user kontextusban (sudo -u real_user) — deb + snap esetén is
#   3. dpkg / snap verzió fallback
#
# Paraméterek: $1=min_ver, $2=real_user (opcionális), $3=real_home (opcionális)
comp_check_vscode() {
  local min="${1:-1.85}"
  local real_user="${2:-${_REAL_USER:-$USER}}"
  local real_home="${3:-${_REAL_HOME:-$HOME}}"
  local ver="" code_bin=""

  # 1. Fájl alapú detektálás — melyik útvonalon van a code bináris?
  for _cb in "/usr/bin/code" "/snap/bin/code" "/usr/local/bin/code"; do
    [ -x "$_cb" ] && { code_bin="$_cb"; break; }
  done

  if [ -n "$code_bin" ]; then
    # 2. Verzió lekérés user kontextusban — az Electron wrapper user session-nel fut
    ver=$(HOME="$real_home" sudo -u "$real_user"           "$code_bin" --version 2>/dev/null           | head -1 | grep -oP "[\d.]+")

    # 3. dpkg fallback deb csomagnál
    [ -z "$ver" ] && ver=$(dpkg -l code 2>/dev/null           | awk "/^ii/{print \$3}"           | grep -oP "\d+\.\d+\.\d+" | head -1)

    # 4. snap fallback
    [ -z "$ver" ] && ver=$(snap list code 2>/dev/null           | awk "NR>1 && \$1=="code"{print \$2}" | head -1)

    # Telepítve van de verziót nem sikerült kinyerni
    [ -z "$ver" ] && ver="installed"
  else
    # Fájl nem található → dpkg utolsó esély
    if dpkg -l code 2>/dev/null | grep -q "^ii"; then
      ver=$(dpkg -l code 2>/dev/null             | awk "/^ii/{print \$3}"             | grep -oP "\d+\.\d+\.\d+" | head -1)
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
    version_ok "$ver" "$min"       && COMP_STATUS[vscode]="ok"       || COMP_STATUS[vscode]="old"
  fi
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

# nvidia_mok_enroll: MOK enrollment végrehajtása ha szükséges
# ────────────────────────────────────────────────────────────
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

# =============================================================================
# SZEKCIÓ 8c — COMP STATE: MENTETT CHECK EREDMÉNYEK KEZELÉSE
# =============================================================================
# CÉLJA: A komponens ellenőrzés eredményét elmenti az infra state fájlba,
#   hogy a 00_master.sh a következő indításnál felajánlhassa a felhasználását.
#   Így nem kell minden egyes telepítési session elején újra végigfutni az
#   összes comp_check_* hívást — elég egyszer lefuttatni check módban.
#
# STATE KULCSOK (példa INFRA 06-ra):
#   COMP_06_TS=2026-04-10T16:30:04    — mikor futott le a check
#   COMP_06_S_VSCODE=ok               — státusz (ok|old|missing|broken)
#   COMP_06_V_VSCODE=1.96.0           — verzió (ha van)
#   COMP_06_S_CURSOR=missing
#   COMP_06_S_CONTINUE_DEV=ok         — underscore megtartva
#   COMP_06_V_CONTINUE_DEV=0.9.210
#
# KONVENCIÓ:
#   - Kulcs prefix: COMP_<INFRA_NUM_UPPER>_  pl. "06" → "COMP_06_"
#   - S_ prefix: státusz (COMP_STATUS[])
#   - V_ prefix: verzió  (COMP_VER[])
#   - TS: timestamp (ISO 8601)
#   - Komponens nevek: lowercase → UPPER a mentéskor, UPPER → lowercase a betöltéskor
# =============================================================================

# comp_save_state: COMP_STATUS[] és COMP_VER[] tömbök mentése az infra state-be.
# Paraméterek: $1=infra_num (pl. "06", "01a")
# Megjegyzés: infra_state_set()-et használja → atomikus sor-csere/hozzáadás
comp_save_state() {
  local infra_num="$1"
  # Kulcs prefix: uppercase, pl. "06" → "COMP_06", "01a" → "COMP_01A"
  local pfx="COMP_$(printf '%s' "$infra_num" | tr '[:lower:]' '[:upper:]')"

  # Timestamp: ISO 8601 másodpercig
  infra_state_set "${pfx}_TS" "$(date '+%Y-%m-%dT%H:%M:%S')"

  # Minden COMP_STATUS[] bejegyzés mentése S_ prefixszel
  local comp_name key
  for comp_name in "${!COMP_STATUS[@]}"; do
    # Komponens név → uppercase kulcs: "continue_dev" → "CONTINUE_DEV"
    key="$(printf '%s' "$comp_name" | tr '[:lower:]' '[:upper:]')"
    infra_state_set "${pfx}_S_${key}" "${COMP_STATUS[$comp_name]:-missing}"
    # Verzió mentése V_ prefixszel (ha van)
    if [ -n "${COMP_VER[$comp_name]:-}" ]; then
      infra_state_set "${pfx}_V_${key}" "${COMP_VER[$comp_name]}"
    fi
  done

  log "STATE" "Komponens állapot mentve: ${pfx}_* (${#COMP_STATUS[@]} komponens)"
}

# comp_load_state: mentett COMP state beolvasása COMP_STATUS[] és COMP_VER[]-be.
# Paraméterek: $1=infra_num
# Visszatér: 0 ha sikeresen betöltött, 1 ha nincs mentett state
comp_load_state() {
  local infra_num="$1"
  local pfx="COMP_$(printf '%s' "$infra_num" | tr '[:lower:]' '[:upper:]')"

  [ ! -f "$INFRA_STATE_FILE" ] && return 1

  # Timestamp ellenőrzés — ha nincs, nincs mentett state
  local ts
  ts=$(infra_state_get "${pfx}_TS" "")
  [ -z "$ts" ] && return 1

  # Beolvasás: minden sor ami a megfelelő prefix-szel kezdődik
  local line key val comp_key comp_name
  while IFS= read -r line; do
    # Üres sor vagy komment kihagyása
    [[ -z "$line" || "$line" == \#* ]] && continue

    key="${line%%=*}"     # kulcs: az első = előtt
    val="${line#*=}"      # érték: az első = után (többszörös = esetén is helyes)

    if [[ "$key" == "${pfx}_S_"* ]]; then
      # Státusz kulcs: COMP_06_S_CONTINUE_DEV → comp_name="continue_dev"
      comp_key="${key#${pfx}_S_}"
      comp_name="$(printf '%s' "$comp_key" | tr '[:upper:]' '[:lower:]')"
      COMP_STATUS["$comp_name"]="$val"

    elif [[ "$key" == "${pfx}_V_"* ]]; then
      # Verzió kulcs: COMP_06_V_VSCODE → comp_name="vscode"
      comp_key="${key#${pfx}_V_}"
      comp_name="$(printf '%s' "$comp_key" | tr '[:upper:]' '[:lower:]')"
      COMP_VER["$comp_name"]="$val"
    fi
  done < "$INFRA_STATE_FILE"

  # Összesítés: hány komponens töltődött be és milyen státuszban
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
  log "COMP" "  Összesítés: ✓ ok=${_ok}  ✗ missing=${_miss}  ⚠ old=${_old}$([ $_brk -gt 0 ] && echo \"  ⚡ broken=${_brk}\" || echo \"\")"
  return 0
}

# comp_state_exists: van-e mentett check eredmény az adott INFRA modulhoz?
# Paraméterek: $1=infra_num
# Visszatér: 0 ha van, 1 ha nincs
comp_state_exists() {
  local infra_num="$1"
  local pfx="COMP_$(printf '%s' "$infra_num" | tr '[:lower:]' '[:upper:]')"
  local ts
  ts=$(infra_state_get "${pfx}_TS" "")
  [ -n "$ts" ]
}

# comp_state_age_hours: mennyi óra telt el a mentett check óta?
# Paraméterek: $1=infra_num
# Kimenet (echo): egész szám (órák), vagy "?" ha nem meghatározható
comp_state_age_hours() {
  local infra_num="$1"
  local pfx="COMP_$(printf '%s' "$infra_num" | tr '[:lower:]' '[:upper:]')"
  local ts
  ts=$(infra_state_get "${pfx}_TS" "")
  [ -z "$ts" ] && { echo "?"; return; }

  local then now
  # date -d: GNU coreutils (Ubuntu-n elérhető)
  then=$(date -d "$ts" +%s 2>/dev/null || echo "0")
  now=$(date +%s)
  echo $(( (now - then) / 3600 ))
}

# comp_log_source: loggolja hogy a komponens állapot honnan jön.
# A child script a felmérés blokk LEGELEJÉN hívja — a [COMP] logban
# egyértelmű legyen a felmérés forrása és oka.
#
# LOGIKA:
#   COMP_USE_CACHED=true + van mentett state -> "Mentett állapot betöltve (Xh)"
#   COMP_USE_CACHED=true + nincs mentett state -> "Friss felmérés (mentett n.a.)"
#   COMP_USE_CACHED=false + check mód -> "Friss felmérés (eredmény mentésre kerül)"
#   COMP_USE_CACHED=false + más mód -> "Friss felmérés (nem kérte a felhasználó: cache=off)"
#
# Paraméterek: $1=infra_num (pl. "01a", "06")
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

# comp_state_master_summary: összes INFRA modul cached state összefoglalója
# Kimenet (echo): többsoros szöveg a dialog_yesno-hoz
# Paraméterek: $@=INFRA_IDS tömb értékei
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
  echo "$count"   # első sor: darabszám
  printf '%b' "$out"  # többi sor: lista
}
