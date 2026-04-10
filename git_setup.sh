#!/usr/bin/env bash
# =============================================================================
# git_setup.sh
# =============================================================================
# Projekt:      AI/ML környezet telepítő (CUDA · PyTorch · Ollama · vLLM)
# Platform:     Ubuntu 24.04 LTS · x86_64
# Leírás:       GitHub repó inicializálása és kapcsolat beállítása.
#               A script elvégzi a teljes Git/GitHub konfigurációt:
#               - Globális Git identity beállítása
#               - SSH kulcs generálása és GitHub-ra feltöltése
#               - Lokális repó inicializálása (ha még nem létezik)
#               - Remote origin beállítása
#               - Kezdeti commit és push
# Verzió:       1.0.0
# Dátum:        2026-04-10
# Dokumentáció: https://docs.github.com/en/authentication
#               https://cli.github.com/manual/
# =============================================================================

set -euo pipefail   # Szigorú hibakezelés: -e=hiba esetén kilép, -u=undefined var hiba, -o pipefail=pipe hiba

# =============================================================================
# SZÍN- ÉS STÍLUS KONSTANSOK
# =============================================================================
readonly CLR_RESET="\033[0m"
readonly CLR_BOLD="\033[1m"
readonly CLR_GREEN="\033[0;32m"
readonly CLR_YELLOW="\033[0;33m"
readonly CLR_RED="\033[0;31m"
readonly CLR_CYAN="\033[0;36m"
readonly CLR_BLUE="\033[0;34m"

# =============================================================================
# NAPLÓZÓ FÜGGVÉNYEK
# =============================================================================

# Általános info üzenet
log_info() {
    echo -e "${CLR_CYAN}[INFO]${CLR_RESET}  $*"
}

# Sikeres művelet visszajelzése
log_ok() {
    echo -e "${CLR_GREEN}[  OK]${CLR_RESET}  $*"
}

# Figyelmeztetés (nem fatális)
log_warn() {
    echo -e "${CLR_YELLOW}[WARN]${CLR_RESET}  $*"
}

# Kritikus hiba, kilépés
log_error() {
    echo -e "${CLR_RED}[HIBA]${CLR_RESET}  $*" >&2
    exit 1
}

# Szekció fejléc megjelenítése
log_section() {
    echo ""
    echo -e "${CLR_BLUE}${CLR_BOLD}═══════════════════════════════════════════════════════${CLR_RESET}"
    echo -e "${CLR_BLUE}${CLR_BOLD}  $*${CLR_RESET}"
    echo -e "${CLR_BLUE}${CLR_BOLD}═══════════════════════════════════════════════════════${CLR_RESET}"
}

# =============================================================================
# FÜGGŐSÉG ELLENŐRZÉS
# =============================================================================

# Ellenőrzi, hogy a szükséges programok telepítve vannak-e
check_dependencies() {
    log_section "Függőségek ellenőrzése"

    local deps=("git" "ssh-keygen" "curl")
    local missing=()

    for dep in "${deps[@]}"; do
        if command -v "$dep" &>/dev/null; then
            log_ok "$dep → $(command -v "$dep")"
        else
            log_warn "$dep → HIÁNYZIK"
            missing+=("$dep")
        fi
    done

    # GitHub CLI (gh) opcionális, de ajánlott
    if command -v gh &>/dev/null; then
        log_ok "gh (GitHub CLI) → $(command -v gh)"
        GH_CLI_AVAILABLE=true
    else
        log_warn "gh (GitHub CLI) → nem telepített (SSH kulcs manuálisan kell feltölteni)"
        GH_CLI_AVAILABLE=false
    fi

    # Ha vannak hiányzó kötelező függőségek, telepítjük őket
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Hiányzó csomagok telepítése: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
        log_ok "Függőségek telepítve."
    fi
}

# =============================================================================
# GITHUB CLI TELEPÍTÉS (opcionális, de erősen ajánlott)
# =============================================================================

