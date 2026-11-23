# Vhost Management Scripts

Bash scripts for creating and removing Nginx virtual hosts on Ubuntu/Debian servers.

## Files

- `prepare_vhost.sh` creates a vhost, SFTP account, MySQL database/user, Nginx config, and (when DNS is ready) SSL certificates.
- `remove_vhost.sh` removes those resources for a domain.
- `migrate_vhost.sh` migrates a WordPress site from the configured old server into a provisioned vhost.
- `migration_state.sh` validates and updates root-private migration resume state.
- `template.conf` is the Nginx server-block template.
- `vhost_config.sh` safely reads the local configuration shared by both scripts.
- `vhost_metadata.sh` validates and updates the root-owned domain-to-system-identifier map.
- `.env.example` documents the supported local settings.

Keep these files together in one directory on the server. The Nginx config is created in `/etc/nginx/conf.d/<domain>.conf`.

## Local configuration

The scripts look for `.env` in their own directory. If it is absent, they keep the current defaults:

- PHP-FPM socket version: `8.3`
- Domain directory base: `/var/www`
- Migration source: `roman@95.217.187.159:10023`, using `/home/roman/.ssh/id_ed25519_oldserver`

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
MIGRATION_SOURCE_HOST=95.217.187.159
MIGRATION_SOURCE_USER=roman
MIGRATION_SOURCE_PORT=10023
MIGRATION_SSH_KEY=/home/roman/.ssh/id_ed25519_oldserver
```

The base directory is the parent of each domain directory. With the example above, the webroot for `example.com` becomes `/mnt/web-volume/www/example.com/public_html`; logs go to `/mnt/web-volume/www/example.com/logs`.

Use only the documented `KEY=VALUE` lines. Values must not be quoted and must not contain spaces or inline comments. The loader validates the values and treats the file as data; it never evaluates shell commands. Unknown or malformed settings make the scripts stop before changing the server. `.env` is ignored by Git; commit `.env.example`, never the local `.env`. Do not store passwords or other secrets in it.

The PHP-FPM setting selects the installed FPM version. New vhosts get a domain-named pool in `/etc/php/<version>/fpm/pool.d/` and a socket at `/run/php/php<version>-fpm-<domain>.sock`. The Nginx config directory remains `/etc/nginx/conf.d`. The existing `www.conf` is used as a template, retaining its pool settings except the pool name, listen address and process manager limits. The new pool uses `ondemand`, `pm.max_children = 2` and `pm.process_idle_timeout = 10s`. The script checks both configurations, reloads PHP-FPM and Nginx, and removes the newly created pool on provisioning failure. Long domains whose Unix socket path exceeds 107 bytes are rejected.

Each pool has its own child limit: two children per pool is not a server-wide limit. Monitor available RAM, swap and FPM logs; increase server memory or reduce pool limits when concurrency warrants it. `ondemand` workers appear only after requests and exit after the idle timeout.

Vhost removal handles pools marked as managed by `prepare_vhost.sh`. Review manually created pools separately before removing them. Keep any pool used by another vhost.

### Moving an existing vhost to a separate PHP-FPM pool

Perform this for one domain at a time. The example applies to Debian's PHP 8.4 configuration shown in the server inventory; inspect `www.conf` and any included files first. Keep the shared `www` pool active. Backups below are outside the PHP-FPM pool directory and are not loaded by either service. Replace the domain only after verifying its Nginx config contains exactly the shared socket shown below.

```bash
DOMAIN=beta.smartmap.sjbdigital.dev
POOL="/etc/php/8.4/fpm/pool.d/$DOMAIN.conf"
NGINX="/etc/nginx/conf.d/$DOMAIN.conf"
SOCKET="/run/php/php8.4-fpm-$DOMAIN.sock"
BACKUP="/root/vhost-pool-backups/$(date +%Y%m%d-%H%M%S)-$DOMAIN"
sudo mkdir -p "$BACKUP"
sudo cp -a /etc/php/8.4/fpm/pool.d/www.conf "$BACKUP/www.conf"
sudo cp -a "$NGINX" "$BACKUP/nginx.conf"
sudo grep -n 'fastcgi_pass' "$NGINX"
sudo test ! -e "$POOL" && sudo test ! -L "$POOL" || { echo 'Pool already exists; stop and inspect'; return 1 2>/dev/null || exit 1; }
```

Using the backed-up `www.conf`, create a pool with the same active user, group, socket ownership and PHP settings; change `[www]` to the domain, `listen` to the new socket, and set `pm = ondemand`, `pm.max_children = 2` and `pm.process_idle_timeout = 10s`. Keep comments and other directives. Ensure no `include` or custom directive refers specifically to `[www]`; resolve those manually. Install the pool as a root-owned file with mode 0644. Then validate and reload PHP-FPM and confirm the socket exists:

```bash
sudo php-fpm8.4 -t && sudo systemctl reload php8.4-fpm
sudo ls -l "$SOCKET"
```

Only after the new socket exists, update the one `fastcgi_pass` in that domain's Nginx file from `/var/run/php/php8.4-fpm.sock` to `$SOCKET`, retaining all other lines. Run `sudo nginx -t` and, if successful, `sudo systemctl reload nginx`. Request the site's PHP page and check for a 502, PHP-FPM/Nginx logs and `htop`. A worker appears only while requests reach the pool. Repeat for the other domains after confirming each one works.

For rollback, restore `$BACKUP/nginx.conf` to `$NGINX`, run `sudo nginx -t` and reload Nginx; only then remove the domain pool, test PHP-FPM and reload it. Keep the backups until all sites have been checked. Leave `www` enabled until all effective Nginx configurations and any other FastCGI clients have been verified not to use its socket.

## Install and prepare a vhost

Keep the scripts and template together, then make the entry points executable:

```bash
sudo chmod +x prepare_vhost.sh remove_vhost.sh
```

Run `--help` for the options and examples:

```bash
sudo ./prepare_vhost.sh --help
sudo ./remove_vhost.sh --help
```

### Interactive setup without parameters

For a guided setup, start the script without options:

```bash
sudo ./prepare_vhost.sh
```

Then follow the prompts:

1. Enter the full domain, for example `beta.example.com`.
2. For a likely root domain with two labels, such as `example.com`, choose whether to include `www.example.com`. Press Enter or `Y` for yes, or `n` to omit it. Subdomains omit `www` automatically.
3. Unless you started with `--skip-ssl`, answer whether DNS is ready. Answer yes only after every requested hostname points to this server; answer no to create an HTTP-only vhost without requesting a certificate.
4. Review the preflight summary. Press Enter or `Y` to create the vhost, or `n` to cancel. Invalid answers repeat the prompt; EOF cancels without changes.
5. After success, the credentials are saved in `/root/vhosts/<domain>.txt`.

The automatic root-domain guess counts labels: two labels are treated as a likely root domain. For domains such as `example.co.uk`, use `--www` or `--no-www` to choose explicitly.

The domain is validated as a DNS hostname and is used unchanged for the webroot, Nginx config, SSL certificate, and credential filename. A separate Linux account/database identifier is derived deterministically: its sanitized full form is used when it fits, otherwise it is shortened with a stable hash suffix. Numeric-leading names receive a letter prefix. Supply `--name IDENTIFIER` to choose one; identifiers must match `^[a-z][a-z0-9_]{0,31}$` and are used as entered.

The `www` alias is prompted for interactively when the domain has exactly two labels, such as `example.com`. The simple default heuristic assumes that a two-label name is a likely root domain: batch runs and `--yes` include `www` for those domains and omit it for subdomains. Override this with `--www` or `--no-www`. The chosen name list is used consistently in the Nginx `server_name`, Certbot request, and DNS preflight; every requested hostname must resolve to this server.

For automated provisioning, pass `--domain`; batch mode does not prompt for the domain. All read-only checks run before the final confirmation. The confirmation preview lists the domain, identifier, Linux user, database, database user, and webroot. Press Enter, `Y`, or `y` to continue; `N` or `n` cancels. Invalid answers are repeated. When the name is derived, the preview includes a rerun command and a hint for choosing a different name. Use `--yes` to skip confirmation. Non-interactive use requires `--yes`.

```bash
sudo ./prepare_vhost.sh --domain example.com --skip-ssl
sudo ./prepare_vhost.sh --domain a-very-long-domain-name.example --name customer_42 --skip-ssl --yes
sudo ./prepare_vhost.sh --domain shop.example.com --no-www --yes
```

For a list of domains (one per line, blank lines and `#` comments ignored), explicitly stop at the first failure. `--yes` enables unattended operation and applies the documented domain-label heuristic:

```bash
while IFS= read -r domain || [ -n "$domain" ]; do
  case "$domain" in ''|\#*) continue ;; esac
  if ! sudo ./prepare_vhost.sh --domain "$domain" --skip-ssl --yes; then
    echo "Provisioning failed for $domain; stopping." >&2
    exit 1
  fi
done < domains.txt
```

Before running, ensure the configured `VHOSTS_BASE_DIR` already exists and its volume is mounted. The script refuses existing webroots, Nginx configs, credentials, accounts, groups, databases, database users, and any matching Certbot lineage or domain; rerunning for a provisioned domain exits with an error. Any provisioning failure exits nonzero and attempts cleanup only for resources created by that invocation. Rollback removes only regular Nginx `access.log` and `error.log` files in the new webroot, then removes the directories only if they are empty; unexpected or user-created files are left in place. Certbot can leave certificate or renewal residue if it fails partway through; the script deliberately does not automatically delete Certbot lineages during rollback, so inspect Certbot state before retrying after an SSL failure.

The script creates:

- A per-domain SFTP user and directory structure.
- A MySQL database and user (MySQL/MariaDB is required; database failures stop provisioning).
- An Nginx config in `/etc/nginx/conf.d`.
- SSL certificates with Certbot when DNS is ready, unless `--skip-ssl` is used.
- Access details in `/root/vhosts/<domain>.txt`.
- A root-owned, mode-restricted identifier map at `/root/vhosts/.vhost-name-map`. It contains the domain, system identifier, database identifier, certificate lineage and SSL-created flag, original webroot base path, and whether `www` was requested; it is not a credentials file. Removal requires a valid mapping and never guesses identifiers or paths for legacy vhosts. It uses the recorded base path even if `.env` changed later, then verifies that volume is mounted before touching it.

