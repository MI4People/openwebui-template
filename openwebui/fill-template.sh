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
ENV_FILE="$COMPOSE_DIR/.env"

# Secrets landen in openwebui-docker/.env (von Git ignoriert), nicht in
# versionierten Dateien. Eine vorhandene .env wird nie überschrieben, weil die
# Datenbank sonst nicht mehr zum Passwort passt.
if [ -f "$ENV_FILE" ] && grep -qE '^(WEBUI_SECRET_KEY|POSTGRES_PASSWORD|WEBUI_ADMIN_PASSWORD)=.+' "$ENV_FILE"; then
  echo "ERROR: $ENV_FILE already contains secrets. Refusing to overwrite them." >&2
  echo "Delete the file manually if you really want to generate new secrets." >&2
  exit 1
fi

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

if [ -n "$DOC_PATH" ] && [ -f "$DOC_PATH" ]; then
  perl -pi -e 's/YOUR_DOMAIN_HERE/$ENV{DOMAIN}/g' "$DOC_PATH"
  perl -pi -e 's/YOUR_SERVER_IP/$ENV{SERVER_IP}/g' "$DOC_PATH"
fi

WEBUI_SECRET_KEY="$(generate_webui_secret)"
DB_PASSWORD="$(generate_db_password)"
OPENWEBUI_ADMIN_PASSWORD="$(generate_admin_password)"

# Bestehende Einträge (z. B. OPENWEBUI_VERSION) bleiben erhalten.
(
  umask 077
  touch "$ENV_FILE"
  {
    echo "WEBUI_SECRET_KEY=$WEBUI_SECRET_KEY"
    echo "POSTGRES_PASSWORD=$DB_PASSWORD"
    echo "WEBUI_ADMIN_EMAIL=$OPENWEBUI_ADMIN_EMAIL"
    echo "WEBUI_ADMIN_PASSWORD=$OPENWEBUI_ADMIN_PASSWORD"
  } >> "$ENV_FILE"
)
chmod 600 "$ENV_FILE"

echo "Template fill complete."
echo "Updated domain in:"
for file in "${FILES_DOMAIN[@]}"; do
  [ -f "$file" ] && echo "  - $file"
done

echo "Updated Let's Encrypt email in:"
for file in "${FILES_EMAIL[@]}"; do
  [ -f "$file" ] && echo "  - $file"
done

echo "Wrote secrets (WEBUI_SECRET_KEY, Postgres password, admin credentials) to:"
echo "  - $ENV_FILE  (ignored by git, copy it to the server together with the rest)"

if [ -n "$DOC_PATH" ] && [ -f "$DOC_PATH" ]; then
  echo "Updated documentation in:"
  echo "  - $DOC_PATH"
else
  echo "Warning: docs/technical-documentation.md not found."
fi

echo
echo "Reminder: review values in $COMPOSE_DIR/docker-compose.yml and $ENV_FILE before production."
echo
echo "OpenWebUI initial admin credentials (first startup with empty database only):"
echo "  Email:    $OPENWEBUI_ADMIN_EMAIL"
echo "  Password: $OPENWEBUI_ADMIN_PASSWORD"
