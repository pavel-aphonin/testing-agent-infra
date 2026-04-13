# testing-agent-infra

Orchestration and deployment for Testing Agent. Holds `docker-compose.yml`, environment templates, seed scripts, and setup documentation.

All other Testing Agent repos are built from sibling directories on the developer's machine:

```
~/Projects/AI/
├── testing-agent-explorer/
├── testing-agent-backend/
├── testing-agent-frontend/
├── testing-agent-llm/
└── testing-agent-infra/      ← you are here
```

## Services

| Service | Port | Image | Repo |
|---|---|---|---|
| `postgres` | 5432 | postgres:16 + pgvector | — |
| `redis` | 6379 | redis:7-alpine | — |
| `backend` | 8000 | build `../testing-agent-backend` | testing-agent-backend |
| `frontend` | 3000 | build `../testing-agent-frontend` | testing-agent-frontend |
| `llm` | 8080 | build `../testing-agent-llm` | testing-agent-llm |
| `explorer` | — | build `../testing-agent-explorer` | testing-agent-explorer (CLI, on-demand) |

The `explorer` service is built but not run as a long-lived container. The backend invokes it through `docker run` (or local subprocess when iOS host tools are needed).

## First-time setup

```bash
# 1. Clone all 5 repos as siblings
cd ~/Projects/AI
git clone git@github.com:pavel-aphonin/testing-agent-explorer.git
git clone git@github.com:pavel-aphonin/testing-agent-backend.git
git clone git@github.com:pavel-aphonin/testing-agent-frontend.git
git clone git@github.com:pavel-aphonin/testing-agent-llm.git
git clone git@github.com:pavel-aphonin/testing-agent-infra.git

# 2. Configure environment
cd testing-agent-infra
cp .env.example .env
# Edit .env: set POSTGRES_PASSWORD, JWT_SECRET, INITIAL_ADMIN_EMAIL, INITIAL_ADMIN_PASSWORD

# 3. Start the main stack (postgres, redis, backend, frontend)
make up
# or: docker compose up -d

# 4. Open http://localhost:3000 and log in as the admin email from step 2
```

The backend seeds the `llm_models` table with two pre-configured
entries (Gemma 4 E4B + Qwen 3.5 35B-A3B) on first startup. The UI
will already show them in `/admin/models`, but the actual GGUF weights
are not on disk until you run the bootstrap in the next section.

## First-time LLM setup

The `llm` container is gated behind the `full` compose profile because
Docker Desktop on macOS can't access Apple Silicon Metal — running
llama.cpp in-container on a Mac is unusably slow for a 35B model. For
production on Linux/CUDA, the in-container path works as expected.

### Option A: Docker-native (Linux + NVIDIA)

```bash
# 1. Install huggingface-cli on the host
pipx install "huggingface_hub[cli]"      # or: pip install --user

# 2. Download the two pre-configured seed models (~28 GB, 15-40 min)
make download-models

# 3. Start the llm container
make up-full
# or: docker compose --profile full up -d

# 4. Verify both models are visible to llama-swap
curl -fsS http://localhost:8080/v1/models | jq
```

### Option B: macOS host mode (recommended for dev on M-series)

Metal acceleration is only available when llama.cpp runs natively on
the Mac host, not inside Docker Desktop.

```bash
# 1. Install llama.cpp and huggingface-cli natively
brew install llama.cpp
pipx install "huggingface_hub[cli]"

# 2. Download the seed models just like Option A
make download-models

# 3. Run llama-swap natively against the yaml the backend writes
#    (llama-swap releases are at https://github.com/mostlygeek/llama-swap/releases)
llama-swap -config volumes/llm-models/llama-swap.yaml \
           -watch-config -listen :8080

# 4. Point the backend at the host
#    Edit .env: LLM_BASE_URL=http://host.docker.internal:8080
docker compose restart backend
```

In either case, after the weights land on disk you can add more
models from the frontend — go to `/admin/models` and click
**Browse HuggingFace**.

### Daily LLM model management

Admins can add any GGUF from HuggingFace through the UI without
touching the filesystem:

1. Open `/admin/models` in the frontend
2. Click **Browse HuggingFace**
3. Search for a repo (e.g. `qwen3.5 gguf`)
4. Pick a `.gguf` file from the repo
5. Fill in the metadata form — name, family, quantization, context
6. Click **Start download** — progress streams live over WebSocket
7. When it finishes, the new model shows up in the table and in the
   New Run dropdown immediately (llama-swap auto-reloads)

The backend regenerates `llama-swap.yaml` atomically after every
create/update/delete and the `llm` container picks up the change
through inotify without a restart.

## Daily dev workflow

```bash
make up                             # start main stack (no llm)
make up-full                        # start main stack + llm container
make logs                           # docker compose logs -f
make down                           # stop everything

# ad-hoc
docker compose logs -f backend      # watch a service
docker compose restart backend      # reload after code change (or use hot-reload)
docker compose down -v              # stop + wipe volumes (DB reset)
```

## Related repos

- `testing-agent-explorer`
- `testing-agent-backend`
- `testing-agent-frontend`
- `testing-agent-llm`
