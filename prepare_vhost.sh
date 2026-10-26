#!/bin/bash
set -Ee -o pipefail

usage() { echo "Usage: $0 [--domain DOMAIN] [--name IDENTIFIER] [--skip-ssl] [--yes]"; }
batch=false domain_arg= name_arg= skip_ssl=false yes=false domain_seen=false name_seen=false
while (($#)); do
  case "$1" in
    --domain) (($# >= 2)) && [[ "$domain_seen" == false && -n "$2" && "$2" != -* ]] || { usage >&2; exit 2; }; domain_arg=$2; domain_seen=true; batch=true; shift 2 ;;
    --name) (($# >= 2)) && [[ "$name_seen" == false && -n "$2" && "$2" != -* ]] || { usage >&2; exit 2; }; name_arg=$2; name_seen=true; shift 2 ;;
    --skip-ssl) [[ "$skip_ssl" == false ]] || exit 2; skip_ssl=true; shift ;;
    --yes) [[ "$yes" == false ]] || exit 2; yes=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ "$batch" == true && -z "$domain_arg" ]]; then echo "--domain is required in batch mode" >&2; usage >&2; exit 2; fi
if [[ "$yes" == true && ! -t 0 && "$batch" == false ]]; then echo "--yes requires --domain when stdin is not a terminal" >&2; exit 2; fi
if [[ "$EUID" -ne 0 ]]; then echo "Please run this script as sudo!" >&2; exit 1; fi

script_dir=$(dirname "$(readlink -f "$0")")
. "$script_dir/vhost_config.sh"
load_vhost_config "$script_dir/.env"
NGINX_CONFIG_DIR=/etc/nginx/conf.d
VHOSTS_DIR=/root/vhosts
. "$script_dir/vhost_metadata.sh"
command -v sha256sum >/dev/null && command -v tr >/dev/null && command -v sed >/dev/null && command -v cut >/dev/null || { echo "Core utilities needed to derive a stable identifier are missing." >&2; exit 1; }
domain=$domain_arg
if [[ "$batch" == false ]]; then read -r -p "Enter domain name (e.g., domain.com): " domain; fi
if ! valid_vhost_domain "$domain"; then
  echo "Error: enter a valid DNS hostname (up to 253 characters)." >&2; exit 1
fi
vhost_name=$name_arg
[[ -n "$vhost_name" ]] || vhost_name=$(derive_vhost_name "$domain")
valid_vhost_name "$vhost_name" || { echo "Error: identifier must match ^[a-z][a-z0-9_]{0,31}$" >&2; exit 1; }
explicit_name=$name_seen
if [[ "$batch" == false && "$skip_ssl" == false ]]; then
  while :; do
    read -r -p "Have DNS records been set up for $domain? (yes/no): " dns_ready || exit 1
    case "$dns_ready" in yes|y|ano|a) break;; no|n|nie) skip_ssl=true; break;; *) echo "Enter yes or no." >&2;; esac
  done
fi
webroot="$VHOSTS_BASE_DIR/$domain"
db_name=$vhost_name; db_user=$db_name
nginx_config="$NGINX_CONFIG_DIR/$domain.conf"
output_file="$VHOSTS_DIR/$domain.txt"
template_file="$script_dir/template.conf"

# Refuse every detectable collision before creating any resource. Base storage must be mounted.
check_vhost_mount "$VHOSTS_BASE_DIR" || exit 1
[[ -d "$NGINX_CONFIG_DIR" ]] || { echo "Nginx config directory does not exist: $NGINX_CONFIG_DIR" >&2; exit 1; }
[[ -f "$template_file" ]] || { echo "Missing template: $template_file" >&2; exit 1; }
if [[ -e "$VHOSTS_DIR" || -L "$VHOSTS_DIR" ]]; then
  [[ -d "$VHOSTS_DIR" && ! -L "$VHOSTS_DIR" && "$(stat -c '%u' "$VHOSTS_DIR")" == 0 ]] || { echo "Refusing unsafe credentials directory: $VHOSTS_DIR" >&2; exit 1; }
