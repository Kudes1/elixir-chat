# Итерация 2 — Client State Machine

Статус: **завершено**

## Отчёт о выполнении

* Открытый вопрос "как ловить connect/disconnect в LiveView" закрыт через Context7 (`phoenixframework/phoenix_live_view` docs): **hooks поддерживают `mounted`/`reconnected`/`disconnected` lifecycle-колбэки из коробки** — не понадобилось трогать `liveSocket.socket.onOpen/onClose` напрямую, как предполагалось в черновике итерации.
* `ElixirChatWeb.ChatLive.ConnectionState` (`lib/elixir_chat_web/live/chat_live/connection_state.ex`) — чистый модуль с таблицей переходов `DISCONNECTED → CONNECTING → (CATCHING_UP | LIVE)`, `transition/2` возвращает `{:ok, state} | {:error, :invalid_transition}` (невозможные переходы, например `LIVE → CATCHING_UP` напрямую, гарантированно отвергаются — таких пар просто нет в таблице). `initial_state/1` резолвит `CONNECTING` в `CATCHING_UP`/`LIVE` по уже существующему `@catching_up?` из Итерации 1.
* `ChatLive.mount/3` — считает `@connection_state` через `ConnectionState.initial_state(catching_up?)`, использует ту же переменную `catching_up?`, что и `@catching_up?`/`@missed_event_count` (без дублирования логики).
* Разметка: вынес `data-catching-up`/`data-missed-event-count` с `#chat-shell` на отдельный скрытый `#connection-state` (`phx-hook="ConnectionState"`, `hidden`), добавил туда же `data-connection-state`. Это чище, чем перегружать `#chat-shell`, у которого уже был свой хук `SidebarResize` (в LiveView один DOM-элемент — один `phx-hook`).
* `assets/js/app.js` — `CONNECTION_TRANSITIONS`/`connectionState` (объект с `current`/`send`/`onChange`) зеркалит ровно ту же таблицу переходов, что и Elixir-модуль (явно прокомментировано, что синхронизировать вручную). Хук `ConnectionState`: `mounted()`/`reconnected()` читают `data-catching-up` из `#connection-state` и резолвят `CONNECTING → CATCHING_UP/LIVE`; если это `CATCHING_UP`, сразу (микротаском) шлют `caught_up → LIVE`, т.к. пока нечего асинхронно ждать (реальное "тихое" применение catch-up — Итерация 3). `disconnected()` шлёт `disconnect`, затем сразу `connect` (Phoenix и так автоматически ретраит). Перед первым `liveSocket.connect()` шлётся `connect` (DISCONNECTED → CONNECTING) — это резолвит самое первое подключение так же, как и все последующие реконнекты. `window.orbitConnectionState` выставлен для отладки и как точка расширения для `NotificationPolicy` (Итерация 3).

### Тесты
* `test/elixir_chat_web/live/chat_live/connection_state_test.exs` (новый, 6 тестов): все валидные переходы; явная проверка невозможности `LIVE → CATCHING_UP`/`LIVE → CONNECTING`/`LIVE → LIVE(caught_up)` напрямую; систематическая проверка "всё, чего нет в таблице, отвергается" (перебор всех состояний × событий); `initial_state/1` для true/false; полный контрольный сценарий пользователя `LIVE → disconnect → DISCONNECTED → connect → CONNECTING → connected_catching_up → CATCHING_UP → caught_up → LIVE`, порядок состояний совпадает 1-в-1.
* `test/elixir_chat_web/live/chat_live_test.exs` — 3 теста из Итерации 1 обновлены под новый селектор `#connection-state` и дополнены проверкой `data-connection-state` (`catching_up`/`live`).
* JS-хук и его runtime-часть (`mounted`/`reconnected`/`disconnected`, реальный порядок событий из живого сокета) тестами не покрыты — в проекте по-прежнему нет JS-тест-раннера (см. Итерацию 1); это то самое "оценить на месте" из черновика итерации — решено не вводить отдельную JS-тест-инфраструктуру ради одного small mirrored-объекта, вместо этого сама таблица переходов имеет один source of truth (Elixir, протестирован), а JS-копия — короткая, наглядно идентичная и явно прокомментированная как обязанная быть в синхроне.
* `mix esbuild elixir_chat` успешно собрал `app.js` (348.8kb, без синтаксических ошибок) — запись в `priv/static/...` упала с `permission denied`, но это существующая проблема прав на файл (владелец `root`, видимо от более раннего запуска `compose.dev.yaml`), не связанная с этой итерацией.
* Полный `mix test`: **167/167 passed** (было 161 после Итерации 1). `mix format --check-formatted` — чисто.

