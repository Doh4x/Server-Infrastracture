## Установка

```bash
sudo git clone https://github.com/<вы>/server-infra.git /srv/infra
sudo bash /srv/infra/setup.sh
```

## Добавить приложение

Правила для любого приложения:

- лежит в своей папке `/srv/apps/<имя>`;
- не открывает порты через `ports:` — Docker пробрасывает их в обход файрвола, и они будут видны из интернета;
- сервис, который должен быть доступен снаружи, подключается к сети `proxy` под уникальным именем, базы и прочее — нет;
- пароли и настройки — в `.env` в папке приложения, не в git.

### Своё приложение из git

На слабом сервере лучше не собирать образы, а скачивать готовые: собирать их на GitHub Actions и складывать в GitHub Container Registry (`ghcr.io`). Тогда на сервере нужны только `compose.yaml` и `.env`:

```bash
mkdir -p /srv/apps/blog && cd /srv/apps/blog
nano .env
nano compose.yaml
```

```yaml
services:
  app:
    image: ghcr.io/<вы>/blog:latest
    restart: unless-stopped
    env_file: .env
    depends_on:
      - db
    networks:
      default:
      proxy:
        aliases:
          - blog

  db:
    image: postgres:17-alpine
    restart: unless-stopped
    env_file: .env
    volumes:
      - db:/var/lib/postgresql/data

networks:
  proxy:
    external: true

volumes:
  db:
```

```bash
docker compose up -d
site add blog.example.ru blog:3000
```

База подключена только к сети самого приложения: приложение её видит, интернет и другие приложения — нет.

Обновить: `docker compose pull && docker compose up -d`.

Если образ приватный, один раз войдите в реестр токеном GitHub с правом `read:packages`: `docker login ghcr.io -u <вы>`.

### Убрать приложение

```bash
cd /srv/apps/kuma
docker compose down                 # с флагом -v удалятся и его данные
site remove status.example.ru
cd .. && rm -rf kuma
```

## Команды

| Что | Команда |
|---|---|
| Какие домены куда ведут | `site list` |
| Добавить домен | `site add <домен> <контейнер:порт>` |
| Убрать домен | `site remove <домен>` |
| Что запущено и сколько ест | `docker ps`, `docker stats` |
| Логи прокси (проблемы с сертификатом, ошибки 502) | `docker compose -f /srv/infra/proxy/compose.yaml logs -f` |
| Логи приложения | `docker compose logs -f` в его папке |
| Сколько места занимает Docker | `docker system df` |
| Обновить саму инфраструктуру | `git -C /srv/infra pull && sudo bash /srv/infra/setup.sh` |

Ошибка 502 от прокси почти всегда значит, что приложение не запущено, не подключено к сети `proxy` или в `site add` указаны не то имя или не тот порт.
