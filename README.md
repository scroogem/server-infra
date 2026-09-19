# Домашний сервер — руководство по восстановлению

Резервная копия конфигурации и всех проектов домашнего сервера.
Цель: перенести рабочую систему на новый железо/сервер за вечер.
**В этом репозитории нет секретов** — только схема, пути и команды.

---

## 1. Железо и ОС

- Слабая машина, **RAM ~3.7 GiB**, swap ~3.7 GiB. OOM-kill реальны!
- Linux (Ubuntu-подобный, apt), пользователь `max`, sudo.
- Греется: были температурные аварии и нечистые выключения — ставить лимиты на node-процессы обязательно.
- LVM c ~58 ГБ свободного места.
- Логин по SSH: порт 22.

## 2. Сеть и доступ

- LAN: `192.168.1.4`, `192.168.1.25`.
- Tailscale: узел `giadaserver`, IP `100.95.16.117`, tailnet `tail71ff28.ts.net`.
  Funnel: `https://giadaserver.tail71ff28.ts.net/` → `http://127.0.0.1:4097` (opencode-mobile).
- Порты, которые слушают наружу:
  | Порт | Что |
  |---|---|
  | 22 | SSH |
  | 4096 | opencode web (основной рабочий UI) |
  | 4097 | opencode mobile (прокси-UI для телефона) |
  | 443 / 8443 / 42877 | Tailscale / funnel |
  | 3000, 8000, 8787, 631 | другие процессы (проверить `ss -tlnp` при переносе) |

## 3. Критичные сервисы (systemd user units)

> Важно: **opencode-web и opencode-mobile — всегда должны работать**, от них доступ с телефона.
> Именно поэтому у них `OOMScoreAdjust` в минус, чтобы oom-killer их не трогал.

| Сервис | Юнит | Порт | Что делает | Путь проекта |
|---|---|---|---|---|
| opencode-web | `opencode-web.service` | 4096 | веб-интерфейс агента | `/home/max` (данные в `~/.config/opencode/`, `~/.local/share/opencode/`) |
| opencode-mobile | `opencode-mobile.service` | 4097 | прокси-UI для телефона | `/home/max/opencode-mobile` (node `server.js`) |
| omniroute | `omniroute.service` — СЕЙЧАС `disabled` | 20128 (dev) | OmniRoute (Next.js) | `/home/max/projects/OmniRoute` |

Проверка/перезапуск:

```bash
systemctl --user status opencode-web opencode-mobile
systemctl --user list-units --type=service --state=running
```

ОмниРоут: dev-юнит остановлен ради экономии RAM. Настройки — в `systemd/omniroute.service`
(heap ограничен 3072, логи в `~/.omniroute-dev.log`). Прод-сборка НЕ завершена
(логи `~/.omniroute-build.log`, прерванная `npm run build` при нехватке RAM).

## 4. Инструменты

- Node.js `v24.19.0`, pnpm `12.3.4` в `/home/max/.npm-global/bin` (НЕ в PATH по умолчанию —
  добавлен строчкой `export PATH="$HOME/.npm-global/bin:$PATH"` в `~/.profile` и `~/.bashrc`).
- Манифесты opencode агента: см. `~/.config/opencode/`.
- Docker + docker compose (стек vairy/talky).

## 5. Проекты и их репозитории на GitHub

Токены для пуша хранятся в `~/.git-credentials` — только на этой машине, в GitHub их не класть.

| Локальный путь | Репозиторий | Статус |
|---|---|---|
| `/home/max/projects` | `scroogem/vairy` (ветка `feature/db-swap`) | запинен |
| `/home/max/projects/OmniRoute` | `diegosouzapw/OmniRoute` (ветка `release/v3.8.51`, локальные правки) | upstream GitHub |
| `/home/max/projects/career-ops` | `santifer/career-ops` | upstream GitHub |
| `/home/max/projects/hearth` | `scroogem/hearth` (private) | искл.: `target/` |
| `/home/max/projects/claude-web` | `scroogem/claude-web` (private) | искл.: `node_modules/`, `data/`, `.env` |
| `/home/max/projects/gramgift` | `scroogem/gramgift` (private) | искл.: `node_modules/`, `.env` |
| `/home/max/stack/talky` | `scroogem/talky` (private) | искл.: `.env`, `.github/workflows/` |
| `/home/max/stack/vairy` | `scroogem/vairy-deploy` (private) | искл.: `.env`, `.github/workflows/` |
| `/home/max/opencode-mobile` | `scroogem/opencode-mobile` (private) | полностью |
| `/home/max/stack/server-infra` | `scroogem/server-infra` (private) | = этот репозиторий |

