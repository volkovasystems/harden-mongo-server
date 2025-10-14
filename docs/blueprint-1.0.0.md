# Harden Mongo Server — Blueprint 1.0.0 (MVP)

## Version Scope
This is the Minimum Viable Product (MVP) release focusing on:
- **Complete automation**: one command, zero manual steps
- **Core security**: TLS, x509, VPN, firewall, backups
- **Essential automation**: automated onboarding, auto-grants, auto-rotation

Features deferred to future versions are advanced management and analytics only.

## Purpose (plain language)
- A single command that hardens a MongoDB server securely with minimal input.
- Private-only by default. No public domain required. Safe to re-run anytime.
- Automated onboarding via Cloudflare Quick Tunnel (one-liner download, no manual steps).

## What you get (secure defaults)
- TLS required with a private Certificate Authority (CA).
- x509-only authentication (passwords disabled).
- Separation of duties:
  - Root (break-glass): full control, localhost/VPN only.
  - Admin (operations): monitoring-only; cannot read/modify app data.
  - App (business): read/write only to business databases; no admin powers.
  - Backup (service): backup-only; cannot administer or write data.
- Networking: localhost-only by default; OpenVPN installed and enabled by default; public IPs must be explicitly allowed.
- Automatic security for new business databases used by the App (no manual approval).
- Backups: local-only, encrypted, scheduled daily with disk-safety.
- Certificates: automated monthly rotation with graceful reload.
- Zero-downtime first, fail-safe rollback if a change is unsafe.
- OpenVPN server installed and configured on first run; MongoDB and SSH are restricted to VPN-only by default. Two initial human VPN profiles (admin and viewer) are created.

## What you do
- First run as root to bootstrap; later runs allowed for users in the tool's system group.
- On first run, the tool sets up everything and prints a one-liner command to download all certificates (admin/viewer VPN profiles and DB certs).
- Copy-paste that one-liner on your client machine to download everything you need.
- If you need public access, use single-IP flags (one at a time). For bulk changes, edit the config file.
- Otherwise, the tool adapts automatically: TLS, auth, new DB access, backups, and firewall.
- No cloud credentials are required at any time. First access typically uses your SSH PEM once; subsequent access uses the VPN.

## How it operates (at a glance)
- Phases: preflight → bootstrap → tls → mongodb-config → provision → firewall → backups → verify.
- Idempotent: reruns safely reconcile the system to the desired secure state.
- Continuous enforcement: on every run, the tool verifies and re-enforces all security features (VPN hardening, firewall policy, TLS/auth settings, roles and auth restrictions, sysctls, backups). If a required condition cannot be met, it stops or rolls back with a clear message.
- Automation: auto-grants DB access when App touches new databases, auto-rotates certificates monthly, auto-locks to VPN after first SSH over VPN.

## Security model
- Root: built-in root role; for provisioning and emergencies. Restricted to localhost/VPN.
- Admin: custom ops role (clusterMonitor only). No data access, no user/role changes.
- App: readWrite on business databases only. Automatically granted when a new business DB is first used.
- Backup: built-in backup role. Default localhost-only.
- Authentication restrictions: each principal limited to safe client networks.

## TLS and certificates
- Private CA only (no public domain required) for server, client, and VPN certificates.
- Database client certificates are used only for MongoDB; VPN client certificates are separate and issued per human. They rotate and can be revoked independently.
- First run certificates: 8 total — 1 MongoDB server cert, 1 VPN server cert, 4 MongoDB x509 client certs (Root, Admin, App, Backup), and 2 OpenVPN client certs for human access (admin and viewer).
- Monthly automated renewal/rotation.
- Zero downtime preferred: perform a graceful reload. If reload fails or is unsupported, warn before a short, safe restart; otherwise revert to last-known-good.

## Databases and access (automatic)
- When the App identity touches a new non-system DB (not admin/local/config), the tool grants App readWrite on that DB automatically.
- This "just-in-time" grant is limited to that specific DB and is fully logged.

## Onboarding (one-liner download via Cloudflare Quick Tunnel)
- Purpose: let any user download everything needed with a single copy-paste command (no PEM, no EC2 IP knowledge, no UI).
- How it works (server side, automated):
  - Package a single archive named hms-onboarding-YYYY-MM-DD.zip containing the files listed below (flat, no subfolders, no README).
  - Launch a short-lived Cloudflare Quick Tunnel (no account) to expose exactly one HTTPS URL for that archive.
  - Enforce single-use and expiry: first successful download deletes the archive and shuts down the tunnel; otherwise the URL expires after 10 minutes.
  - If a public URL cannot be obtained, the tool prints: "Unable to generate the onboarding script. Please contact a human administrator to help download the files." No fallback is attempted.
