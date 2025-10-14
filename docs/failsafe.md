# Fail-safe & Auto-restart System Documentation

## What This System Does

The **Fail-safe & Auto-restart System** is like having a **digital safety net and emergency response team** for your MongoDB hardening process. It ensures that nothing is ever truly broken, always provides a way back, and keeps your database running even when things go wrong.

## 🛡️ Core Protection Features

### **Automatic State Tracking**
- **Remembers everything** - Saves progress continuously so you never lose your work
- **Smart resume** - Picks up exactly where it left off after any interruption
- **Progress checkpoints** - Creates safety points you can return to if needed
- **Session management** - Tracks multiple runs and prevents conflicts

### **Signal Handling & Graceful Interruption**
- **Ctrl+C protection** - Safely handles when you need to stop the script
- **System shutdown handling** - Gracefully responds to server restarts or shutdowns
- **Process isolation** - Prevents multiple instances from interfering with each other
- **Clean exit** - Always saves state before stopping, no matter how it's interrupted

### **Comprehensive Recovery System**
- **MongoDB service recovery** - Automatically restarts MongoDB if it stops
- **Process monitoring** - Watches all related services and restarts them if needed
- **Configuration restoration** - Fixes corrupted configurations automatically
- **Dependency recovery** - Ensures all required components are running

### **Smart Rollback Capabilities**
- **Multiple rollback levels** - Choose how much to undo based on the severity
- **System backups** - Creates restoration points before major changes
- **Selective rollback** - Can undo specific parts without affecting everything
- **Emergency rollback** - Quick restoration when things go very wrong

### **Continuous Monitoring & Auto-restart**
- **24/7 watchdog** - MongoDB process monitor that runs continuously
- **Health checking** - Regular system health verification every 5 minutes
- **Automatic recovery** - Self-healing system that fixes common problems
- **Cron job management** - Ensures scheduled tasks keep running

## 🔄 Auto-restart Components

### **MongoDB Process Monitoring**
```
MongoDB Watchdog Service:
├── Checks MongoDB status every 60 seconds
├── Automatically restarts if MongoDB stops
├── Limits restart attempts (max 5 per session)
├── Logs all restart attempts and outcomes
└── Prevents restart loops with intelligent backoff
```

### **Health Check System**
```
Health Check Schedule:
├── Every 5 minutes: MongoDB connectivity test
├── Every 5 minutes: Disk space monitoring (alerts at 90% full)
├── Every 5 minutes: Memory usage monitoring (alerts at 95% full)
├── Every 5 minutes: Service status verification
└── Continuous: Performance and response time tracking
```

### **Scheduled Maintenance Tasks**
```
Automated Cron Jobs:
├── Every 10 minutes: Auto-recovery system check
├── Daily at 2 AM: MongoDB database backup
├── Weekly: Database maintenance and optimization
├── Monthly: SSL certificate renewal check
└── Weekly: Security audit and compliance check
```

## 🚨 Failure Scenarios & Responses

### **MongoDB Service Failures**
**What happens:** MongoDB process stops unexpectedly
**Auto-response:**
1. Watchdog detects failure within 60 seconds
2. Attempts automatic restart (up to 5 times)
3. If restart fails, triggers emergency recovery
4. Logs failure details for investigation
5. Notifies through system logs

### **System Resource Issues**
**What happens:** Disk space or memory running low
**Auto-response:**
1. Health check detects resource constraint
2. Automatically cleans up old log files
3. Optimizes MongoDB memory usage
4. Creates alerts in system logs
5. If critical, safely stops non-essential processes

### **Configuration Corruption**
**What happens:** MongoDB configuration becomes invalid
**Auto-response:**
1. Service restart fails due to configuration
2. System automatically restores backup configuration
3. Attempts restart with restored configuration
4. If still fails, applies minimal working configuration
5. Logs the incident for manual review

