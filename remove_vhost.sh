#!/bin/bash
set -Eeuo pipefail

usage() {
  cat <<EOF
Usage: $0 [--domain DOMAIN] [--name IDENTIFIER]

Remove a vhost created by prepare_vhost.sh. The protected mapping identifies
its system account, database, certificate and webroot; unmapped legacy vhosts
are refused.

Options:
  --domain DOMAIN     Select the full domain instead of being prompted
  --name IDENTIFIER   Optional assertion; must match the stored identifier
  -h, --help          Show this help and examples

The script previews the mapped resources and asks you to type YES before
removing them. Credentials are archived. The mapped webroot is deleted.

Examples:
  sudo $0
  sudo $0 --domain example.com
  sudo $0 --domain shop.example.com --name shop_account
EOF
}
domain= name_assert= name_seen=false
while (($#)); do
  case "$1" in
    --domain) (($# >= 2)) || { usage >&2; exit 2; }; [[ -z "$domain" && -n "$2" && "$2" != -* ]] || { usage >&2; exit 2; }; domain=$2; shift 2 ;;
    --name) (($# >= 2)) || { usage >&2; exit 2; }; [[ "$name_seen" == false && -n "$2" && "$2" != -* ]] || { usage >&2; exit 2; }; name_assert=$2; name_seen=true; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$EUID" -eq 0 ]] || { echo "Please run this script as sudo!" >&2; exit 1; }
script_dir=$(dirname "$(readlink -f "$0")")
. "$script_dir/vhost_config.sh"
load_vhost_config "$script_dir/.env"
. "$script_dir/vhost_metadata.sh"
if [[ -z "$domain" ]]; then read -r -p "Enter domain name to remove: " domain || exit 1; fi
valid_vhost_domain "$domain" || { echo "Error: enter a valid DNS hostname." >&2; exit 1; }

# Read-only authorization and target checks. A missing or malformed mapping is never guessed.
validate_name_map "$VHOST_NAME_MAP" || exit 1
vhost_name=$(mapped_name_for_domain "$domain" "$VHOST_NAME_MAP") || { echo "[!] ERROR: No provisioned identifier mapping exists for $domain; refusing legacy/unmapped removal." >&2; exit 1; }
assert_mapped_name "$vhost_name" "$name_assert" "$name_seen" || exit 1
db_name= cert_name= ssl_created= mapped_include_www= mapped_domain= mapped_db= mapped_base=
while IFS=$'\t' read -r mapped_domain mapped_name mapped_db cert_name mapped_base ssl_created mapped_include_www; do
  [[ "$(lowercase "$mapped_domain")" == "$(lowercase "$domain")" ]] && { domain=$mapped_domain; db_name=$mapped_db; break; }
done < "$VHOST_NAME_MAP"
[[ -n "$mapped_include_www" ]] || mapped_include_www=true
[[ -n "$db_name" ]] && valid_vhost_base_dir "$mapped_base" || { echo "[!] ERROR: Mapping does not match expected resource names or paths." >&2; exit 1; }
NGINX_CONFIG_DIR=/etc/nginx/conf.d
VHOSTS_DIR=/root/vhosts
ARCHIVE_DIR=$VHOSTS_DIR/archive
webroot="$mapped_base/$domain"
nginx_config="$NGINX_CONFIG_DIR/$domain.conf"
credentials_file="$VHOSTS_DIR/$domain.txt"
archive_timestamp=$(date '+%Y%m%d_%H%M%S')
archive_file="$ARCHIVE_DIR/${domain}_${archive_timestamp}.txt"
[[ -d "$NGINX_CONFIG_DIR" ]] || { echo "Missing Nginx config directory: $NGINX_CONFIG_DIR" >&2; exit 1; }
check_vhost_mount "$mapped_base" || exit 1
command -v findmnt >/dev/null || { echo "findmnt is required to verify that the domain directory contains no nested mounts." >&2; exit 1; }
while IFS= read -r mounted_target; do
  case "$mounted_target" in
    "$webroot"|"$webroot"/*)
      echo "Refusing to remove a domain directory containing a mounted filesystem: $mounted_target" >&2
      exit 1
      ;;
  esac
done < <(findmnt -rn -o TARGET)
if [[ -L "$webroot" ]]; then echo "Refusing symlink webroot: $webroot" >&2; exit 1; fi
if [[ -e "$webroot" ]]; then
  [[ -d "$webroot" && "$(stat -c '%u' "$webroot")" == 0 ]] || { echo "Refusing webroot that is not a root-owned directory: $webroot" >&2; exit 1; }
fi
if [[ -e "$nginx_config" || -L "$nginx_config" ]]; then
  [[ -f "$nginx_config" && ! -L "$nginx_config" ]] || { echo "Refusing non-regular Nginx config: $nginx_config" >&2; exit 1; }
  grep -Fqx "    # vhost-owner: domain=$domain identifier=$vhost_name" "$nginx_config" || { echo "Nginx ownership marker does not match $domain/$vhost_name; refusing removal." >&2; exit 1; }
fi
private_group_removable=false account_primary_gid=
if id "$vhost_name" >/dev/null 2>&1; then
  IFS=: read -r _ _ _ account_primary_gid account_gecos account_home account_shell < <(getent passwd "$vhost_name")
  [[ "$account_home" == "$webroot" && "$account_shell" == /bin/false && "$account_gecos" == "Created by prepare_vhost.sh" ]] || { echo "Account identity does not match this script's mapped vhost; refusing removal." >&2; exit 1; }
  id -nG "$vhost_name" | tr ' ' '\n' | grep -qx sftponly || { echo "Mapped account is not an SFTP vhost account; refusing removal." >&2; exit 1; }
  group_record=$(getent group "$vhost_name" || true)
  [[ -n "$group_record" ]] && private_group_is_owned_by_user "$vhost_name" "$account_primary_gid" "$group_record" /etc/passwd && private_group_removable=true
fi
if [[ -e "$credentials_file" || -L "$credentials_file" ]]; then
  [[ -f "$credentials_file" && ! -L "$credentials_file" ]] || { echo "Refusing non-regular credentials file: $credentials_file" >&2; exit 1; }
  [[ "$(stat -c '%u:%a' "$credentials_file")" == 0:600 ]] || { echo "Refusing credentials file that is not root-owned with mode 600: $credentials_file" >&2; exit 1; }
fi
if [[ -e "$ARCHIVE_DIR" || -L "$ARCHIVE_DIR" ]]; then
  [[ -d "$ARCHIVE_DIR" && ! -L "$ARCHIVE_DIR" && "$(stat -c '%u' "$ARCHIVE_DIR")" == 0 ]] && [[ $((8#$(stat -c '%a' "$ARCHIVE_DIR") & 077)) -eq 0 ]] || { echo "Refusing unsafe credentials archive directory: $ARCHIVE_DIR" >&2; exit 1; }
fi
if [[ -e "$credentials_file" && ( -e "$archive_file" || -L "$archive_file" ) ]]; then
  echo "Credentials archive target already exists: $archive_file" >&2; exit 1
fi
if [[ "$ssl_created" == true && ( -d "/etc/letsencrypt/live/$cert_name" || -d "/etc/letsencrypt/archive/$cert_name" ) ]]; then
  command -v certbot >/dev/null || { echo "Certbot is needed to safely inspect and remove this certificate." >&2; exit 1; }
  cert_listing=$(certbot certificates 2>/dev/null) || { echo "Could not inspect Certbot certificates." >&2; exit 1; }
  cert_domains=$(certbot_domains_for_lineage "$cert_listing" "$cert_name")
  [[ -n "$cert_domains" ]] && certbot_domains_match_lineage "$cert_listing" "$cert_name" "$domain" "$mapped_include_www" || { echo "Certificate $cert_name does not match the exact mapped domain set; refusing removal." >&2; exit 1; }
fi
# Validate DB identifiers against the exact mapping. Queries are read-only.
command -v mysql >/dev/null || { echo "MySQL client is required to safely verify mapped database resources." >&2; exit 1; }
mysql -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db_name';" >/dev/null || { echo "Cannot inspect MySQL database state." >&2; exit 1; }
mysql -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='$db_name' AND Host='localhost';" >/dev/null || { echo "Cannot inspect MySQL user state." >&2; exit 1; }
for cmd in mkdir chmod mv rm userdel; do command -v "$cmd" >/dev/null || { echo "Required command missing: $cmd" >&2; exit 1; }; done
if [[ -f "$nginx_config" ]]; then command -v nginx >/dev/null && command -v systemctl >/dev/null || { echo "Nginx and systemctl are required to safely remove this config." >&2; exit 1; }; fi
if [[ "$private_group_removable" == true ]]; then command -v groupdel >/dev/null || { echo "groupdel is required to remove the mapped private group." >&2; exit 1; }; fi

cat <<EOF
About to remove provisioned vhost:
  Domain: $domain
  System account: $vhost_name
  Webroot: $webroot (including all content)
  Nginx config: $nginx_config
  Database/user: $db_name
  Certificate lineage: $cert_name
  SSL created by this script: $ssl_created
  WWW alias: $([[ "$mapped_include_www" == true ]] && echo "www.$domain included" || echo "not included")
  Credentials: $credentials_file (will be archived)
EOF
while :; do
  read -r -p "Type YES to remove all listed resources for $domain: " confirm || { echo "Removal cancelled."; exit 1; }
  [[ "$confirm" == YES ]] && break
  echo "Removal cancelled."
  exit 0
done

# Mutations start only after explicit confirmation and all preflight checks.
mkdir -p "$ARCHIVE_DIR"
chmod 700 "$VHOSTS_DIR" "$ARCHIVE_DIR"
if [[ -f "$credentials_file" ]]; then
  { printf '\nREMOVED: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"; } >> "$credentials_file"
  mv -- "$credentials_file" "$archive_file"
  chmod 600 "$archive_file"
fi
if [[ -f "$nginx_config" ]]; then
  rm -- "$nginx_config"
  nginx -t || { echo "Nginx config test failed after removing $nginx_config; mapping retained for recovery." >&2; exit 1; }
  systemctl reload nginx || { echo "Nginx reload failed; mapping retained for recovery." >&2; exit 1; }
fi
if [[ "$ssl_created" == true && ( -d "/etc/letsencrypt/live/$cert_name" || -d "/etc/letsencrypt/archive/$cert_name" ) ]]; then
  certbot delete --cert-name "$cert_name" --non-interactive || { echo "Certificate removal failed; remaining resources and mapping are preserved for safe recovery." >&2; exit 1; }
fi
if id "$vhost_name" >/dev/null 2>&1; then userdel "$vhost_name" || { echo "Could not remove account; remaining resources and mapping are preserved." >&2; exit 1; }; fi
if [[ "$private_group_removable" == true ]] && getent group "$vhost_name" >/dev/null; then groupdel "$vhost_name" || { echo "Could not remove private group; mapping retained for recovery." >&2; exit 1; }; fi
if [[ -d "$webroot" ]]; then rm -rf --one-file-system -- "$webroot"; fi
mysql -e "DROP DATABASE IF EXISTS \`$db_name\`;" || exit 1
mysql -e "DROP USER IF EXISTS '$db_name'@'localhost'; FLUSH PRIVILEGES;" || exit 1
shopt -s nullglob
log_files=(/var/log/nginx/"$domain"-*.log /var/log/nginx/"$domain"-*.log.*.gz)
((${#log_files[@]} == 0)) || rm -f -- "${log_files[@]}"
remove_name_mapping "$domain" "$VHOST_NAME_MAP" || { echo "Resources removed but mapping cleanup failed; inspect mapping manually." >&2; exit 1; }
echo "Vhost $domain removed. Shared SFTP group memberships were left intact."
