#!/bin/bash

# Directory for access credentials
VHOSTS_DIR="/root/vhosts"
ARCHIVE_DIR="$VHOSTS_DIR/archive"

# Create archive directory if it doesn't exist
if [ ! -d "$ARCHIVE_DIR" ]; then
    mkdir -p "$ARCHIVE_DIR"
    chmod 700 "$ARCHIVE_DIR"
fi

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as sudo!"
  exit 1
fi

# Check for --auto-confirm parameter
auto_confirm=false
if [ "$1" = "--auto-confirm" ]; then
  auto_confirm=true
  shift
fi

# Ask for domain name
if [ "$auto_confirm" = true ] && [ -n "$1" ]; then
  vhost_name="$1"
else
  read -p "Enter domain name to remove (e.g., domain.com): " vhost_name
fi

# Check if domain name was entered
if [ -z "$vhost_name" ]; then
  echo "Error: Domain name cannot be empty!"
  exit 1
fi

# Set variables
webroot="/var/www/html/$vhost_name"
nginx_config="/etc/nginx/conf.d/$vhost_name.conf"
db_name=$(echo "$vhost_name" | sed 's/\./_/g' | sed 's/-/_/g')
db_user="$db_name"

echo "=========================================="
echo "WARNING: You are about to remove:"
echo "=========================================="
echo "Domain: $vhost_name"
echo "User: $vhost_name"
echo "Webroot: $webroot"
echo "Nginx config: $nginx_config"
echo "MySQL database: $db_name"
echo "MySQL user: $db_user"
echo "SSL certificates: /etc/letsencrypt/live/$vhost_name/"
echo "Nginx logs: /var/log/nginx/$vhost_name-*.log"
echo "=========================================="
echo ""

# User confirmation
if [ "$auto_confirm" = false ]; then
  read -p "Do you really want to remove everything for domain $vhost_name? Type 'YES' to confirm: " confirm

  if [ "$confirm" != "YES" ]; then
    echo "Removal cancelled."
    exit 0
  fi
else
  echo "[AUTO] Automatic confirmation - removing domain $vhost_name"
fi

echo ""

# Archive access credentials
credentials_file="$VHOSTS_DIR/$vhost_name.txt"
if [ -f "$credentials_file" ]; then
  echo "[*] Archiving access credentials..."
  timestamp=$(date '+%Y%m%d_%H%M%S')
  archive_file="$ARCHIVE_DIR/${vhost_name}_${timestamp}.txt"
  
  # Add removal information
  echo "" >> "$credentials_file"
  echo "=======================================================" >> "$credentials_file"
  echo "REMOVED: $(date '+%Y-%m-%d %H:%M:%S')" >> "$credentials_file"
  echo "=======================================================" >> "$credentials_file"
  
  mv "$credentials_file" "$archive_file"
  chmod 600 "$archive_file"
  echo "[OK] Access credentials archived to: $archive_file"
else
  echo "[!] Access credentials for $vhost_name do not exist in $VHOSTS_DIR"
fi

echo ""
echo "[*] Starting removal..."

# Track if changes were made
changes_made=false

# 1. Remove Nginx configuration
if [ -f "$nginx_config" ]; then
  echo "[*] Removing Nginx configuration..."
  rm -f "$nginx_config" && changes_made=true
  echo "[OK] Nginx configuration removed"
else
  echo "[!] Nginx configuration $nginx_config does not exist, skipping"
fi

# 2. Test and reload Nginx (only if configuration was removed)
if [ "$changes_made" = true ]; then
  echo "[*] Testing Nginx configuration..."
  if nginx -t 2>/dev/null; then
    echo "[*] Reloading Nginx..."
    systemctl reload nginx && echo "[OK] Nginx reloaded" || echo "[!] Error reloading Nginx"
  else
    echo "[!] WARNING: Nginx configuration has errors after removal"
  fi
fi

# 3. Remove SSL certificates
ssl_exists=false
if [ -d "/etc/letsencrypt/live/$vhost_name" ] || [ -d "/etc/letsencrypt/archive/$vhost_name" ]; then
  ssl_exists=true
fi

