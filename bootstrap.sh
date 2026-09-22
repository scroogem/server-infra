#!/usr/bin/env bash
# =====================================================================
#  server-infra — bootstrap.sh
#  Восстановление всего домашнего сервера одной командой.
#
#  Использование (на свежем Ubuntu-подобном сервере, пользователь с sudo):
#
#    1) Скопировать на сервер этот репозиторий (или только bootstrap.sh
#       + secrets.env.example -> secrets.env) и заполнить secrets.env.
#
#    2) Запустить:
#         sudo bash bootstrap.sh [secrets.env]
#       или указать файл через переменную:
#         SECRETS_FILE=/path/secrets.env sudo -E bash bootstrap.sh
#
#  Что делает:
#    - ставит базовые пакеты (git, curl, build-essential, node, docker, ...)
#    - ставит pnpm, claude CLI, hapi
#    - настраивает Git-креды (github PAT из secrets.env)
#    - клонирует/обновляет все проекты из repos.txt
#    - раскладывает секреты в .env-файлы проектов (chmod 600)
#    - ставит systemd-юниты (user + system)
#    - поднимает Docker-стек vairy+talky+cloudflared и gramgift
#    - настраивает tailscale + funnel
#    - запускает opencode web / mobile / claude-web
#    - проверяет доступность и печатает сводку
#
#  Скрипт идемпотентен: безопасно запускать повторно.
# =====================================================================
set -euo pipefail

# ---------- конфиг ----------
RUN_USER="${RUN_USER:-max}"
RUN_HOME="${RUN_HOME:-/home/$RUN_USER}"
SECRETS_FILE="${1:-${SECRETS_FILE:-./secrets.env}}"
KEEP_SECRETS="${KEEP_SECRETS:-0}"
SKIP_FOREIGN="${SKIP_FOREIGN:-1}"          # не клонировать чужие репо (OmniRoute, career-ops)
WITH_OMNIROUTE="${WITH_OMNIROUTE:-0}"      # запускать OmniRoute dev-сервер не будем (RAM)

GITHUB_REMOTE="https://github.com"
export DEBIAN_FRONTEND=noninteractive

