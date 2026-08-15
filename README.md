# Orbit

Self-hosted командный чат на Elixir, Phoenix и LiveView. Текущая версия — MVP
для запуска одним экземпляром приложения с PostgreSQL.

## Запуск и разработка

Нужен только Docker Engine с Docker Compose:

```sh
cp .env.example .env
docker compose up --build
```

Откройте [http://localhost:4000](http://localhost:4000). Миграции и стартовые
каналы создаются автоматически. Исходники подключены в контейнер, поэтому
изменения подхватываются без локальной установки Elixir или Node.js.

Проверки также выполняются внутри контейнера:

```sh
docker compose exec web mix test
docker compose exec web mix precommit
```

Production-сборка также проверяет gzip-бюджеты основных ассетов: не более
55 КБ для JavaScript и 20 КБ для CSS. Проверка входит в `mix assets.deploy`.

Остановить сервисы можно через `docker compose down`. Данные PostgreSQL
останутся в именованном volume. `docker compose down -v` удаляет базу и кэши
зависимостей без возможности восстановления.

## Что поддерживается

- Публичные каналы и сообщения в PostgreSQL.
- Личные диалоги один-на-один с историей и проверкой доступа участников.
- Real-time доставка через Phoenix PubSub и Presence для пользователей.
- Авторизация по приглашениям, пользовательские профили и административное управление.
- История сообщений с курсорной пагинацией.
- Один экземпляр приложения и один PostgreSQL.

Личные диалоги используют приватные каналы, доступные только двум участникам.
Групповые приватные каналы, счётчики непрочитанных и уведомления пока не
поддерживаются.

## Production image

Минимальный release-образ собирается и запускается через production override:

```sh
cp .env.example .env
# Замените SECRET_KEY_BASE, POSTGRES_PASSWORD и PHX_HOST на production-значения.
docker compose -f compose.yaml -f compose.prod.yaml up -d --build
```

В этом режиме web-сервис использует release без bind-mount исходников и без
Phoenix code reloader. Перед стартом release автоматически применяет миграции
и запускает идемпотентный seed. Для остановки используйте тот же набор файлов:

```sh
docker compose -f compose.yaml -f compose.prod.yaml down
```

Образ отдельно можно собрать командой:

```sh
docker build --target production -t orbit:latest .
```

При запуске production-контейнера обязательны `DATABASE_URL`, `SECRET_KEY_BASE`
и корректный `PHX_HOST`. Не используйте значения из `.env.example` за пределами
локальной разработки.

## Следующие этапы

1. Рабочие пространства, роли и членство в групповых приватных каналах.
2. Файлы, треды, реакции, поиск, непрочитанные сообщения и уведомления.
3. Только при реальной необходимости — несколько экземпляров приложения:
   имена Erlang-узлов, общий cookie, DNS discovery и sticky WebSocket routing.
4. Федерация как отдельный подписанный протокол с моделью доверия и очередью
   повторной доставки, изолированный от внутренних PubSub-топиков.
