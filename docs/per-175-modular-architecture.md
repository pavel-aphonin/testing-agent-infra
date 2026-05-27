# PER-175: 12-module agent architecture — operator runbook

Replaces the previous one-giant-LLM setup with 11 specialised models
each owning one role in the testing-agent pipeline. The operator picks
which catalog model fills each role via the admin UI; the worker reads
the assignment at run start and routes per-role calls accordingly.

## The 11 roles

| Role | What it does | Recommended model |
|---|---|---|
| `PLANNER` | Picks next action on current screen | mPLUG/GUI-Owl-1.5-4B-Instruct (2.5 GB, +vision) |
| `GROUNDER` | Maps text target → pixel coords | ByteDance/UI-TARS-1.5-7B (4.4 GB, +vision) |
| `SAFETY_GUARD` | Blocks destructive actions pre-dispatch | meta-llama/Llama-Guard-3-1B (0.9 GB) |
| `AMBIGUITY_RESOLVER` | Picks canonical path once per scenario | Qwen/Qwen3-4B-Instruct-2507 (2.5 GB) |
| `MEMORY` | Embedding vectors for similar-screen retrieval | Qwen/Qwen3-Embedding-0.6B (0.6 GB) |
| `REFLECTION` | Periodic review of recent history | multiplex with PLANNER |
| `REWARD_CRITIC` | Scores trajectories for PUCT priors | multiplex with PLANNER |
| `SCREEN_PARSER` | OCR + element bboxes from screenshot | OmniParser-v2 (PyTorch microservice) |
| `DYNAMIC_PERCEIVER` | "Did the screen actually change?" | SigLIP2 (PyTorch microservice) |
| `CONTEXT_IDENTIFIER` | Zero-shot label for current screen | DeBERTa-v3 (ONNX) |
| `GROUNDING_VERIFIER` | Logprobs calibration on Planner choice | optional — leave NULL for logprobs-only mode |

### Roles without a GGUF

The last four roles need PyTorch microservices that are not part of
this iteration. They stay **unassigned** — the worker falls through to
its legacy behaviour for those concerns.

## First-run setup

1. **Download GGUFs** via `/admin/models` browser-based downloader
   (2-3 minutes per model on a fast connection), or via the `huggingface_hub`
   Python API into `volumes/llm-models/`.

2. **Register each model** in the catalog via `/admin/models`. Set
   `supported_roles` so the role picker filters correctly (e.g.
   GUI-Owl gets `PLANNER, REFLECTION, REWARD_CRITIC`).

3. **Assign roles** in `/admin/module-assignments`. Picker for each
   row only shows models that declare support for that role.

4. **Start the stack** via `make start` from `testing-agent-infra/`.
   Worker logs `PER-175 role inventory:` on every run start — verify
   every required role has a model.

## VRAM budget

| Tier | Resident | Cold-start penalty | Use case |
|---|---|---|---|
| All hot | ~14 GB | 0 sec | dev rig with 24 GB+ VRAM |
| Hot path + lazy others | ~8.5 GB | 3-8 sec for rare roles | recommended — fits 16 GB Macs |
| Truly lazy (low TTL) | 2-5 GB peak | +10-15 sec per step | <8 GB, accept slow runs |

Hot path = PLANNER + GROUNDER + SAFETY (called every step). Others
(AMBIGUITY, MEMORY) are sub-second-rare and tolerate cold loads.

Adjust per-model TTL in the generated `llama-swap.yaml` (regenerated
on every `/admin/models` change). Default 600 sec keeps a model
resident for 10 minutes after the last call.

## Troubleshooting

**Worker logs `(unset)` for a role I assigned.**
The worker caches role assignments for 5 min. Wait, restart the
worker, or trigger a fresh probe by creating a new run.

**`PER-196 Ambiguity probe errored (non-fatal)` in worker log.**
The Ambiguity role is unassigned or the model server is down.
Non-fatal — the run proceeds with the raw goal. Check
`/admin/module-assignments` and the assigned model's llama-server
process.

**Russian output from Ambiguity looks corrupted.**
Qwen3-4B-Instruct-2507 is verified multilingual but if you swapped
to a different model, check its model card. Vikhr-Nemo-12B-Instruct-R
is the recommended fallback — native Russian fine-tune, same agent
shape works.

**Cold-start latency dominates every step (>15 sec overhead).**
You're in the "Truly lazy" tier. Either bump per-model TTL in
`llama-swap.yaml` to keep PLANNER + GROUNDER hot, or reassign hot
roles to smaller models.

**`SAFETY_GUARD` blocks a legitimate action.**
Llama-Guard-3 has a low false-positive rate but banking flows that
look like financial transactions occasionally trip it. Either
unassign SAFETY_GUARD via the UI or swap to a less strict model.

## Migration notes

PER-192 deactivates the old `gemma-4-e4b` and `qwen3.5-35b-a3b` catalog
rows. They're not deleted — operators can re-activate via
`/admin/models` if a rollback is needed. PER-193 seeds all 11
module_assignments rows with NULL on a fresh DB; pick assignments
via the UI before the first run.

## Related issues

- PER-191 — HF availability validation for the roster
- PER-192 — drop old monolith models from seed
- PER-193 — ModuleAssignment schema + admin endpoint
- PER-194 — admin UI for picking assignments
- PER-195 — worker resolver + run-start inventory probe
- PER-196 — per-role agent wrappers + Ambiguity scenario probe