Остальные репо на `scroogem`: `Lambo` (private), `miniapp` (public), `qheid` (private),
`taouse` (public), `vairy-site` (public).

## 6. Где лежат секреты (только пути, БЕЗ значений!)

- `~/.git-credentials` — GitHub PAT (fine-grained, умеет пушить в существующие репо, но НЕ создаёт новые; создание делается другим классическим токеном).
- `~/.ssh/` — SSH-ключи.
- `~/.omniroute/server.env` — переменные OmniRoute.
- `~/projects/claude-web/.env` — AUTH_TOKEN для claude-web.
- `~/projects/gramgift/.env` — DATABASE_URL, JWT_SECRET, BOT_TOKEN.
- `~/stack/talky/.env` — SOCIAL_TRAINER_* (SECRET_KEY, JWT, упоминается база).
- `~/stack/vairy/.env` — SECRET_KEY, JWT_SECRET_KEY, SUPABASE_*, UPSTASH_*.
- `~/stack/cloudflared/6b77100a-d47e-4ce7-b895-458be95603ed.json` — credentials Cloudflare Tunnel (`vairy-api`).
- `.env`-файлы имеют права `600`.

## 7. Стек vairy + talky (Docker, Cloudflare Tunnel)

Полное описание и повседневные команды — `docker/` и README из `~/stack`.
Кратко:
- `docker compose` в `~/stack/`, сеть `internal`, наружу не открыт ни один порт.
- `talky` (Flask, :5001) работает, `vairy` (:5000) остановлен под профилем `optional`.
- Единственный вход — Cloudflare Tunnel `vairy-api` (домены `api.vairyapp.com`, `talkyapi.vairyapp.com`).
- Данные снаружи: Postgres в Supabase, Redis в Upstash — локального состояния нет.

## 8. Восстановление на новом сервере

Ручной чек-лист (все секреты — берутся с текущей машины, копируются на новую):

```bash
# 1. Базово
sudo apt update && sudo apt install -y git curl build-essential nodejs npm docker.io docker-compose-plugin

# 2. Node поверх distro (нужен новый node, см. версии в секции 4), pnpm:
npm install -g --allow-scripts=pnpm pnpm
export PATH="$HOME/.npm-global/bin:$PATH"

# 3. Клонировать проекты:
git clone https://github.com/scroogem/hearth.git /home/max/projects/hearth
git clone https://github.com/scroogem/claude-web.git /home/max/projects/claude-web
git clone https://github.com/scroogem/gramgift.git /home/max/projects/gramgift
git clone https://github.com/scroogem/talky.git /home/max/stack/talky
git clone https://github.com/scroogem/vairy-deploy.git /home/max/stack/vairy
git clone https://github.com/scroogem/opencode-mobile.git /home/max/opencode-mobile
git clone -b feature/db-swap https://github.com/scroogem/vairy.git /home/max/projects
git clone https://github.com/diegosouzapw/OmniRoute.git /home/max/projects/OmniRoute
```

```bash
# 4. Секреты: скопировать с текущей машины файлы из секции 6 (в т.ч. .env).
# 5. Юниты:
mkdir -p ~/.config/systemd/user
cp server-infra/systemd/*.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now opencode-web opencode-mobile   # критично!
# 6. Стек:
cd ~/stack && docker compose up -d talky cloudflared
# 7. Tailscale: https://tailscale.com (узел giadaserver), funnel через `tailscale funnel 4097`.
```

```bash
# 8. Проверка доступности с телефона (должно быть 200):
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4097
curl -s -o /dev/null -w "%{http_code}\n" https://giadaserver.tail71ff28.ts.net/
```

## 9. Хвосты и баги

- **OOM**: при поднятом воём стеке node-процессов RAM на исходе. Не запускать могут всё
  одновременно; `omniroute` при необходимости — только с heap-лимитом.
- **PAT и workflow**: у ручного классического токена должен быть scope `repo` + `workflow`,
  иначе `push .github/workflows/*` отклоняется («no workflow scope»).
- **better-sqlite3 (OmniRoute)**: требует `build-essential` (make/gcc) до `pnpm install`.
- **remark-gfm (OmniRoute)**: pnpm создаёт битую симлинк-ссылку на `.pnpm/remark-gfm@4.0.1` —
  нужен ручной симлинк на вариант `remark-gfm@4.0.1_supports-color@10.2.2`, иначе dev-сервер
  отдаёт 500 и белый экран.