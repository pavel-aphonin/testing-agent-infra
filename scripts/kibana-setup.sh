#!/usr/bin/env bash
# Bootstrap Kibana (PER-118):
#   * waits until Kibana answers
#   * imports the data view + saved searches from elk/kibana-objects.ndjson
#   * marks the Markov data view as the default
#
# Idempotent — re-running just overwrites the same saved-object ids.

set -euo pipefail
cd "$(dirname "$0")/.."

KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
BUNDLE="elk/kibana-objects.ndjson"
DV_ID="markov-default-data-view"

if [[ ! -f "$BUNDLE" ]]; then
    echo "ERROR: $BUNDLE not found — нечего импортировать" >&2
    exit 1
fi

echo "→ Ждём пока Kibana отвечает на ${KIBANA_URL}..."
for i in $(seq 1 60); do
    if curl -sf "${KIBANA_URL}/api/status" >/dev/null 2>&1; then
        echo "  ✓ Kibana жива."
        break
    fi
    sleep 2
    if [[ $i -eq 60 ]]; then
        echo "  ✗ Kibana не отвечает за 120 секунд. Проверь docker compose --profile logging ps" >&2
        exit 1
    fi
done

echo "→ Импортируем data view + saved searches..."
RESP=$(curl -sS -X POST "${KIBANA_URL}/api/saved_objects/_import?overwrite=true" \
    -H "kbn-xsrf: true" \
    --form file=@"${BUNDLE}")
SUCCESS=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success', False))" 2>/dev/null || echo "?")
COUNT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('successCount', 0))" 2>/dev/null || echo "?")
echo "  Импортировано объектов: ${COUNT}, success=${SUCCESS}"

if [[ "$SUCCESS" != "True" && "$SUCCESS" != "true" ]]; then
    echo "  ✗ Ошибка импорта. Полный ответ:"
    echo "$RESP"
    exit 1
fi

echo "→ Делаем markov-* data view дефолтным..."
curl -sS -X POST "${KIBANA_URL}/api/data_views/default" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    --data "{\"data_view_id\":\"${DV_ID}\",\"force\":true}" >/dev/null
echo "  ✓ Готово."

cat <<EOF

═══════════════════════════════════════════════════════════════
Kibana настроена.

→ Открой:   ${KIBANA_URL}
→ Меню (☰) → Analytics → Discover
→ Сверху слева — выпадающий список с сохранёнными запросами:
     • Markov • Все логи
     • Markov • Только ошибки
     • Markov • Только backend
     • Markov • Только worker
     • Markov • LLM-решения goal-узлов
   Выбери любой — фильтр применится автоматически.
→ Чтобы строить свои — слева список полей: service, log.level,
   logger, message, run_id (когда в логе есть). Кликай по значению
   "+" чтобы добавить в фильтр.

Чтобы перенастроить с нуля:
   make kibana-setup
═══════════════════════════════════════════════════════════════
EOF
