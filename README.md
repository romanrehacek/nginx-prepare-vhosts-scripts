# Vhost Management Scripts

Automated scripts for creating and removing virtual hosts (vhosts) on an Nginx server.

## 📁 Structure

```
scripts/
├── prepare_vhost.sh   # Create new vhost
├── remove_vhost.sh    # Remove existing vhost
├── template.conf      # Nginx configuration template
└── README.md         # This documentation
```

## 🚀 Installation

1. **Set up MySQL root access** (if not already configured):
   ```bash
   sudo nano /root/.my.cnf
   ```
   
   File content:
   ```
   [client]
   user=root
   password=YourMySQLPassword
   ```
   
   Set permissions:
   ```bash
   sudo chmod 600 /root/.my.cnf
   ```

2. **Set executable permissions**:
   ```bash
   sudo chmod +x /var/www/html/scripts/prepare_vhost.sh
   sudo chmod +x /var/www/html/scripts/remove_vhost.sh
   ```

## 📝 Usage

### Creating a new vhost

```bash
sudo /var/www/html/scripts/prepare_vhost.sh
```

**Process:**
1. Enter domain name (e.g., `mysite.com`)
2. Answer whether DNS records are set up (`yes`/`no`)
   - **YES** - checks DNS and creates SSL certificates
   - **NO** - skips DNS check and SSL (for preparation before DNS pointing)

**What the script creates:**
- ✅ SFTP user with random password
- ✅ Directory structure (`/var/www/html/domain.com/public_html/`)
- ✅ MySQL database and user with random password
- ✅ Nginx configuration from template
- ✅ SSL certificates (if DNS is set)
- ✅ File with access credentials (`/root/vhosts/domain.com.txt`)

### Removing a vhost

```bash
sudo /var/www/html/scripts/remove_vhost.sh
```

**Process:**
1. Enter domain name to remove
2. Confirm by typing `YES`

**What the script removes:**
- 🗑️ Nginx configuration
- 🗑️ SSL certificates
- 🗑️ SFTP user
- 🗑️ Webroot directory (all files!)
- 🗑️ MySQL database and user
- 🗑️ Nginx logs
- 📁 Moves access credentials to archive (`/root/vhosts/archive/`)

## 📂 Vhost directory structure

```
/var/www/html/domain.com/
├── public_html/          # Webroot (775, chroot for SFTP)
│   └── index.html
└── logs/                 # Logs (775)
    ├── access.log
    └── error.log
```

## 🔐 Security

### Access credentials
- Stored in `/root/vhosts/` (root access only)
- File permissions `600`
- After vhost deletion → archive `/root/vhosts/archive/`

### SFTP
- Chroot to `/var/www/html/domain.com/`
- Group `sftponly`
- Shell `/bin/false`

### MySQL
- Separate database for each domain
- Separate user with privileges only for their DB
- Random 16-character passwords

## 🔧 Configuration

### Template.conf
- Preconfigured for PHP 8.3
- PrestaShop/WordPress ready
- Client max body size: 512M
- FastCGI timeout: 300s

### Template customization
Edit `template.conf` as needed. The `$domain` variable is automatically replaced with the actual domain name.

## 📊 Example output

```
=======================================================
VHOST: mysite.com
Created: 2024-01-15 14:32:05
=======================================================

DOMAIN: mysite.com
  Webroot: /var/www/html/mysite.com/public_html
  Nginx config: /etc/nginx/conf.d/mysite.com.conf

SFTP ACCESS:
  Username: mysite.com
  Password: xY9zK2pQ8vNm4rA5
  Chroot directory: /var/www/html/mysite.com

SSL CERTIFICATES:
  Status: Created
  Renewal command: certbot renew

MYSQL DATABASE:
  Database: mysite_com
  Username: mysite_com
  Password: aB3cD4eF5gH6iJ7k
  Host: localhost

=======================================================

💾 Access credentials have been saved to: /root/vhosts/mysite.com.txt
```

## 🆘 Troubleshooting

### DNS not set up
When creating, choose `no` and after setting up DNS run:
```bash
sudo certbot --nginx -d mysite.com -d www.mysite.com
```

### Rollback on error
If creation fails, the script automatically removes all partially created components.

### View saved credentials
```bash
sudo cat /root/vhosts/mysite.com.txt
sudo ls -lh /root/vhosts/archive/
```

### Test Nginx configuration
```bash
sudo nginx -t
```

## 📋 Requirements

- Ubuntu/Debian server
- Nginx
- PHP-FPM (8.3)
- MySQL/MariaDB
- Certbot
- OpenSSH server with SFTP
- dig (dnsutils)

## 🔄 Workflow

### For new domains (before DNS):
1. `sudo ./prepare_vhost.sh` → choose `no`
2. Point DNS to server
3. `sudo certbot --nginx -d domain.com -d www.domain.com`

### For existing domains (after DNS):
1. `sudo ./prepare_vhost.sh` → choose `yes`
2. Done!

## 📝 Notes

- Domain names can contain hyphens and dots
- For MySQL, hyphens and dots are replaced with underscores
- All passwords are 16-character random strings (base64)
- Nginx logs are in `/var/log/nginx/domain.com-*.log`

## 🤝 Support

If you encounter issues, check:
- `/root/vhosts/domain.com.txt` - access credentials
- `/var/log/nginx/error.log` - nginx errors
- `sudo nginx -t` - syntax check
- `sudo systemctl status nginx` - nginx status