#!/usr/bin/env bash
#
# Open WebUI: Update mit automatischer Versionswahl und Rollback,
# dazu Systemupdates (Ubuntu/Debian inklusive Docker) und bei Bedarf Neustart
#
# Ablage: /root/openwebui/update.sh (neben setup.sh und openwebui_backup.sh)
#
# Aufruf:
#   /root/openwebui/update.sh                  mit Rückfrage
#   /root/openwebui/update.sh -y               ohne Rückfrage, startet bei Bedarf auch neu
#   /root/openwebui/update.sh --check          nur anzeigen, was passieren würde
#   /root/openwebui/update.sh --version v0.9.5 bestimmte Version erzwingen
#   /root/openwebui/update.sh --skip-system    keine Systemupdates, nur Open WebUI
#   /root/openwebui/update.sh --no-reboot      nie neu starten, nur Hinweis ausgeben
#
#   HEALTH_TIMEOUT=10 /root/openwebui/update.sh ...   kürzere Wartezeit (z. B. Rollback-Test)
#
# Versionswahl:
#   Das Skript nimmt die neueste stabile Open-WebUI-Version, die seit mindestens
#   MIN_AGE_DAYS Tagen veröffentlicht ist. Ganz frische Releases werden also
#   automatisch übersprungen, bis sie sich bewährt haben. Es wird nie auf eine
#   ältere Version zurückgegangen.
#
# Ablauf:
#   1. Prüfen, ob Open WebUI und/oder das System Updates brauchen
#   2. Systemupdates installieren (zuerst, weil ein Docker-Upgrade alle
#      Container neu startet; das soll nicht mitten im Open-WebUI-Update passieren)
#   3. Ungenutzte Images löschen, Speicherplatz prüfen
#   4. Datenbank sichern (Vektordaten werden aus Platzgründen nicht gesichert)
#   5. Neue Version starten, Funktion prüfen
#   6. Bei Fehler: automatisch alte Version und Datenbank zurück
#   7. Bei Erfolg: alte Images löschen
#   8. Falls das System es verlangt: Neustart (nach Rückfrage, mit -y sofort)
#
# Nutzerdaten (Ordner "storage") werden nie gelöscht.
#

set -euo pipefail

# ---------- Einstellungen ----------
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"   # folgt der Verknüpfung openwebui-update
COMPOSE_DIR="$SCRIPT_DIR/openwebui-docker"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
ENV_FILE="$COMPOSE_DIR/.env"
BACKUP_SCRIPT="$SCRIPT_DIR/openwebui_backup.sh"
BACKUP_DIR="$SCRIPT_DIR/backups"
APP_SERVICE="openwebui"
APP_CONTAINER="openwebui"
DB_SERVICE="postgres"
DB_CONTAINER="openwebui-postgres"
NGINX_SERVICE="nginx"
DB_NAME="openwebui"
DB_USER="openwebui"
RELEASES_URL="https://api.github.com/repos/open-webui/open-webui/releases?per_page=30"
MIN_AGE_DAYS=7          # so alt muss ein Release mindestens sein
MIN_FREE_GB=8           # Platz für das neue Image
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"   # Sekunden, die auf den Start gewartet wird
REBOOT_FILE="/var/run/reboot-required"
LOG_FILE="$SCRIPT_DIR/update.log"

ASSUME_YES=0
CHECK_ONLY=0
SKIP_SYSTEM=0
NO_REBOOT=0
FORCED_VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)   ASSUME_YES=1 ;;
    --check)    CHECK_ONLY=1 ;;
    --version)  FORCED_VERSION="${2:-}"; shift ;;
    --skip-system) SKIP_SYSTEM=1 ;;
    --no-reboot)   NO_REBOOT=1 ;;
    *) echo "Unbekannte Option: $1"; exit 2 ;;
  esac
  shift
done

