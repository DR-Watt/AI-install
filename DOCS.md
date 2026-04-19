<prompt>

# AI-install projekt — hivatalos dokumentációk

> Forrásrend: hivatalos dokumentáció az ELSŐDLEGES referencia minden kódrésznél.
> Nem-hivatalos forrás (StackOverflow, blog, GitHub Issue) csak akkor használható,
> ha a hivatalos docs nem ad választ — és a kódban kommenttel jelölni kell a forrást.

---

## 0. Verzió-követelmények (2026-04)

| Eszköz         | Minimum     | Megjegyzés                                |
|----------------|-------------|-------------------------------------------|
| Ubuntu         | 24.04 LTS   | Noble Numbat                              |
| Bash           | 5.2+        |                                           |
| Python         | 3.12        | pyenv-ből telepítve                       |
| uv             | 0.5+        | csomagkezelő (pip helyett INFRA-ban)      |
| NVIDIA driver  | 560+        | open-kernel, Blackwell support            |
| CUDA           | 12.8+       | Blackwell SM_120 kernelek                 |
| PyTorch        | 2.10+cu128  | RTX 5090 SM_120 natív support             |
| Ollama         | 0.5+        | keep_alive API stabil                     |
| vLLM           | 0.19+       | `--swap-space` megszűnt ebben a verzióban |

---

## 1. Operating System & Base

- Ubuntu Server: https://ubuntu.com/server/docs
- Linux kernel: https://docs.kernel.org/
- systemd: https://www.freedesktop.org/software/systemd/man/latest/
- systemd user services: https://www.freedesktop.org/software/systemd/man/latest/systemd.user.html

## 2. Shell & Terminal UI

- Bash manual: https://www.gnu.org/software/bash/manual/bash.html
- Zsh: https://zsh.sourceforge.io/Doc/
- Oh My Zsh: https://github.com/ohmyzsh/ohmyzsh/wiki
- YAD (upstream repo): https://github.com/v1cont/yad
- whiptail / newt (upstream): https://pagure.io/newt

## 3. Hardware & Drivers

### NVIDIA driver
- https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/

### CUDA
- Fő docs: https://docs.nvidia.com/cuda/
- Linux telepítés: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/
- CUDA Downloads: https://developer.nvidia.com/cuda-downloads
- Ubuntu 24.04 repo: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/

### NVIDIA Blackwell architektúra
- https://developer.nvidia.com/blog/nvidia-blackwell-architecture-for-ai/

## 4. Python ecosystem

- Python 3.12: https://docs.python.org/3.12/
- uv: https://docs.astral.sh/uv/
- pyenv: https://github.com/pyenv/pyenv

## 5. AI Runtimes

### PyTorch
- Docs: https://docs.pytorch.org/docs/stable/
- Local install (CUDA index): https://pytorch.org/get-started/locally/

### Ollama
- Fő docs: https://ollama.readthedocs.io/
- REST API: https://ollama.readthedocs.io/en/api/
- Modelfile szintaxis: https://github.com/ollama/ollama/blob/main/docs/modelfile.md
- Repo: https://github.com/ollama/ollama

### vLLM
- Fő docs: https://docs.vllm.ai/en/latest/
- CLI `vllm serve`: https://docs.vllm.ai/en/stable/cli/serve/
- Quantization: https://docs.vllm.ai/en/stable/features/quantization/
- Repo: https://github.com/vllm-project/vllm

### HuggingFace
- TASK katalógus: https://huggingface.co/tasks
- Hub API: https://huggingface.co/docs/hub/
- Transformers: https://huggingface.co/docs/transformers/

## 6. Quantization

### TurboQuant
- Papír: https://arxiv.org/pdf/2504.19874
- Blog: https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/
- Repo: https://github.com/0xSero/turboquant

### GGUF format
- Spec: https://github.com/ggml-org/ggml/blob/master/docs/gguf.md

## 7. IDE & Extensions

### VS Code
- Docs: https://code.visualstudio.com/docs
- Settings reference: https://code.visualstudio.com/docs/configure/settings

### CLINE
- Docs: https://docs.cline.bot
- Repo: https://github.com/cline/cline

### Continue.dev
- Docs: https://docs.continue.dev
- YAML config reference: https://docs.continue.dev/reference

### Cursor
- Docs: https://cursor.com/docs

## 8. Protocols & Standards

- MCP (Model Context Protocol): https://modelcontextprotocol.io
- JSON (RFC 8259): https://www.json.org/
- YAML: https://yaml.org/spec/
- OpenAI API (vLLM kompatibilitás): https://platform.openai.com/docs/api-reference

## 9. Developer tooling

- Docker: https://docs.docker.com/
- Git: https://git-scm.com/doc

</prompt>
