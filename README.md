# Vhost Management Scripts

Bash scripts for creating and removing Nginx virtual hosts on Ubuntu/Debian servers.

## Files

- `prepare_vhost.sh` creates a vhost, SFTP account, MySQL database/user, Nginx config, and (when DNS is ready) SSL certificates.
- `remove_vhost.sh` removes those resources for a domain.
- `template.conf` is the Nginx server-block template.
- `vhost_config.sh` safely reads the local configuration shared by both scripts.
- `.env.example` documents the supported local settings.

Keep these files together in one directory on the server. The Nginx config is created in `/etc/nginx/conf.d/<domain>.conf`.

## Local configuration

The scripts look for `.env` in their own directory. If it is absent, they keep the current defaults:

- PHP-FPM socket version: `8.3`
- Domain directory base: `/var/www`

To set custom values, copy the example and edit it:

```bash
cp .env.example .env
chmod 600 .env
nano .env
```

Example for a mounted web volume:

```dotenv
PHP_FPM_VERSION=8.3
VHOSTS_BASE_DIR=/mnt/web-volume/www
```

The base directory is the parent of each domain directory. With the example above, the webroot for `example.com` becomes `/mnt/web-volume/www/example.com/public_html`; logs go to `/mnt/web-volume/www/example.com/logs`.

Use only the two supported `KEY=VALUE` lines. Values must not be quoted and must not contain spaces or inline comments. The loader validates both values and treats the file as data; it never evaluates shell commands. Unknown or malformed settings make the scripts stop before changing the server. `.env` is ignored by Git; commit `.env.example`, never the local `.env`. Do not store passwords or other secrets in it.

The PHP-FPM setting controls the socket rendered into each new Nginx config, for example `/var/run/php/php8.3-fpm.sock`. The Nginx config directory remains `/etc/nginx/conf.d`.

## Install and prepare a vhost

Keep the scripts and template together, then make the entry points executable:

```bash
sudo chmod +x prepare_vhost.sh remove_vhost.sh
sudo ./prepare_vhost.sh
```

With no options, the script asks for a domain and whether DNS is ready. For automated provisioning, pass `--domain`; batch mode never prompts. DNS must point to this server and Certbot must succeed unless `--skip-ssl` is passed. `--skip-ssl` skips both DNS checks and Certbot.

```bash
sudo ./prepare_vhost.sh --domain example.com --skip-ssl
```

For a list of domains (one per line, blank lines and `#` comments ignored), explicitly stop at the first failure:

```bash
while IFS= read -r domain || [ -n "$domain" ]; do
  case "$domain" in ''|\#*) continue ;; esac
  if ! sudo ./prepare_vhost.sh --domain "$domain" --skip-ssl; then
    echo "Provisioning failed for $domain; stopping." >&2
    exit 1
  fi
done < domains.txt
```

Before running, ensure the configured `VHOSTS_BASE_DIR` already exists. For the default `/var/www`, no mount check is required. For a custom base directory, its parent must be a mount point; the script checks this before creating accounts, databases, or directories. The script refuses existing webroots, Nginx configs, credentials, accounts, groups, databases, database users, or a Certbot certificate already containing the domain; rerunning for a provisioned domain exits with an error. Any provisioning failure exits nonzero and attempts cleanup only for resources created by that invocation. Certbot can leave certificate or renewal residue if it fails partway through; the script deliberately does not automatically delete Certbot lineages during rollback, so inspect Certbot state before retrying after an SSL failure.

The script creates:

- A per-domain SFTP user and directory structure.
- A MySQL database and user (MySQL/MariaDB is required; database failures stop provisioning).
- An Nginx config in `/etc/nginx/conf.d`.
- SSL certificates with Certbot when DNS is ready, unless `--skip-ssl` is used.
- Access details in `/root/vhosts/<domain>.txt`.

For each domain, the directory structure is:

```text
VHOSTS_BASE_DIR/<domain>/
├── public_html/
└── logs/
```

For the defaults, this is `/var/www/<domain>/`. The public webroot is `public_html/`.

## WordPress setup and migration

1. Create the vhost and database with `prepare_vhost.sh`.
2. Install a clean WordPress copy into that domain's `public_html/` and complete its initial setup.
3. Use the credentials saved in `/root/vhosts/<domain>.txt` when configuring the destination site.
4. Use WP Migrate Pro to move the live site's database and files to the new installation, then verify the site and URLs before switching traffic.

These scripts provision the server-side vhost and database; they do not install WordPress or perform the content migration.

## Remove a vhost

```bash
sudo ./remove_vhost.sh
```

The script asks for the domain and requires typing `YES`. It removes the Nginx config, SSL certificate, SFTP user, webroot, database/user, and Nginx logs. Credentials are moved to `/root/vhosts/archive/`.

**Removing a vhost recursively deletes its entire domain directory, including files stored on a mounted volume.** Back up or move any data you need before confirming removal.

## Requirements and checks

- Ubuntu/Debian
- Nginx with `/etc/nginx/conf.d` included
- PHP-FPM matching `PHP_FPM_VERSION`
- MySQL/MariaDB (required)
- Certbot and `dig` (required unless using `--skip-ssl`)
- OpenSSH server with SFTP
- `dig` from `dnsutils` when creating a vhost with DNS already set

Check Nginx after changes with:

```bash
sudo nginx -t
```
