# Harden Mongo Server — Blueprint

Purpose (plain language)
- A single command that hardens a MongoDB server securely with minimal input.
- Private-only by default. No public domain required. Safe to re-run anytime.

What you get (secure defaults)
- TLS required with a private Certificate Authority (CA).
- x509-only authentication (passwords disabled).
- Separation of duties:
  - Root (break-glass): full control, localhost/VPN only.
  - Admin (operations): monitoring-only; cannot read/modify app data.
  - App (business): read/write only to business databases; no admin powers.
  - Backup (service): backup-only; cannot administer or write data.
- Networking: localhost-only by default; OpenVPN installed and enabled by default; public IPs must be explicitly allowed.
- Automatic security for new business databases used by the App (no manual approval).
- Backups: local-only, encrypted, scheduled (daily/weekly/monthly) at quiet hours with disk-safety.
- Certificates: monthly automated renewal/rotation with graceful reload.
- Zero-downtime first, fail-safe rollback if a change is unsafe.
- OpenVPN server installed and configured on first run; MongoDB and SSH are restricted to VPN-only by default. Two initial human VPN profiles (admin and viewer) are created.

What you do
- First run as root to bootstrap; later runs allowed for users in the tool’s system group.
- On first run, the tool sets up the OpenVPN server and issues two client profiles you can use to connect: admin (full) and viewer (read-only).
- If you need public access, use single-IP flags (one at a time). For bulk changes, edit the config file.
- Otherwise, the tool adapts automatically: TLS, auth, new DB access, backups, and firewall.
- No cloud credentials are required at any time. First access typically uses your SSH PEM once; subsequent access uses the VPN.

How it operates (at a glance)
- Phases: preflight → bootstrap → tls → mongodb-config → provision → firewall → backups → monitor → verify.
- Idempotent: reruns safely reconcile the system to the desired secure state.
- Continuous enforcement: on every run, the tool verifies and re-enforces all security features (VPN hardening, firewall policy, TLS/auth settings, roles and auth restrictions, sysctls, backups). If a required condition cannot be met, it stops or rolls back with a clear message.

Security model
- Root: built-in root role; for provisioning and emergencies. Restricted to localhost/VPN.
- Admin: custom ops role (clusterMonitor only). No data access, no user/role changes.
- App: readWrite on business databases only. Automatically granted when a new business DB is first used.
- Backup: built-in backup role. Default localhost-only.
- Authentication restrictions: each principal limited to safe client networks.

TLS and certificates
- Private CA only (no public domain required) for server, client, and VPN certificates.
- Database client certificates are used only for MongoDB; VPN client certificates are separate and issued per human. They rotate and can be revoked independently.
- First run certificates: 6 total — 4 MongoDB x509 client certs (Root, Admin, App, Backup) and 2 OpenVPN client certs for human access (admin and viewer).
- Monthly automated renewal/rotation.
- Zero downtime preferred: perform a graceful reload. If reload fails or is unsupported, warn before a short, safe restart; otherwise revert to last-known-good.

Databases and access (automatic)
- When the App identity touches a new non-system DB (not admin/local/config), the tool grants App readWrite on that DB automatically.
- This “just-in-time” grant is limited to that specific DB and is fully logged.

MongoDB hardening (enabled by default)
- Enforce WiredTiger; migrate safely if needed. Set featureCompatibilityVersion (FCV) to the installed major/minor.
- Transport and auth: requireTLS, x509-only; tlsMinVersion=TLS1_2; SCRAM disabled. Authentication restrictions pin principals to 127.0.0.1 and/or VPN CIDR; the App principal is also pinned to its allowed IPs.
- Connection safety: set mongod maxIncomingConnections=1024 by default; apply per-source concurrent cap=200 and new-connection rate ≤20/sec (burst 40) at the firewall.
- Least-privilege roles: Root (root), Admin (hmsOpsAdmin → clusterMonitor only), Backup (backup), App (hmsAppRW → minimal DML; no DDL/index operations). Destructive/index operations require an Admin over VPN.
- Preflight gating: if minimum requirements (WiredTiger and TLS 1.2+) are not supported by the installed version, the tool stops and instructs you to upgrade; it does not fall back.

