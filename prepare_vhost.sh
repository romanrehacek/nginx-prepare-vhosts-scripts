#!/bin/bash

# Detect the directory where this script is located
script_dir=$(dirname "$(readlink -f "$0")")

# Directory for storing access credentials
VHOSTS_DIR="/root/vhosts"

# Create directory if it doesn't exist
if [ ! -d "$VHOSTS_DIR" ]; then
    mkdir -p "$VHOSTS_DIR"
    chmod 700 "$VHOSTS_DIR"
fi

# Variables for tracking created components
user_created=false
webroot_created=false
db_created=false
nginx_config_created=false

# Rollback function (runs remove_vhost.sh)
rollback() {
    echo ""
    echo "======================================================="
    echo "          ERROR: STARTING ROLLBACK"
    echo "======================================================="
    echo "[*] Removing partially created components..."
    echo ""
    
    # Path to remove_vhost.sh
    remove_script="$script_dir/remove_vhost.sh"
    
    # Check if remove_vhost.sh exists
    if [ ! -f "$remove_script" ]; then
        echo "[!] WARNING: Script $remove_script not found!"
        echo "[*] Attempting manual cleanup..."
        
        # Manual cleanup as fallback
        [ -f "$nginx_config" ] && rm -f "$nginx_config" && nginx -t &>/dev/null && systemctl reload nginx &>/dev/null
        [ "$db_created" = true ] && command -v mysql &> /dev/null && mysql -e "DROP DATABASE IF EXISTS \`$db_name\`; DROP USER IF EXISTS '$db_user'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
        [ -d "$webroot" ] && rm -rf "$webroot"
        [ "$user_created" = true ] && id "$vhost_name" &>/dev/null && pkill -u "$vhost_name" 2>/dev/null && userdel "$vhost_name" 2>/dev/null
        rm -f /var/log/nginx/$vhost_name-*.log 2>/dev/null
        
        echo "[OK] Manual cleanup completed"
    else
        # Run remove_vhost.sh with automatic confirmation
        "$remove_script" --auto-confirm "$vhost_name"
    fi
    
    echo "======================================================="
    echo "ROLLBACK COMPLETED - All changes have been reverted"
    echo "======================================================="
    exit 1
}

# Set error handler
trap rollback ERR

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as sudo!"
  exit 1
fi

# Ask for domain name
read -p "Enter domain name (e.g., domain.com): " vhost_name

# Check if domain name was entered
if [ -z "$vhost_name" ]; then
  echo "Error: Domain name cannot be empty!"
  exit 1
fi

# Question about DNS setup
echo ""
read -p "Have DNS records been set up for domain $vhost_name? (yes/no): " dns_ready

# Variable for tracking whether to check SSL
skip_ssl=false

if [ "$dns_ready" = "yes" ] || [ "$dns_ready" = "y" ] || [ "$dns_ready" = "ano" ] || [ "$dns_ready" = "a" ]; then
    # Check if domain points to this server
    echo "[*] Checking DNS for domain $vhost_name..."
    server_ip=$(hostname -I | awk '{print $1}')
    domain_ip=$(dig +short "$vhost_name" | tail -n1)

    if [ -z "$domain_ip" ]; then
        echo "[!] ERROR: Domain $vhost_name has no DNS record set!"
        echo "Set DNS A record for domain $vhost_name to IP address $server_ip"
        exit 1
    elif [ "$domain_ip" != "$server_ip" ]; then
        echo "[!] ERROR: Domain $vhost_name points to $domain_ip, but server has IP $server_ip"
        echo "Set DNS A record correctly and run the script again."
        exit 1
    else
        echo "[OK] DNS is correctly set ($domain_ip)"
    fi
elif [ "$dns_ready" = "no" ] || [ "$dns_ready" = "n" ] || [ "$dns_ready" = "nie" ]; then
    echo "[*] DNS not set - skipping DNS check and SSL certificates"
    echo "[*] After setting up DNS, run manually: certbot --nginx -d $vhost_name -d www.$vhost_name"
    skip_ssl=true
else
    echo "[!] ERROR: Invalid answer. Enter 'yes' or 'no'"
    exit 1
fi

# Automatic password generation (16 characters)
vhost_pass=$(openssl rand -base64 12)
db_pass=$(openssl rand -base64 12)

# Set webroot path and database name
webroot="/var/www/$vhost_name"
db_name=$(echo "$vhost_name" | sed 's/\./_/g' | sed 's/-/_/g')
db_user="$db_name"
nginx_config="/etc/nginx/conf.d/$vhost_name.conf"

echo "--- Preparing environment for: $vhost_name ---"

# 1. Create sftponly group
if ! getent group sftponly > /dev/null; then
    groupadd sftponly || { echo "[!] ERROR: Failed to create sftponly group"; rollback; }
fi

# 2. Create user
if id "$vhost_name" &>/dev/null; then
    echo "[!] ERROR: User $vhost_name already exists!"
    exit 1
else
    adduser --shell /bin/false "$vhost_name" --force-badname --disabled-password --gecos "" || { echo "[!] ERROR: Failed to create user"; rollback; }
    echo "$vhost_name:$vhost_pass" | chpasswd || { echo "[!] ERROR: Failed to set password"; rollback; }
    echo "[OK] User created."
    user_created=true
fi

# 3. Set home directory (webroot)
usermod -d "$webroot" "$vhost_name" || { echo "[!] ERROR: Failed to set home directory"; rollback; }

# 4. Add user to sftponly group
adduser "$vhost_name" sftponly || { echo "[!] ERROR: Failed to add user to group"; rollback; }

# Add www-data to group (for web server access)
usermod -aG sftponly www-data || { echo "[!] ERROR: Failed to add www-data to group"; rollback; }