# GitHub CLI (gh) telepítése, ha még nincs fenn
# Forrás: https://cli.github.com/manual/installation
install_gh_cli() {
    log_section "GitHub CLI (gh) telepítése"

    if command -v gh &>/dev/null; then
        log_ok "GitHub CLI már telepítve: $(gh --version | head -1)"
        return 0
    fi

    log_info "GitHub CLI letöltése és telepítése..."

    # Hivatalos GitHub CLI apt repo hozzáadása
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
        https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y gh

    log_ok "GitHub CLI sikeresen telepítve: $(gh --version | head -1)"
    GH_CLI_AVAILABLE=true
}

# =============================================================================
# GIT GLOBÁLIS KONFIGURÁCIÓ
# =============================================================================

# Globális Git identity és hasznos beállítások konfigurálása
configure_git_global() {
    log_section "Git globális konfiguráció"

    # Felhasználói adatok bekérése
    echo -e "${CLR_BOLD}GitHub felhasználói adatok:${CLR_RESET}"
    read -rp "  GitHub felhasználónév: " GIT_USERNAME
    read -rp "  GitHub e-mail cím:     " GIT_EMAIL

    # Validáció
    [[ -z "$GIT_USERNAME" ]] && log_error "Felhasználónév nem lehet üres!"
    [[ -z "$GIT_EMAIL" ]]    && log_error "E-mail cím nem lehet üres!"

    # Alapadatok beállítása
    git config --global user.name  "$GIT_USERNAME"
    git config --global user.email "$GIT_EMAIL"

    # --------------------------------------------------------------
    # Hasznos globális Git beállítások
    # --------------------------------------------------------------

    # Alapértelmezett branch neve 'main' (GitHub standard)
    git config --global init.defaultBranch main

    # Szövegszerkesztő (nano a legbarátságosabb terminálban)
    git config --global core.editor nano

    # Pull stratégia: rebase helyett merge (biztonságosabb kezdőknek)
    git config --global pull.rebase false

    # Automatikus CRLF→LF konverzió (Linux kompatibilitás)
    git config --global core.autocrlf input

    # Színes kimenet engedélyezése
    git config --global color.ui auto

    # Push: csak az aktuális branch-et tolja fel
    git config --global push.default current

    # Credential helper: 8 órán át tárolja a jelszót (SSH esetén nem szükséges)
    git config --global credential.helper "cache --timeout=28800"

    # Hasznos aliasok
    git config --global alias.st   "status -sb"
    git config --global alias.lg   "log --oneline --graph --decorate --all"
    git config --global alias.last "log -1 HEAD --stat"
    git config --global alias.undo "reset --soft HEAD~1"
    git config --global alias.fp   "fetch --prune"

    log_ok "Git globális konfiguráció kész."
    log_info "Beállított adatok:"
    git config --global --list | grep -E "user\.|init\.|alias\." | sed 's/^/    /'
}

# =============================================================================
# SSH KULCS GENERÁLÁS ÉS GITHUB REGISZTRÁCIÓ
# =============================================================================

# Ed25519 SSH kulcspár generálása és GitHub-ra feltöltése
setup_ssh_key() {
    log_section "SSH kulcs beállítása"

    local ssh_key_path="$HOME/.ssh/id_ed25519_github"
    local ssh_pub_path="${ssh_key_path}.pub"

    # Ellenőrzés: létezik-e már kulcs
    if [[ -f "$ssh_key_path" ]]; then
        log_warn "SSH kulcs már létezik: $ssh_key_path"
        read -rp "  Új kulcsot generálsz? (i/n) [n]: " regen
        regen="${regen:-n}"
        if [[ "$regen" != "i" ]]; then
            log_info "Meglévő kulcs használata."
        else
            # Meglévő kulcs biztonsági mentése
            mv "$ssh_key_path"     "${ssh_key_path}.bak.$(date +%s)"
            mv "$ssh_pub_path"     "${ssh_pub_path}.bak.$(date +%s)"
            log_ok "Régi kulcsok átnevezve (.bak)."
            generate_new_key "$ssh_key_path"
        fi
    else
        generate_new_key "$ssh_key_path"
    fi

    # SSH config fájl frissítése
    configure_ssh_config "$ssh_key_path"

    # Publikus kulcs megjelenítése
    echo ""
    log_info "Publikus SSH kulcs (ezt kell GitHub-ra feltölteni):"
    echo -e "${CLR_YELLOW}"
    cat "$ssh_pub_path"
    echo -e "${CLR_RESET}"

    # GitHub-ra feltöltés: gh CLI-vel automatikusan, vagy manuális útmutatás
    if [[ "$GH_CLI_AVAILABLE" == true ]]; then
        upload_ssh_key_via_gh "$ssh_pub_path"
    else
        show_manual_ssh_instructions "$ssh_pub_path"
    fi

    # Kapcsolat tesztelése
    test_github_ssh_connection
}