- What the user runs (one line):
  - Linux/macOS:
    curl -fsSL "https://<random>.trycloudflare.com/download/<TOKEN>" -o hms-onboarding.zip && unzip -q hms-onboarding.zip && rm hms-onboarding.zip
  - Windows (PowerShell):
    iwr -UseBasicParsing "https://<random>.trycloudflare.com/download/<TOKEN>" -OutFile hms-onboarding.zip; Expand-Archive -Force .\hms-onboarding.zip .; Remove-Item .\hms-onboarding.zip
- Compressed file contents (flat, date-stamped YYYY-MM-DD in UTC):
  - admin-YYYY-MM-DD.ovpn
  - viewer-YYYY-MM-DD.ovpn
  - db-root-YYYY-MM-DD.pem      (client cert+key)
  - db-admin-YYYY-MM-DD.pem     (client cert+key)
  - db-app-YYYY-MM-DD.pem       (client cert+key)
  - db-backup-YYYY-MM-DD.pem    (client cert+key)
  - db-ca-YYYY-MM-DD.pem        (server CA chain)
- Notes:
  - The .ovpn profiles embed their client cert/key and the VPN CA chain.
  - Each db-*.pem contains the full client identity (cert+key) suitable for mongosh/drivers via tlsCertificateKeyFile.
  - The date stamp helps operators identify issuance/rotation at a glance; it does not replace internal certificate validity.

## MongoDB hardening (enabled by default)
- Enforce WiredTiger; migrate safely if needed. Set featureCompatibilityVersion (FCV) to the installed major/minor.
- Transport and auth: requireTLS, x509-only; tlsMinVersion=TLS1_2; SCRAM disabled. Authentication restrictions pin principals to 127.0.0.1 and/or VPN CIDR; the App principal is also pinned to its allowed IPs.
- Connection safety: set mongod maxIncomingConnections=1024 by default.
- Least-privilege roles: Root (root), Admin (hmsOpsAdmin → clusterMonitor only), Backup (backup), App (hmsAppRW → minimal DML; no DDL/index operations).
- Preflight gating: if minimum requirements (WiredTiger and TLS 1.2+) are not supported by the installed version, the tool stops and instructs you to upgrade; it does not fall back.

## Networking and exposure
- Default: bind to localhost only; nothing exposed publicly.
- VPN: installed and enabled by default; MongoDB (27017) and SSH (22) are allowed only over the VPN interface by default.
- VPN hardening (enabled): tls-crypt on control channel; cipher AES-256-GCM; auth SHA256; tls-version-min TLS1_2; compression disabled; UDP/1194.
- Public side stealth (enabled): default DROP for unmatched inbound on public interfaces; block ICMP echo on public interfaces; allow ICMP on VPN.
- App access (allowed IPs): 27017 is opened only to exactly the allowed IPs you specify; access still requires x509 DB certs (IP alone is not enough).
- Public access (if truly needed): single-IP flags that write to config and apply firewall safely with zero downtime:
  - --allow-ip-add <IP>
  - --allow-ip-remove <IP>
- SSH policy: VPN-only by default (enforced automatically).
- EC2: OS firewall enforces VPN-only. The tool does not use any cloud credentials and does not change Security Groups. It may print suggested Security Group rules you can apply later, manually.
- Auto-lock to VPN-only: after the first successful SSH login over the VPN, a one-time watcher locks SSH and MongoDB to the VPN interface, then disables itself. No manual flag or timer wait required.
- No bulk changes via flags. For multiple IPs, edit the config file.

## Configuration and flags
- Canonical config: /etc/harden-mongo-server/config.json.
- Everything configurable lives in the config file. Flags exist for convenience only; each flag makes one small, safe change and writes it back to config.
- CLI flags update the config atomically (one change per flag) and keep a backup of the previous version.
- A "last-known-good" config is maintained for automatic rollback.
- Dry-run shows intended changes and whether a reload or restart is required.
- Onboarding scripts: the tool prints one-liners with a short-lived HTTPS URL. If the URL cannot be created, it tells the user to contact a human administrator; no fallback is attempted.