### **Network/Firewall Issues**
**What happens:** MongoDB becomes unreachable
**Auto-response:**
1. Connection health checks fail
2. Verifies firewall rules are still in place
3. Re-applies security rules if needed
4. Tests connectivity and reports status
5. Restarts networking services if required

## 📊 State Management System

### **Progress Tracking**
The system maintains a detailed JSON state file that tracks:
- **Current step** being executed
- **Completed steps** with timestamps
- **Failed steps** with error details
- **Recovery points** for safe rollback
- **Service status** for all components
- **Configuration changes** made

### **Recovery Points**
Automatic backup points are created:
- **Before critical operations** (MongoDB installation, security changes)
- **After successful completions** (SSL setup, user creation)
- **During interruptions** (when script is stopped)
- **On demand** (when user requests backup)

### **Session Management**
- **Process isolation** - Only one hardening process can run at a time
- **Session tracking** - Each run gets a unique identifier
- **Lock file management** - Prevents conflicts between runs
- **Clean termination** - Proper cleanup when process ends

## 🔧 Rollback System

### **Rollback Levels**

#### **Config Level** - `--rollback config`
- Restores original MongoDB configuration files
- Resets service enable/disable state
- Minimal impact, preserves most changes

#### **Security Level** - `--rollback security`  
- Removes authentication setup
- Rolls back firewall rules
- Removes SSL certificates and users
- Recommended for security-related issues

#### **Monitoring Level** - `--rollback monitoring`
- Removes watchdog and monitoring processes
- Cleans up cron jobs and scheduled tasks
- Stops continuous monitoring
- Use when monitoring causes issues

#### **Full Level** - `--rollback full`
- Complete system restoration to pre-hardening state
- Removes MongoDB installation if it was installed by script
- Removes all configuration, security, and monitoring changes
- Nuclear option for complete undo

### **When Rollback is Triggered**
- **Automatically** when multiple critical failures occur (>3 failed steps)
- **On user request** through command line options
- **During emergency recovery** when system is unstable
- **Before major operations** as a safety measure

## 🔍 Monitoring & Health Checks

### **System Health Indicators**
The system continuously monitors:
- **MongoDB service status** - Running/stopped state
- **Process responsiveness** - Response time to queries
- **Resource utilization** - CPU, memory, disk usage
- **Network connectivity** - Database accessibility
- **Configuration validity** - Config file integrity
- **Certificate status** - SSL certificate expiration
- **Log file health** - Log rotation and disk usage

### **Alert Conditions**
Automatic alerts are generated for:
- **Service failures** - MongoDB stops unexpectedly
- **Resource constraints** - Disk >90% full, memory >95% used
- **Security issues** - Failed authentication attempts
- **Performance degradation** - Slow query responses
- **Certificate expiration** - SSL certificates expiring soon
- **Backup failures** - Scheduled backups fail

## 💡 User Benefits

### **Peace of Mind**
- **Never lose progress** - Always resume from where you left off
- **Automatic recovery** - System fixes itself without your intervention
- **Safety net** - Can always rollback if something goes wrong
- **24/7 monitoring** - Database is watched even when you're not there

### **Time Savings**
- **No manual restarts** - System handles MongoDB crashes automatically
- **No monitoring setup** - Continuous monitoring is built-in
- **No manual backups** - Automated backup system runs schedule
- **No troubleshooting** - Self-diagnosis and recovery

### **Reliability**
- **Production-ready** - Built for enterprise-level stability
- **Tested scenarios** - Handles common failure modes automatically
- **Graceful handling** - Never leaves system in broken state
- **Comprehensive logging** - Always know what happened and when

## 🚀 Usage Examples

### **Normal Operation with Fail-safe**
```bash
# Run hardening with full protection
./harden-mongo-server

# If interrupted, simply run again to resume
./harden-mongo-server
```