### Известные ограничения (осознанно отложено)
* `CATCHING_UP` резолвится в `LIVE` практически мгновенно (микротаском) — не гейтится ни на чём асинхронном, т.к. реальное "тихое применение" backlog ещё предстоит сделать в Итерации 3. Сейчас это корректный, но пока "пустой" промежуточный шаг.
* JS-таблица переходов — ручная копия Elixir-таблицы, синхронизация не проверяется автоматически (нет общего источника между языками и нет JS-тестов). Если это станет проблемой на практике — рассмотреть генерацию JS-таблицы из Elixir через `push_event`/начальную разметку вместо дублирования кода.
* Никакой видимой пользователю логики (звук/toast/badge) по-прежнему нет — это Итерация 3.

См. общий контекст в `tasks/00-roadmap.md`. Соответствует "Этапу 5" в `tasks/plan and checklist.md`, адаптировано под LiveView (не ручные Phoenix Channels).

## Цель

Явно ввести состояния клиента `DISCONNECTED → CONNECTING → CATCHING_UP → LIVE` вместо разрозненных булевых флагов, используя фундамент из Итерации 1 (`@catching_up?`/`@missed_event_count`, курсоры `event_seq` в `localStorage`). Пока без звука/toast — только корректные переходы состояний и их видимость в assigns/JS, чтобы Итерация 3 могла на них опереться.

## Особенность LiveView

В отличие от классического Phoenix Channel, тут нет ручного `channel.join()`/`leave()` — LiveView сама управляет соединением. Состояние нужно строить из:
* JS-стороны: события `LiveSocket`/`Socket` (`phx:page-loading-start/stop` уже используется для topbar, `app.js:738-740`; нужно также слушать `liveSocket.socket.onOpen/onClose/onError` или эквивалент — уточнить актуальный API в `phoenix_live_view` через Context7 перед реализацией) — даёт `DISCONNECTED`/`CONNECTING`.
* Серверной стороны: `mount/3` уже знает (после Итерации 1), есть ли backlog (`@missed_event_count > 0`) → `CATCHING_UP`, иначе сразу `LIVE`. Переход `CATCHING_UP → LIVE` — после того как весь backlog из `Outbox.list_events_for_user_since/2` применён к assigns (в текущем mount это происходит синхронно, так что фактически "мгновенный" переход, но важно зафиксировать его как отдельный, видимый шаг — понадобится в Итерации 3 для тихого catch-up).

## Задачи

* Определить состояния и переходы как явный модуль/тип на фронтенде (например, простой JS-объект/enum + функция `transition(state, event)`), не разбрасывать по коду.
* Прокинуть текущее состояние в DOM/JS через `push_event`/assign, чтобы можно было писать тесты на переходы без реального WebSocket (юнит-тест на чистую функцию переходов).
* Защитить невозможные переходы (например, `LIVE → CATCHING_UP` напрямую, минуя `DISCONNECTED`/`CONNECTING`) — по крайней мере залогировать/бросить в dev.

## Тесты

* Юнит-тесты на функцию переходов состояний (можно и на JS, если появится тестовый раннер, либо перенести логику переходов в Elixir и тестировать там, если это упростит покрытие — оценить на месте).
* Контрольный сценарий пользователя: `LIVE → network lost → DISCONNECTED → network restored → CONNECTING → CATCHING_UP → LIVE`, пройден именно в этом порядке.
* Регрессия: `mix test`.

## Критические файлы (уточнить при старте)

* `assets/js/app.js` — слушатели жизненного цикла `LiveSocket`.
* `lib/elixir_chat_web/live/chat_live.ex` — переиспользовать `@catching_up?`/`@missed_event_count` из Итерации 1.

## Открытые вопросы для уточнения перед стартом

* Где хранить состояние: чисто в JS, или частично зеркалить в LiveView assigns для серверных решений (нужно для NotificationPolicy в Итерации 3)? Предварительно: assigns — источник истины для `CATCHING_UP`/`LIVE` (сервер знает про backlog надёжнее), JS — источник истины для `DISCONNECTED`/`CONNECTING` (сервер не может напрямую видеть обрыв сокета раньше клиента).