## CLI flags (1.0.0 MVP - essential only)

### General
- --config PATH                          Set alternate config path for this run (does not write config)
- --dry-run                               Show planned changes only

### Networking (single-IP changes only)
- --allow-ip-add IP                       Allow one IP to access MongoDB (adds to network.allowedIPs)
- --allow-ip-remove IP                    Remove one IP from access list

### Backups (local-only)
- --restore PATH                           Restore from a backup archive

## Backups (local-only, safe by default)
- Schedule: daily at 02:00 local by default.
- Encryption: age; root-only key in /etc/harden-mongo-server/keys/backup.agekey.
- Compression: zstd.
- Initial backup (first run): if an existing MongoDB instance is detected, take an encrypted local backup before any changes. If the backup cannot be taken safely (no key, insufficient space/quota, or mongod unreachable), the tool stops and instructs an operator (fails closed).
- Disk safety: retention (daily=7) and basic quota checks to avoid filling the disk.

## Default configuration (1.0.0 MVP)
- onboarding:
  - method: cloudflared
  - expiryMinutes: 10
  - singleUse: true
  - filenameDateFormat: "YYYY-MM-DD" (UTC, ISO 8601)
- tls:
  - mode: internalCA
  - rotation: periodDays=30, zeroDowntimeReload=true
- network:
  - bind: ["127.0.0.1", "<VPN-interface>"] (VPN enabled by default)
  - allowedIPs: [] (no public access by default)
- mongodb:
  - tlsMinVersion: "TLS1_2"
  - maxIncomingConnections: 1024
- principals:
  - root: { allowedClientSources: ["127.0.0.1", "10.8.0.0/24"] }
  - admin: { allowedClientSources: ["10.8.0.0/24"] }
  - app: { allowedClientSources: ["127.0.0.1", "10.8.0.0/24"] + network.allowedIPs }
  - backup: { allowedClientSources: ["127.0.0.1"] }
- appAccess:
  - autoApproveNewDatabases: true
  - excludeDatabases: ["admin","local","config"]
- firewall:
  - stealth: { dropUnmatchedPublic: true, blockIcmpEchoPublic: true, allowIcmpVpn: true }
- backups:
  - enabled: true
  - targetDir: /var/backups/harden-mongo-server
  - retention: { daily: 7 }
  - compression: zstd
  - encryption: { type: age, keyPath: /etc/harden-mongo-server/keys/backup.agekey }
  - schedule: "02:00"
- openvpn:
  - enabled: true
  - network: 10.8.0.0/24
  - port: 1194
  - proto: udp
  - crypto: { tlsCrypt: true, cipher: "AES-256-GCM", auth: "SHA256", tlsVersionMin: "TLS1_2" }
- ssh:
  - vpnOnly: true
- autoLockToVpnOnFirstRun: true
- humans:
  - [
    { name: "admin", role: "admin", sshAuthorizedKeys: [], vpnEnabled: true },
    { name: "viewer", role: "viewer", sshAuthorizedKeys: [], vpnEnabled: true }
  ]

## Zero downtime and fail-safe
- On any configuration or security update: attempt graceful reload first.
- If a restart is needed, inform you before proceeding.
- If a reload/restart fails or the change is unsafe, revert to last-known-good and keep the database online.

## System integration
- First run requires root: creates directories, users/groups, services, and policies.
- System users/groups and accounts:
  - OS groups: harden-mongo-server-admins (admins)
  - OS users created: hms-admin (admins group; shell + sudo)
- SSH configuration:
  - VPN-only enforced by firewall; sshd drop-in sets PermitRootLogin no.
- OS hardening (enabled): unattended security updates and minimal sysctls (syncookies, rp_filter, reject redirects/source routes, protected symlinks/hardlinks, restricted kptr/dmesg, ignore broadcast pings). Log rotation for mongod and tool logs.
- Systemd timers/services:
  - Backup scheduler (daily)
  - Certificate rotation (monthly)
  - OpenVPN server (enabled at boot)
  - VPN lock watcher (one-time auto-lock service)
