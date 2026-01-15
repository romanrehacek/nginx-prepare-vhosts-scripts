#!/bin/bash

# Zistenie adresára kde sa nachádza tento script
script_dir=$(dirname "$(readlink -f "$0")")

# Adresár pre ukladanie prístupových údajov
VHOSTS_DIR="/root/vhosts"

# Vytvorenie adresára ak neexistuje
if [ ! -d "$VHOSTS_DIR" ]; then
    mkdir -p "$VHOSTS_DIR"
    chmod 700 "$VHOSTS_DIR"
fi

# Premenné pre sledovanie vytvorených komponentov
user_created=false
webroot_created=false
db_created=false
nginx_config_created=false

# Funkcia pre rollback (spustí remove_vhost.sh)
rollback() {
    echo ""
    echo "======================================================="
    echo "          CHYBA: SPÚŠŤAM ROLLBACK"
    echo "======================================================="
    echo "[*] Odstraňujem čiastočne vytvorené komponenty..."
    echo ""
    
    # Cesta k remove_vhost.sh
    remove_script="$script_dir/remove_vhost.sh"
    
    # Kontrola, či existuje remove_vhost.sh
    if [ ! -f "$remove_script" ]; then
        echo "[!] VAROVANIE: Script $remove_script nebol nájdený!"
        echo "[*] Pokúsim sa o manuálne vyčistenie..."
        
        # Manuálne vyčistenie ako záloha
        [ -f "$nginx_config" ] && rm -f "$nginx_config" && nginx -t &>/dev/null && systemctl reload nginx &>/dev/null
        [ "$db_created" = true ] && command -v mysql &> /dev/null && mysql -e "DROP DATABASE IF EXISTS \`$db_name\`; DROP USER IF EXISTS '$db_user'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
        [ -d "$webroot" ] && rm -rf "$webroot"
        [ "$user_created" = true ] && id "$vhost_name" &>/dev/null && pkill -u "$vhost_name" 2>/dev/null && userdel "$vhost_name" 2>/dev/null
        rm -f /var/log/nginx/$vhost_name-*.log 2>/dev/null
        
        echo "[OK] Manuálne vyčistenie dokončené"
    else
        # Spustenie remove_vhost.sh s automatickým potvrdením
        "$remove_script" --auto-confirm "$vhost_name"
    fi
    
    echo "======================================================="
    echo "ROLLBACK DOKONČENÝ - Všetky zmeny boli vrátené späť"
    echo "======================================================="
    exit 1
}

# Nastavenie error handlera
trap rollback ERR

if [ "$EUID" -ne 0 ]; then
  echo "Spusťte skript ako sudo!"
  exit 1
fi

# Vypýtanie názvu domény
read -p "Zadajte názov domény (napr. domena.sk): " vhost_name

# Kontrola, či bola doména zadaná
if [ -z "$vhost_name" ]; then
  echo "Chyba: Názov domény nemôže byť prázdny!"
  exit 1
fi

# Otázka na DNS nastavenie
echo ""
read -p "Boli už nastavené DNS záznamy pre doménu $vhost_name? (ano/nie): " dns_ready

# Premenná pre sledovanie, či kontrolovať SSL
skip_ssl=false

if [ "$dns_ready" = "ano" ] || [ "$dns_ready" = "a" ] || [ "$dns_ready" = "y" ] || [ "$dns_ready" = "yes" ]; then
    # Kontrola, či doména smeruje na tento server
    echo "[*] Kontrolujem DNS pre doménu $vhost_name..."
    server_ip=$(hostname -I | awk '{print $1}')
    domain_ip=$(dig +short "$vhost_name" | tail -n1)

    if [ -z "$domain_ip" ]; then
        echo "[!] CHYBA: Doména $vhost_name nemá nastavený DNS záznam!"
        echo "Nastavte DNS A záznam pre doménu $vhost_name na IP adresu $server_ip"
        exit 1
    elif [ "$domain_ip" != "$server_ip" ]; then
        echo "[!] CHYBA: Doména $vhost_name smeruje na $domain_ip, ale server má IP $server_ip"
        echo "Nastavte DNS A záznam správne a spustite skript znovu."
        exit 1
    else
        echo "[OK] DNS je správne nastavené ($domain_ip)"
    fi
elif [ "$dns_ready" = "nie" ] || [ "$dns_ready" = "n" ] || [ "$dns_ready" = "no" ]; then
    echo "[*] DNS nie sú nastavené - preskakujem DNS kontrolu a SSL certifikáty"
    echo "[*] Po nastavení DNS spustite manuálne: certbot --nginx -d $vhost_name -d www.$vhost_name"
    skip_ssl=true
