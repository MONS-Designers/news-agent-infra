#!/usr/bin/env bash
# Run this ON the VM (as a sudo-capable user, e.g. via `az vm run-command` or SSH),
# after DNS for app.newsagent-ai.com / api.newsagent-ai.com points at this box.
# Idempotent-ish: safe to re-run, but not a full reconciler — review before re-running
# after the first successful pass.
set -euo pipefail

DOMAIN="newsagent-ai.com"
ADMIN_EMAIL="moisi6510@gmail.com"
APP_DIR="/opt/newsagent"
NEWS_AGENT_REPO="https://github.com/MONS-Designers/news-agent.git"
NEWS_AGENT_BRANCH="dev"

# --- 1. System packages ---
sudo apt-get update
sudo apt-get install -y python3.12 python3.12-venv nginx certbot python3-certbot-nginx git

# Node.js via NodeSource, not apt: Ubuntu 24.04's `nodejs` package is v18, but the
# frontend's @tailwindcss/oxide requires >=20.
if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 20 ]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# --- 2. Service user (app never runs as root) ---
if ! id newsagent &>/dev/null; then
    sudo useradd --system --create-home --shell /usr/sbin/nologin newsagent
fi

# --- 3. Clone news-agent (dev branch — see infra repo's launch-readiness notes
#     for why: main is unmaintained scaffolding) ---
sudo mkdir -p "$APP_DIR"
sudo chown newsagent:newsagent "$APP_DIR"
if [ ! -d "$APP_DIR/news-agent" ]; then
    sudo -u newsagent git clone --branch "$NEWS_AGENT_BRANCH" "$NEWS_AGENT_REPO" "$APP_DIR/news-agent"
fi
cd "$APP_DIR/news-agent"
sudo -u newsagent git fetch origin
sudo -u newsagent git checkout "$NEWS_AGENT_BRANCH"
sudo -u newsagent git pull origin "$NEWS_AGENT_BRANCH"

# --- 4. Backend: venv + deps + migrations ---
sudo -u newsagent python3.12 -m venv .venv
sudo -u newsagent .venv/bin/pip install -r requirements-dev.txt
sudo -u newsagent .venv/bin/pip install -e .

# REPLACE: copy the real, filled-in .env here first (chmod 600), e.g.:
#   scp deploy/.env <vm>:/opt/newsagent/news-agent/.env
if [ ! -f .env ]; then
    echo "!! .env missing — copy the filled deploy/.env.example here before continuing." >&2
    exit 1
fi
sudo chown newsagent:newsagent .env
sudo chmod 600 .env

sudo -u newsagent .venv/bin/alembic upgrade head

# --- 5. Frontend: build static assets ---
# VITE_API_BASE points the frontend at the backend's real origin (see
# frontend/.env.example in news-agent — the var name was already declared
# there, just never wired into client.ts until the 2026-08-16 login fix).
# Without this, the frontend's relative "/api" default only works when
# frontend and backend share an origin, which they don't under this
# app.*/api.* split.
cd "$APP_DIR/news-agent/frontend"
sudo -u newsagent npm install
sudo -u newsagent env VITE_API_BASE="https://api.$DOMAIN" npm run build

# --- 6. systemd units (from this repo's deploy/) ---
sudo cp /opt/newsagent/news-agent-infra/deploy/newsagent-pipeline-daily.service /etc/systemd/system/
sudo cp /opt/newsagent/news-agent-infra/deploy/newsagent-pipeline-daily.timer /etc/systemd/system/
sudo cp /opt/newsagent/news-agent-infra/deploy/newsagent-digest-weekly.service /etc/systemd/system/
sudo cp /opt/newsagent/news-agent-infra/deploy/newsagent-digest-weekly.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now newsagent-pipeline-daily.timer newsagent-digest-weekly.timer

# --- 7. Backend as a long-running service (uvicorn, not systemd-oneshot) ---
sudo tee /etc/systemd/system/newsagent-api.service > /dev/null <<EOF
[Unit]
Description=NewsAgent FastAPI backend
After=network-online.target

[Service]
Type=simple
User=newsagent
WorkingDirectory=$APP_DIR/news-agent
EnvironmentFile=$APP_DIR/news-agent/.env
ExecStart=$APP_DIR/news-agent/.venv/bin/uvicorn newsagent.api.main:app --host 127.0.0.1 --port 8000
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now newsagent-api.service

# --- 8. nginx + TLS ---
sudo cp /opt/newsagent/news-agent-infra/deploy/nginx.conf /etc/nginx/sites-available/newsagent
sudo sed -i "s/REPLACE_WITH_DOMAIN/$DOMAIN/g" /etc/nginx/sites-available/newsagent
sudo ln -sf /etc/nginx/sites-available/newsagent /etc/nginx/sites-enabled/newsagent
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d "app.$DOMAIN" -d "api.$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL"

# --- 9. Seed data — run once ---
echo "Manual step: seed admin(s), sources, fields, roles, e.g.:"
echo "  cd $APP_DIR/news-agent && sudo -u newsagent .venv/bin/python -m newsagent.cli add-admin <email>"
echo "  sudo -u newsagent .venv/bin/python -m newsagent.cli seed-sources"
echo "  sudo -u newsagent .venv/bin/python -m newsagent.cli seed-fields"
echo "  sudo -u newsagent .venv/bin/python -m newsagent.cli seed-roles"
echo "Not run automatically — admin emails are a decision, not a default."