Networking and exposure
- Default: bind to localhost only; nothing exposed publicly.
- VPN: installed and enabled by default; MongoDB (27017) and SSH (22) are allowed only over the VPN interface by default.
- VPN hardening (enabled): tls-crypt on control channel; cipher AES-256-GCM; auth SHA256; tls-version-min TLS1_2; compression disabled; UDP/1194. Firewall rate limit on OpenVPN port (avg 50 pkts/sec, burst 200).
- Public side stealth (enabled): default DROP for unmatched inbound on public interfaces; block ICMP echo on public interfaces; allow ICMP on VPN.
- App access (allowed IPs): 27017 is opened only to exactly the allowed IPs you specify; access still requires x509 DB certs (IP alone is not enough).
- Per-source connection controls (enabled): 27017 enforces per-source concurrent cap=200 and new-connection rate limit ≤20/sec (burst 40) on both VPN and allowed IPs.
- Public access (if truly needed): single-IP flags that write to config and apply firewall safely with zero downtime:
  - --allow-ip-add <IP>
  - --allow-ip-remove <IP>
- SSH policy: VPN-only by default. You can toggle with flags if needed (see VPN and SSH flags).
- EC2: OS firewall enforces VPN-only. The tool does not use any cloud credentials and does not change Security Groups. It may print suggested Security Group rules you can apply later, manually.
- Auto-lock to VPN-only: after the first successful SSH login over the VPN, a one-time watcher locks SSH and MongoDB to the VPN interface, then disables itself. No manual flag or timer wait required.
- No bulk changes via flags. For multiple IPs, edit the config file.

Onboarding (one-liner download via Cloudflare Quick Tunnel)
- Purpose: let any user download everything needed with a single copy-paste command (no PEM, no EC2 IP knowledge, no UI).
- How it works (server side, automated):
  - Package a single archive named hms-onboarding-<TOKEN>.zip containing the files listed below (flat, no subfolders, no README).
  - Launch a short-lived Cloudflare Quick Tunnel (no account) to expose exactly one HTTPS URL for that archive.
  - Enforce single-use and expiry: first successful download deletes the archive and shuts down the tunnel; otherwise the URL expires after onboarding.expiryMinutes.
  - If a public URL cannot be obtained, the tool prints: "Unable to generate the onboarding script. Please contact a human administrator to help download the files." No fallback is attempted.
- What the user runs (one line):
  - Linux/macOS:
    curl -fsSL "https://<random>.trycloudflare.com/download/<TOKEN>" -o hms-onboarding.zip && unzip -q hms-onboarding.zip && rm hms-onboarding.zip
  - Windows (PowerShell):
    iwr -UseBasicParsing "https://<random>.trycloudflare.com/download/<TOKEN>" -OutFile hms-onboarding.zip; Expand-Archive -Force .\hms-onboarding.zip .; Remove-Item .\hms-onboarding.zip
- Compressed file contents (flat, date-stamped YYYYMMDD in UTC):
  - admin-YYYYMMDD.ovpn
  - viewer-YYYYMMDD.ovpn
  - db-root-YYYYMMDD.pem      (client cert+key)
  - db-admin-YYYYMMDD.pem     (client cert+key)
  - db-app-YYYYMMDD.pem       (client cert+key)
  - db-backup-YYYYMMDD.pem    (client cert+key)
  - db-ca-YYYYMMDD.pem        (server CA chain)
- Notes:
  - The .ovpn profiles embed their client cert/key and the VPN CA chain.
  - Each db-*.pem contains the full client identity (cert+key) suitable for mongosh/drivers via tlsCertificateKeyFile.
  - The date stamp helps operators identify issuance/rotation at a glance; it does not replace internal certificate validity.

