# OpenWebUI Deployment Template

This repository contains a ready-to-use deployment template in [`openwebui/`](./openwebui) for running **OpenWebUI** in production with:

- Docker Compose
- PostgreSQL (persistent storage)
- Nginx reverse proxy
- Let's Encrypt TLS certificates via Certbot
- Automated certificate renewal
- Automated PostgreSQL backups
- Automatic OS security updates
- One-command updates (`openwebui-update`) with rollback

## What This Template Does

The template is designed for a fresh Linux server and provides scripts to:

1. Fill all placeholders (domain, emails, secrets, passwords).
2. Install Docker and required OS packages.
3. Start the OpenWebUI stack.
4. Issue the first TLS certificate.
5. Enable HTTPS in Nginx.
6. Install cron jobs for renewal and backups.
7. Enable automatic security updates and install the `openwebui-update` command.

## Repository Structure

```text
openwebui/
├── fill-template.sh                 # Run locally to replace placeholders and generate secrets
├── setup.sh                         # Run on server for first-time setup
├── openwebui_backup.sh              # Database backup script
├── update.sh                        # Update with automatic version pick and rollback
├── auto-updates.sh                  # Enables automatic OS security updates (called by setup.sh)
├── docs/
│   ├── technical-documentation.md   # Detailed architecture/ops notes
│   └── nachruestung-bestehender-server.md  # Retrofitting existing customer servers (German)
└── openwebui-docker/
    ├── docker-compose.yml
    ├── .env                         # Created by fill-template.sh (secrets, git-ignored)
    ├── issue-cert.sh
    ├── renew-cert.sh
    ├── README.md
    └── nginx/conf.d/openwebui.conf
```

## Prerequisites

- A domain name pointing to your server IP
- A fresh Ubuntu or Debian server with root access
- At least **80 GB** disk (40 GB is not enough once vector data, the embedding model cache and a second Open WebUI image during updates come together)
- Ports `80` and `443` open in firewall/security group
- `bash`, `perl`, and `openssl` available on the machine where you run `fill-template.sh`

## Quick Start

### 1) Configure the Template (local machine)

From this repository root:

```bash
cd openwebui
./fill-template.sh
```

`fill-template.sh` will prompt for:

- Domain (for example `chat.example.com`)
- Let's Encrypt email
- OpenWebUI admin email
- Server IP

It also generates:

- `WEBUI_SECRET_KEY`
- PostgreSQL password
- OpenWebUI admin password

`fill-template.sh` writes the secrets and the admin email into `openwebui/openwebui-docker/.env`.
This file is ignored by git, so passwords never end up in a commit. It refuses to overwrite an existing `.env` with secrets.

Domain and Let's Encrypt email are written into:

- `openwebui/openwebui-docker/docker-compose.yml`
- `openwebui/openwebui-docker/nginx/conf.d/openwebui.conf`
- `openwebui/openwebui-docker/issue-cert.sh`
- `openwebui/openwebui-docker/README.md`
- `openwebui/docs/technical-documentation.md`

After it finishes, verify that `openwebui/openwebui-docker/.env` exists and that placeholders are gone in the deployment-critical files:

- `openwebui/openwebui-docker/docker-compose.yml`
- `openwebui/openwebui-docker/nginx/conf.d/openwebui.conf`
- `openwebui/openwebui-docker/issue-cert.sh`

Specifically check these placeholder strings are no longer present:

- `YOUR_DOMAIN_HERE`
- `YOUR_LETSENCRYPT_EMAIL`
- `YOUR_OPENWEBUI_ADMIN_EMAIL`

`fill-template.sh` also prints the initial OpenWebUI admin login (email + generated password). Save this output securely (password manager, vault, or encrypted notes), because you will need it to log in to the web interface as admin.

### 2) Copy the template to server

Copy the whole `openwebui/` directory (including the hidden `openwebui-docker/.env`) to:

```text
/root/openwebui
```

Example:

```bash
cd /path/to/this/repo
scp -r ./openwebui root@<your-server-ip>:/root/
```

### 3) Run server setup

On the server:

```bash
cd /root/openwebui
./setup.sh
```

`setup.sh` will:

- Check that placeholders are gone and `.env` contains all secrets
- Install/update packages (`curl`, `git`, `ufw`)
- Enable the firewall (`ufw`) for SSH, `80` and `443`
- Install and start Docker
- Start containers
- Issue initial TLS certificate
- Reload Nginx with HTTPS enabled
- Add cron jobs for renewal and backups
- Enable automatic security updates (`auto-updates.sh`)
- Install the `openwebui-update` command

## Access

After setup, OpenWebUI should be available at:

```text
https://<the-domain-you-entered-in-fill-template.sh>
```

Use the admin credentials printed by `fill-template.sh` for first login.

## Included Services

Defined in `openwebui/openwebui-docker/docker-compose.yml`:

- `openwebui`
- `postgres`
- `nginx`
- `certbot`

## Operations

### Certificate Renewal

- Script: `openwebui/openwebui-docker/renew-cert.sh`
- Cron: `0 3 * * *` (daily at 03:00)
- Log: `/root/openwebui/openwebui-docker/renew.log`

### Database Backups

- Script: `openwebui/openwebui_backup.sh`
- Cron: `0 1 * * *` (daily at 01:00)
- Output: `/root/openwebui/backups/openwebui_*.sql.gz`
- Log: `/root/openwebui/backup.log`
- Retention: backups older than 7 days are deleted
- These backups live on the same disk as the data. Enable Hetzner Backups or regular snapshots in addition, so a lost or broken disk does not take the backups with it.

### Automatic Security Updates

- Script: `openwebui/auto-updates.sh` (run by `setup.sh`, safe to run again)
- Uses `unattended-upgrades` with security sources only; Docker packages are never updated automatically
- Installs daily at 03:30 and reboots at 04:00 only if an update requires it

### Updates

- Script: `openwebui/update.sh`, after setup also available as `openwebui-update`
- Installs all pending OS updates first (including Docker), then picks the newest stable Open WebUI release that is at least 7 days old, backs up the database, starts the new version and rolls back automatically on failure
- If the OS needs a reboot afterwards it asks (with `-y` it reboots directly); Open WebUI is then unavailable for 1 to 2 minutes
- `openwebui-update --check` only reports whether an update is due and changes nothing
- Log: `/root/openwebui/update.log`
- Details: [`openwebui/openwebui-docker/README.md`](./openwebui/openwebui-docker/README.md)

## Notes and Caveats

- The admin bootstrap (`WEBUI_ADMIN_EMAIL` + `WEBUI_ADMIN_PASSWORD`) is only used on first startup with an empty database.
- The template sets `ENABLE_SIGNUP=false` by default.
- Secrets live only in `openwebui/openwebui-docker/.env`. Keep a copy in a password manager or vault; without it the database password is lost.
- Installations created before the `.env` change keep their secrets in `docker-compose.yml`. Do not replace that file on such servers without first moving the values into `.env`.
- Nginx resolves the `openwebui` container on every request (Docker DNS), so a recreated or restarted container never causes 502 Bad Gateway.
- Existing servers set up before these changes: see [`openwebui/docs/nachruestung-bestehender-server.md`](./openwebui/docs/nachruestung-bestehender-server.md).
- Persistent data is stored under:
  - `openwebui/openwebui-docker/storage/openwebui`
  - `openwebui/openwebui-docker/storage/postgres`

## Additional Documentation

For technical/architecture details, see:

- [`openwebui/docs/technical-documentation.md`](./openwebui/docs/technical-documentation.md)
- [`openwebui/openwebui-docker/README.md`](./openwebui/openwebui-docker/README.md)
- [`openwebui/docs/nachruestung-bestehender-server.md`](./openwebui/docs/nachruestung-bestehender-server.md)
