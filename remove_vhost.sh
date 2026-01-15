#!/bin/bash

# Adresár pre prístupové údaje
VHOSTS_DIR="/root/vhosts"
ARCHIVE_DIR="$VHOSTS_DIR/archive"

# Vytvorenie archívneho adresára ak neexistuje
if [ ! -d "$ARCHIVE_DIR" ]; then
    mkdir -p "$ARCHIVE_DIR"
    chmod 700 "$ARCHIVE_DIR"
fi

if [ "$EUID" -ne 0 ]; then
  echo "Spusťte skript ako sudo!"
  exit 1
fi

# Kontrola parametra --auto-confirm
auto_confirm=false
if [ "$1" = "--auto-confirm" ]; then
  auto_confirm=true
  shift
fi

# Vypýtanie názvu domény
if [ "$auto_confirm" = true ] && [ -n "$1" ]; then
  vhost_name="$1"
else
  read -p "Zadajte názov domény na odstránenie (napr. domena.sk): " vhost_name
fi

# Kontrola, či bola doména zadaná
if [ -z "$vhost_name" ]; then
  echo "Chyba: Názov domény nemôže byť prázdny!"
  exit 1
fi

# Nastavenie premenných
webroot="/var/www/html/$vhost_name"
nginx_config="/etc/nginx/conf.d/$vhost_name.conf"
db_name=$(echo "$vhost_name" | sed 's/\./_/g' | sed 's/-/_/g')
db_user="$db_name"

echo "=========================================="
echo "POZOR: Chystáte sa odstrániť:"
echo "=========================================="
echo "Doména: $vhost_name"
echo "Používateľ: $vhost_name"
echo "Webroot: $webroot"
echo "Nginx config: $nginx_config"
echo "MySQL databáza: $db_name"
echo "MySQL používateľ: $db_user"
echo "SSL certifikáty: /etc/letsencrypt/live/$vhost_name/"
echo "Nginx logy: /var/log/nginx/$vhost_name-*.log"
echo "=========================================="
echo ""

# Potvrdenie od používateľa
if [ "$auto_confirm" = false ]; then
  read -p "Naozaj chcete odstrániť všetko pre doménu $vhost_name? Napíšte 'YES' pre potvrdenie: " confirm

  if [ "$confirm" != "YES" ]; then
    echo "Odstránenie zrušené."
    exit 0
  fi
else
  echo "[AUTO] Automatické potvrdenie - odstraňujem doménu $vhost_name"
fi

echo ""

# Presun prístupových údajov do archívu
credentials_file="$VHOSTS_DIR/$vhost_name.txt"
if [ -f "$credentials_file" ]; then
  echo "[*] Archivujem prístupové údaje..."
  timestamp=$(date '+%Y%m%d_%H%M%S')
  archive_file="$ARCHIVE_DIR/${vhost_name}_${timestamp}.txt"
  
  # Pridanie informácie o odstránení
  echo "" >> "$credentials_file"
  echo "=======================================================" >> "$credentials_file"
  echo "ODSTRÁNENÉ: $(date '+%Y-%m-%d %H:%M:%S')" >> "$credentials_file"
  echo "=======================================================" >> "$credentials_file"
  
  mv "$credentials_file" "$archive_file"
  chmod 600 "$archive_file"
  echo "[OK] Prístupové údaje archivované do: $archive_file"
else
  echo "[!] Prístupové údaje pre $vhost_name neexistujú v $VHOSTS_DIR"
fi

echo ""
echo "[*] Začínam odstraňovanie..."

# Sledovanie, či boli nejaké zmeny
changes_made=false

# 1. Odstránenie Nginx konfigurácie
if [ -f "$nginx_config" ]; then
  echo "[*] Odstraňujem Nginx konfiguráciu..."
  rm -f "$nginx_config" && changes_made=true
  echo "[OK] Nginx konfigurácia odstránená"
else
  echo "[!] Nginx konfigurácia $nginx_config neexistuje, preskakujem"
fi

# 2. Test a reload Nginx (len ak bola odstránená konfigurácia)
if [ "$changes_made" = true ]; then
  echo "[*] Testujem Nginx konfiguráciu..."
  if nginx -t 2>/dev/null; then
    echo "[*] Reloadujem Nginx..."
    systemctl reload nginx && echo "[OK] Nginx reloadovaný" || echo "[!] Chyba pri reloadovaní Nginx"
  else
    echo "[!] VAROVANIE: Nginx konfigurácia má chyby po odstránení"
  fi
fi

# 3. Odstránenie SSL certifikátov
ssl_exists=false
if [ -d "/etc/letsencrypt/live/$vhost_name" ] || [ -d "/etc/letsencrypt/archive/$vhost_name" ]; then
  ssl_exists=true
fi

