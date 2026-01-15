# Vhost Management Scripts

Automatizované scripty pre vytváranie a mazanie virtuálnych hostov (vhosts) na Nginx serveri.

## 📁 Štruktúra

```
scripts/
├── prepare_vhost.sh   # Vytvorenie nového vhost
├── remove_vhost.sh    # Odstránenie existujúceho vhost
├── template.conf      # Nginx konfiguračná šablóna
└── README.md         # Táto dokumentácia
```

## 🚀 Inštalácia

1. **Nastavte MySQL root prístup** (ak ešte nie je nastavený):
   ```bash
   sudo nano /root/.my.cnf
   ```
   
   Obsah súboru:
   ```
   [client]
   user=root
   password=VaseMySQLHeslo
   ```
   
   Nastavte práva:
   ```bash
   sudo chmod 600 /root/.my.cnf
   ```

2. **Nastavte spustiteľné práva**:
   ```bash
   sudo chmod +x /var/www/html/scripts/prepare_vhost.sh
   sudo chmod +x /var/www/html/scripts/remove_vhost.sh
   ```

## 📝 Použitie

### Vytvorenie nového vhost

```bash
sudo /var/www/html/scripts/prepare_vhost.sh
```

**Priebeh:**
1. Zadáte názov domény (napr. `mojastranka.sk`)
2. Odpovediete, či sú DNS záznamy nastavené (`ano`/`nie`)
   - **ANO** - skontroluje DNS a vytvorí SSL certifikáty
   - **NIE** - preskočí DNS kontrolu a SSL (pre prípravu pred nasmerovaním DNS)

**Čo script vytvorí:**
- ✅ SFTP používateľa s náhodným heslom
- ✅ Adresárovú štruktúru (`/var/www/html/domena.sk/public_html/`)
- ✅ MySQL databázu a používateľa s náhodným heslom
- ✅ Nginx konfiguráciu z template
- ✅ SSL certifikáty (ak sú DNS nastavené)
- ✅ Súbor s prístupovými údajmi (`/root/vhosts/domena.sk.txt`)

### Odstránenie vhost

```bash
sudo /var/www/html/scripts/remove_vhost.sh
```

**Priebeh:**
1. Zadáte názov domény na odstránenie
2. Potvrdíte zadaním `YES`

**Čo script odstráni:**
- 🗑️ Nginx konfiguráciu
- 🗑️ SSL certifikáty
- 🗑️ SFTP používateľa
- 🗑️ Webroot adresár (všetky súbory!)
- 🗑️ MySQL databázu a používateľa
- 🗑️ Nginx logy
- 📁 Presunie prístupové údaje do archívu (`/root/vhosts/archive/`)

## 📂 Adresárová štruktúra vhost

```
/var/www/html/domena.sk/
├── public_html/          # Webroot (775, chroot pre SFTP)
│   └── index.html
└── logs/                 # Logy (775)
    ├── access.log
    └── error.log
```

## 🔐 Bezpečnosť

### Prístupové údaje
- Uložené v `/root/vhosts/` (prístup len root)
- Práva `600` na súbory
- Po zmazaní vhost → archív `/root/vhosts/archive/`

### SFTP
- Chroot do `/var/www/html/domena.sk/`
- Skupina `sftponly`
- Shell `/bin/false`

### MySQL
- Samostatná databáza pre každú doménu
- Samostatný používateľ s právami len na svoju DB
- Náhodné 16-znakové heslá

## 🔧 Konfigurácia

### Template.conf
- Prednastavené pre PHP 8.3
- PrestaShop/WordPress ready
- Client max body size: 512M
- FastCGI timeout: 300s

### Customizácia template
Upravte `template.conf` podľa potreby. Premenná `$domain` sa automaticky nahradí skutočným názvom domény.

## 📊 Príklad výstupu

```
=======================================================
VHOST: mojastranka.sk
Vytvorené: 2024-01-15 14:32:05
=======================================================

DOMÉNA: mojastranka.sk
  Webroot: /var/www/html/mojastranka.sk/public_html
  Nginx config: /etc/nginx/conf.d/mojastranka.sk.conf

SFTP PRÍSTUP:
  Používateľ: mojastranka.sk
  Heslo: xY9zK2pQ8vNm4rA5
  Chroot adresár: /var/www/html/mojastranka.sk

SSL CERTIFIKÁTY:
  Stav: Vytvorené
  Príkaz pre obnovenie: certbot renew

MYSQL DATABÁZA:
  Databáza: mojastranka_sk
  Používateľ: mojastranka_sk
  Heslo: aB3cD4eF5gH6iJ7k
  Host: localhost

=======================================================

💾 Prístupové údaje boli uložené do: /root/vhosts/mojastranka.sk.txt
```

## 🆘 Riešenie problémov

### DNS nie sú nastavené
Pri vytváraní zvoľte `nie` a po nastavení DNS spustite:
```bash
sudo certbot --nginx -d mojastranka.sk -d www.mojastranka.sk
```

### Rollback pri chybe
Ak vytvorenie zlyhá, script automaticky vymaže všetky čiastočne vytvorené komponenty.

### Zobrazenie uložených údajov
```bash
sudo cat /root/vhosts/mojastranka.sk.txt
sudo ls -lh /root/vhosts/archive/
```

### Testovanie Nginx konfigurácie
```bash
sudo nginx -t
```

## 📋 Požiadavky

- Ubuntu/Debian server
- Nginx
- PHP-FPM (8.3)
- MySQL/MariaDB
- Certbot
- OpenSSH server s SFTP
- dig (dnsutils)

## 🔄 Workflow

### Pre nové domény (pred DNS):
1. `sudo ./prepare_vhost.sh` → zvoľte `nie`
2. Nasmerujte DNS na server
3. `sudo certbot --nginx -d domena.sk -d www.domena.sk`

### Pre existujúce domény (po DNS):
1. `sudo ./prepare_vhost.sh` → zvoľte `ano`
2. Hotovo!

## 📝 Poznámky

- Názvy domén môžu obsahovať pomlčky a bodky
- Pre MySQL sa pomlčky a bodky nahradia podčiarknikmi
- Všetky heslá sú 16-znakové náhodné reťazce (base64)
- Nginx logy sú v `/var/log/nginx/domena.sk-*.log`

## 🤝 Podpora

Pri problémoch skontrolujte:
- `/root/vhosts/domena.sk.txt` - prístupové údaje
- `/var/log/nginx/error.log` - nginx chyby
- `sudo nginx -t` - syntax check
- `sudo systemctl status nginx` - nginx stav