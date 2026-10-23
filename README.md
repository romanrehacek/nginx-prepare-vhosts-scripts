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

The script asks for a domain and whether DNS is ready. Choose `no` to create the vhost before pointing DNS; SSL setup is skipped. When DNS points to this server, run Certbot manually or create the vhost with DNS already ready.

The script creates:

- A per-domain SFTP user and directory structure.
- A MySQL database and user, when MySQL/MariaDB is available.
- An Nginx config in `/etc/nginx/conf.d`.
- SSL certificates with Certbot when DNS is ready and Certbot is installed.
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
- MySQL/MariaDB (optional; database creation is skipped if unavailable)
- Certbot (optional)
- OpenSSH server with SFTP
- `dig` from `dnsutils` when creating a vhost with DNS already set

Check Nginx after changes with:

```bash
sudo nginx -t
```
