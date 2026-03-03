#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/openwebui-docker"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
BACKUP_DIR="$SCRIPT_DIR/backups"
LOGFILE="$SCRIPT_DIR/backup.log"
COMPOSE_SERVICE="postgres"
DB_NAME="openwebui"
DB_USER="openwebui"

mkdir -p "$BACKUP_DIR"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: Compose file not found at $COMPOSE_FILE" | tee -a "$LOGFILE"
  exit 1
fi

TIMESTAMP=$(date +%F_%H-%M-%S)
BACKUP_FILE="$BACKUP_DIR/openwebui_${TIMESTAMP}.sql.gz"

echo "[$TIMESTAMP] Starting backup" | tee -a "$LOGFILE"

if ! docker compose -f "$COMPOSE_FILE" exec -T "$COMPOSE_SERVICE" \
  pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$BACKUP_FILE"; then
  echo "ERROR: Backup failed during pg_dump." | tee -a "$LOGFILE"
  rm -f "$BACKUP_FILE"
  exit 1
fi

if [ ! -s "$BACKUP_FILE" ]; then
  echo "ERROR: Backup file is empty: $BACKUP_FILE" | tee -a "$LOGFILE"
  rm -f "$BACKUP_FILE"
  exit 1
fi

find "$BACKUP_DIR" -type f -name "openwebui_*.sql.gz" -mtime +7 -delete

echo "[$(date +%F_%H-%M-%S)] Backup complete and verified: $BACKUP_FILE" | tee -a "$LOGFILE"
