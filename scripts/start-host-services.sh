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

# PER-108: bind llama-server processes to loopback by default. The
# previous default (literal --host 0.0.0.0) made every model server
# reachable from the LAN (cafe Wi-Fi, hotel, demo venue) without
# auth — anyone on the same network could submit prompts and exhaust
# the M2 Max. Set LLAMA_BIND_HOST=0.0.0.0 explicitly in your shell
# if you really need LAN access (e.g. testing from a second machine).
LLAMA_BIND_HOST="${LLAMA_BIND_HOST:-127.0.0.1}"

# PER-109: list of every PID file this script manages, so the
# pre-flight sweep below can purge stale entries for services that
# might not actually start on this invocation (e.g. chat-model GGUF
# absent, grounder not configured). ``already_running`` already
# cleans up at the per-service check, but only for services we go on
# to launch — a missing chat model would leave ta-llama-chat.pid
# pointing at a long-dead PID forever.
MANAGED_PIDFILES=(
  "$PIDDIR/ta-llama-chat.pid"
  "$PIDDIR/ta-llama-grounder.pid"
  "$PIDDIR/ta-llama-embed.pid"
  "$PIDDIR/ta-llama-rag.pid"
  "$PIDDIR/ta-llama-rerank.pid"
  "$PIDDIR/ta-worker.pid"
  "$PIDDIR/ta-filebeat-bouncer.pid"
)
for pf in "${MANAGED_PIDFILES[@]}"; do
  if [[ -f "$pf" ]]; then
    pid=$(<"$pf")
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pf"
    fi
  fi
done

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
  # PER-165: ``supports_thinking`` arrives as a Python truthiness:
  # ``True`` → model is built to use the reasoning channel and the
  # worker is expected to handle ``reasoning_content`` separately;
  # ``False`` (or missing) → collapse thinking back into ``content``
  # so the JSON-schema parse sees actual tokens instead of an empty
  # string. The 3-way ``--reasoning on/off/auto`` switch on
  # llama-server is too literal — when ``supports_thinking=True``
  # we want llama-server's *default* behaviour (whatever the chat
  # template prescribes), not a forced override.
  CHAT_THINKING_RAW=$(echo "$CHAT_CFG_JSON" | python3 -c 'import sys,json;v=json.load(sys.stdin).get("supports_thinking");print("true" if v else "false")')
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
  # PER-165 v2: bind thinking-channel behaviour to the passport.
  # When the chat template auto-enables thinking mode (Gemma 4,
  # Qwen 3.5/3.6, DeepSeek-R1 family) and the worker isn't built
  # to extract ``reasoning_content``, generated tokens vanish into
  # the thinking channel and ``content`` arrives empty — worker
  # logs ``llm_no_decision`` even though the model actually
  # answered. ``--reasoning off`` collapses thinking back into
  # ``content`` and makes such models work out of the box.
  #
  # For ``supports_thinking=True`` we deliberately emit NO flag —
  # llama-server's default ``auto`` keeps the chat template's own
  # decision, which is what the operator opted into by setting the
  # passport bit.
  REASONING_FLAG=""
  if [[ "$CHAT_THINKING_RAW" == "false" ]]; then
    REASONING_FLAG="--reasoning off"
    echo "    Thinking: collapsed to content (--reasoning off, passport supports_thinking=false)"
  else
    echo "    Thinking: passport supports_thinking=true → leaving llama-server default"
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
        $REASONING_FLAG \
        --host "$LLAMA_BIND_HOST" --port 8080 \
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
        --host "$LLAMA_BIND_HOST" --port 8080 \
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

# 1a. Grounder llama-server (default :8081 = UI-TARS-1.5-7B)
#
# PER-164: dense general-purpose VLMs (Qwen3-VL/Gemma 4/Qwen 3.6 — see
# PER-163 retry #2 comparison) all fail at canvas-keypad grounding.
# We plug in a dedicated grounder model on a second port; the worker
# routes ``tap_at`` with ``element_id=null`` decisions to it instead
# of trusting the chat-LLM's own pixel guess. Endpoint, GGUF, port,
# and image_min_tokens all come from the grounder_models DB row, so
# swapping UI-TARS for Molmo/ShowUI is one UPDATE + restart away.
#
# Silently skipped (no fallback) when there is no active grounder in
# the DB — the worker is expected to fall back to coordinates from
# the chat-LLM in that case, which is the pre-PER-164 behaviour.

GRD_CFG_JSON="$(curl -sS \
  -H "Authorization: Bearer ${WORKER_TOKEN}" \
  http://localhost:8000/api/internal/grounder/config 2>/dev/null || true)"

