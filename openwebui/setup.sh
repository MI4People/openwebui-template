#!/usr/bin/env bash
set -euo pipefail

SERVER_DIR="/root/openwebui"
COMPOSE_DIR="$SERVER_DIR/openwebui-docker"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
NGINX_CONF="$COMPOSE_DIR/nginx/conf.d/openwebui.conf"
ISSUE_CERT="$COMPOSE_DIR/issue-cert.sh"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: Compose file not found at $COMPOSE_FILE"
  exit 1
fi

if [ ! -f "$NGINX_CONF" ]; then
  echo "ERROR: Nginx config not found at $NGINX_CONF"
  exit 1
fi

if [ ! -f "$ISSUE_CERT" ]; then
  echo "ERROR: issue-cert.sh not found at $ISSUE_CERT"
  exit 1
fi

if rg -n "YOUR_DOMAIN_HERE|YOUR_LETSENCRYPT_EMAIL|YOUR_OPENWEBUI_ADMIN_EMAIL|CHANGE_ME_TO_A_LONG_RANDOM_SECRET|CHANGE_ME_DB_PASSWORD|CHANGE_ME_OPENWEBUI_ADMIN_PASSWORD" "$COMPOSE_FILE" "$NGINX_CONF" "$ISSUE_CERT" >/dev/null 2>&1; then
  echo "ERROR: Placeholder values found. Run fill-template.sh first."
  exit 1
fi

echo "Updating OS packages..."
apt update
apt upgrade -y
apt install -y curl git ufw

echo "Installing Docker..."
curl -SL https://get.docker.com -o /tmp/get-docker.sh
sh /tmp/get-docker.sh
rm -f /tmp/get-docker.sh

echo "Enabling Docker service..."
systemctl enable docker
systemctl start docker

comment_ssl_block() {
  local file="$1"
  awk '
    /# BEGIN SSL/ {in_block=1; print; next}
    /# END SSL/ {in_block=0; print; next}
    {
      if (in_block) {
        match($0, /^[[:space:]]*/)
        indent = substr($0, RSTART, RLENGTH)
        rest = substr($0, RLENGTH + 1)
        if (rest ~ /^#/) {
          print $0
        } else {
          print indent "#__SSL__ " rest
        }
      } else {
        print $0
      }
    }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

uncomment_ssl_block() {
  local file="$1"
  awk '
    /# BEGIN SSL/ {in_block=1; print; next}
    /# END SSL/ {in_block=0; print; next}
    {
      if (in_block) {
        if ($0 ~ /^[[:space:]]*#__SSL__ /) {
          sub(/#__SSL__ /, "", $0)
        }
        print $0
      } else {
        print $0
      }
    }
  ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

echo "Disabling SSL block in Nginx config..."
comment_ssl_block "$NGINX_CONF"

echo "Starting Docker Compose stack..."
cd "$COMPOSE_DIR"
docker compose up -d

echo "Issuing initial certificate..."
bash "$ISSUE_CERT"

echo "Re-enabling SSL block in Nginx config..."
uncomment_ssl_block "$NGINX_CONF"

echo "Reloading Nginx..."
docker compose exec nginx nginx -s reload

echo "Installing cron job..."
CRON_RENEW="0 3 * * * /bin/bash /root/openwebui/openwebui-docker/renew-cert.sh"
CRON_BACKUP="0 1 * * * /bin/bash /root/openwebui/openwebui_backup.sh"

{
  crontab -l 2>/dev/null || true
} | grep -v -F "$CRON_RENEW" | grep -v -F "$CRON_BACKUP" | {
  cat
  echo "$CRON_RENEW"
  echo "$CRON_BACKUP"
} | crontab -

printf "\nSetup complete.\n" > /dev/tty
