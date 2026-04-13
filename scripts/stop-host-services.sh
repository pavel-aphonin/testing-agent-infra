#!/usr/bin/env bash
# Stop all host-side services started by start-host-services.sh.
# Reads PIDs from /tmp/ta-*.pid, sends SIGTERM, waits briefly, then
# SIGKILL if still alive. Idempotent — safe to run even if nothing is up.

set -euo pipefail

PIDDIR="/tmp"
SERVICES=(
  "ta-llama-chat:llama-server (Gemma chat)"
  "ta-llama-embed:llama-server (bge embeddings)"
  "ta-worker:explorer worker"
)

echo "=== Stopping host services ==="

for entry in "${SERVICES[@]}"; do
  IFS=: read -r prefix label <<< "$entry"
  pidfile="$PIDDIR/$prefix.pid"
  if [[ -f "$pidfile" ]]; then
    pid=$(<"$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      # Wait up to 3s for graceful shutdown
      for _ in 1 2 3; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      # Force kill if still alive
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
      echo "  ✓ $label stopped (was pid $pid)"
    else
      echo "  · $label was not running"
    fi
    rm -f "$pidfile"
  else
    echo "  · $label — no pidfile"
  fi
done

# Also kill any orphan SimMirror (worker's child process)
SIM_PIDS=$(pgrep -f "SimMirror --port" 2>/dev/null || true)
if [[ -n "$SIM_PIDS" ]]; then
  echo "$SIM_PIDS" | xargs kill 2>/dev/null || true
  echo "  ✓ SimMirror stopped"
fi

echo ""
echo "Host services stopped. Docker containers are still running."
echo "To stop everything:  make down"
