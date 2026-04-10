# =============================================================================
# .github/pull_request_template.md
# =============================================================================
# Projekt:      AI/ML környezet telepítő (CUDA · PyTorch · Ollama · vLLM)
# Leírás:       Pull Request sablon – kötelező adatok és ellenőrzőlista
# =============================================================================

## 📋 Változtatás leírása

<!-- Rövid leírás: mit változtattál és miért? -->

## 🔗 Kapcsolódó issue

<!-- Pl: Closes #12 vagy Fixes #34 -->

Closes #

## 🧩 Változtatás típusa

- [ ] 🐛 Hibajavítás (bug fix)
- [ ] ✨ Új funkció (feature)
- [ ] 🔧 Refaktor (kódminőség, nincs funkcionális változás)
- [ ] 📚 Dokumentáció frissítés
- [ ] 🔒 Biztonsági javítás
- [ ] 🚀 Teljesítmény javítás (CUDA · PyTorch optimalizálás)
- [ ] 🐳 Docker konfiguráció változás
- [ ] 📦 Függőség frissítés

## ✅ Ellenőrzőlista

- [ ] A kód fut és tesztelve lett Ubuntu 24.04-en
- [ ] Shell scriptek `shellcheck`-en átmentek
- [ ] Python kód `ruff`-on átment
- [ ] Kommentek frissítve (HU, részletes)
- [ ] Verzió és dátum frissítve az érintett fájlokban
- [ ] `.gitignore` naprakész
- [ ] Nincs beégetett jelszó / API kulcs / titkos adat

## 🖥️ Tesztelési környezet

- **OS:** Ubuntu 24.04 LTS
- **GPU:** <!-- pl: NVIDIA RTX 4090 -->
- **CUDA:** <!-- pl: 12.x -->
- **Python:** <!-- pl: 3.12 -->

## 📝 Egyéb megjegyzés

<!-- Bármilyen extra info a reviewernek -->