# Új SSH kulcspár generálása (Ed25519 – modern, biztonságos)
generate_new_key() {
    local key_path="$1"
    log_info "Ed25519 SSH kulcs generálása: $key_path"

    # Passphrase bekérése (üres = no passphrase)
    read -rsp "  SSH kulcs passphrase (Enter=üres): " ssh_passphrase
    echo ""

    # Kulcs generálás
    ssh-keygen \
        -t ed25519 \
        -C "${GIT_EMAIL}" \
        -f "$key_path" \
        -N "$ssh_passphrase"

    # Megfelelő jogosultságok beállítása
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"

    log_ok "SSH kulcspár létrehozva."
}

# SSH config fájl (~/.ssh/config) frissítése
configure_ssh_config() {
    local key_path="$1"
    local ssh_config="$HOME/.ssh/config"

    # SSH mappa létrehozása, ha nem létezik
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    # Ellenőrzés: van-e már github.com bejegyzés
    if grep -q "Host github.com" "$ssh_config" 2>/dev/null; then
        log_warn "~/.ssh/config már tartalmaz github.com bejegyzést. Kihagyva."
        return 0
    fi

    # GitHub SSH konfig hozzáadása
    cat >> "$ssh_config" <<EOF

# ── GitHub SSH konfiguráció ────────────────────────────────────────
# Generálva: $(date '+%Y-%m-%d %H:%M:%S')
# Projekt: AI/ML környezet telepítő
Host github.com
    HostName       github.com
    User           git
    IdentityFile   $key_path
    IdentitiesOnly yes
    AddKeysToAgent yes
    ServerAliveInterval 60
EOF

    chmod 600 "$ssh_config"
    log_ok "~/.ssh/config frissítve."
}

# SSH kulcs feltöltése GitHub-ra a gh CLI segítségével
upload_ssh_key_via_gh() {
    local pub_key_path="$1"

    log_info "GitHub CLI bejelentkezés és SSH kulcs feltöltése..."

    # Hitelesítés (ha még nincs)
    if ! gh auth status &>/dev/null; then
        log_info "GitHub bejelentkezés szükséges (böngésző vagy token):"
        gh auth login --git-protocol ssh --web
    fi

    # Kulcs title generálás
    local key_title="AI-ML-Project-$(hostname)-$(date +%Y%m%d)"

    # Feltöltés
    gh ssh-key add "$pub_key_path" --title "$key_title" --type authentication \
        && log_ok "SSH kulcs sikeresen feltöltve GitHub-ra: $key_title" \
        || log_warn "SSH kulcs feltöltés sikertelen (lehet, hogy már létezik)."
}

# Manuális SSH kulcs feltöltési útmutató
show_manual_ssh_instructions() {
    local pub_key_path="$1"
    echo ""
    log_warn "Manuális SSH kulcs feltöltés szükséges:"
    echo "  1. Nyisd meg: https://github.com/settings/ssh/new"
    echo "  2. Title: AI-ML-Project-$(hostname)"
    echo "  3. Key type: Authentication Key"
    echo "  4. Key mező: másold be a fenti publikus kulcsot"
    echo "  5. Kattints: Add SSH key"
    echo ""
    read -rp "  Feltöltötted a kulcsot? Nyomj Enter-t a folytatáshoz..."
}