# ---------- Ausgabe ----------
if [ -t 1 ]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_INFO=$'\e[36m'; C_END=$'\e[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_INFO=""; C_END=""
fi
step() { echo; echo "${C_INFO}==> $*${C_END}"; }
ok()   { echo "${C_OK}  OK: $*${C_END}"; }
warn() { echo "${C_WARN}  ACHTUNG: $*${C_END}"; }
fail() {
  echo "${C_ERR}  FEHLER: $*${C_END}"
  echo
  echo "Das Update wurde abgebrochen. Eure Daten wurden nicht verändert."
  echo "Bei Fragen bitte diese Datei mitschicken: $LOG_FILE"
  exit 1
}

exec > >(tee -a "$LOG_FILE") 2>&1
echo
echo "################ Update gestartet: $(date '+%d.%m.%Y %H:%M:%S') ################"

# ---------- Hilfsfunktionen ----------
free_gb() { df -BG --output=avail "$SCRIPT_DIR" | tail -1 | tr -dc '0-9'; }

# Laufende Version aus der App selbst, z. B. "0.9.5"
running_version() {
  docker exec "$APP_CONTAINER" curl -fsS http://localhost:8080/api/version 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true
}

# Eingestellter Image-Tag aus .env (Standard "main" wie im alten Template)
configured_tag() {
  if [ -f "$ENV_FILE" ] && grep -q '^OPENWEBUI_VERSION=' "$ENV_FILE"; then
    grep '^OPENWEBUI_VERSION=' "$ENV_FILE" | tail -1 | cut -d= -f2-
  else
    echo "main"
  fi
}

set_tag() {
  touch "$ENV_FILE"
  if grep -q '^OPENWEBUI_VERSION=' "$ENV_FILE"; then
    sed -i "s|^OPENWEBUI_VERSION=.*|OPENWEBUI_VERSION=$1|" "$ENV_FILE"
  else
    echo "OPENWEBUI_VERSION=$1" >> "$ENV_FILE"
  fi
}

# Stabile Releases auswerten. Ausgabe (eine Zeile, durch | getrennt):
#   Ziel | Neueste | Neueste veröffentlicht am | Neueste installierbar ab
# Ziel = neueste stabile Version, die mindestens MIN_AGE_DAYS alt ist.
# Neueste = neueste stabile Version überhaupt (die zeigt auch der Hinweis in Open WebUI).
pick_release() {
  curl -fsS --max-time 20 -H "Accept: application/vnd.github+json" "$RELEASES_URL" \
    | python3 -c '
import json, sys, datetime
min_age = datetime.timedelta(days=int(sys.argv[1]))
now = datetime.datetime.now(datetime.timezone.utc)
target = newest = newest_pub = newest_ready = ""
for r in json.load(sys.stdin):
    if r.get("draft") or r.get("prerelease"):
        continue
    pub = datetime.datetime.fromisoformat(r["published_at"].replace("Z", "+00:00"))
    if not newest:
        newest = r["tag_name"]
        newest_pub = pub.strftime("%d.%m.%Y")
        newest_ready = (pub + min_age).strftime("%d.%m.%Y")
    if now - pub >= min_age:
        target = r["tag_name"]
        break
if newest:
    print("|".join([target, newest, newest_pub, newest_ready]))
' "$MIN_AGE_DAYS"
}

# 0 wenn $1 echt neuer als $2 ist (ohne führendes v)
is_newer() {
  local a="${1#v}" b="${2#v}"
  [ "$a" != "$b" ] && [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)" = "$a" ]
}

wait_healthy() {
  local waited=0 status db_restarting
  while :; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$APP_CONTAINER" 2>/dev/null || echo fehlt)"
    db_restarting="$(docker inspect -f '{{.State.Restarting}}' "$DB_CONTAINER" 2>/dev/null || echo true)"
    if [ "$status" = "healthy" ] && [ "$db_restarting" = "false" ]; then
      echo; return 0
    fi
    if [ "$status" = "unhealthy" ] || [ "$waited" -ge "$HEALTH_TIMEOUT" ]; then
      echo; return 1
    fi
    printf "."
    sleep 5
    waited=$((waited + 5))
  done
}