- VPN lock watcher (one-time): detects first SSH over VPN and locks SSH/MongoDB to VPN, then disables itself
- Onboarding one-shot: ephemeral file endpoint + cloudflared quick tunnel (single-use, short-lived); auto-shutdown after success/expiry
- Continuous enforcement: each execution validates and reapplies configured controls; no-ops when compliant; fails closed with rollback or clear stop when preflight requirements are not met.
- Auto-restart and boot behavior:
  - mongod is enabled to start at boot and configured to auto-restart on failure (Restart=on-failure, RestartSec=5s). If the vendor unit lacks these settings, a systemd drop-in is installed to enforce them.
  - If mongod crashes or is terminated, it restarts automatically.
  - If a start or reload fails due to an invalid config, the fail-safe reverts to the last-known-good configuration and brings the service back up.

## Acceptance checklist (1.0.0 MVP)
- One-liner onboarding (HTTPS) without PEM/IP: user downloads a flat, date-stamped zip named hms-onboarding-YYYY-MM-DD.zip containing admin-YYYY-MM-DD.ovpn, viewer-YYYY-MM-DD.ovpn, db-*-YYYY-MM-DD.pem, and db-ca-YYYY-MM-DD.pem; if a public URL cannot be created, the tool instructs the user to contact a human administrator (no fallback attempted).
- First-run initial backup (if existing DB): before any changes are applied, an encrypted local backup is taken. If a safe backup cannot be taken, the tool fails closed with a clear message.
- VPN hardened by default (tls-crypt, AES-256-GCM/SHA256, TLS ≥1.2), and stealth DROP on public interfaces; ICMP allowed only on VPN.
- TLS required; x509-only; private CA; monthly renewal without downtime.
- MongoDB uses WiredTiger; FCV pinned; maxIncomingConnections capped; App role has minimal DML (no DDL/index); Admin ops occur over VPN.
- Admin cannot read or change app data; App has read/write only to business DBs (new DBs auto-secured); Backup can dump only; Root has full control (use sparingly).
- VPN installed and enabled; MongoDB and SSH accessible only over VPN by default; on EC2, OS firewall enforces VPN-only. The tool does not use cloud credentials or modify Security Groups; it may print guidance you can apply manually.
- First run generates 8 certificates: 1 MongoDB server cert, 1 VPN server cert, 4 DB client certs for roles (Root/Admin/App/Backup), and 2 VPN client certs for human access (admin/viewer). DB certs do not work for VPN, and VPN certs do not work for DB.
- Auto-lock to VPN-only occurs after the first successful SSH over VPN; the watcher disables itself; rollback works if failure occurs.
- Local-only by default; public allowed only via single-IP flags; firewall matches the config.
- Backups exist, are encrypted, retained (7 days), and have basic quota checks.
- Config updates apply with zero downtime where possible; otherwise you are informed and fail-safe rollback works.
- mongod auto-restarts on failure and starts at boot; failed starts trigger automatic rollback to last-known-good.
- Re-running the tool is safe and converges to this state.
- Every run verifies and enforces all controls; drift is reconciled automatically; unmet requirements cause a safe stop or rollback with a clear message.

## Implementation notes (1.0.0 MVP scope)
- Main CLI (harden-mongo-server):
  - Single-change networking flags (--allow-ip-add/--allow-ip-remove).
  - Auto app DB management (automatic flow for visibility; automation is on by default).