Configuration and flags
- Canonical config: /etc/harden-mongo-server/config.json.
- Everything configurable lives in the config file. Flags exist for convenience only; each flag makes one small, safe change and writes it back to config.
- CLI flags update the config atomically (one change per flag) and keep a backup of the previous version.
- A “last-known-good” config is maintained for automatic rollback.
- Dry-run shows intended changes and whether a reload or restart is required.
- Onboarding scripts: the tool prints one-liners with a short-lived HTTPS URL. If the URL cannot be created, it tells the user to contact a human administrator; no fallback is attempted.

CLI flags (each flag updates config first, then applies safely)
General
- --config PATH                          Set alternate config path for this run (does not write config)
- --dry-run                               Show planned changes only
- --verbose | --quiet                     Adjust output
- --phase NAME                            Run a single phase: preflight|bootstrap|tls|mongodb-config|provision|firewall|backups|monitor|verify
- --include-phases NAMES                  Comma-separated list to run selected phases in order
- --exclude-phases NAMES                  Comma-separated list to skip phases

Networking (single-IP changes only; no bulk via flags)
- --allow-ip-add IP                       Allow one IP to access MongoDB (adds to network.allowedIPs)
- --allow-ip-remove IP                    Remove one IP from access list

VPN and SSH
- --vpn-enable | --vpn-disable            Turn VPN on/off
- --vpn-network CIDR                      Configure VPN network (e.g., 10.8.0.0/24)
- --vpn-port N                            VPN port (default 1194)
- --vpn-proto udp|tcp                     VPN protocol (default udp)
- --vpn-client-issue NAME                 Issue a client profile (NAME.ovpn)
- --vpn-client-revoke NAME                Revoke a client profile
- --vpn-human-add NAME --role=viewer|admin  Add a human with a per-human VPN cert and OS role
- --vpn-human-revoke NAME                 Revoke a human’s VPN access
- --vpn-human-rotate NAME                 Rotate a human’s VPN cert
- --ssh-vpn-only-enable | --ssh-vpn-only-disable  Enforce or relax SSH VPN-only policy

TLS/certificates (private CA)
- --tls-rotation-days N                   Set monthly rotation period in days (e.g., 30) [writes tls.rotation.periodDays]
- --tls-rotate-now                        Rotate server/client certs now (graceful reload)

App database access
- --app-auto-approve-enable               Enable automatic just-in-time grants for new business DBs
- --app-auto-approve-disable              Disable automatic grants
- --app-denylist-add REGEX                Add a denylist pattern (prevents auto-grant for matching DB names)
- --app-denylist-remove REGEX             Remove a denylist pattern

Backups (local-only)
- --backup-enable | --backup-disable      Turn backups on/off
- --backup-now                             Run a backup immediately
- --restore PATH                           Restore from a backup archive
- --backup-retention-daily N               Set daily retention count
- --backup-retention-weekly N              Set weekly retention count
- --backup-retention-monthly N             Set monthly retention count
- --backup-quota-percent N                 Set max percent of filesystem used by backups
- --backup-quota-max-gib N                 Set absolute cap (GiB)
- --backup-min-free-gib N                  Ensure at least this much free space remains

Principal network restrictions (advanced; per-principal client sources)
- --root-allow-client-add CIDR            Add client source for Root principal
- --root-allow-client-remove CIDR         Remove client source for Root principal
- --admin-allow-client-add CIDR           Add client source for Admin principal
- --admin-allow-client-remove CIDR        Remove client source for Admin principal
- --app-allow-client-add CIDR             Add client source for App principal
- --app-allow-client-remove CIDR          Remove client source for App principal
- --backup-allow-client-add CIDR          Add client source for Backup principal
- --backup-allow-client-remove CIDR       Remove client source for Backup principal

