# server-infra

Настройка сервера на Ubuntu, чтобы держать на нём несколько приложений в Docker и чтобы они не мешали друг другу.

```
/srv
├── infra/              этот репозиторий
│   └── proxy/          общий Caddy: единственный, кто держит порты 80 и 443
│       └── sites/      по файлу на домен
└── apps/
    ├── game/           одно приложение — одна папка
    └── ...
```

Порты 80 и 443 держит общий прокси. Он сам получает HTTPS-сертификаты и раздаёт запросы по доменам. Приложения не открывают свои порты наружу: они подключаются к общей сети Docker `proxy`, и прокси ходит к ним по имени. Базы и внутренние сервисы приложения видны только внутри него самого.

Рассчитано и на слабый сервер (1 ядро, 1 ГБ памяти, 10 ГБ диска): добавляется файл подкачки, логи ограничены по размеру, старые образы удаляются каждую ночь.

## Подготовка

1. В DNS домена направьте A-записи на IP сервера. Удобнее всего одна запись `*.example.ru`: тогда любой поддомен сразу ведёт на сервер.
2. Заведите обычного пользователя и добавьте ему SSH-ключ:

   ```bash
   adduser deploy && usermod -aG sudo deploy        # на сервере под root
   ssh-copy-id deploy@<ip-сервера>                   # на своём компьютере
   ```

## Установка

Под пользователем `deploy`:

```bash
sudo git clone https://github.com/<вы>/server-infra.git /srv/infra
sudo bash /srv/infra/setup.sh
```

Скрипт:

- обновит систему и включит автоматические обновления безопасности;
- добавит 1 ГБ подкачки (размер можно задать: `sudo SWAP_SIZE=2G bash /srv/infra/setup.sh`);
- ограничит журнал системы 100 МБ, а логи каждого контейнера — 30 МБ;
- поставит Docker и каждую ночь будет удалять образы, которые не используются больше трёх дней;
- включит файрвол: открыты только SSH, 80 и 443;
- отключит вход по паролю, если у пользователя уже есть SSH-ключ;
- создаст общую сеть `proxy`, запустит прокси и добавит команду `site`.

Скрипт можно запускать повторно. После установки перезайдите по SSH, чтобы работать с `docker` без `sudo`.

## Добавить приложение

Правила для любого приложения:

- лежит в своей папке `/srv/apps/<имя>`;
- не открывает порты через `ports:` — Docker пробрасывает их в обход файрвола, и они будут видны из интернета;
- сервис, который должен быть доступен снаружи, подключается к сети `proxy` под уникальным именем, базы и прочее — нет;
- пароли и настройки — в `.env` в папке приложения, не в git.

### Готовый образ

Например, Uptime Kuma для слежения за доступностью сайтов:

```bash
mkdir /srv/apps/kuma && cd /srv/apps/kuma
nano compose.yaml
```

```yaml
services:
  kuma:
    image: louislam/uptime-kuma:1
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    networks:
      default:
      proxy:
        aliases:
          - kuma

networks:
  proxy:
    external: true
```

```bash
docker compose up -d
site add status.example.ru kuma:3001
```

`3001` — порт, который приложение слушает внутри своего контейнера (он указан в документации образа). Через несколько секунд сайт откроется по HTTPS.

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
