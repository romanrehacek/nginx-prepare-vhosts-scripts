#!/bin/bash
set -Ee -o pipefail

usage() { echo "Usage: $0 [--domain DOMAIN] [--skip-ssl]"; }
batch=false domain_arg= skip_ssl=false domain_seen=false
while (($#)); do
  case "$1" in
    --domain)
      (($# >= 2)) || { usage >&2; exit 2; }
      [[ "$domain_seen" == false && -n "$2" && "$2" != -* ]] || { echo "--domain must be specified once with a domain value" >&2; usage >&2; exit 2; }
      domain_arg=$2; domain_seen=true; batch=true; shift 2 ;;
    --skip-ssl)
      [[ "$skip_ssl" == false ]] || { echo "--skip-ssl may be specified only once" >&2; usage >&2; exit 2; }
      skip_ssl=true; batch=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ "$batch" == true && -z "$domain_arg" ]]; then echo "--domain is required in batch mode" >&2; usage >&2; exit 2; fi
if [[ "$EUID" -ne 0 ]]; then echo "Please run this script as sudo!" >&2; exit 1; fi

script_dir=$(dirname "$(readlink -f "$0")")
. "$script_dir/vhost_config.sh"
load_vhost_config "$script_dir/.env"
NGINX_CONFIG_DIR=/etc/nginx/conf.d
VHOSTS_DIR=/root/vhosts
vhost_name=$domain_arg
if [[ "$batch" == false ]]; then read -r -p "Enter domain name (e.g., domain.com): " vhost_name; fi
if [[ ! "$vhost_name" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?[.])*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ || ${#vhost_name} -gt 32 ]]; then
  echo "Error: domain must be valid and at most 32 characters (used as account/database name)." >&2; exit 1
fi

if [[ "$batch" == false ]]; then
  read -r -p "Have DNS records been set up for domain $vhost_name? (yes/no): " dns_ready
  case "$dns_ready" in
    yes|y|ano|a) ;;
    no|n|nie) skip_ssl=true ;;
    *) echo "Invalid answer. Enter yes or no." >&2; exit 1 ;;
  esac
fi

webroot="$VHOSTS_BASE_DIR/$vhost_name"
db_name=${vhost_name//./_}; db_name=${db_name//-/_}; db_user=$db_name
nginx_config="$NGINX_CONFIG_DIR/$vhost_name.conf"
output_file="$VHOSTS_DIR/$vhost_name.txt"
template_file="$script_dir/template.conf"

# Refuse every detectable collision before creating any resource. Base storage must be mounted.
[[ -d "$VHOSTS_BASE_DIR" ]] || { echo "Configured domain base directory is missing; mount/create it first: $VHOSTS_BASE_DIR" >&2; exit 1; }
[[ -d "$NGINX_CONFIG_DIR" ]] || { echo "Nginx config directory does not exist: $NGINX_CONFIG_DIR" >&2; exit 1; }
[[ -f "$template_file" ]] || { echo "Missing template: $template_file" >&2; exit 1; }
[[ ! -e "$webroot" && ! -L "$webroot" ]] || { echo "Refusing existing webroot: $webroot" >&2; exit 1; }
[[ ! -e "$nginx_config" && ! -L "$nginx_config" ]] || { echo "Refusing existing Nginx config: $nginx_config" >&2; exit 1; }
[[ ! -e "$output_file" && ! -L "$output_file" ]] || { echo "Refusing existing credentials: $output_file" >&2; exit 1; }
! id "$vhost_name" >/dev/null 2>&1 || { echo "Refusing existing account: $vhost_name" >&2; exit 1; }
! getent group "$vhost_name" >/dev/null || { echo "Refusing existing group: $vhost_name" >&2; exit 1; }
[[ ! -e "/home/$vhost_name" && ! -L "/home/$vhost_name" ]] || { echo "Refusing existing account home directory: /home/$vhost_name" >&2; exit 1; }
getent group sftponly >/dev/null || command -v groupadd >/dev/null || { echo "groupadd is required" >&2; exit 1; }
for cmd in adduser usermod userdel groupadd groupdel gpasswd chpasswd mysql openssl nginx systemctl sed mktemp ln awk grep; do command -v "$cmd" >/dev/null || { echo "Required command missing: $cmd" >&2; exit 1; }; done
[[ -d /root ]] || exit 1
mysql -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db_name';" | grep -qx 0 || { echo "Refusing existing database: $db_name (or MySQL query failed)" >&2; exit 1; }
mysql -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='$db_user' AND Host='localhost';" | grep -qx 0 || { echo "Refusing existing database user: $db_user (or MySQL query failed)" >&2; exit 1; }
if [[ "$skip_ssl" == false ]]; then
  command -v dig >/dev/null || { echo "dig is required for DNS validation" >&2; exit 1; }
  command -v certbot >/dev/null || { echo "Certbot is required unless --skip-ssl is used" >&2; exit 1; }
  cert_listing=$(certbot certificates 2>/dev/null) || { echo "Could not inspect existing Certbot certificates" >&2; exit 1; }
  if awk -v domain="$vhost_name" '/^[[:space:]]*Domains:[[:space:]]*/ { sub(/^[[:space:]]*Domains:[[:space:]]*/, ""); n=split($0, domains, /[[:space:]]+/); for (i=1; i<=n; i++) if (tolower(domains[i]) == tolower(domain)) found=1 } END { exit !found }' <<< "$cert_listing"; then
    echo "Refusing existing certificate containing $vhost_name" >&2; exit 1
  fi
  server_ip=$(hostname -I | awk '{print $1}'); domain_ip=$(dig +short "$vhost_name" | tail -n1)
  [[ -n "$domain_ip" && "$domain_ip" == "$server_ip" ]] || { echo "DNS for $vhost_name does not resolve to this server" >&2; exit 1; }
fi
nginx -t

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
adduser --no-create-home --shell /bin/false "$vhost_name" --force-badname --disabled-password --gecos "Created by prepare_vhost.sh" || fail "Failed to create account"
user_created=true
if getent group "$vhost_name" >/dev/null; then private_group_created=true; fi
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
sed -e "s|__DOMAIN__|$vhost_name|g" -e "s|__VHOSTS_BASE_DIR__|$VHOSTS_BASE_DIR|g" -e "s|__PHP_FPM_VERSION__|$PHP_FPM_VERSION|g" "$template_file" > "$tmp_config" || fail "Failed to render Nginx config"
ln -- "$tmp_config" "$nginx_config" || fail "Could not atomically install Nginx config"
config_created=true
rm -f -- "$tmp_config"
tmp_config=
nginx -t || fail "Nginx configuration test failed"
mkdir -p "$VHOSTS_DIR" || fail "Could not create credentials directory"
chmod 700 "$VHOSTS_DIR" || fail "Could not secure credentials directory"
tmp_credentials=$(mktemp "$VHOSTS_DIR/.${vhost_name}.XXXXXX")
cat > "$tmp_credentials" <<EOF
VHOST: $vhost_name
DOMAIN: $vhost_name
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
  certbot --nginx -d "$vhost_name" -d "www.$vhost_name" --non-interactive --agree-tos --register-unsafely-without-email || fail "Certbot failed"
fi
trap - ERR
echo "Vhost $vhost_name created successfully. Credentials: $output_file"
