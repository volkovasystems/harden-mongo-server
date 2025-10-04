# Changelog

All notable changes to the MongoDB Server Hardening Script will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2024-10-04

### 🔒 **BREAKING CHANGE: SSL/TLS Now Mandatory**

This major release transforms the MongoDB hardening script into an enterprise-grade security solution with **mandatory SSL/TLS encryption**. SSL cannot be disabled, ensuring the highest security standards.

### Added

#### **Maximum Security Features**
- **Mandatory SSL/TLS encryption** - All connections must be encrypted
- **Let's Encrypt certificate integration** - Automatic free SSL certificate generation
- **Client certificate authentication** - x.509 certificate-based auth via local CA
- **Automatic certificate renewal** - Monthly renewal via systemd timers
- **Domain-based SSL setup** - Proper domain validation and certificate management

#### **User Experience Improvements**
- **User-friendly explanations** - Clear, non-technical descriptions for all security measures
- **Interactive domain configuration** - Guided setup with examples and validation
- **Enhanced logging system** - Color-coded output with intuitive icons (🔒, 📋, ✓, ⚠, ✗)
- **Comprehensive status reporting** - SSL certificate status, expiry dates, and connection examples
- **Dry-run mode improvements** - Preview SSL setup and certificate operations

#### **SSL Certificate Management**
- **Local Certificate Authority** - Private CA for issuing client certificates
- **Client certificate generation** - Automated creation of application certificates (90-day expiry)
- **Certificate renewal system** - Automated renewal of both Let's Encrypt and client certificates
- **SSL connection examples** - Clear instructions for connecting with certificates

#### **New Commands**
- `ssl-setup` - Setup SSL/TLS with Let's Encrypt certificates
- `ssl-renew` - Manually renew certificates
- Enhanced `status` command with SSL certificate information

#### **Configuration Enhancements**
- **Domain validation** - Required domain name with DNS validation
- **SSL configuration in MongoDB** - requireSSL mode with proper certificate paths
- **x.509 authentication** - Certificate-based authentication support
- **Enhanced security validation** - SSL-aware security checks

### Changed

#### **Security Hardening**
- **SSL/TLS is now MANDATORY** - Cannot be disabled for maximum security
- **Enhanced MongoDB configuration** - SSL settings automatically configured
- **Improved firewall rules** - SSL-aware network security
- **Updated authentication** - Support for both password and certificate auth

#### **User Interface**
- **Redesigned logging** - More intuitive messages with security context
- **Interactive prompts** - Better guidance for domain setup and configuration
- **Help documentation** - Updated examples and requirements
- **Error handling** - More descriptive error messages with solutions

#### **System Integration**
- **Systemd integration** - Certificate renewal timers and services
- **MongoDB 3.4.24 optimization** - SSL-optimized configuration
- **File permissions** - Enhanced security for certificate files

### Enhanced

#### **Documentation**
- **SSL setup instructions** - Comprehensive SSL configuration guide
- **Certificate management** - Client certificate generation and renewal
- **Connection examples** - SSL connection strings and authentication methods
- **Requirements updated** - Added domain name and SSL requirements

#### **Monitoring & Maintenance**
- **Certificate expiry monitoring** - Track SSL certificate validity
- **Enhanced status reporting** - SSL certificate status and domain information
- **Backup system** - SSL-aware backup and restore operations

### Technical Details

#### **SSL Certificate Paths**
- Let's Encrypt certificates: `/etc/letsencrypt/live/{domain}/`
- Local CA: `/etc/mongoCA/ca.pem`
- Client certificates: `/etc/mongoCA/clients/`

#### **MongoDB Configuration**
```yaml
net:
  ssl:
    mode: requireSSL
    PEMKeyFile: /etc/letsencrypt/live/{domain}/privkey.pem
    CAFile: /etc/mongoCA/ca.pem
    allowConnectionsWithoutCertificates: false

security:
  authorization: enabled
  clusterAuthMode: x509
```

#### **New Environment Variables**
- `MONGO_DOMAIN` - Domain name for SSL certificates (REQUIRED)
- `MONGO_USE_SSL` - Hardcoded to "true" (no longer configurable)

### Migration Guide

#### **From v1.x to v2.0**

1. **Domain Requirement**: Ensure you have a domain name pointing to your server
2. **SSL Setup**: Run the script - it will automatically prompt for domain configuration
3. **Application Updates**: Update applications to use SSL connections:
   ```bash
   # With password authentication
   mongo --ssl --sslPEMKeyFile /etc/mongoCA/clients/app1.pem \
         --sslCAFile /etc/mongoCA/ca.pem \
         --host your-domain.com:27017 \
         -u admin -p password --authenticationDatabase admin
   
   # With x.509 certificate authentication
   mongo --ssl --sslPEMKeyFile /etc/mongoCA/clients/app1.pem \
         --sslCAFile /etc/mongoCA/ca.pem \
         --host your-domain.com:27017 \
         --authenticationMechanism MONGODB-X509
   ```

#### **Breaking Changes**
- SSL/TLS is now mandatory - all connections must be encrypted
- Domain name is required for SSL certificate generation
- Applications must be updated to use SSL connections
- New certificate-based authentication options available

### Security Enhancements

#### **Encryption**
- All network traffic is now encrypted via SSL/TLS
- Certificate-based authentication available
- Regular certificate renewal prevents expiry issues

#### **Certificate Management**
- Automated Let's Encrypt certificate generation
- Local CA for client certificate issuance  
- 90-day client certificate rotation for enhanced security
- Monthly automatic renewal system

#### **Access Control**
- x.509 certificate-based authentication
- Enhanced firewall rules for SSL traffic
- Proper certificate file permissions and ownership

---

## [1.x] - Previous Versions

### Features from Previous Versions
- MongoDB 3.4.24 installation and configuration
- mmapv1 to WiredTiger storage engine migration
- Authentication setup and firewall configuration
- Automated backup and monitoring systems
- Log rotation and maintenance scripts
- Health checking and status reporting
- Cron job automation for maintenance tasks

### Configuration Management
- Separate configuration files for credentials and settings
- Interactive setup scripts
- Environment variable overrides
- Comprehensive maintenance commands

---

## Security Notice

This script now implements **military-grade security standards** with mandatory SSL/TLS encryption. All connections are encrypted, and certificate-based authentication is available for maximum security. The script is suitable for production environments requiring the highest security standards.

## Compatibility

- **Operating System**: Ubuntu/Debian Linux
- **MongoDB**: 3.4.24 (with SSL support)
- **SSL/TLS**: Let's Encrypt + Local CA
- **Certificate Types**: RSA 2048-bit (client), RSA 4096-bit (CA)
- **Renewal**: Automated via systemd timers