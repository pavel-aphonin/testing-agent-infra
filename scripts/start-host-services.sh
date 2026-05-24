#!/usr/bin/env bash
# Start all host-side services that can't run inside Docker on macOS:
#   1. llama-server (Gemma chat, Metal GPU)      — port 8080
#   2. llama-server (Qwen3-Embedding-8B)          — port 8082
#   3. llama-server (Qwen3-8B Instruct for RAG)   — port 8083
#   4. llama-server (Qwen3-Reranker-8B)           — port 8084
#   5. Explorer worker                            — claims runs from backend
#
# SimMirror is NOT started here — the worker spawns it automatically
# when it claims a run, and kills it when the run finishes.
#
# Usage:
#   ./scripts/start-host-services.sh       # from testing-agent-infra/
#   make start                              # same thing via Makefile
#
# Prerequisites:
#   - llama-server installed (brew install llama.cpp)
#   - Gemma GGUF downloaded into volumes/llm-models/
#   - bge-small GGUF downloaded into volumes/llm-models/
#   - testing-agent-explorer venv set up (.venv with deps)
#   - iOS Simulator booted with TestApp installed
#   - SimMirror built (swift build -c release in testing-agent-sim-mirror)
#
# All processes write logs to /tmp/ta-*.log and their PIDs to /tmp/ta-*.pid
# so stop-host-services.sh can clean them up.

set -euo pipefail
cd "$(dirname "$0")/.."

MODELS_DIR="$(pwd)/volumes/llm-models"
EXPLORER_DIR="$(cd ../testing-agent-explorer && pwd)"
PIDDIR="/tmp"
LOGDIR="/tmp"

# Load .env for WORKER_TOKEN
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

if [[ -z "${WORKER_TOKEN:-}" ]]; then
  echo "ERROR: WORKER_TOKEN is not set." >&2
  echo "Set it in infra/.env (the file is loaded above) or export it" >&2
  echo "before running this script. Generate with:" >&2
  echo "  openssl rand -hex 32" >&2
  echo "No default is supplied — falling back to a placeholder would" >&2
  echo "leave /api/internal/* protected by a known token (PER-104)." >&2
  exit 1
fi

# ---------------------------------------------------------------- helpers