if echo "$GRD_CFG_JSON" | python3 -c 'import sys, json; json.loads(sys.stdin.read())["name"]' >/dev/null 2>&1; then
  export MODELS_DIR
  GRD_NAME=$(echo "$GRD_CFG_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["name"])')
  GRD_GGUF=$(echo "$GRD_CFG_JSON" | python3 -c 'import sys,json,os;p=json.load(sys.stdin)["gguf_path"];print(p.replace("/var/lib/llm-models",os.environ["MODELS_DIR"]))' )
  GRD_MMPROJ=$(echo "$GRD_CFG_JSON" | python3 -c 'import sys,json,os;p=json.load(sys.stdin).get("mmproj_path");print((p or "").replace("/var/lib/llm-models",os.environ["MODELS_DIR"]))' )
  GRD_PORT=$(echo "$GRD_CFG_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("endpoint_port") or 8081)')
  GRD_CTX=$(echo "$GRD_CFG_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("max_context_tokens") or 16384)')
  GRD_IMG_MIN=$(echo "$GRD_CFG_JSON" | python3 -c 'import sys,json;v=json.load(sys.stdin).get("image_min_tokens");print(v if v else "")')

  GRD_MMPROJ_FLAG=""
  if [[ -n "$GRD_MMPROJ" && -f "$GRD_MMPROJ" ]]; then
    GRD_MMPROJ_FLAG="--mmproj $GRD_MMPROJ"
  fi
  GRD_IMG_MIN_FLAG=""
  if [[ -n "$GRD_IMG_MIN" ]]; then
    GRD_IMG_MIN_FLAG="--image-min-tokens $GRD_IMG_MIN"
  fi

  if [[ ! -f "$GRD_GGUF" ]]; then
    echo "  ⚠ Grounder GGUF not on disk: $GRD_GGUF — skipping :$GRD_PORT"
  else
    echo "  ✓ Grounder from backend: $GRD_NAME (port :$GRD_PORT)"
    start_service "llama-server (grounder :$GRD_PORT = $GRD_NAME)" \
      "$PIDDIR/ta-llama-grounder.pid" "$LOGDIR/ta-llama-grounder.log" \
      llama-server \
        --model "$GRD_GGUF" \
        $GRD_MMPROJ_FLAG \
        $GRD_IMG_MIN_FLAG \
        --reasoning off \
        --host "$LLAMA_BIND_HOST" --port "$GRD_PORT" \
        --ctx-size "$GRD_CTX" --n-gpu-layers 99 \
        --alias grounder --jinja
  fi
else
  echo "  · No active grounder in DB — tap_at will use chat-LLM coords (pre-PER-164 path)"
fi

# 2. Qwen3-Embedding-8B (llama-server on :8082)
EMBED_GGUF="$MODELS_DIR/Qwen3-Embedding-8B-Q8_0.gguf"
if [[ -f "$EMBED_GGUF" ]]; then
  start_service "llama-server (Qwen3-Embedding :8082)" \
    "$PIDDIR/ta-llama-embed.pid" "$LOGDIR/ta-llama-embed.log" \
    llama-server \
      --model "$EMBED_GGUF" \
      --host "$LLAMA_BIND_HOST" --port 8082 \
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
      --host "$LLAMA_BIND_HOST" --port 8083 \
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
      --host "$LLAMA_BIND_HOST" --port 8084 \
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


# PER-163 retry #2: poke Filebeat into re-reading host log files.
#
# Docker Desktop's gRPC-FUSE bind-mount on macOS caches a snapshot of
# /tmp at container-start time. When start-host-services truncates or
# replaces /tmp/ta-llama-*.log (new inode after the host process
# restarts), the Filebeat container keeps seeing the stale inode and
# never picks up the live host file. Symptom: markov-llama-* index
# stays frozen at the time the container booted, even though host
# llama-server keeps writing.
#
# Cleanest fix is to recreate the container so the FUSE mount
# refreshes. Cheaper than tearing it down/up: kill the harvester
# state and let docker restart re-attach. We do the restart only when
# docker is reachable and the ta-filebeat container exists — otherwise
# the script still completes cleanly for ad-hoc local dev.
if docker inspect ta-filebeat >/dev/null 2>&1; then
  echo "  ⟳ Restarting ta-filebeat so it re-mounts the host /tmp view"
  docker restart ta-filebeat >/dev/null 2>&1 || \
    echo "    (restart failed — Filebeat may keep showing stale llama logs)"
fi

# PER-163 retry #3: VirtioFS bounce loop.
#
# Even after the one-shot restart above, Docker Desktop's VirtioFS
# does not propagate further host appends through the bind-mounted
# ``/private/tmp`` view — the container keeps its initial snapshot
# of each file's size/mtime and Filebeat reads against that frozen
# view. Empirically: host file grows from 38KB → 44KB, container
# still sees 38KB, fresh ``llama-server`` lines never reach ELK.
# This is a known limitation of macOS Docker Desktop file sharing
# (independent of close_inactive / scan_frequency tweaks — VirtioFS
# returns cached stat() even after open()+close()+reopen()).
#
# The only workaround that actually works is to recreate the FUSE
# snapshot periodically by restarting the container. We do it in a
# background loop at 60s cadence — short enough that grounding
# audit lag stays observable, long enough that the ~3s restart
# downtime is a tiny fraction of uptime. The bouncer becomes one
# more managed service in the PIDS/ scheme so ``stop-host-services``
# kills it cleanly.
if docker inspect ta-filebeat >/dev/null 2>&1; then
  start_service "filebeat-bouncer (VirtioFS workaround)" \
    "$PIDDIR/ta-filebeat-bouncer.pid" "$LOGDIR/ta-filebeat-bouncer.log" \
    bash -c 'while true; do sleep 60; docker restart ta-filebeat >/dev/null 2>&1 || true; done'
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