- Libraries (lib/harden-mongo-server/*.sh):
  - mongodb.sh: x509-only, custom ops role, user provisioning, auto just-in-time DB grants, zero-downtime apply.
  - ssl.sh: private CA issuance, CRL, monthly rotation with graceful reload.
  - firewall.sh: basic rules for 27017 based on config and flags.
- backup.sh: simple scheduled, encrypted local backups with basic retention; perform a one-time initial backup before changes if an existing DB is detected.
  - system.sh/failsafe.sh: atomic config writes, last-known-good tracking, rollback on failed reloads.
- Timers/services: backup (daily), cert-rotate (monthly), openvpn (at boot), vpn-lock-watcher (one-time).

## Planned file changes (1.0.0 MVP structure)
- Onboarding helper
  - Create an ephemeral static file endpoint (127.0.0.1) to serve exactly one archive hms-onboarding-YYYY-MM-DD.zip (flat, date-stamped files).
  - Invoke cloudflared quick tunnel (no account) to expose a single HTTPS URL; enforce single-use and TTL; auto-delete archive and stop tunnel after success/expiry.
  - Print one-liners for Unix/Windows with the full URL embedded; if the tunnel cannot be created, print an instruction to contact a human administrator.
- Main CLI (./harden-mongo-server)
  - Single-IP networking flags: --allow-ip-add IP, --allow-ip-remove IP. Each flag updates config atomically and applies firewall changes without downtime.
  - Auto App DB management (automation is on by default for just-in-time grants).
  - Phases: preflight, bootstrap, tls, mongodb-config, provision, firewall, backups, verify.
- Core (./lib/harden-mongo-server/core.sh)
  - Parse config keys (onboarding, tls, network, mongodb, principals, appAccess, firewall, backups, openvpn, ssh, autoLockToVpnOnFirstRun, humans).
  - Atomic config writes with previous-version backup and a last-known-good pointer; diff logged for audit.
- MongoDB (./lib/harden-mongo-server/mongodb.sh)
  - Enforce x509-only + TLS-required; set tlsMinVersion=TLS1_2 (preflight gates if unsupported); custom ops role (clusterMonitor-only); provision $external users (Root/Admin/App/Backup) with auth restrictions.
  - Create App custom role hmsAppRW (minimal DML; no DDL/index operations). Grant/revoke App readWrite via this role; automatic just-in-time grant for new business DBs when first used by App.
  - Apply changes via graceful reload where supported; warn if restart is required; on failure, trigger rollback.
- TLS/PKI (./lib/harden-mongo-server/ssl.sh)
  - Private CA issuance for server and client certs; CRL management; monthly rotation; graceful reload.
  - VPN client cert issuance for admin and viewer. Enable tls-crypt by default; enforce tlsVersionMin=TLS1_2.
- Firewall (./lib/harden-mongo-server/firewall.sh)
  - Enforce default DROP on public interfaces; block ICMP echo on public; allow ICMP on VPN.
  - Basic firewall rules for 27017 (VPN and allowed IPs).
- System (./lib/harden-mongo-server/system.sh)
  - Ensure directories/permissions; zero-downtime reload path; prompt before unavoidable restarts; restore last-known-good on failure.
  - Create OS groups (admins), manage sshd drop-ins.
  - Apply minimal sysctls and enable unattended security updates; configure log rotation for mongod and tool logs.
- Logging (./lib/harden-mongo-server/logging.sh)
  - Clear audit tags for grants, config diffs, and backup actions.
- Failsafe (./lib/harden-mongo-server/failsafe.sh)
  - Last-known-good snapshot; automatic rollback on failed reloads.
- Installer (./install.sh)
  - Create directories (keys, backups) with strict permissions; add timers only if missing.
- Systemd timers/services
  - harden-mongo-server-backup.timer/service (daily)
  - harden-mongo-server-cert-rotate.timer/service (monthly cert rotation)
  - harden-mongo-server-vpn-lock-watcher.service (one-time auto-lock)
  - openvpn@server.service (enabled at boot)
- Tests (./tests)
  - Verify auth separation; x509-only + CRL; monthly rotation zero-downtime; backup retention; just-in-time DB grants; rollback on failed reload.
  - Verify SSH VPN-only enforced.

## Configuration schema (1.0.0 MVP)
This schema shows the configuration for 1.0.0.
- onboarding:
  - method: "cloudflared"
  - expiryMinutes: 10
  - singleUse: true
  - filenameDateFormat: "YYYY-MM-DD" (UTC, ISO 8601)
- tls:
  - mode: "internalCA"
  - rotation: { periodDays: 30, zeroDowntimeReload: true }
- network:
  - bind: ["127.0.0.1", "<VPN-interface>"] (VPN enabled by default)
  - allowedIPs: [] (empty means no public exposure)
- mongodb:
  - tlsMinVersion: "TLS1_2"
  - maxIncomingConnections: 1024
- principals:
  - root: { allowedClientSources: ["127.0.0.1", "10.8.0.0/24"] }
  - admin: { allowedClientSources: ["10.8.0.0/24"] }
  - app: { allowedClientSources: ["127.0.0.1", "10.8.0.0/24"] + network.allowedIPs }
  - backup: { allowedClientSources: ["127.0.0.1"] }
- appAccess:
  - autoApproveNewDatabases: true
  - excludeDatabases: ["admin", "local", "config"]
- firewall:
  - stealth: { dropUnmatchedPublic: true, blockIcmpEchoPublic: true, allowIcmpVpn: true }
- backups:
  - enabled: true
  - targetDir: "/var/backups/harden-mongo-server"
  - retention: { daily: 7 }
  - compression: "zstd"
  - encryption: { type: "age", keyPath: "/etc/harden-mongo-server/keys/backup.agekey" }
  - schedule: "02:00"
- openvpn:
  - enabled: true
  - network: "10.8.0.0/24"
  - port: 1194
  - proto: "udp"
  - crypto: { tlsCrypt: true, cipher: "AES-256-GCM", auth: "SHA256", tlsVersionMin: "TLS1_2" }
- ssh:
  - vpnOnly: true
- autoLockToVpnOnFirstRun: true
- humans:
  - [ { name, role: "viewer"|"admin", sshAuthorizedKeys: [], vpnEnabled: true } ]

---

## Features deferred to 1.1.0 and beyond

### Deferred to 1.1.0+:
1. **Advanced backup features**
   - Quiet-hour learning (adaptive scheduling)
   - Weekly/monthly retention policies
   - Advanced quota management
   - Activity-based scheduling
   - **1.0.0**: Fixed daily schedule at 02:00, basic retention (7 days)

2. **Viewer role and chroot**
   - SFTP-only viewer account
   - Chroot environment with curated paths
   - Read-only access to logs and config
   - Per-human VPN certificate management
   - **1.0.0**: Only admin role with full access

3. **Advanced monitoring**
   - Activity sampling
   - Event watchers
   - Monitoring phase
   - **1.0.0**: Basic continuous enforcement only

4. **Advanced firewall rate limiting**
   - Per-source concurrent connection caps (200)
   - New connection rate limits (20/sec, burst 40)
   - OpenVPN port rate limiting (50 pkt/sec, burst 200)
   - **1.0.0**: Basic firewall rules only

5. **Advanced CLI flags**
   - --include-phases, --exclude-phases
   - --vpn-client-issue, --vpn-client-revoke
   - --vpn-human-add, --vpn-human-revoke, --vpn-human-rotate
   - --vpn-cipher, --vpn-auth, --vpn-tls-min, --vpn-reneg-seconds
   - --tls-zero-downtime-reload, --tls-rotation-days
   - --app-allow-ddl, --app-allow-index
   - --app-auto-approve-enable/disable, --app-denylist-add/remove
   - --backup-retention-weekly/monthly, --backup-quota-percent, --backup-quota-max-gib
   - --backup-min-free-gib, --backup-compression, --backup-encryption-type, --backup-encryption-key
   - --backup-schedule auto (adaptive)
   - --fw-ovpn-rate-avg, --fw-ovpn-rate-burst
   - --fw-mongo-per-source, --fw-mongo-new-per-sec, --fw-mongo-new-burst
   - --zero-downtime-preferred, --warn-if-restart-required
   - --viewer-chroot-root, --viewer-include-add/remove, --viewer-exclude-add/remove
   - **1.0.0**: Essential flags only


### Version roadmap:
- **1.0.0**: Core security + essential automation (TLS, x509, VPN, firewall, backups, auto-onboarding, auto-grants, auto-rotation, auto-lock)
- **1.1.0**: Advanced backup features (weekly/monthly retention, quiet-hour learning, adaptive scheduling)
- **1.2.0**: Viewer role with chroot, advanced monitoring, activity sampling
- **1.3.0**: Advanced firewall rate limiting, per-human VPN management beyond initial 2, complete CLI flag set
- **2.0.0**: Full feature set as documented in main blueprint

---

## Summary: 1.0.0 MVP is production-ready for core security

This MVP provides:
✅ Complete TLS/x509 enforcement  
✅ VPN-only access by default  
✅ Role separation with least-privilege  
✅ Basic firewall protection  
✅ Encrypted backups with retention  
✅ **Automated certificate distribution** (one-liner download)  
✅ **Automatic database access grants** (just-in-time)  
✅ **Automated certificate rotation** (monthly, zero-downtime)  
✅ **Auto-lock to VPN** (after first SSH over VPN)  
✅ Zero-downtime operations where possible  
✅ Fail-safe rollback  
✅ Continuous security enforcement  

**What's deferred to future versions:**
- Viewer role with chroot (not needed initially)
- Advanced monitoring and activity sampling (nice-to-have analytics)
- Quiet-hour learning for adaptive backup scheduling (basic daily schedule works)
- Advanced firewall rate limiting (basic rules sufficient for 1.0.0)
- Fine-grained CLI controls (essentials covered)

**This is a complete, secure, production-ready system with full automation.** Future versions add advanced management features and analytics, not core security or automation.