else
    echo "[!] CHYBA: Neplatná odpoveď. Zadajte 'ano' alebo 'nie'"
    exit 1
fi

# Automatické vygenerovanie hesiel (16 znakov)
vhost_pass=$(openssl rand -base64 12)
db_pass=$(openssl rand -base64 12)

# Nastavenie webroot cesty a databázového názvu
webroot="/var/www/html/$vhost_name"
db_name=$(echo "$vhost_name" | sed 's/\./_/g' | sed 's/-/_/g')
db_user="$db_name"
nginx_config="/etc/nginx/conf.d/$vhost_name.conf"

echo "--- Pripravujem prostredie pre: $vhost_name ---"

# 1. Vytvorenie grupy sftponly
if ! getent group sftponly > /dev/null; then
    groupadd sftponly || { echo "[!] CHYBA: Nepodarilo sa vytvoriť skupinu sftponly"; rollback; }
fi

# 2. Vytvorenie používateľa
if id "$vhost_name" &>/dev/null; then
    echo "[!] CHYBA: Používateľ $vhost_name už existuje!"
    exit 1
else
    adduser --shell /bin/false "$vhost_name" --force-badname --disabled-password --gecos "" || { echo "[!] CHYBA: Nepodarilo sa vytvoriť používateľa"; rollback; }
    echo "$vhost_name:$vhost_pass" | chpasswd || { echo "[!] CHYBA: Nepodarilo sa nastaviť heslo"; rollback; }
    echo "[OK] Používateľ vytvorený."
    user_created=true
fi

# 3. Nastavenie domovského adresára (webroot)
usermod -d "$webroot" "$vhost_name" || { echo "[!] CHYBA: Nepodarilo sa nastaviť domovský adresár"; rollback; }

# 4. Pridanie používateľa do grupy sftponly
adduser "$vhost_name" sftponly || { echo "[!] CHYBA: Nepodarilo sa pridať používateľa do skupiny"; rollback; }

# Pridanie www-data do grupy (pre prístup webservera)
usermod -aG sftponly www-data || { echo "[!] CHYBA: Nepodarilo sa pridať www-data do skupiny"; rollback; }

# 5. Vytvorenie adresárovej štruktúry
mkdir -p "$webroot/public_html" || { echo "[!] CHYBA: Nepodarilo sa vytvoriť public_html"; rollback; }
mkdir -p "$webroot/logs" || { echo "[!] CHYBA: Nepodarilo sa vytvoriť logs"; rollback; }
webroot_created=true
echo "[OK] Adresárová štruktúra vytvorená"

# 6. Nastavenie práv
chmod 775 -R "$webroot/public_html" || { echo "[!] CHYBA: Nepodarilo sa nastaviť práva"; rollback; }
chown -R "$vhost_name:sftponly" "$webroot/public_html" || { echo "[!] CHYBA: Nepodarilo sa nastaviť vlastníka"; rollback; }
chmod g+s "$webroot/public_html/" || { echo "[!] CHYBA: Nepodarilo sa nastaviť SGID bit"; rollback; }

chown -R "$vhost_name:sftponly" "$webroot/logs" || { echo "[!] CHYBA: Nepodarilo sa nastaviť vlastníka logov"; rollback; }
chmod 775 -R "$webroot/logs" || { echo "[!] CHYBA: Nepodarilo sa nastaviť práva pre logy"; rollback; }

chmod 755 "$webroot" || { echo "[!] CHYBA: Nepodarilo sa nastaviť práva pre webroot"; rollback; }
chown root:root "$webroot" || { echo "[!] CHYBA: Nepodarilo sa nastaviť vlastníka webroot"; rollback; }
echo "[OK] Práva nastavené"

# 7. Vytvorenie MySQL databázy a používateľa
echo "[*] Vytváram MySQL databázu a používateľa..."

if ! command -v mysql &> /dev/null; then
    echo "[!] VAROVANIE: MySQL/MariaDB nie je nainštalované. Databáza nebola vytvorená."
    db_created=false
else
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
    if [ $? -eq 0 ]; then
        mysql -e "CREATE USER IF NOT EXISTS '$db_user'@'localhost' IDENTIFIED BY '$db_pass';" 2>/dev/null || { echo "[!] CHYBA: Nepodarilo sa vytvoriť MySQL používateľa"; rollback; }
        mysql -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';" 2>/dev/null || { echo "[!] CHYBA: Nepodarilo sa nastaviť MySQL práva"; rollback; }
        mysql -e "FLUSH PRIVILEGES;" 2>/dev/null
        echo "[OK] MySQL databáza a používateľ vytvorené"
        db_created=true
    else
        echo "[!] VAROVANIE: Nepodarilo sa vytvoriť databázu. Pokračujem bez databázy."
        db_created=false
    fi