if [ "$ssl_exists" = true ]; then
  echo "[*] Removing SSL certificates..."
  if command -v certbot &> /dev/null; then
    certbot delete --cert-name "$vhost_name" --non-interactive 2>/dev/null && echo "[OK] SSL certificates removed" || {
      echo "[!] Failed to remove certificates via certbot, removing manually..."
      rm -rf "/etc/letsencrypt/live/$vhost_name"
      rm -rf "/etc/letsencrypt/archive/$vhost_name"
      rm -f "/etc/letsencrypt/renewal/$vhost_name.conf"
      echo "[OK] SSL certificates removed manually"
    }
  else
    echo "[*] Certbot not installed, removing certificates manually..."
    rm -rf "/etc/letsencrypt/live/$vhost_name"
    rm -rf "/etc/letsencrypt/archive/$vhost_name"
    rm -f "/etc/letsencrypt/renewal/$vhost_name.conf"
    echo "[OK] SSL certificates removed manually"
  fi
else
  echo "[!] SSL certificates for $vhost_name do not exist, skipping"
fi

# 4. Remove user
if id "$vhost_name" &>/dev/null; then
  echo "[*] Removing user $vhost_name..."

  # Kill all user processes
  pkill -u "$vhost_name" 2>/dev/null

  # Remove user
  deluser --remove-home "$vhost_name" 2>/dev/null || userdel "$vhost_name" 2>/dev/null
  
  # Verify user was removed
  if id "$vhost_name" &>/dev/null; then
    echo "[!] WARNING: User was not completely removed"
  else
    echo "[OK] User removed"
  fi
else
  echo "[!] User $vhost_name does not exist, skipping"
fi

# 5. Remove webroot directory
if [ -d "$webroot" ]; then
  echo "[*] Removing webroot directory..."
  rm -rf "$webroot"
  
  # Verify directory was removed
  if [ -d "$webroot" ]; then
    echo "[!] WARNING: Webroot directory was not completely removed"
  else
    echo "[OK] Webroot directory removed"
  fi
else
  echo "[!] Webroot directory $webroot does not exist, skipping"
fi

# 6. Remove MySQL database and user
if command -v mysql &> /dev/null; then
  db_found=false
  user_found=false
  
  # Check if database exists
  db_exists=$(mysql -e "SHOW DATABASES LIKE '$db_name';" 2>/dev/null | grep "$db_name")
  
  if [ -n "$db_exists" ]; then
    db_found=true
  fi
  
  # Check if user exists
  user_exists=$(mysql -e "SELECT User FROM mysql.user WHERE User='$db_user';" 2>/dev/null | grep "$db_user")
  
  if [ -n "$user_exists" ]; then
    user_found=true
  fi
  
  # Remove only if exists
  if [ "$db_found" = true ] || [ "$user_found" = true ]; then
    echo "[*] Removing MySQL database and user..."
    
    if [ "$db_found" = true ]; then
      mysql -e "DROP DATABASE IF EXISTS \`$db_name\`;" 2>/dev/null && echo "[OK] MySQL database $db_name removed" || echo "[!] Error removing database"
    fi
    
    if [ "$user_found" = true ]; then
      mysql -e "DROP USER IF EXISTS '$db_user'@'localhost';" 2>/dev/null
      mysql -e "FLUSH PRIVILEGES;" 2>/dev/null
      echo "[OK] MySQL user $db_user removed"
    fi
  else
    echo "[!] MySQL database and user $db_name do not exist, skipping"
  fi
else
  echo "[!] MySQL is not installed, skipping database removal"
fi

# 7. Remove nginx logs
logs_found=false
if ls /var/log/nginx/$vhost_name-*.log* 1> /dev/null 2>&1; then
  logs_found=true
fi

if [ "$logs_found" = true ]; then
  echo "[*] Removing Nginx logs..."
  rm -f /var/log/nginx/$vhost_name-*.log
  rm -f /var/log/nginx/$vhost_name-*.log.*.gz
  echo "[OK] Nginx logs removed"
else
  echo "[!] Nginx logs for $vhost_name do not exist, skipping"
fi

# 8. Check and cleanup sftponly group
if getent group sftponly > /dev/null; then
  # Check if group still has members
  group_members=$(getent group sftponly | cut -d: -f4)
  if [ -z "$group_members" ]; then
    echo "[*] Group sftponly has no more members, keeping it for future use"
  fi
fi

echo ""
echo "=========================================="
echo "REMOVAL COMPLETED"
echo "=========================================="
echo "Domain $vhost_name has been completely removed from the server."
if [ -f "$archive_file" ]; then
  echo "📁 Access credentials archive: $archive_file"
fi
echo "=========================================="