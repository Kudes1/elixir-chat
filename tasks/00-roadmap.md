# Рефакторинг системы уведомлений — дорожная карта

> Источник контекста для будущих заходов на эту задачу. Черновые заметки пользователя (написаны в чате с нейросетью, без доступа к коду) лежат в `tasks/plan.md` и `tasks/plan and checklist.md` — они описывают целевую архитектуру в общем виде (в стиле Slack/Mattermost) и остаются как референс. Этот документ — сверка того плана с реальным кодом проекта и практический roadmap.

## Зачем

Нужна надёжная доставка realtime-событий и уведомлений: ничего не должно теряться при разрыве соединения/рестарте, reconnect должен полностью восстанавливать состояние, а "догон" пропущенных событий не должен превращаться в поток старых звуков/toast. Двигаемся небольшими проработанными итерациями, каждая — код + тесты + короткий отчёт, без перехода дальше, пока текущая не закрыта.

## Важное открытие про архитектуру проекта

Это **Phoenix LiveView-приложение, а не SPA с ручными Phoenix Channels.** Весь realtime держится на `ElixirChatWeb.ChatLive` (`lib/elixir_chat_web/live/chat_live.ex`) + PubSub + LiveView-протокол. Отдельного `user_socket.js` / `channel.join()` / `channel.on()` в проекте нет (закомментирован при генерации, никогда не использовался). Это меняет то, как реализуются reconnect/replay/ACK — через LiveView `mount/3` + `connect_params` (уже используется на `chat_live.ex:90`), а не через ручной Channel handshake, как в классических Slack/Mattermost-подобных доках.

## Что из целевой архитектуры уже реализовано (реюзать, не переизобретать)

* **Message + event атомарно.** `ElixirChat.Chat.persist_message_transaction/4` (`lib/elixir_chat/chat.ex:771`) — уже `Ecto.Multi`: `Message` (идемпотентно по `{user_id, client_message_id}`) + `OutboxEvent` в одной транзакции. Пункт "Ecto.Multi для связанных операций" по сути готов для пути message→event.
* **Durable outbox уже существует.** Таблица `outbox_events` (`event_id`, `event_type`, `partition_key = "channel:#{id}"`, `payload` jsonb, `attempt_count`, `available_at`, `published_at`), обрабатывается `ElixirChat.OutboxDispatcher` (`lib/elixir_chat/outbox_dispatcher.ex`): poll раз в секунду или `wake_up`/`dispatch_now`, `FOR UPDATE SKIP LOCKED`, забирает самое старое неопубликованное событие на партицию (гарантирует порядок публикации per channel), retry с exponential backoff (до 60с), telemetry `retry_exhausted` после 10 попыток, retention — строки удаляются через 7 дней после `published_at`. Публикация — `ElixirChat.OutboxPublisher` (`lib/elixir_chat/outbox_publisher.ex`): broadcast на `chat:#{channel_id}` (группа) или на оба `chat:user:#{id}` (DM), плюс per-recipient `:conversation_message_created/updated/deleted` на `chat:user:#{user_id}` (для unread), плюс вызов `Notifications.enqueue/2,3` для push. Это уже даёт **at-least-once delivery + строгий порядок per partition** — фундамент под sequence/replay частично есть, просто не выставлен наружу клиенту.
* **Unread уже реализован как позиция**, не построчно. `conversation_reads` (`user_id, channel_id, last_read_at, last_read_message_id`, миграция `20260816120000_add_conversation_reads.exs`, схема `lib/elixir_chat/chat/conversation_read.ex`), считается join+count в `Chat.list_unread_counts/2` (`chat.ex:466`), апдейтится атомарно raw-SQL upsert с монотонной защитой (`upsert_read_cursor/5`, `chat.ex:1149`). Пункт "не хранить unread как отдельную строку на каждое сообщение" — уже выполнен, трогать не нужно.
* **Web Push уже есть как отдельный транспорт**, независимый от LiveView-соединения. `push_subscriptions` / `push_deliveries` + `ElixirChat.NotificationSender` (`lib/elixir_chat/notification_sender.ex`) — тоже poll-GenServer с retry/backoff (cap 300с, discard после 10 попыток), переживает рестарт (доставки — строки в БД с `available_at`/`attempt_count`). Presence нигде не используется как условие для пуша.
* **Fire-and-forget `Task.start`/`Task.async` для важной работы не используется.** Единственное использование `Task` — `Task.async_stream` для параллельной отправки пушей внутри уже устойчивого пайплайна (`notification_sender.ex:55`), не для чего-то, что может тихо потеряться.

## Настоящие пробелы (то, что реально нужно строить)