# 5. Create directory structure
mkdir -p "$webroot/public_html" || { echo "[!] ERROR: Failed to create public_html"; rollback; }
mkdir -p "$webroot/logs" || { echo "[!] ERROR: Failed to create logs"; rollback; }
webroot_created=true
echo "[OK] Directory structure created"

# 6. Set permissions
chmod 775 -R "$webroot/public_html" || { echo "[!] ERROR: Failed to set permissions"; rollback; }
chown -R "$vhost_name:sftponly" "$webroot/public_html" || { echo "[!] ERROR: Failed to set owner"; rollback; }
chmod g+s "$webroot/public_html/" || { echo "[!] ERROR: Failed to set SGID bit"; rollback; }

chown -R "$vhost_name:sftponly" "$webroot/logs" || { echo "[!] ERROR: Failed to set logs owner"; rollback; }
chmod 775 -R "$webroot/logs" || { echo "[!] ERROR: Failed to set logs permissions"; rollback; }

chmod 755 "$webroot" || { echo "[!] ERROR: Failed to set webroot permissions"; rollback; }
chown root:root "$webroot" || { echo "[!] ERROR: Failed to set webroot owner"; rollback; }
echo "[OK] Permissions set"

# 7. Create MySQL database and user
echo "[*] Creating MySQL database and user..."

if ! command -v mysql &> /dev/null; then
    echo "[!] WARNING: MySQL/MariaDB is not installed. Database was not created."
    db_created=false
else
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
    if [ $? -eq 0 ]; then
        mysql -e "CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';" 2>/dev/null || { echo "[!] ERROR: Failed to create MySQL user"; rollback; }
        mysql -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';" 2>/dev/null || { echo "[!] ERROR: Failed to set MySQL privileges"; rollback; }
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null
        echo "[OK] MySQL database and user created"
        db_created=true
    else
        echo "[!] WARNING: Failed to create database. Continuing without database."
        db_created=false
    fi
fi

# 8. Create Nginx configuration from template
template_file="$script_dir/template.conf"
nginx_config="/etc/nginx/conf.d/$vhost_name.conf"

if [ ! -f "$template_file" ]; then
    echo "[!] ERROR: Template $template_file does not exist!"
    rollback
fi

echo "[*] Creating Nginx configuration..."
sed "s/\$domain/$vhost_name/g" "$template_file" > "$nginx_config" || { echo "[!] ERROR: Failed to create Nginx configuration"; rollback; }
nginx_config_created=true
echo "[OK] Nginx configuration created: $nginx_config"

# 9. Test Nginx configuration
echo "[*] Testing Nginx configuration..."
if ! nginx -t 2>&1; then
    echo "[!] ERROR: Nginx configuration has errors!"
    echo "Configuration file: $nginx_config"
    rollback
fi
echo "[OK] Nginx configuration is valid"

# 10. Restart Nginx
echo "[*] Restarting Nginx..."
if ! systemctl restart nginx; then
    echo "[!] ERROR: Failed to restart Nginx!"
    rollback
fi
echo "[OK] Nginx successfully restarted"

# 11. Run Certbot for SSL certificates (only if DNS is set)
if [ "$skip_ssl" = false ]; then
    echo "[*] Running Certbot for domain $vhost_name..."
    if command -v certbot &> /dev/null; then
        certbot --nginx -d "$vhost_name" -d "www.$vhost_name" --non-interactive --agree-tos --register-unsafely-without-email || {
            echo "[!] WARNING: Certbot failed. SSL certificates were not created."
            echo "    You can try manually with: certbot --nginx -d $vhost_name -d www.$vhost_name"
        }
    else
        echo "[!] WARNING: Certbot is not installed. SSL certificates were not created."
        echo "    Install certbot and run: certbot --nginx -d $vhost_name -d www.$vhost_name"
    fi
else
    echo "[!] SSL certificates were not created (DNS not set)"
    echo "    After setting up DNS run: certbot --nginx -d $vhost_name -d www.$vhost_name"
fi

# Disable error handler (everything succeeded)
trap - ERR

# Prepare output
output_file="$VHOSTS_DIR/$vhost_name.txt"
timestamp=$(date '+%Y-%m-%d %H:%M:%S')

# Create output file with access credentials
cat > "$output_file" << EOF
=======================================================
VHOST: $vhost_name
Created: $timestamp
=======================================================

DOMAIN: $vhost_name
  Webroot: $webroot/public_html
  Nginx config: $nginx_config
  Logs: /var/log/nginx/$vhost_name-access.log
        /var/log/nginx/$vhost_name-error.log

SFTP ACCESS:
  Username: $vhost_name
  Password: $vhost_pass
  Chroot directory: $webroot

SSL CERTIFICATES:
EOF

if [ "$skip_ssl" = false ]; then
cat >> "$output_file" << EOF
  Status: Created (or attempted to create)
  Renewal command: certbot renew

EOF
else
cat >> "$output_file" << EOF
  Status: NOT CREATED (DNS not set)
  After setting up DNS run: certbot --nginx -d $vhost_name -d www.$vhost_name

EOF
fi

# Add MySQL credentials if created
if [ "$db_created" = true ]; then
cat >> "$output_file" << EOF
MYSQL DATABASE:
  Database: $db_name
  Username: $db_user
  Password: $db_pass
  Host: localhost

EOF
else
cat >> "$output_file" << EOF
MYSQL DATABASE:
  [!] Database was not created (MySQL not available)

EOF
fi

echo "=======================================================" >> "$output_file"

# Set file permissions
chmod 600 "$output_file"

# Display output to console
echo ""
cat "$output_file"
echo ""
echo "💾 Access credentials have been saved to: $output_file"
echo ""