### **Recovery Operations**
```bash
# Force recovery mode
./harden-mongo-server --recovery

# Check system health
./harden-mongo-server --check

# View current status
./harden-mongo-server --status
```

### **Rollback Operations**
```bash
# Rollback just security changes
./harden-mongo-server --rollback security

# Complete rollback to original state
./harden-mongo-server --rollback full

# Rollback only monitoring components
./harden-mongo-server --rollback monitoring
```

### **Monitoring Commands**
```bash
# View watchdog status
ps aux | grep harden-mongo-server-watchdog

# Check recent recovery activity
tail -f /var/lib/harden-mongo-server/recovery.log

# View health check results
tail -f /var/lib/harden-mongo-server/health-check.log
```

## 🔧 Technical Implementation

### **File Locations**
- **State tracking**: `/var/lib/harden-mongo-server/hardening-state.json`
- **Recovery logs**: `/var/lib/harden-mongo-server/recovery.log`
- **Watchdog script**: `/var/lib/harden-mongo-server/harden-mongo-server-watchdog.sh`
- **Health checks**: `/var/lib/harden-mongo-server/harden-mongo-server-health-check.sh`
- **Auto-recovery**: `/var/lib/harden-mongo-server/harden-mongo-server-auto-recovery.sh`
- **Rollback script**: `/var/lib/harden-mongo-server/rollback.sh`
- **System backups**: `/var/lib/harden-mongo-server/backups/`

### **Cron Jobs Installed**
```bash
# Health checks every 5 minutes
*/5 * * * * /var/lib/harden-mongo-server/harden-mongo-server-health-check.sh

# Auto-recovery every 10 minutes  
*/10 * * * * /var/lib/harden-mongo-server/harden-mongo-server-auto-recovery.sh

# Daily backups at 2 AM
0 2 * * * /var/lib/harden-mongo-server/backup-mongodb.sh

# Weekly maintenance on Sundays at 3 AM
0 3 * * 0 /var/lib/harden-mongo-server/maintenance.sh

# Monthly certificate renewal on 1st at 4 AM
0 4 1 * * /var/lib/harden-mongo-server/renew-certificates.sh
```

## 🛠️ Advanced Features

### **Multi-level Backup Strategy**
- **Pre-operation backups** before critical changes
- **Checkpoint backups** after successful operations
- **Emergency backups** during failure recovery
- **Scheduled backups** for data protection

### **Intelligent Recovery Logic**
- **Failure pattern recognition** - Identifies common problem types
- **Progressive recovery attempts** - Tries gentle fixes before drastic measures
- **Resource-aware recovery** - Considers system resources when recovering
- **User preference learning** - Remembers user choices for future decisions

### **Integration with System Services**
- **Systemd integration** - Works with system service manager
- **Log aggregation** - Integrates with system logging
- **Resource monitoring** - Uses system monitoring tools
- **Security integration** - Works with system security features

## ✅ What You Get

After the fail-safe system is installed, you have:

### **Automatic Protection**
- ✅ MongoDB auto-restart if it stops
- ✅ Configuration auto-recovery if corrupted  
- ✅ Resource monitoring and cleanup
- ✅ Security rule maintenance
- ✅ Certificate renewal automation

### **Recovery Capabilities**
- ✅ Resume interrupted installations
- ✅ Rollback problematic changes
- ✅ Emergency recovery procedures
- ✅ System state restoration
- ✅ Configuration backup and restore

### **Monitoring & Maintenance**
- ✅ 24/7 system health monitoring
- ✅ Automated backup scheduling
- ✅ Performance optimization tasks
- ✅ Security audit automation
- ✅ Log management and rotation

### **User Experience**
- ✅ Never lose installation progress
- ✅ Simple recovery commands
- ✅ Clear status reporting
- ✅ Minimal user intervention required
- ✅ Professional-grade reliability

The fail-safe system transforms a potentially risky database hardening process into a reliable, recoverable, and monitored operation that you can trust in production environments.