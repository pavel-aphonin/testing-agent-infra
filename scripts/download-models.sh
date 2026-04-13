#!/usr/bin/env bash
# Bootstrap the two pre-installed LLM models into the shared bind-mount.
#
# This script is idempotent: it skips files that already exist with a
# non-zero size, so rerunning after a partial download just resumes the
# missing ones. The resulting filenames MUST match what app/seed.py
# inserts into llm_models.gguf_path / mmproj_path — otherwise llama-swap
# will spawn llama-server with a path that doesn't exist on disk.
#
# Why huggingface-cli and not `curl`:
#   - resumes partial downloads on reconnect
#   - validates SHAs from the HF Hub
#   - chunked parallel transfer for large files (the 22 GB Qwen shard)
#
# Why `huggingface-cli download` with `local-dir` and not the new
# `hf download` subcommand: as of HF Hub 0.24 the `hf` CLI is still
# under active rename and some distros only ship the legacy
# `huggingface-cli` entrypoint. Both accept the same flags.

set -euo pipefail

# --- resolve LLM_MODELS_DIR from .env (relative paths are fine) ---

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; . .env; set +a
fi

: "${LLM_MODELS_DIR:?LLM_MODELS_DIR is not set. Create testing-agent-infra/.env from .env.example first.}"

# Resolve relative paths against the infra repo root so the script works
# regardless of the caller's cwd.
if [[ "$LLM_MODELS_DIR" != /* ]]; then
  LLM_MODELS_DIR="$REPO_ROOT/$LLM_MODELS_DIR"
fi

mkdir -p "$LLM_MODELS_DIR"
echo "[download-models] writing to $LLM_MODELS_DIR"

# --- check for huggingface-cli ---

if ! command -v huggingface-cli >/dev/null 2>&1; then
  cat <<'EOF' >&2
[download-models] huggingface-cli not found on PATH.

Install it with one of:

    pip install "huggingface_hub[cli]"
    pipx install "huggingface_hub[cli]"

Then re-run `make download-models`.
EOF
  exit 1
fi

# --- download helper ---------------------------------------------------------
#
# Takes: repo_id, filename, target_filename (rename after download), size_human
# Skips if target_filename already exists and is non-empty.
#
# `huggingface-cli download ... --local-dir ... <filename>` places the file
# at "$LLM_MODELS_DIR/$filename" preserving the original name. We then rename
# it to the target name expected by the seed (handles the small
# `gemma-4-E4B-it-` vs `gemma-4-E4B-it-mmproj-` prefixing we do for mmprojs).

dl() {
  local repo_id="$1"
  local source_name="$2"
  local target_name="$3"
  local size_hint="$4"
  local target_path="$LLM_MODELS_DIR/$target_name"

  if [[ -s "$target_path" ]]; then
    local size
    size=$(du -h "$target_path" | awk '{print $1}')
    echo "[download-models] ✓ $target_name ($size) already present — skipping"
    return 0
  fi

  echo "[download-models] ↓ $repo_id :: $source_name  (~$size_hint, target: $target_name)"

  # --local-dir-use-symlinks=False gives us an actual file copy rather than
  # a symlink into the HF cache — the llm container needs to see a regular
  # file at the path the seed writes into llm_models.gguf_path.
  huggingface-cli download "$repo_id" "$source_name" \
    --local-dir "$LLM_MODELS_DIR" \
    --local-dir-use-symlinks False \
    --quiet

  # If source and target names differ, rename in place.
  if [[ "$source_name" != "$target_name" ]]; then
    mv "$LLM_MODELS_DIR/$source_name" "$target_path"
  fi

  local final_size
  final_size=$(du -h "$target_path" | awk '{print $1}')
  echo "[download-models] ✓ $target_name ($final_size)"
}

# --- Gemma 4 E4B -------------------------------------------------------------

dl "unsloth/gemma-4-E4B-it-GGUF" \
   "gemma-4-E4B-it-Q4_K_M.gguf" \
   "gemma-4-E4B-it-Q4_K_M.gguf" \
   "5.0 GB"

# Unsloth publishes the mmproj alongside the main weights as a generic
# `mmproj-F16.gguf`. Rename on download so both mmprojs live under
# distinguishable filenames in the shared models dir.
dl "unsloth/gemma-4-E4B-it-GGUF" \
   "mmproj-F16.gguf" \
   "gemma-4-E4B-it-mmproj-F16.gguf" \
   "0.8 GB"

# --- Qwen 3.5 35B-A3B --------------------------------------------------------

dl "unsloth/Qwen3.5-35B-A3B-GGUF" \
   "Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf" \
   "Qwen3.5-35B-A3B-UD-Q4_K_XL.gguf" \
   "22 GB"

dl "unsloth/Qwen3.5-35B-A3B-GGUF" \
   "mmproj-F16.gguf" \
   "Qwen3.5-35B-A3B-mmproj-F16.gguf" \
   "2 GB"

echo ""
echo "[download-models] done. Contents of $LLM_MODELS_DIR:"
ls -lh "$LLM_MODELS_DIR" | grep -E '\.gguf$' || true