# GitHub SSH kapcsolat tesztelése
test_github_ssh_connection() {
    log_info "GitHub SSH kapcsolat tesztelése..."

    # ssh-agent indítása és kulcs hozzáadása
    eval "$(ssh-agent -s)" &>/dev/null
    ssh-add "$HOME/.ssh/id_ed25519_github" 2>/dev/null

    # Kapcsolat teszt (sikeres, ha 'Hi <username>!' üzenetet kap)
    if ssh -T git@github.com -o StrictHostKeyChecking=accept-new 2>&1 | grep -q "successfully authenticated"; then
        log_ok "GitHub SSH kapcsolat: SIKERES"
    else
        log_warn "GitHub SSH kapcsolat nem ellenőrizhető automatikusan."
        log_info "Manuális teszt: ssh -T git@github.com"
    fi
}

# =============================================================================
# LOKÁLIS REPÓ INICIALIZÁLÁS
# =============================================================================

# Git repó inicializálása a projekt könyvtárban
init_local_repo() {
    log_section "Lokális Git repó inicializálása"

    # Projekt könyvtár bekérése
    read -rp "  Projekt könyvtár teljes elérési útja [$(pwd)]: " PROJECT_DIR
    PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"

    # Könyvtár létrehozása, ha nem létezik
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"

    # Ellenőrzés: már van-e git repó
    if [[ -d ".git" ]]; then
        log_warn "Git repó már létezik: $PROJECT_DIR/.git"
        REPO_EXISTS=true
    else
        git init
        log_ok "Git repó inicializálva: $PROJECT_DIR"
        REPO_EXISTS=false
    fi
}

# =============================================================================
# REMOTE ORIGIN BEÁLLÍTÁSA
# =============================================================================

# GitHub remote origin URL beállítása (SSH protokollal)
setup_remote_origin() {
    log_section "GitHub Remote Origin beállítása"

    # Ellenőrzés: van-e már remote
    if git remote get-url origin &>/dev/null; then
        local current_remote
        current_remote=$(git remote get-url origin)
        log_warn "Remote origin már létezik: $current_remote"
        read -rp "  Felülírja? (i/n) [n]: " overwrite
        overwrite="${overwrite:-n}"
        [[ "$overwrite" != "i" ]] && return 0
        git remote remove origin
    fi

    # Repó adatok bekérése
    echo ""
    echo -e "${CLR_BOLD}GitHub repó adatok:${CLR_RESET}"
    read -rp "  GitHub felhasználónév [$GIT_USERNAME]: " repo_owner
    repo_owner="${repo_owner:-$GIT_USERNAME}"

    read -rp "  Repó neve (pl.: ai-ml-installer): " repo_name
    [[ -z "$repo_name" ]] && log_error "Repó neve kötelező!"

    # SSH URL összeállítása
    local remote_url="git@github.com:${repo_owner}/${repo_name}.git"

    # Remote hozzáadása
    git remote add origin "$remote_url"
    log_ok "Remote origin beállítva: $remote_url"

    # Opcionális: repó létrehozása gh CLI-vel, ha még nem létezik
    if [[ "$GH_CLI_AVAILABLE" == true ]]; then
        create_github_repo_if_needed "$repo_owner" "$repo_name"
    else
        log_info "GitHub repót manuálisan hozd létre: https://github.com/new"
        log_info "Repó neve legyen: $repo_name"
        read -rp "  Létrehoztad? Nyomj Enter-t..."
    fi
}

# GitHub repó létrehozása gh CLI-vel (ha még nem létezik)
create_github_repo_if_needed() {
    local owner="$1"
    local name="$2"

    # Ellenőrzés: létezik-e már a repó
    if gh repo view "${owner}/${name}" &>/dev/null; then
        log_ok "GitHub repó már létezik: ${owner}/${name}"
        return 0
    fi

    echo ""
    read -rp "  GitHub repó leírása (Enter=üres): " repo_desc
    read -rp "  Privát repó? (i/n) [n]: " is_private
    is_private="${is_private:-n}"

    local visibility_flag=""
    [[ "$is_private" == "i" ]] && visibility_flag="--private" || visibility_flag="--public"

    # Repó létrehozása
    gh repo create "${owner}/${name}" \
        $visibility_flag \
        --description "${repo_desc:-AI/ML környezet telepítő projekt}" \
        --source . \
        --remote origin \
        && log_ok "GitHub repó létrehozva: https://github.com/${owner}/${name}" \
        || log_warn "Repó létrehozás sikertelen (esetleg már létezik)."
}