* **Sequence не выставлен клиенту, resume/replay нет.** LiveView `mount/3` при реконнекте просто грузит всё заново (список каналов, DM, unread, последние 50 сообщений). Это **не "теряет" данные** в классическом смысле (в отличие от SPA-проблемы, для которой писались исходные заметки пользователя) — но и не даёт клиенту знать, что именно произошло, пока его не было, что нужно для будущего тихого catch-up.
* **Звука/toast/browser-notification в приложении нет вообще.** Ни `Audio()`, ни `new Notification()` в JS-коде — только `showNotification` внутри `priv/static/sw.js` (Web Push, работает независимо). Это чистый лист: фичу предстоит строить с нуля, а не чинить существующий спам.
* **ACK и client state machine отсутствуют.** Нет `DISCONNECTED/CONNECTING/CATCHING_UP/LIVE` — LiveView сама прозрачно решает переподключение.
* **NotificationPolicy отсутствует** — нечего выносить, так как ничего не вызывает `playSound()` напрямую (его просто нет).
* **Notifications = каждое сообщение.** `ElixirChat.Notifications.enqueue/2,3` создаёт `push_deliveries` для **каждого** получателя на **каждое** сообщение (канал или DM), если не замьючено. Разбора `@mention` на бэкенде нет вообще — сегодня это чисто UI-фича (автокомплит + подсветка текста, `lib/elixir_chat_web/live/chat_live/components.ex:868-884`, `insert_mention` в `chat_live.ex:431`). Уже сейчас воспроизводимо: канал на 200 участников → 1 обычное сообщение → до 199 `push_deliveries` строк и push-уведомлений.
* **Oban не используется.** Два самодельных poll-GenServer (`OutboxDispatcher`, `NotificationSender`) уже обеспечивают durability через рестарт, но без стандартных инструментов Oban (Web UI, cron-plugin для cleanup, dead-letter, стандартный retry/backoff API).

## Решения пользователя

1. Первая итерация — **фундамент sequence + replay**, а не сужение push-уведомлений.
2. Фоновые задачи — **мигрировать на Oban** (итерация 6).

## Дорожная карта

| # | Итерация | Файл | Статус |
|---|----------|------|--------|
| 1 | Sequence + Replay фундамент поверх существующего outbox | `01-sequence-replay.md` | завершено |
| 2 | Явная client state machine (DISCONNECTED/CONNECTING/CATCHING_UP/LIVE) | `02-client-state-machine.md` | завершено |
| 3 | NotificationPolicy + первая версия звука/toast/badge, тихий catch-up по построению | `03-notification-policy-sound.md` | завершено |
| 4 | Разбор `@mention`, durable `Notification`, сужение push до mention/DM, received/seen/read | `04-notifications-mentions.md` | завершено |
| 5 | Защита от звукового спама (cooldown/группировка) по реальным паттернам | `05-sound-spam-protection.md` | завершено |
| 6 | Миграция `OutboxDispatcher`/`NotificationSender` на Oban + Oban Cron | `06-oban-migration.md` | завершено |
| 7 | Retention/cleanup + сквозные regression-тесты (сценарии A–G) | `07-retention-cleanup.md` | завершено |

Каждая итерация — отдельный небольшой проход: код + тесты + краткий отчёт о результатах и известных ограничениях. Переход к следующей — только после того, как текущая закрыта тестами и не даёт регрессий (`mix test` целиком).

## Definition of Done всей переработки

Соответствует итоговому чеклисту пользователя (`tasks/plan and checklist.md`, раздел "Финальная end-to-end проверка" и "Definition of Done всей системы"), адаптированному под реальную архитектуру:

* Ни одно durable-событие не теряется при временном disconnect; reconnect восстанавливает пропущенное.
* Повторная доставка безопасна (идемпотентность где возможен at-least-once).
* ACK ≠ read; received/seen/read разделены.
* Catch-up не создаёт звуков/toast-спама; burst новых LIVE-событий тоже не создаёт спам.
* Обычные сообщения не создают push-уведомление каждому участнику канала — только mention/DM/др. явно определённые типы.
* Рестарт Phoenix не теряет важные фоновые задачи (Oban).
* WebSocket/LiveView-соединение не рассматривается как persistent storage; Presence не рассматривается как доказательство доставки.
* NotificationPolicy отделён от транспорта.
* Web Push работает независимо от активного LiveView-соединения.
* Старые технические данные (outbox, push_deliveries, notifications, Oban jobs) автоматически очищаются, retention — конфигурируемый.
* Все критические сценарии покрыты автотестами; вся существующая функциональность чата продолжает работать.
