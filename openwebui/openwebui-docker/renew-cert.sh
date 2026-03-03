#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

NOW=$(date +"%Y-%m-%d %H:%M:%S")
LOGFILE="$PROJECT_DIR/renew.log"

if [ -f "$LOGFILE" ]; then
  LOG_SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
  if [ "$LOG_SIZE" -ge 1048576 ]; then
    mv "$LOGFILE" "${LOGFILE}.$(date +"%Y-%m-%d_%H-%M-%S")"
  fi
fi

echo "[$NOW] Starting certificate renewal..." >> "$LOGFILE"

cd "$PROJECT_DIR"

if docker compose run --rm certbot renew >> "$LOGFILE" 2>&1; then
  echo "[$NOW] Certbot renew completed successfully." >> "$LOGFILE"
  docker compose exec nginx nginx -s reload >> "$LOGFILE" 2>&1
  echo "[$NOW] Nginx reloaded." >> "$LOGFILE"
else
  echo "[$NOW] Certbot renew failed." >> "$LOGFILE"
  exit 1
fi