# Ältere nginx-Konfigurationen (ohne "resolver") merken sich die interne IP von
# Open WebUI nur beim eigenen Start. Neu starten schadet nie und verhindert dort 502.
restart_nginx() {
  docker compose restart "$NGINX_SERVICE" >/dev/null 2>&1 || return 1
  sleep 3
  [ "$(docker compose ps --format '{{.State}}' "$NGINX_SERVICE" 2>/dev/null)" = "running" ]
}

# apt-get ohne Rückfragen; bei geänderten Konfigurationsdateien die vorhandene behalten.
# Wartet bis zu 5 Minuten, falls gerade die automatischen Sicherheitsupdates laufen.
apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -y -q \
    -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

# Namen der Pakete, die "apt-get upgrade --with-new-pkgs" installieren würde.
# --with-new-pkgs: auch neue Kernel (brauchen neue Pakete), aber nie etwas entfernen.
pending_packages() {
  apt-get -s -o Debug::NoLocking=1 upgrade --with-new-pkgs 2>/dev/null | awk '/^Inst /{print $2}'
}

wait_docker() {
  local waited=0
  until docker info >/dev/null 2>&1; do
    [ "$waited" -ge 120 ] && return 1
    sleep 5; waited=$((waited + 5))
  done
}

offer_reboot() {
  [ -f "$REBOOT_FILE" ] || return 0
  echo
  warn "Der Server muss neu starten, damit alle Systemupdates wirksam werden."
  if [ "$NO_REBOOT" = 1 ]; then
    echo "  Neustart übersprungen (--no-reboot). Später mit dem Befehl: reboot"
    return 0
  fi
  echo "  Open WebUI ist dabei etwa 1 bis 2 Minuten nicht erreichbar und startet von selbst wieder."
  if [ "$ASSUME_YES" != 1 ]; then
    read -r -p "Jetzt neu starten? [j/N] " answer
    case "$answer" in
      j|J|ja|Ja|y|Y) ;;
      *) echo "  Kein Neustart. Bitte bald nachholen, z. B. abends mit dem Befehl: reboot"; return 0 ;;
    esac
  fi
  echo "  Der Server startet in 10 Sekunden neu. Die Verbindung zur Konsole bricht dabei ab."
  echo "  Danach etwa 2 Minuten warten und Open WebUI im Browser öffnen."
  echo "################ Neustart: $(date '+%d.%m.%Y %H:%M:%S') ################"
  sleep 10
  systemctl reboot
  exit 0
}

db_stable() {
  [ "$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' "$DB_CONTAINER" 2>/dev/null || echo 'false false')" = "true false" ]
}

# ---------- 0. Voraussetzungen ----------
step "Voraussetzungen prüfen"
[ -f "$COMPOSE_FILE" ]  || fail "Keine docker-compose.yml in $COMPOSE_DIR. Das Skript muss in /root/openwebui liegen."
[ -f "$BACKUP_SCRIPT" ] || fail "Backup-Skript $BACKUP_SCRIPT nicht gefunden."
docker info >/dev/null 2>&1           || fail "Kein Zugriff auf Docker. Bitte als root starten."
docker compose version >/dev/null 2>&1 || fail "'docker compose' ist nicht installiert."
command -v python3 >/dev/null || fail "python3 fehlt (apt install -y python3)."
command -v curl >/dev/null    || fail "curl fehlt (apt install -y curl)."
cd "$COMPOSE_DIR"

# Einmalige Umstellung alter Installationen von festem ":main" auf die Variable
if grep -q 'open-webui/open-webui:main' "$COMPOSE_FILE"; then
  if [ "$CHECK_ONLY" = 1 ]; then
    warn "docker-compose.yml nutzt noch festes ':main'. Wird beim echten Update umgestellt (Prüfmodus ändert nichts)."
  else
    cp "$COMPOSE_FILE" "$COMPOSE_FILE.vor-update-umstellung"
    sed -i 's|open-webui/open-webui:main|open-webui/open-webui:${OPENWEBUI_VERSION:-main}|' "$COMPOSE_FILE"
    ok "docker-compose.yml auf steuerbare Version umgestellt (Kopie: docker-compose.yml.vor-update-umstellung)"
  fi
