# OpenWebUI Deployment Template

This repository contains a ready-to-use deployment template in [`openwebui/`](./openwebui) for running **OpenWebUI** in production with:

- Docker Compose
- PostgreSQL (persistent storage)
- Nginx reverse proxy
- Let's Encrypt TLS certificates via Certbot
- Automated certificate renewal
- Automated PostgreSQL backups

## What This Template Does

The template is designed for a fresh Linux server and provides scripts to:

1. Fill all placeholders (domain, emails, secrets, passwords).
2. Install Docker and required OS packages.
3. Start the OpenWebUI stack.
4. Issue the first TLS certificate.
5. Enable HTTPS in Nginx.
6. Install cron jobs for renewal and backups.

## Repository Structure

```text
openwebui/
├── fill-template.sh                 # Run locally to replace placeholders and generate secrets
├── setup.sh                         # Run on server for first-time setup
├── openwebui_backup.sh              # Database backup script
├── docs/
│   └── technical-documentation.md   # Detailed architecture/ops notes
└── openwebui-docker/
    ├── docker-compose.yml
    ├── issue-cert.sh
    ├── renew-cert.sh
    ├── README.md
    └── nginx/conf.d/openwebui.conf
```

## Prerequisites

- A domain name pointing to your server IP
- A fresh Linux server with root access
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

`fill-template.sh` writes values into:

- `openwebui/openwebui-docker/docker-compose.yml`
- `openwebui/openwebui-docker/nginx/conf.d/openwebui.conf`
- `openwebui/openwebui-docker/issue-cert.sh`
- `openwebui/openwebui-docker/README.md`
- `openwebui/docs/technical-documentation.md`

After it finishes, verify placeholders are gone in the deployment-critical files:

- `openwebui/openwebui-docker/docker-compose.yml`
- `openwebui/openwebui-docker/nginx/conf.d/openwebui.conf`
- `openwebui/openwebui-docker/issue-cert.sh`

Specifically check these placeholder strings are no longer present:

- `YOUR_DOMAIN_HERE`
- `YOUR_LETSENCRYPT_EMAIL`
- `YOUR_OPENWEBUI_ADMIN_EMAIL`
- `CHANGE_ME_TO_A_LONG_RANDOM_SECRET`
- `CHANGE_ME_DB_PASSWORD`
- `CHANGE_ME_OPENWEBUI_ADMIN_PASSWORD`

`fill-template.sh` also prints the initial OpenWebUI admin login (email + generated password). Save this output securely (password manager, vault, or encrypted notes), because you will need it to log in to the web interface as admin.

### 2) Copy the template to server

Copy the whole `openwebui/` directory to:

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

- Install/update packages (`curl`, `git`, `ufw`)
- Install and start Docker
- Start containers
- Issue initial TLS certificate
- Reload Nginx with HTTPS enabled
- Add cron jobs for renewal and backups

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

## Notes and Caveats

- The admin bootstrap (`WEBUI_ADMIN_EMAIL` + `WEBUI_ADMIN_PASSWORD`) is only used on first startup with an empty database.
- The template sets `ENABLE_SIGNUP=false` by default.
- Persistent data is stored under:
  - `openwebui/openwebui-docker/storage/openwebui`
  - `openwebui/openwebui-docker/storage/postgres`

## Additional Documentation

For technical/architecture details, see:

- [`openwebui/docs/technical-documentation.md`](./openwebui/docs/technical-documentation.md)
- [`openwebui/openwebui-docker/README.md`](./openwebui/openwebui-docker/README.md)