Update policy
- --zero-downtime-preferred true|false    Prefer reload over restart (default true)
- --warn-if-restart-required true|false   If restart is unavoidable, require explicit confirmation (default true)

Onboarding (operator convenience)
- --onboarding-one-liner [--unix|--windows]  Generate a fresh short-lived URL and print the copy-paste one-liner
- --onboarding-expiry MINUTES                Override link TTL (default 10)

Backups (local-only, safe by default)
- Schedule: daily, weekly (Sunday), monthly (1st) at 02:00 local by default; adjusts to the quietest hour as data is gathered.
- Encryption: age; root-only key in /etc/harden-mongo-server/keys/backup.agekey.
- Compression: zstd.
- Disk safety: retention and quotas to avoid filling the disk; if space would be exceeded, trim in a safe order or skip with an alert.

Default configuration (best security)
- onboarding:
  - method: cloudflared
  - expiryMinutes: 10
  - singleUse: true
  - includeReadme: false
  - filenameDateFormat: "YYYYMMDD" (UTC)
- tls:
  - mode: internalCA
  - rotation: periodDays=30, zeroDowntimeReload=true
- network:
  - bind: ["127.0.0.1"] (plus VPN interface if enabled)
  - allowedIPs: [] (no public access by default)
- mongodb:
  - tlsMinVersion: "TLS1_2"
  - maxIncomingConnections: 1024
  - appRole: { allowDDL: false, allowIndex: false }
- principals (authenticationRestrictions clientSource defaults):
  - root: ["127.0.0.1", "VPN CIDR if enabled"]
  - admin: ["VPN CIDR if enabled"]
- app: ["127.0.0.1", "VPN CIDR if enabled", "network.allowedIPs"]
  - backup: ["127.0.0.1"]
- appAccess:
  - autoApproveNewDatabases: true
  - excludeDatabases: ["admin","local","config"]
  - denylistPatterns: []
- firewall:
  - stealth: { dropUnmatchedPublic: true, blockIcmpEchoPublic: true, allowIcmpVpn: true }
  - openvpnRateLimit: { avgPktsPerSec: 50, burstPkts: 200 }
  - mongodbConnLimits: { perSourceConcurrent: 200, newConnPerSec: 20, burst: 40 }
- backups:
  - enabled: true; targetDir: /var/backups/harden-mongo-server
  - retention: daily=7, weekly=4, monthly=12
  - quota: percent=20, maxGiB=50, minFreeGiB=15
  - compression: zstd; encryption: age (keyPath=/etc/harden-mongo-server/keys/backup.agekey)
  - schedule: auto (02:00 local by default; adjusts to the quietest hour as data is gathered)
- updatePolicy:
  - zeroDowntimePreferred: true; warnIfRestartRequired: true
- openvpn:
  - enabled: true
  - network: 10.8.0.0/24
  - port: 1194
  - proto: udp
  - crypto: { tlsCrypt: true, cipher: "AES-256-GCM", auth: "SHA256", tlsVersionMin: "TLS1_2", renegSeconds: 43200 }
- ssh:
  - vpnOnly: true (enforced automatically after first successful SSH over VPN)
- autoLockToVpnOnFirstRun: true
- humans:
  - [
    { name: "admin", role: "admin", sshAuthorizedKeys: [], vpnEnabled: true },
    { name: "viewer", role: "viewer", sshAuthorizedKeys: [], vpnEnabled: true }
  ]
- viewer:
  - chrootViewRoot: /var/lib/harden-mongo-server/view
  - includePaths:
    - /var/log/harden-mongo-server
    - /var/log/mongodb
    - /etc/harden-mongo-server/config.redacted.json (sanitized copy without secrets)
  - excludePaths:
    - /etc/harden-mongo-server/keys

Zero downtime and fail-safe
- On any configuration or security update: attempt graceful reload first.
- If a restart is needed, inform you before proceeding.
- If a reload/restart fails or the change is unsafe, revert to last-known-good and keep the database online.

