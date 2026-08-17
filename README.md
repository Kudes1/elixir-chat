# Orbit

Self-hosted командный чат на Elixir, Phoenix и LiveView. Текущая версия — MVP
для запуска одним экземпляром приложения с PostgreSQL.

## Запуск и разработка

Нужен только Docker Engine с Docker Compose.

### Разработка

`compose.yaml` — production-стек. Для разработки поверх него подключается
`compose.dev.yaml`, который переключает web-сервис на `development`-таргет
Dockerfile, монтирует исходники для hot reload и запускает dev-entrypoint:

```sh
cp .env.example .env
docker compose -f compose.yaml -f compose.dev.yaml up --build
```

Откройте [http://localhost:4000](http://localhost:4000). Миграции и стартовые
каналы создаются автоматически. Исходники подключены в контейнер, поэтому
изменения подхватываются без локальной установки Elixir или Node.js.

Проверки также выполняются внутри контейнера:

```sh
docker compose -f compose.yaml -f compose.dev.yaml exec web mix test
docker compose -f compose.yaml -f compose.dev.yaml exec web mix precommit
```

Вместо длинных команд можно использовать `make`:

```sh
make dev-up     # docker compose -f compose.yaml -f compose.dev.yaml up --build
make dev-down
make test
make precommit
```

Остановить сервисы можно через `docker compose -f compose.yaml -f compose.dev.yaml down`.
Данные PostgreSQL останутся в именованном volume. `down -v` удаляет базу и кэши
зависимостей без возможности восстановления.

## Что поддерживается

- Публичные каналы и сообщения в PostgreSQL.
- Личные диалоги один-на-один с историей и проверкой доступа участников.
- Real-time доставка через Phoenix PubSub и Presence для пользователей.
- Авторизация по приглашениям, пользовательские профили и административное управление.
- История сообщений с курсорной пагинацией.
- Постоянные счётчики непрочитанных сообщений с синхронизацией между вкладками.
- Браузерные Web Push-уведомления с настройками по диалогам и повторной доставкой.
- Один экземпляр приложения и один PostgreSQL.

Личные диалоги используют приватные каналы, доступные только двум участникам.
Групповые приватные каналы пока не поддерживаются.

## Production

`compose.yaml` самодостаточен и предназначен для прода: один файл запускает
PostgreSQL и минимальный release-образ web-сервиса. Запуск одной командой:

```sh
cp .env.example .env
# Замените SECRET_KEY_BASE и POSTGRES_PASSWORD на production-значения.
docker compose up -d --build
```

Web-сервис использует release без bind-mount исходников и без Phoenix code
reloader. Перед стартом release автоматически применяет миграции и запускает
идемпотентный seed. Остановка — той же командой `docker compose down`.
`make prod-up` и `make prod-down` делают то же самое.

Production-сборка также проверяет gzip-бюджеты основных ассетов: не более
55 КБ для JavaScript и 20 КБ для CSS. Проверка входит в `mix assets.deploy`.

Образ отдельно можно собрать командой:

```sh
docker build --target production -t orbit:latest .
```

При запуске production-контейнера обязательны `DATABASE_URL` и
`SECRET_KEY_BASE`. Не используйте значения из `.env.example` за пределами
локальной разработки.

Web Push включается только когда заданы оба VAPID-ключа. Допустимые домены
push-провайдеров перечисляются через `WEB_PUSH_ALLOWED_HOST_SUFFIXES`; не
добавляйте туда пользовательские домены или широкие публичные суффиксы.

### Первый администратор

Первого администратора проще всего создать через `bin/orbit-admin` в web-контейнере.
Команда выполняет миграции, idempotent-seed и в одной транзакции создаёт
одноразовое приглашение (для bootstrap — если администратора ещё нет):

```sh
make admin-bootstrap LOGIN=alice NAME="Alice"
```

В **production**-контейнере `make admin-bootstrap` эквивалентен:

```sh
docker compose exec web bin/orbit-admin bootstrap --login alice --name "Alice"
```

В **dev**-контейнере (`bin/orbit-admin` существует только в production-релизе)
используйте вместо этого Mix task:

```sh
docker compose -f compose.yaml -f compose.dev.yaml exec web mix orbit.admin bootstrap --login alice --name "Alice"
```

Скрипт печатает путь `/invitation/TOKEN`. Добавьте этот путь к любому
разрешённому домену сервиса и откройте его в браузере, чтобы зарегистрировать
первого администратора. Вместо `bootstrap` доступны `transfer --to-login LOGIN`
(сделать админом существующего пользователя) и `reset` (перевыпустить пароль
админу) — в Makefile им соответствуют `make admin-transfer` и `make admin-reset`.
Аналоги `transfer`/`reset` в dev-контейнере: `mix orbit.admin transfer --to-login LOGIN`
и `mix orbit.admin reset`.

## Несколько публичных доменов

Orbit не задаёт канонический публичный домен и может обслуживать несколько
доменов через один reverse proxy. Allowlist доменов и TLS-сертификаты находятся
на стороне nginx; порт Phoenix не должен быть доступен из публичной сети.
Неизвестные домены нужно отклонять до передачи запроса приложению.

Прокси обязан перезаписывать клиентские `X-Forwarded-Host`,
`X-Forwarded-Port` и `X-Forwarded-Proto`, а не пропускать их исходные значения.
Для каждого HTTPS-запроса передавайте внешний host, порт `443` и протокол
`https`. Для LiveView также требуется WebSocket upgrade на `/live`:

```nginx
upstream orbit {
    server 127.0.0.1:4000;
}

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate /etc/nginx/certs/default.crt;
    ssl_certificate_key /etc/nginx/certs/default.key;
    return 444;
}

server {
    listen 443 ssl;
    server_name chat.example.com team.example.net;
    ssl_certificate /etc/nginx/certs/orbit.crt;
    ssl_certificate_key /etc/nginx/certs/orbit.key;

    location / {
        proxy_pass http://orbit;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Forwarded-Proto https;
    }

    location /live {
        proxy_pass http://orbit;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

Веб-админка, `mix orbit.admin` и release-команда `orbit-admin` печатают
одноразовое приглашение как путь `/invitation/TOKEN`. Добавьте этот путь к
любому разрешённому домену сервиса. Cookies остаются привязаны к конкретному
host, поэтому вход на разных доменах выполняется независимо.

## Следующие этапы

1. Рабочие пространства, роли и членство в групповых приватных каналах.
2. Файлы, треды, реакции и поиск.
3. Только при реальной необходимости — несколько экземпляров приложения:
   имена Erlang-узлов, общий cookie, DNS discovery и sticky WebSocket routing.
4. Федерация как отдельный подписанный протокол с моделью доверия и очередью
   повторной доставки, изолированный от внутренних PubSub-топиков.