fi
[ "$CHECK_ONLY" = 1 ] || grep -q 'OPENWEBUI_VERSION' "$COMPOSE_FILE" \
  || fail "docker-compose.yml nutzt kein OPENWEBUI_VERSION. Bitte Image-Zeile prüfen."
ok "Docker erreichbar"

# ---------- 1. Prüfen, was zu tun ist ----------
step "Open-WebUI-Version bestimmen"
PREV_TAG="$(configured_tag)"
CURRENT="$(running_version)"
APP_UPDATE=0
TARGET=""
NEWEST=""
PENDING_MSG=""
echo "  Eingestellt:  $PREV_TAG"
echo "  Läuft:        ${CURRENT:-unbekannt (App läuft gerade nicht)}"

if [ -n "$FORCED_VERSION" ]; then
  TARGET="$FORCED_VERSION"
  APP_UPDATE=1
  warn "Version manuell vorgegeben: $TARGET"
else
  RELEASE_INFO="$(pick_release || true)"
  IFS='|' read -r TARGET NEWEST NEWEST_PUB NEWEST_READY <<< "$RELEASE_INFO"
  if [ -z "$RELEASE_INFO" ]; then
    # Systemupdates sollen nicht an einer gerade nicht erreichbaren GitHub-API scheitern.
    warn "Liste der Open-WebUI-Versionen nicht abrufbar. Open WebUI wird diesmal nicht aktualisiert."
  elif [ -z "$TARGET" ]; then
    warn "Keine Open-WebUI-Version ist älter als $MIN_AGE_DAYS Tage. Open WebUI wird diesmal nicht aktualisiert."
  else
    echo "  Ziel:         $TARGET (neueste Version, die älter als $MIN_AGE_DAYS Tage ist)"
    if [ -n "$CURRENT" ] && ! is_newer "$TARGET" "$CURRENT"; then
      ok "Open WebUI ist auf dem aktuellen Stand."
    elif [ -z "$CURRENT" ] && [ "$PREV_TAG" = "main" ]; then
      fail "Laufende Version nicht ermittelbar. Bitte zuerst 'docker compose up -d' und erneut versuchen."
    else
      APP_UPDATE=1
    fi
  fi
  # Der Hinweis in Open WebUI zeigt neue Versionen sofort, installiert wird erst nach
  # MIN_AGE_DAYS Tagen. Das erklären, damit "aktueller Stand" nicht verwirrt.
  if [ -n "$NEWEST" ] && [ "$NEWEST" != "$TARGET" ] && is_newer "$NEWEST" "${CURRENT:-0}"; then
    PENDING_MSG="Version $NEWEST wurde am $NEWEST_PUB veröffentlicht und wird zur Sicherheit erst ab dem $NEWEST_READY installiert. Der Hinweis in Open WebUI zeigt sie schon jetzt an. Bitte ab dem $NEWEST_READY erneut openwebui-update ausführen."
    echo "  Neueste:      $NEWEST (veröffentlicht am $NEWEST_PUB, installierbar ab $NEWEST_READY)"
  fi
fi

step "Systemupdates prüfen"
SYS_PACKAGES=""
SYS_COUNT=0
if [ "$SKIP_SYSTEM" = 1 ]; then
  echo "  Übersprungen (--skip-system)."
elif ! command -v apt-get >/dev/null; then
  warn "Kein apt-get gefunden, Systemupdates werden übersprungen."
else
  apt_get update -qq >/dev/null 2>&1 || warn "Paketlisten konnten nicht aktualisiert werden."
  SYS_PACKAGES="$(pending_packages || true)"
  SYS_COUNT="$(printf '%s' "$SYS_PACKAGES" | grep -c . || true)"
  if [ "$SYS_COUNT" -eq 0 ]; then
    ok "Betriebssystem ist auf dem aktuellen Stand."
  else
    echo "  $SYS_COUNT Pakete können aktualisiert werden."
    if printf '%s\n' "$SYS_PACKAGES" | grep -qE '^(docker-|containerd)'; then
      echo "  Darunter Docker: alle Container starten dabei kurz neu."
    fi
  fi
fi
[ -f "$REBOOT_FILE" ] && echo "  Ein Neustart steht bereits aus."

