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
- Постоянные счётчики непрочитанных сообщений с синхронизацией между вкладками.
- Один экземпляр приложения и один PostgreSQL.

Личные диалоги используют приватные каналы, доступные только двум участникам.
Групповые приватные каналы и уведомления вне приложения пока не поддерживаются.

## Production image

Минимальный release-образ собирается и запускается через production override:

```sh
cp .env.example .env
# Замените SECRET_KEY_BASE и POSTGRES_PASSWORD на production-значения.
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

При запуске production-контейнера обязательны `DATABASE_URL` и
`SECRET_KEY_BASE`. Не используйте значения из `.env.example` за пределами
локальной разработки.

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
2. Файлы, треды, реакции, поиск и уведомления.
3. Только при реальной необходимости — несколько экземпляров приложения:
   имена Erlang-узлов, общий cookie, DNS discovery и sticky WebSocket routing.
4. Федерация как отдельный подписанный протокол с моделью доверия и очередью
   повторной доставки, изолированный от внутренних PubSub-топиков.
