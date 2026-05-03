# Демо-бандл «Перевод выше лимита»

Содержит три артефакта для демо «агент находит баг через RAG-сверку
со спекой» (PER-43):

1. **`spec.md`** — спецификация приложения. Загружается в RAG.
2. **TestApp с экраном `Transfer`** — собирается из репо
   `/Users/pavelafonin/Projects/AI/TestApp` (см. ниже).
3. **Сценарий «Перевод выше лимита (демо)»** — сидится автоматически
   при старте backend (`seed_demo_scenario`).

## Известный баг

В `TransferScreen.tsx::validateAmount`:

```ts
if (num > 100000) {
  setError('Неверная карта');  // ← BUG
  return false;
}
```

По спеке (раздел «4. Перевод») сообщение должно быть **«Превышен
лимит»**. Намеренное расхождение для RAG-сверки.

## Подготовка к демо (5 шагов)

### 1. Собрать TestApp

```bash
cd /Users/pavelafonin/Projects/AI/TestApp
npm install   # если ещё не установлено

# iOS .app.zip:
cd ios && xcodebuild \
  -workspace TestApp.xcworkspace \
  -scheme TestApp \
  -configuration Release \
  -sdk iphonesimulator \
  -derivedDataPath build
cd build/Build/Products/Release-iphonesimulator
zip -r TestApp-Release.app.zip TestApp.app
```

Получаем `TestApp-Release.app.zip` (bundle_id
`org.reactjs.native.example.TestApp`).

### 2. Загрузить .app.zip в Маркова

UI → New Run → «Загрузить приложение» → выбрать
`TestApp-Release.app.zip`.

### 3. Загрузить spec.md в knowledge

UI → Admin → База знаний → «+ Загрузить документ» →
`testing-agent-infra/demo/spec.md`. Дождаться индексации
(10-20 секунд — embeddings + reranker).

### 4. Привязать сценарий к спеке

UI → Сценарии → выбрать «Перевод выше лимита (демо)» →
поле «Спека (документы базы знаний)» → выбрать `spec.md` → Сохранить.

### 5. Заполнить test_data

UI → Тестовые данные → добавить:

- `email` = `demo@bank.local`
- `password` = `Demo2026!`

(значения нужны только чтобы LoginScreen TestApp пропустил —
он не валидирует credentials, любая строка проходит).

## Запуск демо-сценария

UI → Запуски → «Новый запуск» → выбрать загруженный TestApp →
сценарий «Перевод выше лимита (демо)» → mode=hybrid → Старт.

## Что должно произойти

- Шаги 1–5 пройдут как `scenario.step_completed`.
- Шаг 6 («Перевести 200 000 ₽»):
  - `tap` на кнопку выполнится (`ok=true`),
  - но RAG-сверка `expected_result` («Превышен лимит» по спеке) с
    наблюдаемым «Неверная карта» даст `matched=false`,
  - PER-37 переведёт шаг в `step_failed` с reason `spec_mismatch`,
  - PER-37 запостит P1 defect kind=`spec_mismatch` с цитатой из спеки
    в `llm_analysis_json`.
- На странице `/runs/{id}/results`:
  - В timeline (PER-25) у шага 6 пилл «✗ спека» (PER-36).
  - В дефектах (PER-26) карточка с расширяемой секцией «Анализ модели»
    показывает цитату спеки.

## Если приложение не собирается

Можно демонстрировать на готовом TestApp без экрана Transfer —
RAG-сверка тогда работать не будет, но scenario runner / timeline /
data drawer покажут себя на существующем Login → Profile flow.
