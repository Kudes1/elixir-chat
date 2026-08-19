# Итерация 1 — Sequence + Replay фундамент

Статус: **завершено**

## Отчёт о выполнении

* `Outbox.list_since/3` и `Outbox.list_events_since/2` (`lib/elixir_chat/chat/outbox.ex`) — читают `outbox_events` с курсором `id > since_id`, батчами; `list_events_since/2` объединяет несколько партиций по разным курсорам одним запросом (динамический `or_where`). Индекс `(partition_key, id)` уже существовал в БД — миграция не понадобилась.
* `Outbox.partition_key/1` вынесен как публичная функция (раньше строка `"channel:#{id}"` была захардкожена только в одном месте) — переиспользуется и в `event_changeset/3`, и в новом коде `chat_live.ex`.
* `OutboxPublisher.publish/1` (`lib/elixir_chat/outbox_publisher.ex`) — добавлен один новый, полностью аддитивный broadcast `{:event_sequence, partition_key, event.id}` каждому получателю (member/DM-участнику), рядом с уже существующими broadcast'ами. Существующие broadcast-кортежи (`{event_type, message}` и т.д.) не тронуты.
* `ChatLive.mount/3` (`lib/elixir_chat_web/live/chat_live.ex`) — читает `last_sequences` из `get_connect_params/1`, считает `@missed_event_count`/`@catching_up?` через `count_missed_events/2` (батчами по 200, capped на 2000 событий за один mount). Новый `handle_info({:event_sequence, ...})` пробрасывает актуальный sequence в браузер через `push_event(socket, "event_seq", ...)`.
* `#chat-shell` в `chat_live.html.heex` получил `data-catching-up`/`data-missed-event-count` — сейчас чисто для наблюдаемости/тестов и как точка опоры для JS state machine в Итерации 2.
* `assets/js/app.js` — курсоры `partition_key => event_seq` хранятся в `localStorage` (`orbit:event-seq:v1`), обновляются по `phx:event_seq`, передаются на каждый коннект/реконнект через `LiveSocket` `params.last_sequences`.

### Тесты
* `test/elixir_chat/chat/outbox_test.exs` (новый, 6 тестов) — порядок/фильтрация по партиции, пагинация большого backlog (25 событий батчами по 7), мердж нескольких партиций с разными курсорами, лимит батча, конкурентная вставка 100 событий в 5 партиций (проверка уникальности id и монотонности порядка на партицию).
* `test/elixir_chat_web/live/chat_live_test.exs` — 3 новых интеграционных теста: catch-up с реальным пропущенным backlog (3 сообщения), "свежий" mount без курсора и без истории, курсор уже на head (0 missed).
* Полный `mix test`: **161/161 passed**, регрессий нет. `mix format --check-formatted` — чисто.

