# Technical Documentation

## Overview
This system hosts an OpenWebUI application with PostgreSQL, fronted by Nginx and secured via Let's Encrypt certificates managed by Certbot. The deployment uses Docker Compose and stores persistent application and database data on the server filesystem.

## Hosting Environment
- Provider: Hetzner
- Server: `cx22` (adjust as needed)
- vCPU: 2
- RAM: 4 GB
- Disk: 40 GB (local)
- Snapshots: daily, trailing 7 days

## Network and Access
- Public IP: `YOUR_SERVER_IP`
- Domain: `YOUR_DOMAIN_HERE`
- Firewall open ports:
  - `22` (SSH)
  - `80` (HTTP)
  - `443` (HTTPS)

## Tech Stack
- **Docker Compose**: Orchestrates all services as containers with a shared network.
- **OpenWebUI**: Main application UI/API.
- **PostgreSQL**: Database backend for OpenWebUI.
- **Nginx**: Reverse proxy providing HTTPS termination and routing to OpenWebUI.
- **Certbot**: Handles TLS certificate issuance and renewal via HTTP-01 webroot.

## Components and Responsibilities
- **OpenWebUI**
  - Runs the application UI and backend.
  - Listens on port `8080` inside the Docker network and is accessed externally only through Nginx on `80/443`.
  - Persists application data to `storage/openwebui` on disk.
  - Supports headless admin bootstrap on first startup using `WEBUI_ADMIN_EMAIL` and `WEBUI_ADMIN_PASSWORD`.

- **PostgreSQL**
  - Stores OpenWebUI application data.
  - Data directory is persisted to `storage/postgres` on disk.

- **Nginx**
  - Listens on ports `80` and `443`.
  - Routes traffic for `YOUR_DOMAIN_HERE` to the `openwebui` service.
  - Serves `/.well-known/acme-challenge/` for Let's Encrypt validation.

- **Certbot**
  - Issues initial certificates via `issue-cert.sh` (HTTP-01 webroot).
  - Renews certificates via `renew-cert.sh`.

## Information Flow
1. **User Access**
   - User requests `https://YOUR_DOMAIN_HERE`.
   - Nginx terminates TLS and proxies traffic to the OpenWebUI container.

2. **Application Data**
   - OpenWebUI reads/writes application data to PostgreSQL.
   - OpenWebUI runtime/application data is stored in `storage/openwebui`.

3. **Certificates**
   - Certbot validates via HTTP-01 through Nginx and stores certs under the Nginx/Certbot directories.

## Backups and Exports
- **Database exports** are handled by `openwebui_backup.sh`.
  - Schedule: daily at **01:00**.
  - Output: gzip-compressed SQL dumps stored in `/root/openwebui/backups/`.
  - Logging: `/root/openwebui/backup.log`.
  - Safety: fails if dump is empty and removes empty files on failure.

## Certificates and Renewal
- **Initial issuance**: `issue-cert.sh` (HTTP-01 webroot).
- **Renewals**: `renew-cert.sh`.
  - Schedule: daily at **03:00**.
  - Logs: `/root/openwebui/openwebui-docker/renew.log`.
  - Log rotation: rotates when the log exceeds 1MB.

## Scripts

### `issue-cert.sh`
Purpose:
- Runs a one-time `certbot certonly --webroot` flow for `YOUR_DOMAIN_HERE`.
- Uses `/var/www/certbot` as the webroot for the ACME HTTP-01 challenge.
- Writes certificates under `/root/openwebui/openwebui-docker/nginx/certbot/conf` on the host.

How it is invoked:
- Automatically by `/root/openwebui/setup.sh` after the Docker stack starts.
- Can also be run manually: `/root/openwebui/openwebui-docker/issue-cert.sh`

### `renew-cert.sh`
Purpose:
- Runs `certbot renew` to refresh certificates.
- Reloads Nginx if renewal succeeds.
- Appends logs to `/root/openwebui/openwebui-docker/renew.log` and rotates when the log exceeds 1MB.

Cron schedule:
- Runs daily at **03:00** as root.
- Crontab entry:

```
0 3 * * * /bin/bash /root/openwebui/openwebui-docker/renew-cert.sh
```

### `openwebui_backup.sh`
Purpose:
- Executes a PostgreSQL dump from the `postgres` service using Docker Compose.
- Compresses the output (`.sql.gz`) and stores it in `/root/openwebui/backups/`.
- Verifies the dump is non-empty; removes empty files on failure.
- Appends logs to `/root/openwebui/backup.log`.

Cron schedule:
- Runs daily at **01:00** as root.
- Crontab entry:

```
0 1 * * * /bin/bash /root/openwebui/openwebui_backup.sh
```

## Directory Structure (Server)
- `/root/openwebui/`
  - `openwebui-docker/` (Compose files, Nginx config, Certbot config)
  - `openwebui_backup.sh` (database backup script)
  - `backups/` (database dumps)
  - `backup.log` (backup execution log)

## Notes
- Persistent data is stored on the host filesystem to ensure data survives container restarts.
- The PostgreSQL data directory must be empty on first startup (do not place placeholder files inside `storage/postgres`).
- `ENABLE_SIGNUP=false` is used together with headless admin bootstrap variables for first startup on a fresh database.