fi
[[ ! -e "$webroot" && ! -L "$webroot" ]] || { echo "Refusing existing webroot: $webroot" >&2; exit 1; }
[[ ! -e "$nginx_config" && ! -L "$nginx_config" ]] || { echo "Refusing existing Nginx config: $nginx_config" >&2; exit 1; }
[[ ! -e "$output_file" && ! -L "$output_file" ]] || { echo "Refusing existing credentials: $output_file" >&2; exit 1; }
! id "$vhost_name" >/dev/null 2>&1 || { echo "Refusing existing account: $vhost_name" >&2; exit 1; }
! getent group "$vhost_name" >/dev/null || { echo "Refusing existing group: $vhost_name" >&2; exit 1; }
[[ ! -e "/home/$vhost_name" && ! -L "/home/$vhost_name" ]] || { echo "Refusing existing account home directory: /home/$vhost_name" >&2; exit 1; }
getent group sftponly >/dev/null || command -v groupadd >/dev/null || { echo "groupadd is required" >&2; exit 1; }
for cmd in adduser usermod userdel groupadd groupdel gpasswd chpasswd mysql openssl nginx systemctl sed mktemp ln awk grep realpath stat; do command -v "$cmd" >/dev/null || { echo "Required command missing: $cmd" >&2; exit 1; }; done
[[ -d /root ]] || exit 1
mysql -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db_name';" | grep -qx 0 || { echo "Refusing existing database: $db_name (or MySQL query failed)" >&2; exit 1; }
mysql -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='$db_user' AND Host='localhost';" | grep -qx 0 || { echo "Refusing existing database user: $db_user (or MySQL query failed)" >&2; exit 1; }
if [[ "$skip_ssl" == false ]]; then
  command -v dig >/dev/null || { echo "dig is required for DNS validation" >&2; exit 1; }
  command -v certbot >/dev/null || { echo "Certbot is required unless --skip-ssl is used" >&2; exit 1; }
  cert_listing=$(certbot certificates 2>/dev/null) || { echo "Could not inspect existing Certbot certificates" >&2; exit 1; }
  if certbot_lineage_conflicts "$cert_listing" "$domain"; then
    echo "Refusing existing Certbot lineage or certificate domain for $domain" >&2; exit 1
  fi
  server_ip=$(hostname -I | awk '{print $1}'); domain_ip=$(dig +short "$domain" | tail -n1)
  [[ -n "$domain_ip" && "$domain_ip" == "$server_ip" ]] || { echo "DNS for $domain does not resolve to this server" >&2; exit 1; }
fi
if [[ -e "$VHOST_NAME_MAP" || -L "$VHOST_NAME_MAP" ]]; then
  validate_name_map "$VHOST_NAME_MAP" || exit 1
  [[ -z "$(mapped_name_for_domain "$domain" "$VHOST_NAME_MAP" || true)" ]] || { echo "Refusing existing domain mapping for $domain" >&2; exit 1; }
  ! map_contains_name "$vhost_name" "$VHOST_NAME_MAP" || { echo "Refusing identifier already mapped to another domain: $vhost_name" >&2; exit 1; }
fi
nginx -t
if [[ "$yes" == false ]]; then
  tty=false; [[ -t 0 ]] && tty=true
  require_confirmation_mode "$yes" "$tty" || exit 1
  confirm_provisioning "$domain" "$vhost_name" "$explicit_name" "$skip_ssl" "$VHOSTS_BASE_DIR" || exit 0
fi
mkdir -p "$VHOSTS_DIR" || { echo "Could not create credentials directory: $VHOSTS_DIR" >&2; exit 1; }
chmod 700 "$VHOSTS_DIR" || { echo "Could not secure credentials directory: $VHOSTS_DIR" >&2; exit 1; }

user_created=false group_created=false private_group_created=false webroot_created=false db_created=false db_user_created=false config_created=false www_group_added=false credentials_created=false
tmp_config= tmp_credentials=
vhost_pass=$(openssl rand -base64 12); db_pass=$(openssl rand -base64 12)
rollback() {
  trap - ERR
  set +e
  echo "Provisioning failed; cleaning resources created by this invocation." >&2
  [[ "$config_created" == true ]] && rm -f -- "$nginx_config"
  [[ -n "$tmp_config" ]] && rm -f -- "$tmp_config"
  [[ -n "$tmp_credentials" ]] && rm -f -- "$tmp_credentials"
  if [[ "$db_user_created" == true ]]; then mysql -e "DROP USER '$db_user'@'localhost';"; fi
  if [[ "$db_created" == true ]]; then mysql -e "DROP DATABASE \`$db_name\`;"; fi
  [[ "$credentials_created" == true ]] && rm -f -- "$output_file"
  [[ "$webroot_created" == true ]] && { rmdir "$webroot/public_html" "$webroot/logs" "$webroot" 2>/dev/null || true; }
  if [[ "$user_created" == true ]] && id "$vhost_name" >/dev/null 2>&1; then
    # Delete only the account created here; never remove its home recursively.
    userdel "$vhost_name" 2>/dev/null || true
  fi
  [[ "$www_group_added" == true ]] && gpasswd -d www-data sftponly >/dev/null 2>&1
  [[ "$private_group_created" == true ]] && groupdel "$vhost_name" 2>/dev/null
  [[ "$group_created" == true ]] && groupdel sftponly 2>/dev/null
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1
  exit 1
}
trap rollback ERR
fail() { echo "ERROR: $*" >&2; rollback; }

