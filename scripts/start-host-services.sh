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

# 1. Gemma chat (llama-server on :8080)
GEMMA_GGUF="$MODELS_DIR/gemma-4-E4B-it-Q4_K_M.gguf"
if [[ -f "$GEMMA_GGUF" ]]; then
  MMPROJ_GGUF="$MODELS_DIR/mmproj-F16.gguf"
  MMPROJ_FLAG=""
  if [[ -f "$MMPROJ_GGUF" ]]; then
    MMPROJ_FLAG="--mmproj $MMPROJ_GGUF"
    echo "  ✓ Vision enabled (mmproj found)"
  fi

  # Gemma-4 has a built-in "thinking" chat template that emits <think>...</think>
  # and dumps the answer into `reasoning_content` — which broke our RAG endpoint.
  # Force chatml to keep the answer in `content`. Also expand context to 32K so
  # RAG can stuff full documents into the prompt.
  start_service "llama-server (Gemma chat :8080)" \
    "$PIDDIR/ta-llama-chat.pid" "$LOGDIR/ta-llama-chat.log" \
    llama-server \
      --model "$GEMMA_GGUF" \
      $MMPROJ_FLAG \
      --host 0.0.0.0 --port 8080 \
      --ctx-size 32768 --n-gpu-layers 99 \
      --chat-template chatml \
      --alias chat
else
  echo "  ⚠ Gemma GGUF not found at $GEMMA_GGUF — AI/Hybrid modes won't work"
  echo "    Run: make download-models"
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