### Известные ограничения (осознанно отложено)
* Курсоры per-partition, а не единый глобальный sequence — соответствует дизайн-решению итерации (см. ниже), но означает, что "общий прогресс" по всем диалогам сразу не выражается одним числом.
* Если пользователь вступил в новый канал, а `last_sequences` в localStorage про него ничего не знает — `since_id` берётся как 0, то есть при первом визите в канал возможен полный replay истории канала (ограничено ретеншном outbox в 7 дней и cap'ом в 2000 событий за mount). Не проблема для этой итерации (assigns пока ни на что не влияют), но стоит учесть в Итерации 2/3.
* `@catching_up?`/`@missed_event_count` пока не используются нигде в UI/логике — это фундамент для Итерации 2 (client state machine) и Итерации 3 (тихий catch-up).
* State machine, звук, сужение push-уведомлений и Oban — сознательно не в этой итерации (см. `tasks/02-*` … `tasks/06-*`).

См. общий контекст в `tasks/00-roadmap.md` перед началом работы.

## Цель

Дать клиенту (браузер + LiveView) durable, resumable понятие "какой последний event я видел" на партицию (канал/DM), и серверный API для получения событий "после X". **Без изменений видимого UX** — ни звука, ни toast, ни state machine ещё нет (это итерации 2-3). Итерация полностью аддитивна и обратно совместима: существующий live-путь (`OutboxDispatcher` → `OutboxPublisher` → PubSub → `handle_info`) не меняется.

## Почему per-partition, а не глобальный sequence

`outbox_events.id` (bigserial) уже монотонно упорядочен **в рамках `partition_key`** (`"channel:#{id}"`), и `OutboxDispatcher` уже полагается на этот порядок для доставки (claims самое старое неопубликованное событие на партицию). Вместо изобретения нового глобального per-user sequence — переиспользовать существующую партиционную модель: resume делается per-partition (канал или DM-канал), что не требует миграции существующих данных и минимально трогает уже работающий `OutboxDispatcher`/`OutboxPublisher`.

## Изменения

**Бэкенд — новые read-функции (`lib/elixir_chat/chat/outbox.ex`, рядом с существующим кодом):**
* `Outbox.list_since(partition_key, since_id, limit)` — `outbox_events` где `partition_key = ^partition_key and id > ^since_id`, `order_by: id`, `limit: ^limit`. Обязательно батчами — чеклист пользователя явно требует поддержку backlog в 50/500 событий несколькими batch, не одним огромным запросом.
* `Outbox.list_events_for_user_since(user_id, cursors)`, где `cursors` — map `%{partition_key => since_id}` для всех каналов/DM пользователя. Список актуальных партиций пользователя переиспользовать из существующей загрузки списка каналов при mount (`chat.ex`, функции, которые уже используются в `ChatLive.mount/3` для сайдбара). Функция возвращает события, сгруппированные так, чтобы можно было и применить их к состоянию, и посчитать `missed_event_count`.
* Не трогать `OutboxDispatcher`/`OutboxPublisher` — они остаются источником доставки в LIVE-режиме как есть.

**Проброс sequence в payload (`lib/elixir_chat/chat/outbox.ex:payload/3`, `outbox_publisher.ex`):**
* Добавить `event_seq` (значение `outbox_events.id`) в payload/broadcast, который получает LiveView через существующие `handle_info` в `chat_live.ex`, — чтобы клиент знал текущий "sequence" каждого применённого события.

**Клиент — хранение курсора (`assets/js/app.js`):**
* JS хранит максимум увиденных `event_seq` per `partition_key` в `localStorage` (аналогично уже существующему паттерну `orbit:push-opt-out:v1`, `app.js:496`).
* При коннекте передавать эти курсоры через `LiveSocket` `params` (сейчас там только `_csrf_token, time_zone`, `app.js:719-735`) — например `last_sequences: {...}`.

**Бэкенд — mount (`chat_live.ex`, рядом с существующим `get_connect_params(socket)` на строке 90):**
* Прочитать переданные курсоры, вызвать `Outbox.list_events_for_user_since/2`, сохранить в assigns `@catching_up?` (bool) и `@missed_event_count` (int) — **пока только для наблюдаемости/тестов**, без влияния на UI. Это точка, которую в итерации 2 использует state machine.

## Тесты

* Unit: `Outbox.list_since/3` — порядок, пагинация батчами, отсутствие пропусков/дублей при постраничном чтении.
* Конкурентный тест: параллельная вставка N событий в одну и разные партиции → идентификаторы уникальны и монотонны в пределах партиции (аналог контрольного теста пользователя на 100 конкурентных событий, `tasks/plan and checklist.md`, "Этап 2").
* Интеграционный (LiveView test): клиент коннектится с сохранённым курсором `since_id = X`, создаются события `X+1..X+50` в нескольких каналах/DM, реконнект с этим курсором → `Outbox.list_events_for_user_since/2` возвращает ровно недостающие события, в правильном порядке, без потерь и дублей (аналог "Этап 3, контрольный тест" пользователя).
* Регрессия: прогнать весь существующий `mix test`, особенно `test/elixir_chat_web/live/chat_live_test.exs` и `test/elixir_chat/chat_test.exs` — обычный live-поток не должен измениться.

## Критические файлы

* `lib/elixir_chat/chat/outbox.ex` — новые read-функции, `event_seq` в payload.
* `lib/elixir_chat/chat/outbox_event.ex` (схема) — проверить, нужна ли миграция (вероятно нет, `id` уже bigserial, уникален и монотонен).
* `lib/elixir_chat/outbox_publisher.ex` — прокинуть `event_seq` дальше в broadcast, который видит `chat_live.ex`.
* `lib/elixir_chat_web/live/chat_live.ex` (mount, `handle_info`) — вычисление `@catching_up?`/`@missed_event_count`.
* `assets/js/app.js` — сохранение курсоров в `localStorage`, передача через `LiveSocket params`.
* Новые тесты: `test/elixir_chat/chat/outbox_test.exs` (новый файл) + дополнения к `test/elixir_chat_web/live/chat_live_test.exs`.

## Verification

* `mix test` — новые unit/integration тесты + весь существующий сьют (регрессия по чату/уведомлениям/presence).
* Ручная проверка через тест/iex: создать события в БД напрямую, дернуть `Outbox.list_events_for_user_since/2`, свериться с ожидаемым списком.
* Убедиться, что обычный live-поток (открыть два браузера, отправить сообщение) работает как раньше — эта итерация не должна быть заметна пользователю.

## По завершении

Обновить статус на "завершено" в этом файле и в таблице `tasks/00-roadmap.md`. Короткий отчёт: что сделано, какие тесты добавлены, что осознанно отложено (state machine, звук, сужение push-уведомлений, Oban) — и только потом переход к Итерации 2.