# ---------- утилиты ----------
say()  { printf '\033[1;36m[server-infra]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[server-infra]\033[0m WARNING: %s\n' "$*"; }
die()  { printf '\033[1;31m[server-infra]\033[0m ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- проверка прав ----------
[ "$(id -u)" -eq 0 ] || die "Запустите с sudo: sudo bash bootstrap.sh"

# ---------- секреты ----------
[ -f "$SECRETS_FILE" ] || die "Файл секретов '$SECRETS_FILE' не найден. Скопируйте secrets.env.example -> secrets.env и заполните."

set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

[ -n "${GITHUB_TOKEN:-}" ] || warn "GITHUB_TOKEN пуст — клонирование приватных репо потребует ручного ввода."

# ---------- 1. базовые пакеты ----------
say "Устанавливаю базовые пакеты..."
if have apt-get; then
  apt-get update -y
  apt-get install -y \
    git curl wget ca-certificates gnupg lsb-release \
    build-essential python3 python3-venv python3-pip \
    nodejs npm \
    docker.io docker-compose-plugin \
    jq unzip rsync ufw
  systemctl enable --now docker || true
elif have dnf; then
  dnf install -y git curl wget ca-certificates python3 python3-pip \
    nodejs npm docker python3-docker-plugin jq unzip rsync
  systemctl enable --now docker || true
else
  warn "Неизвестный менеджер пакетов — ставьте базовые пакеты вручную."
fi

# ---------- 2. node/pnpm поверх distro ----------
if ! have pnpm; then
  say "Устанавливаю pnpm..."
  npm install -g --allow-scripts=pnpm pnpm
fi
export PATH="$HOME/.npm-global/bin:$PATH"

# ---------- 3. hapi (HAPI hub, systemd юнит hapi.service) ----------
if ! have hapi; then
  say "Устанавливаю hapi (@twsxtd/hapi)..."
  npm install -g @twsxtd/hapi || warn "hapi не установился — пропускаю."
fi

# ---------- 4. claude CLI ----------
if ! have claude; then
  say "Устанавливаю claude CLI..."
  npm install -g @anthropic-ai/claude-code || warn "claude CLI не установился."
fi

# ---------- 5. tailscale ----------
if ! have tailscale; then
  say "Устанавливаю tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh || warn "tailscale ставится из apt."
  apt-get install -y tailscale || true
fi

# ---------- 6. пользователь + home -----------------
if ! id "$RUN_USER" >/dev/null 2>&1; then
  say "Создаю пользователя $RUN_USER..."
  useradd -m -s /bin/bash "$RUN_USER"
  usermod -aG docker,sudo "$RUN_USER"
else
  usermod -aG docker,sudo "$RUN_USER" || true
fi
mkdir -p "$RUN_HOME/projects" "$RUN_HOME/stack" "$RUN_HOME/.config/systemd/user" "$RUN_HOME/.config/opencode"

# ---------- 7. Git-креды ----------
if [ -n "${GITHUB_TOKEN:-}" ]; then
  say "Настраиваю Git-креды для $GITHUB_USER..."
  printf 'https://%s:%s@github.com\n' "$GITHUB_USER" "$GITHUB_TOKEN" > "$RUN_HOME/.git-credentials"
  chmod 600 "$RUN_HOME/.git-credentials"
  sudo -u "$RUN_USER" git config --global credential.helper store
  sudo -u "$RUN_USER" git config --global user.name  "$GITHUB_USER"
  sudo -u "$RUN_USER" git config --global user.email "$GITHUB_USER@users.noreply.github.com"
fi

# ---------- 8. клонирование репозиториев ----------
clone_or_update() { # $1 dir  $2 url  $3 branch(optional)
  local dir="$1" url="$2" br="${3:-}"
  if [ -d "$dir/.git" ]; then
    say "Обновляю $(basename "$dir")..."
    git -C "$dir" fetch --all --quiet || true
    if [ -n "$br" ]; then git -C "$dir" checkout "$br" --quiet 2>/dev/null || git -C "$dir" checkout -b "$br" --track "origin/$br" 2>/dev/null || true; fi
    git -C "$dir" pull --ff-only --quiet 2>/dev/null || warn "pull $(basename "$dir") не полный (локальные правки)."
  else
    say "Клонирую $(basename "$dir")..."
    if [ -n "$br" ]; then
      sudo -u "$RUN_USER" git clone --quiet --branch "$br" "$url" "$dir" || warn "Не смог клонировать $url"
    else
      sudo -u "$RUN_USER" git clone --quiet "$url" "$dir" || warn "Не смог клонировать $url"
    fi
  fi
}

say "Клонирую/обновляю проекты..."
clone_or_update "$RUN_HOME/projects"           "$GITHUB_REMOTE/$GITHUB_USER/vairy.git"          "feature/db-swap"
clone_or_update "$RUN_HOME/projects/hearth"    "$GITHUB_REMOTE/$GITHUB_USER/hearth.git"
clone_or_update "$RUN_HOME/projects/claude-web" "$GITHUB_REMOTE/$GITHUB_USER/claude-web.git"
clone_or_update "$RUN_HOME/projects/gramgift"  "$GITHUB_REMOTE/$GITHUB_USER/gramgift.git"
clone_or_update "$RUN_HOME/stack/talky"        "$GITHUB_REMOTE/$GITHUB_USER/talky.git"
clone_or_update "$RUN_HOME/stack/vairy"        "$GITHUB_REMOTE/$GITHUB_USER/vairy-deploy.git"
clone_or_update "$RUN_HOME/opencode-mobile"    "$GITHUB_REMOTE/$GITHUB_USER/opencode-mobile.git"
clone_or_update "$RUN_HOME/stack/server-infra" "$GITHUB_REMOTE/$GITHUB_USER/server-infra.git"

if [ "$SKIP_FOREIGN" = "0" ]; then
  clone_or_update "$RUN_HOME/projects/OmniRoute"  "$GITHUB_REMOTE/diegosouzapw/OmniRoute.git" "release/v3.8.51"
  clone_or_update "$RUN_HOME/projects/career-ops" "$GITHUB_REMOTE/santifer/career-ops.git"
else
  say "Пропускаю чужие репо (SKIP_FOREIGN=1): OmniRoute, career-ops."
fi

# ---------- 9. разложить секреты по .env (chmod 600) ----------
# write_env <path> <KEY> <value> [<KEY> <value> ...]
write_env() {
  local path="$1"; shift
  : > "$path"
  while [ "$#" -ge 2 ]; do
    printf '%s=%s\n' "$1" "$2" >> "$path"
    shift 2
  done
  chown "$RUN_USER:$RUN_USER" "$path"
  chmod 600 "$path"
}

say "Раскладываю секреты по .env-файлам..."

write_env "$RUN_HOME/stack/vairy/.env" \
  SECRET_KEY "${VAIRY_SECRET_KEY:-}" \
  JWT_SECRET_KEY "${VAIRY_JWT_SECRET_KEY:-}" \
  ENCRYPTION_KEY "${VAIRY_ENCRYPTION_KEY:-}" \
  FLASK_ENV "${VAIRY_FLASK_ENV:-}" \
  DATABASE_URL "${VAIRY_DATABASE_URL:-}" \
  SUPABASE_URL "${VAIRY_SUPABASE_URL:-}" \
  SUPABASE_KEY "${VAIRY_SUPABASE_KEY:-}" \
  SUPABASE_ANON_KEY "${VAIRY_SUPABASE_ANON_KEY:-}" \
  SUPABASE_JWT_SECRET "${VAIRY_SUPABASE_JWT_SECRET:-}" \
  PASSWORD_PEPPER "${VAIRY_PASSWORD_PEPPER:-}" \
  UPSTASH_REDIS_REST_URL "${VAIRY_UPSTASH_REDIS_REST_URL:-}" \
  UPSTASH_REDIS_REST_TOKEN "${VAIRY_UPSTASH_REDIS_REST_TOKEN:-}" \
  REDIS_URL "${VAIRY_REDIS_URL:-}" \
  GOOGLE_CLIENT_ID "${VAIRY_GOOGLE_CLIENT_ID:-}" \
  GEMINI_API_KEY "${VAIRY_GEMINI_API_KEY:-}" \
  FLASK_DEBUG 0

write_env "$RUN_HOME/stack/talky/.env" \
  SOCIAL_TRAINER_SECRET_KEY "${TALKY_SOCIAL_TRAINER_SECRET_KEY:-}" \
  SOCIAL_TRAINER_JWT_SECRET "${TALKY_SOCIAL_TRAINER_JWT_SECRET:-}" \
  SOCIAL_TRAINER_PASSWORD_PEPPER "${TALKY_SOCIAL_TRAINER_PASSWORD_PEPPER:-}" \
  FLASK_ENV "${TALKY_FLASK_ENV:-}" \
  SOCIAL_TRAINER_DB_URL "${TALKY_SOCIAL_TRAINER_DB_URL:-}" \
  SOCIAL_TRAINER_SUPABASE_URL "${TALKY_SOCIAL_TRAINER_SUPABASE_URL:-}" \
  SOCIAL_TRAINER_SUPABASE_ANON_KEY "${TALKY_SOCIAL_TRAINER_SUPABASE_ANON_KEY:-}" \
  SOCIAL_TRAINER_REDIS_URL "${TALKY_SOCIAL_TRAINER_REDIS_URL:-}" \
  SOCIAL_TRAINER_GOOGLE_CLIENT_ID "${TALKY_SOCIAL_TRAINER_GOOGLE_CLIENT_ID:-}" \
  SOCIAL_TRAINER_GEMINI_KEY "${TALKY_SOCIAL_TRAINER_GEMINI_KEY:-}"

write_env "$RUN_HOME/projects/claude-web/.env" \
  AUTH_TOKEN "${CLAUDE_WEB_AUTH_TOKEN:-}" \
  PORT "${CLAUDE_WEB_PORT:-8787}"

write_env "$RUN_HOME/projects/gramgift/.env" \
  DATABASE_URL "${GRAMGIFT_DATABASE_URL:-}" \
  APP_BASE_URL "${GRAMGIFT_APP_BASE_URL:-}" \
  ADMIN_IDS "${GRAMGIFT_ADMIN_IDS:-}" \
  JWT_SECRET "${GRAMGIFT_JWT_SECRET:-}" \
  ALLOWED_BOT_USERS "${GRAMGIFT_ALLOWED_BOT_USERS:-}" \
  BOT_TOKEN "${GRAMGIFT_BOT_TOKEN:-}" \
  VITE_API_URL "${GRAMGIFT_VITE_API_URL:-}" \
  VITE_BOT_USERNAME "${GRAMGIFT_BOT_USERNAME:-}" \
  ADMIN_PASSWORD "${GRAMGIFT_ADMIN_PASSWORD:-}" \
  POSTGRES_USER "${GRAMGIFT_POSTGRES_USER:-}" \
  POSTGRES_PASSWORD "${GRAMGIFT_POSTGRES_PASSWORD:-}" \
  POSTGRES_DB "${GRAMGIFT_POSTGRES_DB:-}" \
  ALLOW_DEV_AUTH "${GRAMGIFT_ALLOW_DEV_AUTH:-}"

if [ -n "${OMNIROUTE_JWT_SECRET:-}" ]; then
  mkdir -p "$RUN_HOME/.omniroute"
  write_env "$RUN_HOME/.omniroute/server.env" \
    JWT_SECRET "${OMNIROUTE_JWT_SECRET:-}" \
    STORAGE_ENCRYPTION_KEY "${OMNIROUTE_STORAGE_ENCRYPTION_KEY:-}" \
    API_KEY_SECRET "${OMNIROUTE_API_KEY_SECRET:-}"
fi

if [ -n "${CLAUDE_CREDENTIALS_B64:-}" ]; then
  say "Восстанавливаю ~/.claude/.credentials.json из CLAUDE_CREDENTIALS_B64..."
  mkdir -p "$RUN_HOME/.claude"
  printf '%s' "$CLAUDE_CREDENTIALS_B64" | base64 -d > "$RUN_HOME/.claude/.credentials.json"
  chown -R "$RUN_USER:$RUN_USER" "$RUN_HOME/.claude"
  chmod 600 "$RUN_HOME/.claude/.credentials.json"
fi

# ---------- 10. Cloudflare Tunnel creds ----------
if [ -n "${CLOUDFLARED_TUNNEL_ID:-}" ] && [ -n "${CLOUDFLARED_CREDENTIALS_JSON:-}" ]; then
  say "Восстанавливаю credentials Cloudflare Tunnel..."
  mkdir -p "$RUN_HOME/stack/cloudflared"
  printf '%s' "$CLOUDFLARED_CREDENTIALS_JSON" > "$RUN_HOME/stack/cloudflared/$CLOUDFLARED_TUNNEL_ID.json"
  # генерируем конфиг туннеля с правильным ID
  cat > "$RUN_HOME/stack/cloudflared/config.yml" <<EOF
tunnel: $CLOUDFLARED_TUNNEL_ID
credentials-file: /etc/cloudflared/$CLOUDFLARED_TUNNEL_ID.json

ingress:
  - hostname: api.vairyapp.com
    service: http://vairy:5000
  - hostname: talkyapi.vairyapp.com
    service: http://talky:5001
  - service: http_status:404
EOF
  chown -R "$RUN_USER:$RUN_USER" "$RUN_HOME/stack/cloudflared"
  chmod 700 "$RUN_HOME/stack/cloudflared"
  chmod 600 "$RUN_HOME/stack/cloudflared/$CLOUDFLARED_TUNNEL_ID.json"
else
  warn "CLOUDFLARED_TUNNEL_ID/CREDENTIALS пусты — туннель не настрою. Скопируйте ~/stack/cloudflared/ вручную."
fi

# ---------- 11. systemd юниты ----------
say "Ставлю systemd-юниты..."
# пользовательские юниты (запускаются от RUN_USER)
for u in claude-web.service opencode-web.service opencode-mobile.service omniroute.service; do
  [ -f "$RUN_HOME/stack/server-infra/systemd/$u" ] && cp "$RUN_HOME/stack/server-infra/systemd/$u" "$RUN_HOME/.config/systemd/user/"
done

# системные юниты (root)
for u in hapi.service opencode-funnel.service; do
  if [ -f "$RUN_HOME/stack/server-infra/systemd/$u" ]; then
    cp "$RUN_HOME/stack/server-infra/systemd/$u" /etc/systemd/system/
  fi
done

chown -R "$RUN_USER:$RUN_USER" "$RUN_HOME/.config/systemd/user"
systemctl daemon-reload
sudo -u "$RUN_USER" systemctl --user daemon-reload

# ---------- 12. зависимости проектов ----------
say "Устанавливаю зависимости проектов..."
sudo -u "$RUN_USER" bash -lc '
  export PATH="$HOME/.npm-global/bin:$PATH"
  # claude-web
  if [ -f "$HOME/projects/claude-web/package.json" ] && [ ! -d "$HOME/projects/claude-web/node_modules" ]; then
    (cd "$HOME/projects/claude-web" && npm install --no-audit --no-fund)
  fi
  # hearth (Rust) — только если есть cargo
  if command -v cargo >/dev/null 2>&1 && [ -f "$HOME/projects/hearth/Cargo.toml" ]; then
    (cd "$HOME/projects/hearth" && cargo build --release >/dev/null 2>&1 || true)
  fi
'

# ---------- 13. Docker-стек vairy+talky+cloudflared ----------
if [ -f "$RUN_HOME/stack/docker-compose.yml" ] || [ -f "$RUN_HOME/stack/server-infra/docker/docker-compose.yml" ]; then
  say "Собираю и поднимаю Docker-стек vairy+talky+cloudflared..."
  cp "$RUN_HOME/stack/server-infra/docker/docker-compose.yml" "$RUN_HOME/stack/docker-compose.yml"
  ( cd "$RUN_HOME/stack" && docker compose up -d --build talky cloudflared ) || warn "Верхний стек поднялся не полностью. Проверьте docker compose ps."
else
  warn "docker-compose.yml стека не найден."
fi

# ---------- 14. gramgift ----------
if [ -f "$RUN_HOME/projects/gramgift/docker-compose.yml" ]; then
  say "Поднимаю gramgift (docker compose)..."
  ( cd "$RUN_HOME/projects/gramgift" && docker compose up -d --build ) || warn "gramgift поднялся не полностью."
fi

# ---------- 15. tailscale + funnel ----------
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
  say "Подключаю tailscale (AUTHKEY найден)..."
  tailscale up --hostname="${TAILSCALE_HOSTNAME:-giadaserver}" --authkey="$TAILSCALE_AUTHKEY" || warn "tailscale up не удался — проверьте AUTHKEY."
else
  say "TAILSCALE_AUTHKEY не задан. Выполните вручную: sudo tailscale up"
fi

# ---------- 16. включение пользовательских сервисов ----------
say "Включаю пользовательские сервисы..."
sudo loginctl enable-linger "$RUN_USER" 2>/dev/null || true
sudo -u "$RUN_USER" systemctl --user enable --now opencode-web opencode-mobile claude-web 2>/dev/null || \
  warn "Не все user-сервисы поднялись; проверьте systemctl --user list-units"

# opencode CLI (если нет)
if ! have opencode; then
  say "opencode CLI не найден. Установка последней версии..."
  npm install -g opencode-ai 2>/dev/null || \
    warn "Не смог установить opencode через npm — сделайте вручную: https://opencode.ai/docs/cli"
fi

# ---------- 17. файрвол ----------
say "Настраиваю ufw (открываю только SSH)..."
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || warn "ufw уже настроен или недоступен."

# ---------- 18. чистка secrets ----------
if [ "$KEEP_SECRETS" = "0" ] && [ -f "$SECRETS_FILE" ]; then
  say "Удаляю $SECRETS_FILE (KEEP_SECRETS=0)."
  rm -f "$SECRETS_FILE"
fi

# ---------- 19. проверки ----------
say "======================== СВОДКА ========================"
check() { # $1 name $2 cmd
  if eval "$2" >/dev/null 2>&1; then echo "  ✅ $1"; else echo "  ⚠️  $1 — НЕ ОТВЕЧАЕТ"; fi
}
check "opencode web :4096"    "curl -sf -o /dev/null http://127.0.0.1:4096/"
check "opencode mobile :4097" "curl -sf -o /dev/null http://127.0.0.1:4097/"
check "claude-web :8787"      "curl -sf -o /dev/null http://127.0.0.1:8787/"
check "talky container"       "docker inspect -f '{{.State.Running}}' talky 2>/dev/null | grep -q true"
check "cloudflared container" "docker inspect -f '{{.State.Running}}' cloudflared 2>/dev/null | grep -q true"
check "docker daemon"         "docker info >/dev/null 2>&1"
check "tailscale"             "tailscale ip -4 2>/dev/null | head -1 | grep -q ."
echo "========================================================"
say "Готово!"
echo
echo "Дальше вручную (по желанию):"
echo "  opencode server:  opencode web --hostname 0.0.0.0 --port 4096   (или user-юнит)"
echo "  funnel (телефон): sudo tailscale funnel --bg 4097"
echo "  claude login (если пустей CLAUDE_CREDENTIALS_B64): claude"
echo "  домены туннеля:  см. ~/stack/cloudflared/config.yml"