For each domain, the directory structure is:

```text
VHOSTS_BASE_DIR/<domain>/
├── public_html/
└── logs/
```

For the defaults, this is `/var/www/<domain>/`. The public webroot is `public_html/`.

## WordPress migration

### Select a site from the old server

On the destination server, run the interactive menu from the project directory:

```bash
sudo ./migrate_vhost_menu.sh
```

The menu lists WordPress sites under the source server's standard domains directory and compares them with local vhosts and migration state. Pick one numbered entry at a time. New vhosts request HTTPS using the existing provisioning script, so point the selected hostname to the destination and make it reachable for Certbot first. The menu then runs the migration script. A completed migration disappears from the next menu. Review existing targets and interrupted runs before continuing, especially if files or database tables already exist.

`migrate_vhost.sh` copies a beta/development WordPress site to the new server. It uses the existing source SSH key and trusted `known_hosts`; install/verify the source host key through your normal process first. It never disables host-key checking. Run it from this directory:

```bash
sudo ./migrate_vhost.sh beta.example.com
# Optional source/path/name overrides, resume after interruption, or skip safe confirmations:
sudo ./migrate_vhost.sh beta.example.com --source-host old.example.net --source-port 10023 --ssh-key /home/roman/.ssh/id_ed25519_oldserver
sudo ./migrate_vhost.sh beta.example.com --source-path /mnt/old/domains/beta.example.com/public --name beta_site
sudo ./migrate_vhost.sh beta.example.com --resume
```

If the destination vhost is absent, the migration invokes `prepare_vhost.sh --skip-ssl --yes` only after source database access and destination mount/disk checks pass, then reads its protected `/root/vhosts/<domain>.txt` record. The migration checks SSH access, source files, local MariaDB/MySQL, tools, and free disk space; copies all files with `rsync` (no `--delete`); imports the source database into the recorded destination database; and updates WordPress DB settings. Existing destination files or database tables are backed up before merge/replacement and always require an interactive confirmation, even with `--yes`. Database and `wp-config.php` backups are stored under `/root/vhosts/` with mode `0600`; the file archive is stored beside the destination webroot. Progress is recorded in `/var/lib/nginx-prepare-vhosts/migrations/<domain>.state`, bound to the source host/user/port/path/key and destination path/database. Use `--resume` only after inspecting the state and backups. A completed state makes repeated `--resume` return without rerunning migration steps.

The script supports ordinary literal `define()` values for `DB_NAME`, `DB_USER`, `DB_PASSWORD`, and `DB_HOST`, plus a literal `$table_prefix` in the source `wp-config.php`. It does not execute the old config. Dynamic PHP expressions must be converted to literal values before migration. Path replacement is previewed and requires confirmation; URL replacement is limited to a changed hostname inferred from the imported WordPress `home` option. Both use WP-CLI serialization-aware search-replace and skip `guid`. It applies the provisioning account/group ownership and `2775` directories/`0664` files. Review site URLs, uploads, plugins and access before switching traffic.

The script is intended for a one-time beta/development move, not ongoing synchronization. It does not change the source server, DNS, maintenance mode, or live traffic. Do not use it on production without a separately planned migration and recovery window.

## Remove a vhost

```bash
sudo ./remove_vhost.sh
# Or select a domain directly (confirmation is still required)
sudo ./remove_vhost.sh --domain example.com
```

The script asks for the domain and requires typing `YES` after its read-only checks. Optional `--name IDENTIFIER` is only an assertion against the recorded identifier. It removes the mapped Nginx config, any SSL lineage created by this script, SFTP user and its verified private group, webroot, database/user, and Nginx logs. Credentials are moved to `/root/vhosts/archive/`. It refuses missing or corrupt mapping data, symlinked or mismatched targets, mounted filesystems inside the domain directory, configs without the matching ownership marker, and shared certificate lineages. Shared SFTP group membership is left intact.

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
