# Examples Directory

This directory contains example files and integration samples for the MongoDB Hardening Utility.

## Files

### `mongodb-hardening.conf.example`
Example configuration file showing all available configuration options for the MongoDB hardening script. Copy this file to customize the behavior of the hardening process.

Usage:
```bash
cp examples/mongodb-hardening.conf.example /etc/mongodb-hardening.conf
# Edit the configuration file as needed
vim /etc/mongodb-hardening.conf
# Run hardening with custom configuration
./harden-mongodb.sh -c /etc/mongodb-hardening.conf configure
```

### `failsafe-integration-example.sh`
Complete example showing how to integrate the fail-safe and auto-restart system into custom MongoDB hardening scripts. This demonstrates:

- Automatic recovery from interruptions
- State management and progress tracking
- Signal handling for graceful shutdown
- Multi-level rollback capabilities
- Comprehensive error handling
- Command-line interface for recovery operations

This example is particularly useful if you want to:
- Build your own MongoDB hardening script with fail-safe protection
- Understand how the fail-safe system works internally
- Customize the recovery and rollback behavior
- Add fail-safe capabilities to existing scripts

## Usage Notes

These files are provided as references and starting points. The main `harden-mongodb.sh` script already includes full fail-safe protection and doesn't require additional integration - these examples are for educational purposes and custom implementations.