# OpenWebUI Docker Template

## 1) Fill Template Values (Local)

Run the template helper to:
- replace domain / Let's Encrypt placeholders
- ask for the OpenWebUI admin email
- generate the WebUI secret, Postgres password, and admin password
- print the generated admin login credentials

```bash
./fill-template.sh
```

This updates:
- `openwebui-docker/docker-compose.yml`
- `openwebui-docker/nginx/conf.d/openwebui.conf`
- `openwebui-docker/issue-cert.sh`
- `openwebui-docker/README.md`
- `template/openwebui/docs/technical-documentation.md`

## 2) Set Secrets (Local, Before Deploy)

`fill-template.sh` generates and injects these values in `openwebui-docker/docker-compose.yml`:
- `WEBUI_SECRET_KEY=CHANGE_ME_TO_A_LONG_RANDOM_SECRET`
- `POSTGRES_PASSWORD=CHANGE_ME_DB_PASSWORD`
- `DATABASE_URL=...:CHANGE_ME_DB_PASSWORD@...`
- `WEBUI_ADMIN_PASSWORD=CHANGE_ME_OPENWEBUI_ADMIN_PASSWORD`

It also asks for and injects:
- `WEBUI_ADMIN_EMAIL=YOUR_OPENWEBUI_ADMIN_EMAIL`

Review the generated values before deployment (the placeholders should be gone after running `./fill-template.sh`).
`setup.sh` also validates this and will stop if placeholders are still present.

## 3) First Login / Admin Account

The template defaults to:
- `ENABLE_SIGNUP=false`

This template is configured for headless admin creation on first startup using:
- `WEBUI_ADMIN_EMAIL`
- `WEBUI_ADMIN_PASSWORD`

`fill-template.sh` asks for the admin email, generates the admin password automatically, and prints both values at the end for convenience.

Important:
- The admin account is only auto-created on first startup when the database is empty.
- If users already exist, these variables are ignored.
- OpenWebUI disables sign-up after admin creation (which matches this template default).

## 4) Server Setup (After Copying to `/root/openwebui`)

After copying the entire `template/openwebui` folder to `/root/openwebui` on a fresh server, run:

```bash
/root/openwebui/setup.sh
```

This script performs:
- OS update + installs `curl`, `git`, and `ufw`
- Docker installation and service enable/start
- Temporarily disables the HTTPS block in Nginx for HTTP-01 validation
- Starts the Docker Compose stack
- Issues the initial TLS certificate via `issue-cert.sh`
- Re-enables HTTPS and reloads Nginx
- Adds cron jobs for nightly certificate renewal and PostgreSQL backups

## 5) Services Included

- `openwebui`
- `postgres`
- `nginx`
- `certbot`

`anythingllm` is intentionally not included in this template.

## 6) Scripts

### `issue-cert.sh`

Runs one-time certificate issuance for `YOUR_DOMAIN_HERE` using the webroot challenge.
Email placeholder: `YOUR_LETSENCRYPT_EMAIL`.

### `renew-cert.sh`

Runs `certbot renew`, reloads nginx on success, and logs to `openwebui-docker/renew.log`.
If the log exceeds 1MB it is rotated with a timestamp suffix.

### `openwebui_backup.sh`

Creates a gzip-compressed PostgreSQL dump under `./backups` next to the script.
Uses the Compose file at `/root/openwebui/openwebui-docker/docker-compose.yml` to reach the `postgres` service.
Writes a log to `/root/openwebui/backup.log` and fails if the dump is empty.
If a failure occurs after a file is created, the empty file is removed.
Backups older than 7 days are deleted automatically.

## 7) Cron

Nightly certificate renewal at 3am:

```bash
0 3 * * * /bin/bash /root/openwebui/openwebui-docker/renew-cert.sh
```

Nightly PostgreSQL backup at 1am:

```bash
0 1 * * * /bin/bash /root/openwebui/openwebui_backup.sh
```

## 8) Updates

`/root/openwebui/update.sh` (nach dem Setup auch als Befehl `openwebui-update`) aktualisiert Open WebUI:

- wählt automatisch die neueste stabile Version, die mindestens 7 Tage alt ist (nie ein Downgrade)
- löscht vorher ungenutzte Images und prüft den Speicherplatz
- sichert die Datenbank über `openwebui_backup.sh` (Vektordaten werden nicht gesichert)
- startet die neue Version und prüft den Health-Check
- spielt bei einem Fehler Datenbank und alte Version automatisch zurück
- startet nginx nach dem Update neu (sonst 502, weil nginx die alte Container-IP behält)
- löscht alte Images erst nach erfolgreichem Update
- schreibt alles nach `/root/openwebui/update.log`

Die eingestellte Version steht in `openwebui-docker/.env` (`OPENWEBUI_VERSION`). Ohne Eintrag gilt `main`.
Bestehende Installationen mit festem `:main` in der `docker-compose.yml` werden beim ersten Lauf automatisch umgestellt.

```bash
openwebui-update                    # mit Rückfrage
openwebui-update --check            # nur prüfen, ob ein Update fällig ist
openwebui-update --version v0.9.5   # bestimmte Version erzwingen
```

Bestehende Server einmalig nachrüsten:

```bash
chmod +x /root/openwebui/update.sh
ln -sf /root/openwebui/update.sh /usr/local/bin/openwebui-update
```

### Anleitung für Kund:innen

1. In der Hetzner Cloud Console den Server öffnen und auf **Konsole** (`>_`) klicken.
2. Als `root` anmelden.
3. `openwebui-update` eintippen, Enter, Frage mit `j` bestätigen.
4. Warten bis „Fertig“ erscheint (meist 3 bis 5 Minuten), dann im Browser anmelden und eine Frage stellen.

„Ihr seid auf dem aktuellen Stand“ heißt: nichts zu tun.
Ein roter **FEHLER** heißt: Die alte Version läuft weiter. Bitte `update.log` oder ein Foto des Bildschirms schicken.