# =============================================================================
# .GITIGNORE LÉTREHOZÁSA
# =============================================================================

# Projekt-specifikus .gitignore fájl generálása
create_gitignore() {
    log_section ".gitignore fájl létrehozása"

    if [[ -f ".gitignore" ]]; then
        log_warn ".gitignore már létezik."
        read -rp "  Felülírja? (i/n) [n]: " overwrite_gi
        overwrite_gi="${overwrite_gi:-n}"
        [[ "$overwrite_gi" != "i" ]] && return 0
    fi

    cat > .gitignore <<'GITIGNORE'
# =============================================================================
# .gitignore – AI/ML Környezet Telepítő Projekt
# Platform: Ubuntu 24.04 · CUDA · PyTorch · Ollama · vLLM · Docker
# =============================================================================

# ── Python ────────────────────────────────────────────────────────────────────
__pycache__/
*.py[cod]
*$py.class
*.so
*.egg
*.egg-info/
dist/
build/
eggs/
parts/
var/
sdist/
develop-eggs/
.installed.cfg
lib/
lib64/
.eggs/

# ── UV (Python csomagkezelő) ──────────────────────────────────────────────────
# Dokumentáció: https://docs.astral.sh/uv/
.venv/
.uv/
uv.lock

# ── Virtuális környezetek ─────────────────────────────────────────────────────
venv/
env/
ENV/
.virtualenv/

# ── PyTorch / CUDA modellek és checkpointok ──────────────────────────────────
# Dokumentáció: https://docs.pytorch.org/docs/stable/index.html
*.pt
*.pth
*.ckpt
*.safetensors
*.bin
checkpoints/
runs/
wandb/
mlruns/

# ── Ollama modellek ───────────────────────────────────────────────────────────
# Dokumentáció: https://ollama.readthedocs.io/en/
.ollama/
ollama_models/

# ── vLLM ─────────────────────────────────────────────────────────────────────
# Dokumentáció: https://docs.vllm.ai/en/latest/
vllm_cache/
model_cache/
*.gguf
*.ggml

# ── TurboQuant ────────────────────────────────────────────────────────────────
# Dokumentáció: https://github.com/0xSero/turboquant
turboquant_output/
quantized_models/

# ── Docker ───────────────────────────────────────────────────────────────────
# Dokumentáció: https://docs.docker.com/
.docker/
docker-compose.override.yml

# ── Naplófájlok ───────────────────────────────────────────────────────────────
*.log
logs/
*.log.*

# ── Rendszer fájlok ───────────────────────────────────────────────────────────
.DS_Store
Thumbs.db
*.swp
*.swo
*~
.directory

# ── IDE és szerkesztők ────────────────────────────────────────────────────────
.idea/
.vscode/
*.code-workspace
.vim/

# ── Környezeti változók és titkok ─────────────────────────────────────────────
.env
.env.*
!.env.example
*.secret
secrets/
*.pem
*.key
*.p12
*.pfx

# ── Telepítési cache ──────────────────────────────────────────────────────────
.cache/
*.cache
pip_cache/
apt_cache/

# ── Adatfájlok (nagy méretű) ─────────────────────────────────────────────────
datasets/
data/raw/
*.csv
*.parquet
*.arrow
*.hdf5
*.h5

# ── Ideiglenes fájlok ────────────────────────────────────────────────────────
tmp/
temp/
*.tmp
*.bak
*.orig

# ── ZSH ──────────────────────────────────────────────────────────────────────
# Dokumentáció: https://zsh.sourceforge.io/Doc/
.zsh_history
.zcompdump*
GITIGNORE

    log_ok ".gitignore létrehozva."
}

# =============================================================================
# KEZDETI COMMIT ÉS PUSH
# =============================================================================

