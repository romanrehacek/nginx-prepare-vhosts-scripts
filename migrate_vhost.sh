#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: sudo ./migrate_vhost.sh DOMAIN [OPTIONS]

Options:
  --source-host HOST   Old server (default: 95.217.187.159)
  --source-user USER   SSH user (default: roman)
  --source-port PORT   SSH port (default: 10023)
  --ssh-key PATH       Existing SSH key (default: /home/roman/.ssh/id_ed25519_oldserver)
  --source-path PATH   Override old webroot
  --name IDENTIFIER    Name passed to prepare_vhost.sh if needed
  --resume             Reuse completed file/database steps recorded for this domain
  --yes                Skip confirmations for safe steps (destructive steps still prompt)
  -h, --help           Show help

This script transfers a WordPress site once. It does not synchronize later changes.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
confirm() {
  local prompt=$1 answer
  [[ "$yes" == true ]] && return 0
  confirm_tty "$prompt"
}
confirm_tty() {
  local prompt=$1 answer
  [[ -t 0 ]] || die "Confirmation required in a terminal: $prompt"
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] || die "Cancelled."
}
get_record_value() {
  local key=$1 file=$2
  awk -v key="$key" 'index($0, key ": ")==1 {sub("^" key ": ", ""); print; found=1; exit} END {if (!found) exit 1}' "$file"
}
valid_path() { [[ "$1" == /* && "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *'..'* ]]; }
quote_sql() { local s=$1; s=${s//\\/\\\\}; s=${s//\'/\\\'}; printf '%s' "$s"; }

domain= source_host= source_user= source_port= ssh_key= source_path= name= resume=false yes=false domain_seen=false
source_host_seen=false source_user_seen=false source_port_seen=false ssh_key_seen=false
while (($#)); do
  case "$1" in
    --source-host|--source-user|--source-port|--ssh-key|--source-path|--name)
      (($# >= 2)) || { usage >&2; exit 2; }
      case "$1" in
        --source-host) source_host=$2; source_host_seen=true;; --source-user) source_user=$2; source_user_seen=true;; --source-port) source_port=$2; source_port_seen=true;;
        --ssh-key) ssh_key=$2; ssh_key_seen=true;; --source-path) source_path=$2;; --name) name=$2;;
      esac
      shift 2;;
    --resume) [[ "$resume" == false ]] || exit 2; resume=true; shift;;
    --yes) [[ "$yes" == false ]] || exit 2; yes=true; shift;;
    -h|--help) usage; exit 0;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2;;
    *) [[ "$domain_seen" == false ]] || die "Only one domain is accepted."; domain=$1; domain_seen=true; shift;;
  esac
done
[[ "$domain_seen" == true ]] || { usage >&2; exit 2; }
[[ "$EUID" -eq 0 ]] || die "Run with sudo so destination files, MariaDB and nginx can be managed."
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$script_dir/vhost_config.sh"
load_vhost_config "$script_dir/.env" || exit 1
. "$script_dir/migration_state.sh"
[[ "$source_host_seen" == true ]] || source_host=$MIGRATION_SOURCE_HOST
[[ "$source_user_seen" == true ]] || source_user=$MIGRATION_SOURCE_USER
[[ "$source_port_seen" == true ]] || source_port=$MIGRATION_SOURCE_PORT
[[ "$ssh_key_seen" == true ]] || ssh_key=$MIGRATION_SSH_KEY
. "$script_dir/vhost_metadata.sh"
valid_vhost_domain "$domain" || die "Invalid domain name: $domain"
[[ "$source_host" =~ ^[A-Za-z0-9.-]+$ && "$source_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die "Invalid source host or user."
[[ "$source_port" =~ ^[0-9]{1,5}$ ]] && ((10#$source_port > 0 && 10#$source_port < 65536)) || die "Invalid SSH port."
valid_path "$ssh_key" || die "SSH key path must be absolute and cannot contain '..'."
for cmd in ssh rsync awk sed grep df stat realpath mktemp cp mv chmod chown tar gzip find date cut head mountpoint; do command -v "$cmd" >/dev/null || die "Required command missing: $cmd"; done
db_client=$(command -v mariadb || command -v mysql) || die "MariaDB/MySQL client is required."
db_dump=$(command -v mariadb-dump || command -v mysqldump) || die "MariaDB/MySQL dump client is required."
[[ -f "$ssh_key" && -r "$ssh_key" ]] || die "SSH key is missing or unreadable: $ssh_key"
key_mode=$(stat -c '%a' "$ssh_key") || die "Cannot inspect SSH key permissions."
(( (8#$key_mode & 077) == 0 )) || die "SSH key must not be accessible by group or others (chmod 600)."
known_hosts=/home/roman/.ssh/known_hosts
[[ -f "$known_hosts" && -r "$known_hosts" ]] || die "Trusted known_hosts file is required: $known_hosts"
ssh_opts=(-p "$source_port" -i "$ssh_key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
remote="$source_user@$source_host"
old_root="/mnt/HC_Volume_6080276/domains/$domain/public"
new_root="$VHOSTS_BASE_DIR/$domain/public_html"
[[ -n "$source_path" ]] && old_root=$source_path
valid_path "$old_root" || die "Unsafe source path."

echo "Checking source SSH, webroot and wp-config.php..."
ssh "${ssh_opts[@]}" "$remote" "test -d '$old_root' && test -r '$old_root/wp-config.php'" || die "Source is unreachable or webroot/wp-config.php is missing. Check host key and SSH access."
[[ -d "$VHOSTS_BASE_DIR" ]] || die "Destination volume is not mounted: $VHOSTS_BASE_DIR"
[[ -d /etc/nginx/conf.d ]] || die "Nginx config directory is missing."
command -v wp >/dev/null || die "WP-CLI is required."
command -v nginx >/dev/null || die "nginx is required."
command -v php >/dev/null || die "PHP CLI is required."
"$db_client" -N -B -e 'SELECT 1' >/dev/null 2>&1 || die "Destination MariaDB is unavailable."

source_config=$(mktemp); source_defaults=$(mktemp); dump_file=$(mktemp); dest_defaults=$(mktemp)
cleanup() { rm -f "$source_config" "$source_defaults" "$dump_file" "$dest_defaults"; }
trap cleanup EXIT
# Read and validate source DB metadata before touching destination files.
ssh "${ssh_opts[@]}" "$remote" "cat '$old_root/wp-config.php'" > "$source_config" || die "Could not read source wp-config.php."
extract_php_literal() {
  local key=$1
  php -r '$s=file_get_contents($argv[0]); $k=$argv[1]; $q=preg_quote($k,"/"); if(!preg_match("/define\\s*\\(\\s*[\x27\\\"]".$q."[\x27\\\"]\\s*,\\s*([\x27\\\"])(.*?)\\1\\s*\\)\\s*;/s",$s,$m)){exit(1);} echo stripcslashes($m[2]);' "$source_config" "$key"
}
src_db=$(extract_php_literal DB_NAME) || die "Source wp-config DB_NAME must be a literal string define."
src_user=$(extract_php_literal DB_USER) || die "Source wp-config DB_USER must be a literal string define."
src_pass=$(extract_php_literal DB_PASSWORD) || die "Source wp-config DB_PASSWORD must be a literal string define."
src_host=$(extract_php_literal DB_HOST) || die "Source wp-config DB_HOST must be a literal string define."
prefix=$(sed -nE "s/^[[:space:]]*\$table_prefix[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"][[:space:]]*;.*/\1/p" "$source_config" | head -n1)
[[ "$src_db" =~ ^[A-Za-z0-9_]+$ && "$src_user" =~ ^[A-Za-z0-9_]+$ && -n "$src_pass" && -n "$src_host" ]] || die "Source database settings are unsupported or unsafe."
[[ "$prefix" =~ ^[A-Za-z0-9_]+$ ]] || die "Could not safely read literal table_prefix from wp-config.php."
printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "$src_user" "$src_pass" "$src_host" > "$source_defaults"
chmod 600 "$source_defaults"
ssh "${ssh_opts[@]}" "$remote" "(command -v mariadb >/dev/null || command -v mysql >/dev/null) && (command -v mariadb-dump >/dev/null || command -v mysqldump >/dev/null)" || die "Source MariaDB/MySQL client or dump tools are unavailable."
remote_check="umask 077; f=\$(mktemp); trap 'rm -f \"\$f\"' EXIT; cat > \"\$f\"; if command -v mariadb >/dev/null; then c=mariadb; else c=mysql; fi; \$c --defaults-extra-file=\"\$f\" -N -B -e \"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$src_db';\""
cat "$source_defaults" | ssh "${ssh_opts[@]}" "$remote" "$remote_check" | grep -Eq '^[1-9][0-9]*$' || die "Source database is unavailable or has no tables."

check_vhost_mount "$VHOSTS_BASE_DIR" || die "Destination volume is not safely mounted."
source_size=$(ssh "${ssh_opts[@]}" "$remote" "du -sb '$old_root' | cut -f1") || die "Could not measure source files."
available=$(df -Pk "$VHOSTS_BASE_DIR" | awk 'NR==2 {print $4*1024}')
[[ "$source_size" =~ ^[0-9]+$ && "$available" =~ ^[0-9]+$ ]] || die "Could not determine disk space."
(( available > source_size + source_size / 10 )) || die "Insufficient destination disk space (need source size plus 10% headroom)."
vhost_file="/root/vhosts/$domain.txt"
if [[ ! -f "$vhost_file" ]]; then
  [[ -x "$script_dir/prepare_vhost.sh" ]] || die "Vhost is absent and prepare_vhost.sh is not executable."
  args=(--domain "$domain" --skip-ssl)
  [[ -n "$name" ]] && args+=(--name "$name")
  args+=(--yes)
  echo "Preparing destination vhost via prepare_vhost.sh (HTTP only)."
  "$script_dir/prepare_vhost.sh" "${args[@]}"
fi
[[ -f "$vhost_file" && ! -L "$vhost_file" ]] || die "Missing or unsafe vhost credentials: $vhost_file"
chmod 600 "$vhost_file"
dest_webroot=$(get_record_value Webroot "$vhost_file") || die "Vhost record is missing Webroot."
dest_db=$(get_record_value Database "$vhost_file") || die "Vhost record is missing Database."
dest_db_user=$(get_record_value 'Database user' "$vhost_file") || die "Vhost record is missing Database user."
dest_db_pass=$(get_record_value 'Database password' "$vhost_file") || die "Vhost record is missing Database password."
dest_db_host=$(get_record_value 'Database host' "$vhost_file") || die "Vhost record is missing Database host."
[[ "$dest_webroot" == "$new_root" && -d "$dest_webroot" ]] || die "Vhost webroot does not match configured path or is missing."
[[ "$(realpath "$dest_webroot")" == "$dest_webroot" ]] || die "Destination webroot resolves through a symlink; refusing migration."
[[ "$dest_db" =~ ^[A-Za-z0-9_]+$ && "$dest_db_user" =~ ^[A-Za-z0-9_]+$ ]] || die "Unsafe destination database identifier in vhost record."
[[ "$dest_db_host" == localhost ]] || die "Only local destination MariaDB is supported."

state_dir=/var/lib/nginx-prepare-vhosts/migrations
mkdir -p "$state_dir"; chmod 700 "$(dirname "$state_dir")" "$state_dir"
state="$state_dir/$domain.state"
state_identity=("domain=$domain" "source=$remote:$source_port" "source_path=$old_root" "ssh_key=$ssh_key" "destination=$new_root" "database=$dest_db")
if [[ -e "$state" || -L "$state" ]]; then
  [[ "$resume" == true ]] || die "Migration state exists; inspect $state and use --resume or remove it after review."
  migration_state_init "$state" "${state_identity[@]}" || die "Migration state is unsafe or does not match current source/destination settings."
fi
if [[ ! -e "$state" ]]; then migration_state_init "$state" "${state_identity[@]}" || die "Could not create migration state."; fi
mark_step() { migration_state_mark_step "$state" "$1" || die "Could not record migration step: $1"; }
has_step() { migration_state_has_step "$state" "$1"; }
if has_step complete; then echo "Migration already completed for $domain; no steps were repeated."; exit 0; fi


if [[ "$resume" != true ]] || ! has_step files; then
  if [[ -n "$(find "$dest_webroot" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    confirm_tty "Destination files already exist. Back them up and merge source files?"
    backup="${dest_webroot%/}.pre-migration.$(date +%Y%m%d%H%M%S%N).tar.gz"
    tar -czf "$backup" -C "$dest_webroot" . || die "Could not back up destination files."
    chmod 600 "$backup"
    echo "Destination backup: $backup"
  fi
  confirm "Transfer WordPress files from $remote:$old_root to $dest_webroot?"
  rsync -avh --progress -e "ssh -p $source_port -i $ssh_key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts" "$remote:$old_root/" "$dest_webroot/" || die "File transfer failed."
  chown -R "$(get_record_value 'SFTP username' "$vhost_file"):sftponly" "$dest_webroot"
  find "$dest_webroot" -type d -exec chmod 2775 {} +
  find "$dest_webroot" -type f -exec chmod 0664 {} +
  mark_step files
fi

if [[ "$resume" != true ]] || ! has_step database; then
  remote_script="umask 077; f=\$(mktemp); trap 'rm -f \"\$f\"' EXIT; cat > \"\$f\"; if command -v mariadb-dump >/dev/null; then d=mariadb-dump; else d=mysqldump; fi; \$d --defaults-extra-file=\"\$f\" --single-transaction --quick --skip-lock-tables '$src_db'"
  cat "$source_defaults" | ssh "${ssh_opts[@]}" "$remote" "$remote_script" > "$dump_file" || die "Source database dump failed."
  [[ -s "$dump_file" ]] || die "Source database dump was empty."
  printf '[client]\nuser=%s\npassword=%s\nhost=localhost\n' "$dest_db_user" "$dest_db_pass" > "$dest_defaults"
  chmod 600 "$dest_defaults"
  table_count=$("$db_client" --defaults-extra-file="$dest_defaults" -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$(quote_sql "$dest_db")';") || die "Could not inspect destination database."
  if (( table_count > 0 )); then
    confirm_tty "Destination database contains $table_count tables. Back it up and replace its contents?"
    db_backup="/root/vhosts/${domain}.pre-migration.$(date +%Y%m%d%H%M%S%N).sql.gz"
    "$db_dump" --defaults-extra-file="$dest_defaults" --single-transaction "$dest_db" | gzip -c > "$db_backup" || die "Could not back up destination database."
    chmod 600 "$db_backup"
    {
      printf 'SET FOREIGN_KEY_CHECKS=0;\n'
      while IFS= read -r table; do
        [[ "$table" =~ ^[A-Za-z0-9_]+$ ]] || die "Unsafe table name while clearing destination database."
        printf 'DROP TABLE IF EXISTS `%s`;\n' "$table"
      done < <("$db_client" --defaults-extra-file="$dest_defaults" -N -B -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA='$(quote_sql "$dest_db")';")
      printf 'SET FOREIGN_KEY_CHECKS=1;\n'
    } | "$db_client" --defaults-extra-file="$dest_defaults" "$dest_db" || die "Could not clear destination database."
  fi
  "$db_client" --defaults-extra-file="$dest_defaults" "$dest_db" < "$dump_file" || die "Database import failed."
  imported=$("$db_client" --defaults-extra-file="$dest_defaults" -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$(quote_sql "$dest_db")' AND TABLE_NAME LIKE '$(quote_sql "$prefix")%';") || die "Could not verify imported tables."
  (( imported > 0 )) || die "Import completed but no tables with the source prefix were found."
  mark_step database
fi
printf '[client]\nuser=%s\npassword=%s\nhost=localhost\n' "$dest_db_user" "$dest_db_pass" > "$dest_defaults"
chmod 600 "$dest_defaults"
imported=$("$db_client" --defaults-extra-file="$dest_defaults" -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$(quote_sql "$dest_db")' AND TABLE_NAME LIKE '$(quote_sql "$prefix")%';") || die "Could not verify destination tables."
(( imported > 0 )) || die "No tables with the source prefix were found in destination database."

wp_config="$dest_webroot/wp-config.php"
[[ -f "$wp_config" ]] || die "Destination wp-config.php is missing after file transfer."
[[ -d /root/vhosts && ! -L /root/vhosts && "$(stat -c '%u' /root/vhosts)" == 0 ]] || die "Backup directory must be a root-owned real directory: /root/vhosts"
chmod 700 /root/vhosts
wp_config_backup=$(mktemp "/root/vhosts/${domain}.wp-config.pre-migration.XXXXXX") || die "Could not create protected wp-config backup."
cp -p "$wp_config" "$wp_config_backup" || die "Could not back up destination wp-config.php."
chmod 600 "$wp_config_backup"
wp --allow-root --path="$dest_webroot" config set DB_NAME "$dest_db" --type=constant --quiet
wp --allow-root --path="$dest_webroot" config set DB_USER "$dest_db_user" --type=constant --quiet
wp --allow-root --path="$dest_webroot" config set DB_PASSWORD --type=constant --prompt=value --quiet <<< "$dest_db_pass" || die "Could not update DB_PASSWORD."
wp --allow-root --path="$dest_webroot" config set DB_HOST "$dest_db_host" --type=constant --quiet

old_fs="$old_root"
new_fs="$dest_webroot"
replace_output=$(wp --allow-root --path="$dest_webroot" search-replace "$old_fs" "$new_fs" --all-tables-with-prefix --skip-columns=guid --dry-run 2>&1) || die "Path search-replace dry run failed."
printf '%s\n' "$replace_output" | sed -E 's/[0-9]+ replacements/REPLACEMENTS/'
path_count=$(printf '%s\n' "$replace_output" | awk '/Success: Made [0-9]+ replacements/ {print $3; exit}')
path_count=${path_count:-0}
if (( path_count > 0 )); then
  confirm_tty "Apply $path_count filesystem path replacements in WordPress data?"
  wp --allow-root --path="$dest_webroot" search-replace "$old_fs" "$new_fs" --all-tables-with-prefix --skip-columns=guid --quiet || die "Path replacement failed."
fi

old_home=$(wp --allow-root --path="$dest_webroot" option get home --quiet) || die "Could not read pre-migration WordPress home URL."
old_host=$(php -r '$u=parse_url($argv[0], PHP_URL_HOST); if(!$u) exit(1); echo $u;' "$old_home") || die "Could not parse source WordPress home URL."
url_count=0
if [[ "${old_host,,}" != "${domain,,}" ]]; then
  url_output=$(wp --allow-root --path="$dest_webroot" search-replace "$old_host" "$domain" --all-tables-with-prefix --skip-columns=guid --dry-run 2>&1) || die "URL search-replace dry run failed."
  printf '%s\n' "$url_output" | sed -E 's/[0-9]+ replacements/REPLACEMENTS/'
  url_count=$(printf '%s\n' "$url_output" | awk '/Success: Made [0-9]+ replacements/ {print $3; exit}')
  url_count=${url_count:-0}
  if (( url_count > 0 )); then
    confirm_tty "Apply $url_count URL replacements from $old_host to $domain?"
    wp --allow-root --path="$dest_webroot" search-replace "$old_host" "$domain" --all-tables-with-prefix --skip-columns=guid --quiet || die "URL replacement failed."
  fi
fi
wp --allow-root --path="$dest_webroot" db check || die "WordPress database check failed."
wp --allow-root --path="$dest_webroot" core is-installed || die "WordPress core is not installed."
home=$(wp --allow-root --path="$dest_webroot" option get home --quiet) || die "Could not read WordPress home URL."
siteurl=$(wp --allow-root --path="$dest_webroot" option get siteurl --quiet) || die "Could not read WordPress site URL."
[[ -d "$dest_webroot/wp-content/uploads" ]] || echo "Notice: wp-content/uploads directory is absent."
nginx -t || die "Nginx configuration test failed."
printf '\nMigration completed\nDomain: %s\nFiles: OK\nDatabase import: OK (%s prefixed tables)\nWP config: OK\nPath replacements: %s\nURL replacements: %s\nPermissions: OK\nWordPress: OK (home=%s, siteurl=%s)\nNginx: OK\n' "$domain" "$imported" "$path_count" "$url_count" "$home" "$siteurl"
mark_step complete