if ! getent group sftponly >/dev/null; then groupadd sftponly || fail "Failed to create sftponly group"; group_created=true; fi
groupadd "$vhost_name" || fail "Failed to create private group"
private_group_created=true
adduser --no-create-home --shell /bin/false --ingroup "$vhost_name" --force-badname --disabled-password --gecos "Created by prepare_vhost.sh" "$vhost_name" || fail "Failed to create account"
user_created=true
echo "$vhost_name:$vhost_pass" | chpasswd || fail "Failed to set account password"
usermod -d "$webroot" "$vhost_name" || fail "Failed to set account home"
adduser "$vhost_name" sftponly || fail "Failed to add account to sftponly"
if ! id -nG www-data | tr ' ' '\n' | grep -qx sftponly; then usermod -aG sftponly www-data || fail "Failed to add www-data to sftponly"; www_group_added=true; fi
mkdir -- "$webroot" || fail "Could not atomically create webroot"
webroot_created=true
mkdir "$webroot/public_html" "$webroot/logs" || fail "Failed to create domain directories"
chmod 775 "$webroot/public_html" "$webroot/logs" || fail "Failed to set directory permissions"
chown "$vhost_name:sftponly" "$webroot/public_html" "$webroot/logs" || fail "Failed to set directory ownership"
chmod g+s "$webroot/public_html" || fail "Failed to set SGID bit"
chmod 755 "$webroot" && chown root:root "$webroot" || fail "Failed to set webroot ownership"

mysql -e "CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || fail "Failed to create database"
db_created=true
mysql -e "CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';" || fail "Failed to create database user"
db_user_created=true
mysql -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost'; FLUSH PRIVILEGES;" || fail "Failed to grant database privileges"

tmp_config=$(mktemp "$NGINX_CONFIG_DIR/.${vhost_name}.XXXXXX")
sed -e "s|__DOMAIN__|$domain|g" -e "s|__VHOST_NAME__|$vhost_name|g" -e "s|__VHOSTS_BASE_DIR__|$VHOSTS_BASE_DIR|g" -e "s|__PHP_FPM_VERSION__|$PHP_FPM_VERSION|g" "$template_file" > "$tmp_config" || fail "Failed to render Nginx config"
ln -- "$tmp_config" "$nginx_config" || fail "Could not atomically install Nginx config"
config_created=true
rm -f -- "$tmp_config"
tmp_config=
nginx -t || fail "Nginx configuration test failed"
tmp_credentials=$(mktemp "$VHOSTS_DIR/.${vhost_name}.XXXXXX")
cat > "$tmp_credentials" <<EOF
VHOST: $domain
DOMAIN: $domain
Webroot: $webroot/public_html
Nginx config: $nginx_config
SFTP username: $vhost_name
SFTP password: $vhost_pass
Database: $db_name
Database user: $db_user
Database password: $db_pass
Database host: localhost
SSL: $([[ "$skip_ssl" == true ]] && echo skipped || echo created)
EOF
chmod 600 "$tmp_credentials" || fail "Could not secure credentials"
ln -- "$tmp_credentials" "$output_file" || fail "Could not atomically save credentials"
credentials_created=true
rm -f "$tmp_credentials"
tmp_credentials=
if [[ "$skip_ssl" == false ]]; then
  certbot --nginx -d "$domain" -d "www.$domain" --non-interactive --agree-tos --register-unsafely-without-email || fail "Certbot failed"
fi
cert_name=- ssl_created=false
if [[ "$skip_ssl" == false ]]; then cert_name=$domain; ssl_created=true; fi
write_name_mapping "$domain" "$vhost_name" "$db_name" "$cert_name" "$VHOSTS_BASE_DIR" "$ssl_created" "$VHOST_NAME_MAP" || fail "Could not securely save domain-to-identifier mapping"
trap - ERR
echo "Vhost $domain (system identifier $vhost_name) created successfully. Credentials: $output_file"
