# 🔒 MongoDB Server Hardening Script

A comprehensive, enterprise-grade security hardening script for MongoDB servers with **mandatory SSL/TLS encryption**, automated certificate management, and user-friendly operation for anyone regardless of technical background.

[![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)](CHANGELOG.md)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Security](https://img.shields.io/badge/security-SSL%2FTLS%20Mandatory-red.svg)](#security-features)
[![MongoDB](https://img.shields.io/badge/MongoDB-3.4.24-green.svg)](#mongodb-support)

## 🚀 Quick Start

```bash
# Clone the repository
git clone <repository-url>
cd harden-mongo-server

# Make executable
chmod +x harden-mongo-server.sh

# Run with domain name (interactive setup)
sudo ./harden-mongo-server.sh

# Or with environment variables (non-interactive)
sudo MONGO_DOMAIN="db.mycompany.com" MONGO_ADMIN_PASS="securepass" ./harden-mongo-server.sh
```

## 🔐 Security Features

### **Mandatory SSL/TLS Encryption**
- ✅ **All connections encrypted** - No unencrypted traffic ever transmitted
- ✅ **Let's Encrypt certificates** - Free, trusted SSL certificates
- ✅ **Client certificate authentication** - x.509 certificate-based auth
- ✅ **Automatic renewal** - Certificates renewed monthly via systemd
- ✅ **Domain validation** - Proper DNS-based certificate validation

### **Enterprise-Grade Security**
- ✅ **WiredTiger storage engine** - Modern, secure data storage
- ✅ **Strong authentication** - Root-level admin access control
- ✅ **Firewall protection** - Only specified IPs allowed
- ✅ **Service isolation** - Dedicated mongodb user account
- ✅ **mmapv1 migration** - Automatic upgrade from legacy storage

### **Automated Security Maintenance**
- ✅ **Certificate monitoring** - Track expiry dates automatically
- ✅ **Service watchdog** - Auto-restart if MongoDB goes down
- ✅ **Disk space cleanup** - Prevent disk-full situations
- ✅ **Security validation** - Regular configuration verification
- ✅ **Backup automation** - Weekly encrypted backups

## 🎯 Who This Is For

This script is designed for **anyone** who needs to secure a MongoDB server:

- **System administrators** - Get enterprise-grade security without complexity
- **Developers** - Secure your development and production databases easily  
- **Small businesses** - Implement professional security without hiring experts
- **DevOps teams** - Automate MongoDB security hardening in your pipelines
- **Security conscious users** - Maximum protection with minimal effort

**No MongoDB expertise required** - the script explains everything in plain language.

## 📋 Requirements

- **Operating System**: Ubuntu or Debian Linux
- **Privileges**: Root access (sudo)
- **Network**: Internet connection for package downloads and certificate generation
- **Domain**: A domain name pointing to your server (required for SSL certificates)
- **Port**: Port 80 temporarily available for SSL certificate verification

## 🛠️ Installation & Usage

### Basic Usage

```bash
# Full hardening (interactive - will prompt for domain)
sudo ./harden-mongo-server.sh

# Check security status
sudo ./harden-mongo-server.sh status

# Preview changes without making them
sudo ./harden-mongo-server.sh --dry-run
```

### Advanced Usage

```bash
# Non-interactive setup with environment variables
sudo MONGO_DOMAIN="db.example.com" \
     MONGO_ADMIN_PASS="strong-password" \
     MONGO_APP_IP="10.0.1.15" \
     ./harden-mongo-server.sh

# SSL-specific operations
sudo ./harden-mongo-server.sh ssl-setup    # Setup SSL certificates
sudo ./harden-mongo-server.sh ssl-renew    # Renew certificates

# Maintenance operations
sudo ./harden-mongo-server.sh maintenance cleanup-logs
sudo ./harden-mongo-server.sh maintenance restart
sudo ./harden-mongo-server.sh maintenance security-check

# Backup and restore
sudo ./harden-mongo-server.sh backup
sudo ./harden-mongo-server.sh restore /path/to/backup.tar.gz
```

## 📍 Commands Reference

| Command | Description | Example |
|---------|-------------|----------|
| `harden` | Full security hardening (default) | `sudo ./harden-mongo-server.sh` |
| `status` | Check MongoDB status and security | `sudo ./harden-mongo-server.sh status` |
| `ssl-setup` | Setup SSL/TLS certificates | `sudo ./harden-mongo-server.sh ssl-setup` |
| `ssl-renew` | Renew SSL certificates | `sudo ./harden-mongo-server.sh ssl-renew` |
| `backup` | Create immediate backup | `sudo ./harden-mongo-server.sh backup` |
| `restore <file>` | Restore from backup | `sudo ./harden-mongo-server.sh restore backup.tar.gz` |
| `maintenance` | Various maintenance tasks | `sudo ./harden-mongo-server.sh maintenance restart` |
| `config` | Interactive configuration | `sudo ./harden-mongo-server.sh config` |

### Maintenance Sub-commands

| Sub-command | Description |
|-------------|-------------|
| `cleanup-logs` | Clean old log files (>7 days) |
| `cleanup-backups` | Clean old backups (based on retention policy) |
| `restart` | Restart MongoDB service |
| `security-check` | Verify all security configurations |
| `disk-cleanup` | Emergency disk space cleanup |

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview changes without executing |
| `--force` | Skip confirmation prompts |
| `--verbose` | Enable detailed output |
| `--config-only` | Only setup configuration files |

## 🌐 Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `MONGO_DOMAIN` | Domain name for SSL certificates | - | ✅ Yes |
| `MONGO_ADMIN_USER` | MongoDB admin username | `admin` | No |
| `MONGO_ADMIN_PASS` | MongoDB admin password | (prompted) | No |
| `MONGO_APP_IP` | Application server IP for firewall | `127.0.0.1` | No |
| `MONGO_BACKUP_RETENTION` | Backup retention days | `30` | No |

## 🔌 Connecting to MongoDB

After hardening, your MongoDB will require SSL connections:

### With Username/Password
```bash
mongo --ssl \
      --sslPEMKeyFile /etc/mongoCA/clients/app1.pem \
      --sslCAFile /etc/mongoCA/ca.pem \
      --host your-domain.com:27017 \
      -u admin -p "your-password" \
      --authenticationDatabase admin
```

### With x.509 Certificate Authentication
```bash
mongo --ssl \
      --sslPEMKeyFile /etc/mongoCA/clients/app1.pem \
      --sslCAFile /etc/mongoCA/ca.pem \
      --host your-domain.com:27017 \
      --authenticationMechanism MONGODB-X509
```

### Connection String Format
```javascript
// For applications
mongodb://username:password@your-domain.com:27017/database?ssl=true&authSource=admin

// With certificate authentication
mongodb://your-domain.com:27017/database?ssl=true&authMechanism=MONGODB-X509
```

## 📁 File Locations

### Configuration Files
- **MongoDB Config**: `/etc/mongod.conf`
- **SSL Certificates**: `/etc/letsencrypt/live/{domain}/`
- **Client Certificates**: `/etc/mongoCA/clients/`
- **CA Certificate**: `/etc/mongoCA/ca.pem`

### Data & Logs
- **Database**: `/var/lib/mongodb`
- **Logs**: `/var/log/mongodb/mongod.log`
- **Backups**: `/var/backups/mongodb/`
- **Hardening Logs**: `/var/log/mongodb-hardening-{date}.log`

### Generated Scripts
- **Disk Monitor**: `/usr/local/bin/check_mongo_disk.sh`
- **Service Watchdog**: `/usr/local/bin/mongo_watchdog.sh`
- **Backup Script**: `/usr/local/bin/mongo_backup.sh`
- **Certificate Renewal**: `/usr/local/bin/mongo-cert-renew.sh`

## ⚙️ What The Script Does

### 1. **MongoDB Installation**
- Installs MongoDB 3.4.24 with SSL support
- Creates dedicated `mongodb` system user
- Configures proper directory permissions
- Sets up systemd service with security limits

### 2. **SSL/TLS Setup**
- Obtains Let's Encrypt certificate for your domain
- Creates local Certificate Authority (CA)
- Generates client certificates for applications
- Configures MongoDB for mandatory SSL mode
- Sets up automatic certificate renewal

### 3. **Security Configuration**
- Enables MongoDB authentication
- Configures restrictive firewall rules
- Sets up network binding restrictions
- Implements x.509 certificate authentication
- Validates all security configurations

### 4. **Storage Engine Migration**
- Detects legacy mmapv1 storage engine
- Creates backup before migration
- Migrates to secure WiredTiger engine
- Preserves all existing data
- Enables crash-recovery journaling

### 5. **Monitoring & Automation**
- Sets up disk space monitoring
- Creates service watchdog system
- Configures automated backups
- Implements log rotation
- Schedules maintenance tasks

## 🔧 Customization

### Custom Certificate Locations
```bash
# Override default paths
export CA_DIR="/custom/path/mongoCA"
export CLIENT_DIR="/custom/path/clients"
sudo ./harden-mongo-server.sh
```

### Custom MongoDB Paths
```bash
# Override database and log paths
export DB_PATH="/custom/mongodb/data"
export LOG_PATH="/custom/mongodb/logs/mongod.log"
export BACKUP_PATH="/custom/backups/mongodb"
sudo ./harden-mongo-server.sh
```

## 🩺 Health Monitoring

The script sets up automated monitoring:

### Scheduled Tasks (Cron)
- **Every 5 minutes**: Service watchdog check
- **Every 15 minutes**: Disk space monitoring
- **Weekly (Sundays 2 AM)**: Automated backup
- **Monthly**: SSL certificate renewal

### Manual Health Checks
```bash
# Comprehensive status report
sudo ./harden-mongo-server.sh status

# Security-specific validation
sudo ./harden-mongo-server.sh maintenance security-check

# Check certificate expiry
sudo openssl x509 -in /etc/letsencrypt/live/your-domain/cert.pem -noout -dates
```

## 🚨 Troubleshooting

### Common Issues & Solutions

**"Domain name required"**
```bash
# Set domain as environment variable
export MONGO_DOMAIN="your-domain.com"
sudo ./harden-mongo-server.sh
```

**SSL Certificate Generation Failed**
```bash
# Ensure domain points to your server
nslookup your-domain.com

# Check port 80 is available
sudo netstat -tlnp | grep :80

# Check DNS propagation
dig your-domain.com
```

**Connection Refused**
```bash
# Check MongoDB is running with SSL
sudo systemctl status mongod

# Verify SSL configuration
sudo grep -A 10 "ssl:" /etc/mongod.conf

# Test SSL connection
openssl s_client -connect your-domain.com:27017 -servername your-domain.com
```

**Certificate Expired**
```bash
# Manually renew certificates
sudo ./harden-mongo-server.sh ssl-renew

# Check renewal timer status
sudo systemctl status mongo-cert-renew.timer
```

### Log Analysis
```bash
# MongoDB application logs
sudo tail -f /var/log/mongodb/mongod.log

# Hardening script logs
sudo tail -f /var/log/mongodb-hardening-$(date +%F).log

# System service logs
sudo journalctl -u mongod -f

# Certificate renewal logs
sudo journalctl -u mongo-cert-renew -f
```

## 🔄 Migration Guide

### From v1.x to v2.0

This is a **major version upgrade** with breaking changes:

#### **Before Migration**
1. **Get a domain name** pointing to your server
2. **Backup your existing data**:
   ```bash
   mongodump --out /tmp/migration-backup
   ```
3. **Note your current admin credentials**

#### **Migration Process**
1. **Run the new script**:
   ```bash
   sudo MONGO_DOMAIN="your-domain.com" ./harden-mongo-server.sh
   ```
2. **The script will automatically**:
   - Detect your existing MongoDB installation
   - Preserve your data during SSL setup
   - Generate SSL certificates
   - Update configuration for mandatory SSL

3. **Update your applications** to use SSL connections (see connection examples above)

#### **Rollback (if needed)**
If you need to rollback:
```bash
# Disable SSL temporarily
sudo sed -i 's/mode: requireSSL/mode: disabled/' /etc/mongod.conf
sudo systemctl restart mongod
```

## 🛡️ Security Best Practices

### Certificate Management
- **Client certificates expire every 90 days** for security
- **Let's Encrypt certificates auto-renew** every 60 days
- **Monitor certificate expiry** via status command
- **Keep CA private key secure** (600 permissions)

### Access Control
- **Use certificate authentication** when possible
- **Limit application server IPs** in firewall rules
- **Regular security validation** via maintenance commands
- **Monitor logs** for unauthorized access attempts

### Backup Security
- **Backups are authenticated** with admin credentials
- **Regular backup testing** recommended
- **Encrypted backups** via SSL connections
- **Secure backup storage** with proper permissions

## 📈 Performance Impact

The security hardening has minimal performance impact:

- **SSL/TLS overhead**: ~2-5% CPU usage for encryption
- **Certificate validation**: Negligible impact
- **WiredTiger engine**: Often improves performance vs mmapv1
- **Monitoring scripts**: Run only when needed
- **Backup process**: Scheduled during low-usage hours

## 🤝 Contributing

We welcome contributions! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

- **Issues**: Report bugs or request features via [GitHub Issues](../../issues)
- **Documentation**: Check [CHANGELOG.md](CHANGELOG.md) for version history
- **Security**: Report security vulnerabilities privately

## 🔗 Related Projects

- [MongoDB Official Documentation](https://docs.mongodb.com/v3.4/)
- [Let's Encrypt](https://letsencrypt.org/)
- [WiredTiger Storage Engine](https://docs.mongodb.com/v3.4/core/wiredtiger/)

---

**⚠️ Security Notice**: This script implements enterprise-grade security with mandatory SSL/TLS encryption. All connections are encrypted and authenticated. Suitable for production environments requiring maximum security.

**📝 Version**: 2.0.0 | **Updated**: 2024-10-04 | **MongoDB**: 3.4.24