fi

# 8. Vytvorenie Nginx konfigurácie zo šablóny
template_file="$script_dir/template.conf"
nginx_config="/etc/nginx/conf.d/$vhost_name.conf"

if [ ! -f "$template_file" ]; then
    echo "[!] CHYBA: Šablóna $template_file neexistuje!"
    rollback
fi

echo "[*] Vytváram Nginx konfiguráciu..."
sed "s/\$domain/$vhost_name/g" "$template_file" > "$nginx_config" || { echo "[!] CHYBA: Nepodarilo sa vytvoriť Nginx konfiguráciu"; rollback; }
nginx_config_created=true
echo "[OK] Nginx konfigurácia vytvorená: $nginx_config"

# 9. Test Nginx konfigurácie
echo "[*] Testujem Nginx konfiguráciu..."
if ! nginx -t 2>&1; then
    echo "[!] CHYBA: Nginx konfigurácia má chyby!"
    echo "Konfiguračný súbor: $nginx_config"
    rollback
fi
echo "[OK] Nginx konfigurácia je v poriadku"

# 10. Restart Nginx
echo "[*] Reštartujem Nginx..."
if ! systemctl restart nginx; then
    echo "[!] CHYBA: Nepodarilo sa reštartovať Nginx!"
    rollback
fi
echo "[OK] Nginx bol úspešne reštartovaný"

# 11. Spustenie Certbot pre SSL certifikáty (len ak sú DNS nastavené)
if [ "$skip_ssl" = false ]; then
    echo "[*] Spúšťam Certbot pre doménu $vhost_name..."
    if command -v certbot &> /dev/null; then
        certbot --nginx -d "$vhost_name" -d "www.$vhost_name" --non-interactive --agree-tos --register-unsafely-without-email || {
            echo "[!] VAROVANIE: Certbot zlyhal. SSL certifikáty neboli vytvorené."
            echo "    Môžete to skúsiť manuálne pomocou: certbot --nginx -d $vhost_name -d www.$vhost_name"
        }
    else
        echo "[!] VAROVANIE: Certbot nie je nainštalovaný. SSL certifikáty neboli vytvorené."
        echo "    Nainštalujte certbot a spustite: certbot --nginx -d $vhost_name -d www.$vhost_name"
    fi
else
    echo "[!] SSL certifikáty neboli vytvorené (DNS nie sú nastavené)"
    echo "    Po nastavení DNS spustite: certbot --nginx -d $vhost_name -d www.$vhost_name"
fi

# Vypnutie error handlera (všetko prebehlo úspešne)
trap - ERR

# Príprava výstupu
output_file="$VHOSTS_DIR/$vhost_name.txt"
timestamp=$(date '+%Y-%m-%d %H:%M:%S')

# Vytvorenie výstupného súboru s prístupovými údajmi
cat > "$output_file" << EOF
=======================================================
VHOST: $vhost_name
Vytvorené: $timestamp
=======================================================

DOMÉNA: $vhost_name
  Webroot: $webroot/public_html
  Nginx config: $nginx_config
  Logy: /var/log/nginx/$vhost_name-access.log
        /var/log/nginx/$vhost_name-error.log

SFTP PRÍSTUP:
  Používateľ: $vhost_name
  Heslo: $vhost_pass
  Chroot adresár: $webroot

SSL CERTIFIKÁTY:
EOF

if [ "$skip_ssl" = false ]; then
cat >> "$output_file" << EOF
  Stav: Vytvorené (alebo sa pokúsilo vytvoriť)
  Príkaz pre obnovenie: certbot renew

EOF
else
cat >> "$output_file" << EOF
  Stav: NEVYTVORENÉ (DNS neboli nastavené)
  Po nastavení DNS spustite: certbot --nginx -d $vhost_name -d www.$vhost_name

EOF
fi

# Pridanie MySQL údajov ak boli vytvorené
if [ "$db_created" = true ]; then
cat >> "$output_file" << EOF
MYSQL DATABÁZA:
  Databáza: $db_name
  Používateľ: $db_user
  Heslo: $db_pass
  Host: localhost

EOF
else
cat >> "$output_file" << EOF
MYSQL DATABÁZA:
  [!] Databáza nebola vytvorená (MySQL nie je dostupné)

EOF
fi

echo "=======================================================" >> "$output_file"

# Nastavenie práv na súbor
chmod 600 "$output_file"

# Zobrazenie výstupu na konzole
echo ""
cat "$output_file"
echo ""
echo "💾 Prístupové údaje boli uložené do: $output_file"
echo ""