if [ "$ssl_exists" = true ]; then
  echo "[*] Odstraňujem SSL certifikáty..."
  if command -v certbot &> /dev/null; then
    certbot delete --cert-name "$vhost_name" --non-interactive 2>/dev/null && echo "[OK] SSL certifikáty odstránené" || {
      echo "[!] Nepodarilo sa odstrániť certifikáty cez certbot, odstraňujem manuálne..."
      rm -rf "/etc/letsencrypt/live/$vhost_name"
      rm -rf "/etc/letsencrypt/archive/$vhost_name"
      rm -f "/etc/letsencrypt/renewal/$vhost_name.conf"
      echo "[OK] SSL certifikáty odstránené manuálne"
    }
  else
    echo "[*] Certbot nie je nainštalovaný, odstraňujem certifikáty manuálne..."
    rm -rf "/etc/letsencrypt/live/$vhost_name"
    rm -rf "/etc/letsencrypt/archive/$vhost_name"
    rm -f "/etc/letsencrypt/renewal/$vhost_name.conf"
    echo "[OK] SSL certifikáty odstránené manuálne"
  fi
else
  echo "[!] SSL certifikáty pre $vhost_name neexistujú, preskakujem"
fi

# 4. Odstránenie používateľa
if id "$vhost_name" &>/dev/null; then
  echo "[*] Odstraňujem používateľa $vhost_name..."

  # Ukončenie všetkých procesov používateľa
  pkill -u "$vhost_name" 2>/dev/null

  # Odstránenie používateľa
  deluser --remove-home "$vhost_name" 2>/dev/null || userdel "$vhost_name" 2>/dev/null
  
  # Overenie, či bol používateľ odstránený
  if id "$vhost_name" &>/dev/null; then
    echo "[!] VAROVANIE: Používateľ nebol úplne odstránený"
  else
    echo "[OK] Používateľ odstránený"
  fi
else
  echo "[!] Používateľ $vhost_name neexistuje, preskakujem"
fi

# 5. Odstránenie webroot adresára
if [ -d "$webroot" ]; then
  echo "[*] Odstraňujem webroot adresár..."
  rm -rf "$webroot"
  
  # Overenie, či bol adresár odstránený
  if [ -d "$webroot" ]; then
    echo "[!] VAROVANIE: Webroot adresár nebol úplne odstránený"
  else
    echo "[OK] Webroot adresár odstránený"
  fi
else
  echo "[!] Webroot adresár $webroot neexistuje, preskakujem"
fi

# 6. Odstránenie MySQL databázy a používateľa
if command -v mysql &> /dev/null; then
  db_found=false
  user_found=false
  
  # Kontrola či databáza existuje
  db_exists=$(mysql -e "SHOW DATABASES LIKE '$db_name';" 2>/dev/null | grep "$db_name")
  
  if [ -n "$db_exists" ]; then
    db_found=true
  fi
  
  # Kontrola či používateľ existuje
  user_exists=$(mysql -e "SELECT User FROM mysql.user WHERE User='$db_user';" 2>/dev/null | grep "$db_user")
  
  if [ -n "$user_exists" ]; then
    user_found=true
  fi
  
  # Odstrániť len ak existuje
  if [ "$db_found" = true ] || [ "$user_found" = true ]; then
    echo "[*] Odstraňujem MySQL databázu a používateľa..."
    
    if [ "$db_found" = true ]; then
      mysql -e "DROP DATABASE IF EXISTS \`$db_name\`;" 2>/dev/null && echo "[OK] MySQL databáza $db_name odstránená" || echo "[!] Chyba pri odstraňovaní databázy"
    fi
    
    if [ "$user_found" = true ]; then
      mysql -e "DROP USER IF EXISTS '$db_user'@'localhost';" 2>/dev/null
      mysql -e "FLUSH PRIVILEGES;" 2>/dev/null
      echo "[OK] MySQL používateľ $db_user odstránený"
    fi
  else
    echo "[!] MySQL databáza ani používateľ $db_name neexistujú, preskakujem"
  fi
else
  echo "[!] MySQL nie je nainštalované, preskakujem odstránenie databázy"
fi

# 7. Odstránenie nginx logov
logs_found=false
if ls /var/log/nginx/$vhost_name-*.log* 1> /dev/null 2>&1; then
  logs_found=true
fi

if [ "$logs_found" = true ]; then
  echo "[*] Odstraňujem Nginx logy..."
  rm -f /var/log/nginx/$vhost_name-*.log
  rm -f /var/log/nginx/$vhost_name-*.log.*.gz
  echo "[OK] Nginx logy odstránené"
else
  echo "[!] Nginx logy pre $vhost_name neexistujú, preskakujem"
fi

# 8. Kontrola a upratanie sftponly grupy
if getent group sftponly > /dev/null; then
  # Skontroluj či má skupina ešte nejakých členov
  group_members=$(getent group sftponly | cut -d: -f4)
  if [ -z "$group_members" ]; then
    echo "[*] Skupina sftponly už nemá žiadnych členov, ponechávam ju pre budúce použitie"
  fi
fi

echo ""
echo "=========================================="
echo "ODSTRÁNENIE DOKONČENÉ"
echo "=========================================="
echo "Doména $vhost_name bola úplne odstránená zo servera."
if [ -f "$archive_file" ]; then
  echo "📁 Archív prístupových údajov: $archive_file"
fi
echo "=========================================="
