# =============================================================================
# .github/CONTRIBUTING.md
# =============================================================================
# Projekt:      AI/ML környezet telepítő (CUDA · PyTorch · Ollama · vLLM)
# Leírás:       Fejlesztési konvenciók és munkafolyamat útmutató
# Verzió:       1.0.0
# Dátum:        2026-04-10
# =============================================================================

# Fejlesztési Útmutató

## 🌿 Branch stratégia

```
main          ← stabil, kiadásra kész kód
develop       ← aktív fejlesztés
feature/*     ← új funkciók  (pl: feature/cuda-12-support)
fix/*         ← hibajavítások (pl: fix/ollama-gpu-detection)
docs/*        ← dokumentáció (pl: docs/vllm-setup-guide)
```

## 📝 Commit üzenet konvenció (Conventional Commits)

```
<típus>(<hatókör>): <rövid leírás>

[opcionális részletes leírás]

[opcionális: Closes #issue]
```

### Típusok:
| Típus      | Mikor használd                               |
|------------|----------------------------------------------|
| `feat`     | Új funkció hozzáadása                        |
| `fix`      | Hibajavítás                                  |
| `docs`     | Csak dokumentáció változás                   |
| `style`    | Formázás, szóköz (nem funkcionális változás) |
| `refactor` | Kód átstrukturálás (nincs új feature/fix)    |
| `perf`     | Teljesítmény javítás (CUDA, PyTorch)         |
| `test`     | Tesztek hozzáadása/javítása                  |
| `chore`    | Build, CI, függőség változás                 |
| `revert`   | Korábbi commit visszavonása                  |

### Hatókörök (scope):
`cuda` · `pytorch` · `ollama` · `vllm` · `docker` · `python` · `uv` · `zsh` · `ci` · `docs`

### Példák:
```bash
feat(cuda): CUDA 12.8 telepítő hozzáadása Ubuntu 24.04-hez
fix(ollama): GPU memória felszabadítás javítása leálláskor
docs(vllm): vLLM quantizálás dokumentáció frissítése
perf(pytorch): TurboQuant integráció extrém tömörítéshez
chore(ci): shellcheck futtatás hozzáadása CI pipeline-ba
```

## 🔧 Kód stílus

### Shell scriptek:
- `#!/usr/bin/env bash` shebang
- `set -euo pipefail` minden script elején
- Teljes, részletes magyar kommentek
- `NAGY_BETU` konstansok, `kis_betu` változók és függvények
- Minden függvény dokumentálva (mit csinál, paraméterek)

### Python:
- `ruff` linter és formázó (UV-vel: `uv tool run ruff`)
- Type hints kötelező
- Docstring minden publikus függvényhez (Google stílus)
- Python 3.12+ kompatibilitás

## 🚀 Munkafolyamat

```bash
# 1. Új feature branch
git checkout develop
git pull
git checkout -b feature/cuda-12-support

# 2. Fejlesztés + commit
git add -A
git commit -m "feat(cuda): CUDA 12.8 apt telepítő"

# 3. Push és PR
git push -u origin feature/cuda-12-support
gh pr create --base develop --title "feat(cuda): CUDA 12.8 támogatás"
```