System integration
- First run requires root: creates directories, users/groups, services, and policies.
- System users/groups and accounts:
  - OS groups: harden-mongo-server-admins (admins) and harden-mongo-server-viewers (viewers)
  - OS users created: hms-admin (admins group; shell + sudo) and hms-viewer (viewers group; SFTP-only chroot; no shell)
- SSH configuration:
  - VPN-only enforced by firewall; sshd drop-in sets PermitRootLogin no; Match Group harden-mongo-server-viewers forces internal-sftp + ChrootDirectory.
- OS hardening (enabled): unattended security updates and minimal sysctls (syncookies, rp_filter, reject redirects/source routes, protected symlinks/hardlinks, restricted kptr/dmesg, ignore broadcast pings). Log rotation for mongod and tool logs.
- Systemd timers/services:
  - Backup scheduler (daily/weekly/monthly)
  - Certificate rotation (monthly)
  - Lightweight monitor (for activity sampling and auto-grants)
  - OpenVPN server (enabled at boot)
- VPN lock watcher (one-time): detects first SSH over VPN and locks SSH/MongoDB to VPN, then disables itself
- Onboarding one-shot: ephemeral file endpoint + cloudflared quick tunnel (single-use, short-lived); auto-shutdown after success/expiry
- Continuous enforcement: each execution validates and reapplies configured controls; no-ops when compliant; fails closed with rollback or clear stop when preflight requirements are not met.
- Auto-restart and boot behavior:
  - mongod is enabled to start at boot and configured to auto-restart on failure (Restart=on-failure, RestartSec=5s, StartLimitIntervalSec=60, StartLimitBurst=5). If the vendor unit lacks these settings, a systemd drop-in is installed to enforce them.
  - If mongod crashes or is terminated, it restarts automatically.
  - All timers are enabled and Persistent=true, so they resume after reboot and run missed jobs when appropriate.
  - If a start or reload fails due to an invalid config, the fail-safe reverts to the last-known-good configuration and brings the service back up.
- Polkit rules allow approved users to operate the tool without sudo after bootstrap.

Acceptance checklist
- One-liner onboarding (HTTPS) without PEM/IP: user downloads a flat, date-stamped zip (admin-YYYYMMDD.ovpn, viewer-YYYYMMDD.ovpn, db-*-YYYYMMDD.pem, db-ca-YYYYMMDD.pem); if a public URL cannot be created, the tool instructs the user to contact a human administrator (no fallback attempted).
- VPN hardened by default (tls-crypt, AES-256-GCM/SHA256, TLS ≥1.2), rate-limited port, and stealth DROP on public interfaces; ICMP allowed only on VPN.
- TLS required; x509-only; private CA; monthly renewal without downtime.
- MongoDB uses WiredTiger; FCV pinned; maxIncomingConnections capped; per-source connection limits on 27017; App role has minimal DML (no DDL/index) and is IP-pinned; Admin ops occur over VPN.
- Admin cannot read or change app data; App has read/write only to business DBs (new DBs auto-secured);
  Backup can dump only; Root has full control (use sparingly).
- VPN installed and enabled; MongoDB and SSH accessible only over VPN by default; on EC2, OS firewall enforces VPN-only. The tool does not use cloud credentials or modify Security Groups; it may print guidance you can apply manually.
- First run generates 6 certificates: 4 for DB roles (Root/Admin/App/Backup) and 2 for VPN human access (admin/viewer). DB certs do not work for VPN, and VPN certs do not work for DB.
- Auto-lock to VPN-only occurs after the first successful SSH over VPN; the watcher disables itself; rollback works if failure occurs.
- Human access via VPN uses per-human certs; Viewer role is SFTP-only with curated, read-only paths and no secrets; Admin role has shell with sudo.
- Local-only by default; public allowed only via single-IP flags; firewall matches the config.
- Backups exist, are encrypted, retained, and never fill the disk.
- Config updates apply with zero downtime where possible; otherwise you are informed and fail-safe rollback works.
- mongod auto-restarts on failure and starts at boot; timers are enabled and Persistent; failed starts trigger automatic rollback to last-known-good.
- Re-running the tool is safe and converges to this state.
- Every run verifies and enforces all controls; drift is reconciled automatically; unmet requirements cause a safe stop or rollback with a clear message.

