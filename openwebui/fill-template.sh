#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
COMPOSE_DIR="$BASE_DIR/openwebui-docker"
DOC_PATH=""
if [ -f "$BASE_DIR/docs/technical-documentation.md" ]; then
  DOC_PATH="$BASE_DIR/docs/technical-documentation.md"
fi

FILES_DOMAIN=(
  "$COMPOSE_DIR/docker-compose.yml"
  "$COMPOSE_DIR/nginx/conf.d/openwebui.conf"
  "$COMPOSE_DIR/issue-cert.sh"
  "$COMPOSE_DIR/README.md"
)

FILES_EMAIL=(
  "$COMPOSE_DIR/issue-cert.sh"
  "$COMPOSE_DIR/README.md"
)

FILE_COMPOSE="$COMPOSE_DIR/docker-compose.yml"

read -r -p "Enter domain (e.g., example.com): " DOMAIN
while [ -z "${DOMAIN// }" ]; do
  read -r -p "Domain cannot be empty. Enter domain: " DOMAIN
done

read -r -p "Enter Let's Encrypt email: " LE_EMAIL
while [ -z "${LE_EMAIL// }" ]; do
  read -r -p "Email cannot be empty. Enter Let's Encrypt email: " LE_EMAIL
done

read -r -p "Enter OpenWebUI admin email: " OPENWEBUI_ADMIN_EMAIL
while [ -z "${OPENWEBUI_ADMIN_EMAIL// }" ]; do
  read -r -p "Admin email cannot be empty. Enter OpenWebUI admin email: " OPENWEBUI_ADMIN_EMAIL
done

read -r -p "Enter server IP (e.g., 203.0.113.10): " SERVER_IP
while [ -z "${SERVER_IP// }" ]; do
  read -r -p "Server IP cannot be empty. Enter server IP: " SERVER_IP
done

export DOMAIN LE_EMAIL OPENWEBUI_ADMIN_EMAIL SERVER_IP

generate_webui_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    printf "\n"
  fi
}

generate_db_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    printf "\n"
  fi
}

generate_admin_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    printf "\n"
  fi
}

for file in "${FILES_DOMAIN[@]}"; do
  if [ -f "$file" ]; then
    perl -pi -e 's/YOUR_DOMAIN_HERE/$ENV{DOMAIN}/g' "$file"
  fi
done

for file in "${FILES_EMAIL[@]}"; do
  if [ -f "$file" ]; then
    perl -pi -e 's/YOUR_LETSENCRYPT_EMAIL/$ENV{LE_EMAIL}/g' "$file"
  fi
done

if [ -f "$FILE_COMPOSE" ]; then
  perl -pi -e 's/YOUR_OPENWEBUI_ADMIN_EMAIL/$ENV{OPENWEBUI_ADMIN_EMAIL}/g' "$FILE_COMPOSE"
fi

if [ -n "$DOC_PATH" ] && [ -f "$DOC_PATH" ]; then
  perl -pi -e 's/YOUR_DOMAIN_HERE/$ENV{DOMAIN}/g' "$DOC_PATH"
  perl -pi -e 's/YOUR_SERVER_IP/$ENV{SERVER_IP}/g' "$DOC_PATH"
fi

if [ -f "$FILE_COMPOSE" ]; then
  WEBUI_SECRET_KEY="$(generate_webui_secret)"
  DB_PASSWORD="$(generate_db_password)"
  OPENWEBUI_ADMIN_PASSWORD="$(generate_admin_password)"
  export WEBUI_SECRET_KEY
  export DB_PASSWORD
  export OPENWEBUI_ADMIN_PASSWORD
  perl -pi -e 's/CHANGE_ME_TO_A_LONG_RANDOM_SECRET/$ENV{WEBUI_SECRET_KEY}/g' "$FILE_COMPOSE"
  perl -pi -e 's/CHANGE_ME_DB_PASSWORD/$ENV{DB_PASSWORD}/g' "$FILE_COMPOSE"
  perl -pi -e 's/CHANGE_ME_OPENWEBUI_ADMIN_PASSWORD/$ENV{OPENWEBUI_ADMIN_PASSWORD}/g' "$FILE_COMPOSE"
fi

echo "Template fill complete."
echo "Updated domain in:"
for file in "${FILES_DOMAIN[@]}"; do
  [ -f "$file" ] && echo "  - $file"
done

echo "Updated Let's Encrypt email in:"
for file in "${FILES_EMAIL[@]}"; do
  [ -f "$file" ] && echo "  - $file"
done

if [ -f "$FILE_COMPOSE" ]; then
  echo "Generated WEBUI_SECRET_KEY in:"
  echo "  - $FILE_COMPOSE"
  echo "Generated Postgres password in:"
  echo "  - $FILE_COMPOSE"
  echo "Configured OpenWebUI admin credentials in:"
  echo "  - $FILE_COMPOSE"
fi

if [ -n "$DOC_PATH" ] && [ -f "$DOC_PATH" ]; then
  echo "Updated documentation in:"
  echo "  - $DOC_PATH"
else
  echo "Warning: template/openwebui/docs/technical-documentation.md not found."
fi

echo
echo "Reminder: review values in $COMPOSE_DIR/docker-compose.yml before production."
echo
echo "OpenWebUI initial admin credentials (first startup with empty database only):"
echo "  Email:    $OPENWEBUI_ADMIN_EMAIL"
if [ -n "${OPENWEBUI_ADMIN_PASSWORD:-}" ]; then
  echo "  Password: $OPENWEBUI_ADMIN_PASSWORD"
fi