already_running() {
  local pidfile="$1"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(<"$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    rm -f "$pidfile"
  fi
  return 1
}

start_service() {
  local name="$1" pidfile="$2" logfile="$3"
  shift 3
  if already_running "$pidfile"; then
    echo "  ✓ $name already running (pid $(<"$pidfile"))"
    return
  fi
  "$@" > "$logfile" 2>&1 &
  local pid=$!
  echo "$pid" > "$pidfile"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    echo "  ✓ $name started (pid $pid, log $logfile)"
  else
    echo "  ✗ $name failed to start — check $logfile"
    return 1
  fi
}

# ---------------------------------------------------------------- main

echo "=== Starting host services ==="
echo ""

# 1. Chat llama-server on :8080 — config from backend
#
# PER-163: the launcher asks the backend which model is currently
# active and reads its full config (GGUF path, mmproj, ctx tokens,
# image_min_tokens for grounding). Hard-coding Gemma here was the
# reason every model swap forced a script edit + restart cycle; now
# swapping a model is a single UPDATE llm_models SET is_active=true
# WHERE name='...' and a process restart.
#
# Falls back to the legacy Gemma-4 path only when the backend has
# no active chat model and the legacy GGUF is on disk — so the
# script still boots on a fresh machine before any model is
# registered.

CHAT_CFG_JSON="$(curl -sS \
  -H "Authorization: Bearer ${WORKER_TOKEN}" \
  http://localhost:8000/api/internal/chat-model/config 2>/dev/null || true)"

if echo "$CHAT_CFG_JSON" | python3 -c 'import sys, json; json.loads(sys.stdin.read())["name"]' >/dev/null 2>&1; then
  # Translate container-internal paths (/var/lib/llm-models/<file>)
  # back to host paths (the backend stores the container view).
  export MODELS_DIR
  CHAT_NAME=$(echo "$CHAT_CFG_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["name"])')
  CHAT_GGUF=$(echo "$CHAT_CFG_JSON" | python3 -c 'import sys,json,os;p=json.load(sys.stdin)["gguf_path"];print(p.replace("/var/lib/llm-models",os.environ["MODELS_DIR"]))' )
  CHAT_MMPROJ=$(echo "$CHAT_CFG_JSON" | python3 -c 'import sys,json,os;p=json.load(sys.stdin).get("mmproj_path");print((p or "").replace("/var/lib/llm-models",os.environ["MODELS_DIR"]))' )
  CHAT_CTX=$(echo "$CHAT_CFG_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("max_context_tokens") or 32768)')
  CHAT_IMG_MIN=$(echo "$CHAT_CFG_JSON" | python3 -c 'import sys,json;v=json.load(sys.stdin).get("image_min_tokens");print(v if v else "")')
  echo "  ✓ Chat model from backend: $CHAT_NAME"

  MMPROJ_FLAG=""
  if [[ -n "$CHAT_MMPROJ" && -f "$CHAT_MMPROJ" ]]; then
    MMPROJ_FLAG="--mmproj $CHAT_MMPROJ"
    echo "    Vision enabled (mmproj=$(basename "$CHAT_MMPROJ"))"
  fi
  IMG_MIN_FLAG=""
  if [[ -n "$CHAT_IMG_MIN" ]]; then
    IMG_MIN_FLAG="--image-min-tokens $CHAT_IMG_MIN"
    echo "    Grounding budget: --image-min-tokens $CHAT_IMG_MIN"
  fi

  if [[ ! -f "$CHAT_GGUF" ]]; then
    echo "  ⚠ Chat GGUF not on disk: $CHAT_GGUF — skipping :8080"
  else
    start_service "llama-server (chat :8080 = $CHAT_NAME)" \
      "$PIDDIR/ta-llama-chat.pid" "$LOGDIR/ta-llama-chat.log" \
      llama-server \
        --model "$CHAT_GGUF" \
        $MMPROJ_FLAG \
        $IMG_MIN_FLAG \
        --host 0.0.0.0 --port 8080 \
        --ctx-size "$CHAT_CTX" --n-gpu-layers 99 \
        --alias chat --jinja
  fi
else
  # PER-163 retry: real fallback to the legacy Gemma-4 GGUF if it's on
  # disk. Lets the script boot on a fresh machine before any model
  # is registered in the DB. Logs the fact loudly so it's obvious
  # the script picked a default instead of the operator's choice.
  GEMMA_LEGACY="$MODELS_DIR/gemma-4-E4B-it-Q4_K_M.gguf"
  if [[ -f "$GEMMA_LEGACY" ]]; then
    echo "  ⚠ Backend chat-model config unavailable — falling back to"
    echo "    legacy GGUF $GEMMA_LEGACY"
    MMPROJ_LEGACY="$MODELS_DIR/mmproj-F16.gguf"
    MMPROJ_FLAG=""
    if [[ -f "$MMPROJ_LEGACY" ]]; then
      MMPROJ_FLAG="--mmproj $MMPROJ_LEGACY"
    fi
    start_service "llama-server (chat :8080 = legacy gemma)" \
      "$PIDDIR/ta-llama-chat.pid" "$LOGDIR/ta-llama-chat.log" \
      llama-server \
        --model "$GEMMA_LEGACY" \
        $MMPROJ_FLAG \
        --host 0.0.0.0 --port 8080 \
        --ctx-size 32768 --n-gpu-layers 99 \
        --chat-template chatml \
        --alias chat
  else
    echo "  ⚠ Backend chat-model config unavailable (backend down or no"
    echo "    active vision model) AND no legacy GGUF on disk."
    echo "    Skipping :8080 — set is_active=true on a row in llm_models"
    echo "    and re-run, or drop a model file at $GEMMA_LEGACY."
  fi
fi

# 2. Qwen3-Embedding-8B (llama-server on :8082)
EMBED_GGUF="$MODELS_DIR/Qwen3-Embedding-8B-Q8_0.gguf"
if [[ -f "$EMBED_GGUF" ]]; then
  start_service "llama-server (Qwen3-Embedding :8082)" \
    "$PIDDIR/ta-llama-embed.pid" "$LOGDIR/ta-llama-embed.log" \
    llama-server \
      --model "$EMBED_GGUF" \
      --host 0.0.0.0 --port 8082 \
      --embeddings --pooling last \
      --ubatch-size 8192 --batch-size 8192 --ctx-size 32768 \
      --n-gpu-layers 99 \
      --alias embeddings
else
  echo "  ⚠ Qwen3-Embedding GGUF not found at $EMBED_GGUF — RAG embeddings won't work"
fi

# 3. Qwen3-8B Instruct for RAG answer generation (llama-server on :8083)
# Better than Gemma for Russian Q&A over retrieved chunks.
RAG_LLM_GGUF="$MODELS_DIR/Qwen3-8B-Q8_0.gguf"
if [[ -f "$RAG_LLM_GGUF" ]]; then
  start_service "llama-server (Qwen3-8B RAG :8083)" \
    "$PIDDIR/ta-llama-rag.pid" "$LOGDIR/ta-llama-rag.log" \
    llama-server \
      --model "$RAG_LLM_GGUF" \
      --host 0.0.0.0 --port 8083 \
      --ctx-size 32768 --n-gpu-layers 99 \
      --chat-template chatml \
      --alias rag-chat
else
  echo "  ⚠ Qwen3-8B GGUF not found at $RAG_LLM_GGUF — RAG answers will use Gemma (worse quality)"
fi

# 4. Qwen3-Reranker-8B for two-stage RAG retrieval (llama-server on :8084)
# Over-fetches top-N from embedding search, then reranks for precision.
RERANKER_GGUF="$MODELS_DIR/Qwen3-Reranker-8B-Q8_0.gguf"
if [[ -f "$RERANKER_GGUF" ]]; then
  start_service "llama-server (Qwen3-Reranker :8084)" \
    "$PIDDIR/ta-llama-rerank.pid" "$LOGDIR/ta-llama-rerank.log" \
    llama-server \
      --model "$RERANKER_GGUF" \
      --host 0.0.0.0 --port 8084 \
      --reranking --pooling rank \
      --ctx-size 8192 --n-gpu-layers 99 \
      --alias reranker
else
  echo "  ⚠ Qwen3-Reranker GGUF not found — RAG will skip reranking stage"
fi

# 5. Explorer worker (PER-48: synthetic mode + docker worker removed)
if [[ -d "$EXPLORER_DIR/.venv" ]]; then
  # Worker must run from the explorer directory so `python -m explorer.worker`
  # finds the package. We use env -C (change dir) + TA_LLM_BASE_URL so it
  # can reach the host llama-server for AI/Hybrid modes.
  #
  # PER-51: corporate security suites (Norton 360 etc.) can configure a
  # system-wide HTTP proxy via macOS ``scutil --proxy``. Worker uses
  # ``httpx.AsyncClient(trust_env=False)`` to bypass it (see worker.py
  # BackendClient docstring). No env-var manipulation needed here.
  start_service "explorer worker" \
    "$PIDDIR/ta-worker.pid" "$LOGDIR/ta-worker.log" \
    env -C "$EXPLORER_DIR" \
      TA_LLM_BASE_URL="http://localhost:${LLM_PORT:-8080}" \
      "$EXPLORER_DIR/.venv/bin/python" -m explorer.worker \
        --backend-url "http://localhost:${BACKEND_PORT:-8000}" \
        --worker-token "$WORKER_TOKEN" \
        -v
else
  echo "  ⚠ Explorer venv not found at $EXPLORER_DIR/.venv — runs will stay pending"
  echo "    Run: cd $EXPLORER_DIR && python -m venv .venv && .venv/bin/pip install -r requirements.txt"
fi

echo ""
echo "=== Done ==="
echo ""
echo "Open http://localhost:${FRONTEND_PORT:-3000} in your browser."
echo "Create a new run → the worker will pick it up, launch the app,"
echo "start the simulator mirror, and stream everything to the UI."
echo ""
echo "To stop host services:  make stop"
echo "To view logs:           tail -f /tmp/ta-*.log"