if [ "$APP_UPDATE" != 1 ] && [ "$SYS_COUNT" -eq 0 ]; then
  echo
  ok "Ihr seid auf dem aktuellen Stand. Kein Update nötig."
  [ -z "$PENDING_MSG" ] || echo "  $PENDING_MSG"
  if [ "$CHECK_ONLY" != 1 ]; then
    docker image prune -a -f >/dev/null 2>&1 || true
    offer_reboot
  fi
  exit 0
fi

if [ "$CHECK_ONLY" = 1 ]; then
  echo
  echo "Prüfmodus, nichts geändert. Fällig wäre:"
  [ "$APP_UPDATE" = 1 ] && echo "  - Open WebUI von ${CURRENT:-$PREV_TAG} auf $TARGET"
  [ "$SYS_COUNT" -gt 0 ] && echo "  - $SYS_COUNT Systempakete"
  [ -z "$PENDING_MSG" ] || echo "  $PENDING_MSG"
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  echo
  echo "Geplant:"
  [ "$SYS_COUNT" -gt 0 ]  && echo "  - $SYS_COUNT Systempakete aktualisieren"
  [ "$APP_UPDATE" = 1 ]   && echo "  - Open WebUI auf $TARGET aktualisieren"
  echo "  - falls nötig danach den Server neu starten (mit Rückfrage)"
  read -r -p "Update starten? Open WebUI ist einige Minuten nicht erreichbar. [j/N] " answer
  case "$answer" in j|J|ja|Ja|y|Y) ;; *) echo "Abgebrochen, nichts verändert."; exit 0 ;; esac
fi

# ---------- 2. Systemupdates ----------
if [ "$SYS_COUNT" -gt 0 ]; then
  step "Systemupdates installieren ($SYS_COUNT Pakete)"
  if apt_get upgrade --with-new-pkgs; then
    ok "Systemupdates installiert"
  else
    warn "Nicht alle Systemupdates konnten installiert werden. Es geht trotzdem weiter."
  fi
  apt_get autoremove >/dev/null 2>&1 || true

  # Nach einem Docker-Upgrade: warten, bis Docker wieder da ist, und den Stack sicher starten.
  wait_docker || fail "Docker läuft nach den Systemupdates nicht. Bitte den Server neu starten (reboot)."
  docker compose up -d >/dev/null 2>&1 || true
  if [ "$APP_UPDATE" != 1 ]; then
    printf "  Warte auf Open WebUI"
    if wait_healthy; then
      restart_nginx || true
      ok "Open WebUI läuft"
    else
      warn "Open WebUI meldet sich noch nicht. Nach einem Neustart sollte es wieder laufen."
    fi
  fi
fi

if [ "$APP_UPDATE" != 1 ]; then
  docker image prune -a -f >/dev/null 2>&1 || true
  step "Fertig"
  echo "  Open WebUI:       ${CURRENT:-$PREV_TAG} (unverändert)"
  [ -z "$PENDING_MSG" ] || echo "  $PENDING_MSG"
  echo "  Systempakete:     $SYS_COUNT aktualisiert"
  echo "  Freier Speicher:  $(free_gb) GB"
  offer_reboot
  echo
  echo "Bitte kurz im Browser prüfen: Anmelden, einen Chat öffnen, eine Frage stellen."
  exit 0
fi

# ---------- 3. Platz schaffen ----------
step "Ungenutzte Images löschen (das laufende bleibt erhalten)"
docker image prune -a -f >/dev/null
docker builder prune -f >/dev/null 2>&1 || true
FREE="$(free_gb)"
[ "$FREE" -ge "$MIN_FREE_GB" ] || fail "Nur $FREE GB frei, benötigt werden $MIN_FREE_GB GB. Der Server braucht mehr Speicher."
ok "$FREE GB frei"

# ---------- 4. Sichern ----------
step "Datenbank sichern"
if ! db_stable; then
  echo "  Datenbank läuft nicht stabil, starte sie für das Backup ..."
  docker compose up -d "$DB_SERVICE" >/dev/null 2>&1 || true
  sleep 10
  db_stable || fail "Die Datenbank startet nicht. Ohne Backup kein Update. Log: docker compose logs --tail=40 postgres"