Implementation notes (at a glance)
- Main CLI (harden-mongo-server):
  - Adds single-change networking flags (--allow-ip-add/--allow-ip-remove).
  - Adds app DB management flags (discover/approve automatic flow for visibility; automation is on by default).
- Libraries (lib/harden-mongo-server/*.sh):
  - mongodb.sh: x509-only, custom ops role, user provisioning, auto just-in-time DB grants, zero-downtime apply.
  - ssl.sh: private CA issuance, CRL, monthly rotation with graceful reload.
  - firewall.sh: least-privilege rules for 27017 based on config and flags.
  - backup.sh: scheduled, encrypted local backups with retention/quotas; run at quiet hour.
  - monitoring.sh: light activity sampling and event detection to support scheduling and auto-grants.
  - system.sh/failsafe.sh: atomic config writes, last-known-good tracking, rollback on failed reloads.
- Timers/services: backup, cert-rotate, monitor (low overhead).


Planned file changes (structure-preserving)
- Onboarding helper
  - Create an ephemeral static file endpoint (127.0.0.1) to serve exactly one archive hms-onboarding-<TOKEN>.zip (flat, date-stamped files).
  - Invoke cloudflared quick tunnel (no account) to expose a single HTTPS URL; enforce single-use and TTL; auto-delete archive and stop tunnel after success/expiry.
  - Print one-liners for Unix/Windows with the full URL embedded; if the tunnel cannot be created, print an instruction to contact a human administrator.
- Firewall (./lib/harden-mongo-server/firewall.sh)
  - Enforce default DROP on public interfaces; block ICMP echo on public; allow ICMP on VPN.
  - Add lightweight rate limiting on UDP/1194; apply per-source concurrent connection caps and small new-connection rate limits to 27017 (VPN and allowed IPs).
- Main CLI (./harden-mongo-server)
  - Single-IP networking flags: --allow-ip-add IP, --allow-ip-remove IP. Each flag updates config atomically and applies firewall changes without downtime. No bulk changes via flags.
  - App DB management flags (visibility): discover/approve; automation is on by default for just-in-time grants.
  - VPN human management flags: --vpn-human-add/--vpn-human-revoke/--vpn-human-rotate with role=viewer|admin.
  - Phases unchanged; help text documents new flags.
- Core (./lib/harden-mongo-server/core.sh)
  - Parse new config keys (principals, appAccess, backups, tls, network, updatePolicy, onboarding, humans, viewer config).
  - Atomic config writes with previous-version backup and a last-known-good pointer; diff logged for audit.
- MongoDB (./lib/harden-mongo-server/mongodb.sh)
  - Enforce x509-only + TLS-required; set tlsMinVersion=TLS1_2 (preflight gates if unsupported); custom ops role (clusterMonitor-only); provision $external users (Root/Admin/App/Backup) with auth restrictions.
  - Create App custom role hmsAppRW (minimal DML; no DDL/index operations). Grant/revoke App readWrite via this role; automatic just-in-time grant for new business DBs when first used by App.
  - Apply changes via graceful reload where supported; warn if restart is required; on failure, trigger rollback.
- TLS/PKI (./lib/harden-mongo-server/ssl.sh)
  - Private CA issuance for server and client certs; CRL management; monthly rotation; graceful reload.
  - VPN per-human client cert issuance/revocation/rotation (separate from DB certs). Enable tls-crypt by default; enforce tlsMinVersion=TLS1_2.
- Firewall (./lib/harden-mongo-server/firewall.sh)
  - Enforce default DROP on public interfaces; block ICMP echo on public; allow ICMP on VPN.
  - Rate limit UDP/1194 (avgPktsPerSec=50, burstPkts=200); enforce mongodbConnLimits (perSourceConcurrent=200, newConnPerSec=20, burst=40) on 27017 (VPN and allowed IPs).
- Monitoring (./lib/harden-mongo-server/monitoring.sh)
  - Light activity sampling (quiet-hour learning) and event watcher to trigger just-in-time DB grants.
  - One-time VPN lock watcher: detect first SSH over VPN and trigger lock-to-VPN changes, then disable itself.
- System (./lib/harden-mongo-server/system.sh)
  - Ensure directories/permissions; zero-downtime reload path; prompt before unavoidable restarts; restore last-known-good on failure.
  - Create OS groups (admins/viewers), configure chroot SFTP for viewers, and manage sshd drop-ins.
  - Apply minimal sysctls and enable unattended security updates; configure log rotation for mongod and tool logs.
- Logging (./lib/harden-mongo-server/logging.sh)
  - Clear audit tags for grants, config diffs, and backup actions.
- Failsafe (./lib/harden-mongo-server/failsafe.sh)
  - Last-known-good snapshot; automatic rollback on failed reloads.
- Installer (./install.sh)
  - Create any new directories (keys, backups, viewer chroot) with strict permissions; add timers only if missing.
- Systemd timers/services
  - harden-mongo-server-backup.timer/service (scheduling)
  - harden-mongo-server-cert-rotate.timer/service (monthly cert rotation)
  - harden-mongo-server-monitor.timer/service (low-overhead sampling/auto-grants)
  - harden-mongo-server-vpn-lock-watcher.service (one-time auto-lock)
- Tests (./tests)
  - Verify auth separation; x509-only + CRL; monthly rotation zero-downtime; backup retention/quota; just-in-time DB grants; rollback on failed reload.
  - Verify VPN human roles: viewer chroot and no shell; admin shell+sudo; SSH VPN-only enforced.


Planned configuration keys (concise)
- onboarding:
  - method: "cloudflared" | "disabled"
  - expiryMinutes: 10
  - singleUse: true
  - includeReadme: false
  - filenameDateFormat: "YYYYMMDD" (UTC)
- tls:
  - mode: "internalCA"; rotation: { periodDays: 30, zeroDowntimeReload: true }
- network:
  - bind: ["127.0.0.1"] (plus VPN if enabled); allowedIPs: [] (empty means no public exposure)
- mongodb:
  - tlsMinVersion: "TLS1_2"
  - maxIncomingConnections: 1024
  - appRole: { allowDDL: false, allowIndex: false }
- firewall:
  - stealth: { dropUnmatchedPublic: true, blockIcmpEchoPublic: true, allowIcmpVpn: true }
  - openvpnRateLimit: { avgPktsPerSec: 50, burstPkts: 200 }
  - mongodbConnLimits: { perSourceConcurrent: 200, newConnPerSec: 20, burst: 40 }
- updatePolicy:
  - zeroDowntimePreferred: true; warnIfRestartRequired: true
- openvpn:
  - enabled: true; network: "10.8.0.0/24"; port: 1194; proto: "udp"
  - crypto: { tlsCrypt: true, cipher: "AES-256-GCM", auth: "SHA256", tlsVersionMin: "TLS1_2", renegSeconds: 43200 }
- ssh:
  - vpnOnly: true
- autoLockToVpnOnFirstRun: true
- humans:
  - [ { name, role: "viewer"|"admin", sshAuthorizedKeys: ["ssh-ed25519 AAA..."], vpnEnabled: true } ]
- viewer:
  - chrootViewRoot: "/var/lib/harden-mongo-server/view"
  - includePaths: [ "/var/log/harden-mongo-server", "/var/log/mongodb", "/etc/harden-mongo-server/config.redacted.json" ]
  - excludePaths: [ "/etc/harden-mongo-server/keys" ]