# Első commit létrehozása és GitHub-ra feltöltése
initial_commit_and_push() {
    log_section "Kezdeti commit és push"

    # Staged fájlok ellenőrzése
    local untracked
    untracked=$(git status --porcelain | wc -l)

    if [[ "$untracked" -eq 0 && "$REPO_EXISTS" == true ]]; then
        log_info "Nincs új fájl commitolni."
        return 0
    fi

    # Összes fájl staging-be
    git add -A

    # Commit üzenet
    local commit_msg
    commit_msg="feat: projekt inicializálás

- Git konfiguráció és SSH beállítás
- .gitignore: Python, CUDA, PyTorch, Ollama, vLLM, Docker
- Dokumentációs prompt hozzáadva
- AI/ML telepítő projekt alapstruktúra

Platform: Ubuntu 24.04 LTS
Dátum: $(date '+%Y-%m-%d %H:%M:%S')"

    git commit -m "$commit_msg"
    log_ok "Commit létrehozva."

    # Push (upstream beállításával)
    log_info "Push a GitHub-ra (origin main)..."
    git push --set-upstream origin main \
        && log_ok "Push sikeres! Repó: $(git remote get-url origin | sed 's/git@github.com:/https:\/\/github.com\//; s/\.git$//')" \
        || log_warn "Push sikertelen. Ellenőrizd a GitHub repó és az SSH kulcs beállításokat."
}

# =============================================================================
# ÖSSZEFOGLALÓ
# =============================================================================

# Végső összefoglaló és útmutatás kiírása
print_summary() {
    log_section "Beállítás kész!"

    echo ""
    echo -e "  ${CLR_GREEN}${CLR_BOLD}✓ GitHub integráció sikeresen konfigurálva${CLR_RESET}"
    echo ""
    echo -e "  ${CLR_BOLD}Hasznos git aliasok (ez a gépre konfigurálva):${CLR_RESET}"
    echo "    git st    → git status -sb"
    echo "    git lg    → fa szerkezetű log minden branch-el"
    echo "    git last  → utolsó commit részletei"
    echo "    git undo  → utolsó commit visszavonása (kód megtartva)"
    echo "    git fp    → fetch és remote branch tisztítás"
    echo ""
    echo -e "  ${CLR_BOLD}Tipikus munkafolyamat:${CLR_RESET}"
    echo "    git st              → változások megtekintése"
    echo "    git add -A          → minden változás staging-be"
    echo "    git commit -m '...' → commit üzenettel"
    echo "    git push            → feltöltés GitHub-ra"
    echo "    git pull            → letöltés GitHub-ról"
    echo ""
    echo -e "  ${CLR_BOLD}SSH teszt:${CLR_RESET}  ssh -T git@github.com"
    echo -e "  ${CLR_BOLD}Repó link:${CLR_RESET}  $(git remote get-url origin 2>/dev/null | sed 's/git@github.com:/https:\/\/github.com\//; s/\.git$//' || echo 'nem beállított')"
    echo ""
}

# =============================================================================
# FŐPROGRAM
# =============================================================================
main() {
    clear
    echo -e "${CLR_BLUE}${CLR_BOLD}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║       GitHub Integráció – AI/ML Projekt Setup        ║"
    echo "  ║       Platform: Ubuntu 24.04 · CUDA · PyTorch        ║"
    echo "  ╚═══════════════════════════════════════════════════════╝"
    echo -e "${CLR_RESET}"

    check_dependencies     # 1. Függőségek ellenőrzése
    install_gh_cli         # 2. GitHub CLI telepítése (ha szükséges)
    configure_git_global   # 3. Git identity és beállítások
    setup_ssh_key          # 4. SSH kulcs generálás + GitHub regisztráció
    init_local_repo        # 5. Lokális repó inicializálás
    create_gitignore       # 6. .gitignore fájl létrehozása
    setup_remote_origin    # 7. Remote origin beállítása
    initial_commit_and_push # 8. Kezdeti commit és push
    print_summary          # 9. Összefoglaló
}

# Script meghívása főprogramként (ne fusson le import esetén)
main "$@"