fi
bash "$BACKUP_SCRIPT" || fail "Datenbank-Backup fehlgeschlagen. Details: $SCRIPT_DIR/backup.log"
BACKUP_FILE="$(ls -1t "$BACKUP_DIR"/openwebui_*.sql.gz | head -1)"
gzip -t "$BACKUP_FILE" || fail "Backup-Datei ist beschädigt: $BACKUP_FILE"
ok "Backup: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"

# ---------- Rollback ----------
rollback() {
  echo
  warn "Neue Version läuft nicht. Stelle den vorherigen Zustand wieder her ..."
  docker compose logs --tail=30 "$APP_SERVICE" || true
  docker compose stop "$APP_SERVICE" >/dev/null 2>&1 || true

  db_stable || { docker compose up -d "$DB_SERVICE" >/dev/null; sleep 10; }
  docker compose exec -T "$DB_SERVICE" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE);" \
    -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" >/dev/null \
    && gunzip -c "$BACKUP_FILE" | docker compose exec -T "$DB_SERVICE" \
         psql -U "$DB_USER" -d "$DB_NAME" -q -v ON_ERROR_STOP=1 >/dev/null \
    || { echo "${C_ERR}  Datenbank konnte nicht zurückgespielt werden. Backup: $BACKUP_FILE${C_END}"; exit 1; }
  ok "Datenbank zurückgespielt"

  set_tag "$PREV_TAG"
  docker compose up -d >/dev/null
  printf "  Warte auf alte Version"
  if wait_healthy; then
    restart_nginx || warn "Nginx konnte nicht neu gestartet werden. Bitte 'docker compose restart nginx' ausführen."
    echo "${C_WARN}  Die vorherige Version läuft wieder. Das Update auf $TARGET wurde nicht übernommen.${C_END}"
    echo "  Falls Wissensspeicher keine Treffer mehr liefern: Dokumente dort neu hochladen bzw. neu indexieren."
    echo "  Beim nächsten Lauf wird es erneut versucht, sobald eine neuere Version verfügbar ist."
    exit 1
  fi
  echo "${C_ERR}  Auch die vorherige Version startet nicht. Bitte Ansprechpartner kontaktieren und $LOG_FILE mitschicken.${C_END}"
  exit 1
}

# ---------- 5. Update ----------
step "Version $TARGET herunterladen"
set_tag "$TARGET"
if ! docker compose pull; then
  set_tag "$PREV_TAG"
  docker compose up -d >/dev/null
  fail "Download fehlgeschlagen. Die bisherige Version läuft weiter."
fi

step "Neue Version starten"
docker compose up -d --remove-orphans || rollback
printf "  Warte auf Open WebUI (bis zu %s Minuten)" "$((HEALTH_TIMEOUT / 60))"
wait_healthy || rollback

NEW_VERSION="$(running_version)"
if [ -n "$NEW_VERSION" ] && [ "${NEW_VERSION#v}" != "${TARGET#v}" ]; then
  warn "App meldet Version $NEW_VERSION statt $TARGET"
fi
ok "Open WebUI läuft"
restart_nginx || fail "Nginx startet nicht. Bitte Ansprechpartner kontaktieren und $LOG_FILE mitschicken."
ok "Webserver neu gestartet"

# ---------- 7. Aufräumen ----------
step "Alte Versionen löschen"
docker image prune -a -f >/dev/null
ok "Aufgeräumt"

step "Fertig"
echo "  Version vorher:   ${CURRENT:-$PREV_TAG}"
echo "  Version jetzt:    ${NEW_VERSION:-$TARGET}"
echo "  Systempakete:     $SYS_COUNT aktualisiert"
echo "  Freier Speicher:  $(free_gb) GB"
echo "  Backup:           $BACKUP_FILE"
[ -z "$PENDING_MSG" ] || echo "  $PENDING_MSG"
offer_reboot
echo
echo "Bitte kurz im Browser prüfen: Anmelden, einen Chat öffnen, eine Frage stellen."
