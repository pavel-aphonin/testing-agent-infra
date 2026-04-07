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

# 3. Download seed LLM models (~24 GB, 15-40 min)
./scripts/seed-models.sh

# 4. Start the stack
docker compose up -d

# 5. Open http://localhost:3000 and log in as the admin email from step 2
```

## Daily dev workflow

```bash
docker compose up -d                # start everything
docker compose logs -f backend      # watch a service
docker compose restart backend      # reload after code change (or use hot-reload)
docker compose down                 # stop everything
docker compose down -v              # stop + wipe volumes (DB reset)
```

## Related repos

- `testing-agent-explorer`
- `testing-agent-backend`
- `testing-agent-frontend`
- `testing-agent-llm`
