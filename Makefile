# testing-agent-infra — convenience targets.
#
# These targets are meant to be run from the testing-agent-infra directory on
# a developer's laptop or on a deployment host. They are NOT run inside any
# container; they just orchestrate things that touch the host filesystem or
# the docker daemon.

SHELL := bash
.DEFAULT_GOAL := help

# Load .env so `make` targets see LLM_MODELS_DIR etc. Missing .env is fine —
# scripts that actually need the vars will error out themselves with a clear
# message.
ifneq (,$(wildcard .env))
  include .env
  export
endif

.PHONY: help
help:
	@echo ""
	@echo "  make start             🚀 Запустить всё (Docker + LLM + worker + iOS)"
	@echo "  make stop              ⏹  Остановить хостовые сервисы (Docker остаётся)"
	@echo "  make down              ⬇  Остановить всё включая Docker"
	@echo "  make logs              📋 Логи docker compose (Ctrl+C для выхода)"
	@echo "  make host-logs         📋 Логи хостовых сервисов (worker, LLM)"
	@echo "  make download-models   📦 Скачать Gemma 4 E4B + Qwen 3.5 GGUFs"
	@echo ""

# ---------- Primary workflow ----------

.PHONY: start
start: up
	@bash scripts/start-host-services.sh

.PHONY: stop
stop:
	@bash scripts/stop-host-services.sh

.PHONY: down
down: stop
	docker compose down

# ---------- Docker ----------

.PHONY: up
up:
	docker compose up -d

.PHONY: logs
logs:
	docker compose logs -f

.PHONY: host-logs
host-logs:
	@tail -f /tmp/ta-llama-chat.log /tmp/ta-llama-embed.log /tmp/ta-worker.log 2>/dev/null || echo "No host logs yet — run 'make start' first"

# ---------- Setup ----------

.PHONY: download-models
download-models:
	@bash scripts/download-models.sh
