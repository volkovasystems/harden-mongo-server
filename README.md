# MongoDB Hardening Utility

A comprehensive, modular security hardening utility for MongoDB deployments.

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)](CHANGELOG.md)

## Features

- **Modular Architecture**: 10 specialized library modules for different aspects of MongoDB security
- **Security Profiles**: Basic, standard, strict, and paranoid hardening profiles
- **SSL/TLS Management**: Complete certificate authority with automatic certificate generation
- **Multi-Firewall Support**: Automatic detection and configuration for UFW, FirewallD, IPTables, NFTables
- **Backup & Monitoring**: Compressed backups, health checks, and metrics collection
- **Cross-Platform**: Supports major Linux distributions with automatic detection

## Quick Start

### Installation
```bash
# System-wide installation (recommended)
sudo ./install.sh

# Or install with make
sudo make install
```

### Basic Usage
```bash
# Interactive configuration wizard
sudo harden-mongodb configure

# Apply standard security hardening
sudo harden-mongodb harden standard

# System analysis
sudo harden-mongodb system-info

# Security assessment
sudo harden-mongodb security-check
```

## Project Structure

```
harden-mongo-server/
├── harden-mongodb.sh                    # Main executable
├── install.sh                           # System installer  
├── Makefile                             # Build system
│
├── lib/mongodb-hardening/               # Core library modules
│   ├── core.sh                         # Core utilities
│   ├── logging.sh                      # Logging system
│   ├── ui.sh                           # User interaction
│   ├── system.sh                       # System detection
│   ├── mongodb.sh                      # MongoDB management
│   ├── security.sh                     # Security hardening
│   ├── ssl.sh                          # SSL/TLS management
│   ├── firewall.sh                     # Firewall configuration
│   ├── backup.sh                       # Backup operations
│   └── monitoring.sh                   # Health monitoring
│
├── examples/
│   └── mongodb-hardening.conf.example  # Configuration template
│
├── tests/
│   ├── test-runner.sh                  # Test framework
│   └── README.md                       # Test documentation
│
└── Documentation
    ├── README.md
    ├── CHANGELOG.md
    ├── CONTRIBUTING.md
    ├── LICENSE
    └── MANIFEST.txt
```

## Security Profiles

### Basic
- Enable authentication (SCRAM-SHA-1)
- Set proper file permissions
- Configure basic logging

### Standard (Default)
- All basic features plus:
- SCRAM-SHA-256 authentication
- Keyfile for replica sets
- System resource limits

### Strict
- All standard features plus:
- Restrictive file permissions
- Connection limits and timeouts
- Enhanced audit logging

### Paranoid
- All strict features plus:
- Localhost-only binding
- SSL/TLS required
- JavaScript disabled

## Commands

### System Analysis
```bash
harden-mongodb system-info        # Display system information
harden-mongodb mongodb-status     # Show MongoDB service status
harden-mongodb security-check     # Security configuration assessment
harden-mongodb health-check       # MongoDB health monitoring
```

### Configuration & Hardening
```bash
harden-mongodb configure          # Interactive configuration wizard
harden-mongodb harden [PROFILE]   # Apply security hardening profile
harden-mongodb setup-ssl          # Configure SSL/TLS encryption
harden-mongodb setup-auth         # Setup authentication
harden-mongodb setup-firewall     # Configure firewall rules
```

### Backup & Monitoring
```bash
harden-mongodb backup             # Create backup
harden-mongodb restore FILE       # Restore from backup
harden-mongodb backup-schedule    # Setup automated backups
harden-mongodb monitoring setup   # Configure monitoring
harden-mongodb metrics collect    # Collect performance metrics
```

### Service Management
```bash
harden-mongodb start              # Start MongoDB service
harden-mongodb stop               # Stop MongoDB service
harden-mongodb restart            # Restart MongoDB service
harden-mongodb enable             # Enable auto-start
```

## Requirements

- **OS**: Linux (Ubuntu, CentOS, RHEL, Debian)
- **Shell**: Bash 4.0+
- **Privileges**: Root access for system operations
- **MongoDB**: 3.6+ (detects and adapts to installed version)

## Development

### Building & Testing
```bash
make help          # Show available targets
make build         # Build the project
make test          # Run tests
make check         # Run all checks (lint + test)
make package       # Create distribution packages
make clean         # Clean build artifacts
```

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `make check`
5. Submit a pull request

See [CONTRIBUTING.md](CONTRIBUTING.md) for detailed guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Security Considerations

- **Test first**: Always test in non-production environments
- **Review configs**: Examine generated configurations before applying
- **Monitor logs**: Regular monitoring for security events
- **Keep updated**: Use latest version for security patches

This tool hardens MongoDB configurations but doesn't replace comprehensive security policies or monitoring systems.