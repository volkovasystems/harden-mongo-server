# Test Blueprint (blueprint.md)

This document defines a TAP-compliant test blueprint for the full Harden Mongo Server blueprint (docs/blueprint.md).

IMPORTANT policy
- No stubbing or mocking of any kind will be used.
- All tests run strictly inside Docker containers. Nothing is executed on the host.
- Tests exercise real services and binaries (systemd, mongod/mongosh, openvpn, iptables, cloudflared, age, zstd, curl, jq, tar), with proper isolation.

Outcomes
- Prove functional correctness, security posture, idempotence/drift correction, and fail-safe rollback for all features described in blueprint.md, including advanced networking/rate-limiting, monitoring, viewer chroot, per-human VPN management, quotas, and flags.


## 1) Test philosophy
- Reality over simulation: always run the real stack inside a privileged Docker container with systemd.
- TAP-compliant via BATS; readable diagnostics; explicit skip with reason when external dependencies (e.g., cloudflared internet) are unavailable.
- Reproducible, hermetic testbed: ephemeral containers, no host mutation.


## 2) Environment and prerequisites (Docker-only)
- Base image: modern systemd-enabled Linux (e.g., Ubuntu with systemd as PID 1).
- Required packages in the image: bats-core, bats-support, bats-assert, bats-file, jq, openssl, iptables, iproute2, age, zstd, curl, tar, unzip, systemd, openvpn, cloudflared, MongoDB (mongod, mongosh or mongo), rsync.
- Device/capabilities: /dev/net/tun, NET_ADMIN, SYS_ADMIN (or simply --privileged), cgroups mounted for systemd.
- All paths, services, timers, firewall, VPN, MongoDB, and onboarding run inside the container.

Example container run (guidance):
```bash path=null start=null
# Build the test image (includes systemd and all deps)
docker build -t hms-test:latest -f tests/Dockerfile .

# Run tests fully inside Docker (systemd as PID 1)
docker run --rm -t \
  --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$PWD":/workspace:rw \
  -w /workspace \
  --name hms-test \
  hms-test:latest /bin/bash -lc "tests/run-all-bats.sh"
```

Notes:
- Do not run any test on the host. All scripts and BATS suites are invoked inside the container.
- Artifacts are copied out via docker cp after the container exits, if needed.


## 3) Isolation, data, and artifacts
- Filesystem: use only container FS; write tool data to /var/lib/harden-mongo-server, logs to /var/log/harden-mongo-server, configs under /etc/harden-mongo-server.
- Network: use container namespaces for iptables and OpenVPN; no host rules modified.
- Artifacts on failure: capture (within the container) iptables-save output, systemctl status, journalctl slices, cert metadata (openssl x509 -noout), backup metadata, cloudflared logs; export via docker cp.


## 4) Test levels (all inside Docker)
- Unit (pure bash helpers): core/logging/system/failsafe small-scope tests (no mocks, but limited to filesystem and shell semantics).
- Integration (module-level): ssl, mongodb, firewall, backups, onboarding, vpn, rotation, monitoring, system integration (users/groups/sshd/polkit/sysctls/logrotate/timers).
- End-to-End (phases): full run preflight → bootstrap → tls → mongodb-config → provision → firewall → backups → monitor → verify; rerun idempotence and drift correction; flags.


## 5) BATS harness and helpers
- Harness: bats-core with bats-support, bats-assert, bats-file.
- Helpers: tests/helpers/
  - sandbox.bash: container-aware setup/teardown; artifact sinks; common env exports.
  - prereqs.bash: dependency checks; graceful skips with reason.
  - assertions.bash: reusable assertions (iptables rules present, TLS config present, service/timer active, file perms/ownership).
- All helpers run exclusively inside the container.


## 6) Suites and scenarios mapped to blueprint.md

### 6.1 Phases/E2E
- Phase order enforcement; each phase leaves required state.
- Rerun idempotence: no unintended changes; no duplicate firewall rules; checksums stable.
- Drift correction: manually perturb config/rules then rerun; verify reconciliation.
- Dry-run: actions listed without changing system state.
- include/exclude/phase-only flags: run subsets; verify ordering, dependencies, and no cross-phase leakage.

### 6.2 TLS/PKI
- Private CA initialization; verify key/cert; CA subject; key/cert match.
- Server cert with SANs (localhost + hostname); consolidated PEM; correct perms/ownership.
- DB client certificates for Root/Admin/App/Backup; DNs retrievable; PEMs contain cert+key.
- VPN CA + server cert generation.
- Monthly rotation: timer/service; certs replaced; mongod graceful reload preferred; rollback if unsafe.
- Flags: tls-mode, zero-downtime-reload, rotation-days, rotate-now → verify config+behavior.

### 6.3 MongoDB hardening
- WiredTiger enforced; FCV pinned to installed major.minor.
- Transport/auth: requireTLS; tlsMinVersion=TLS1_2; SCRAM disabled.
- Roles: hmsOpsAdmin (clusterMonitor); hmsAppRW (minimal DML); destructive/index ops restricted.
- Users by certificate DN in $external; authenticationRestrictions clientSource per principal (Root/Admin VPN; App VPN+allowedIPs; Backup localhost).
- App toggles: allowDDL/allowIndex reflect in role actions when enabled; default false.
- Per-source connection controls: enforce concurrent cap=200 and new-conn ≤20/sec (burst 40) on 27017 (VPN + allowed IPs) at the firewall.
- JIT grants: create/initiate new business DB as App; auto grant hmsAppRW; logs present.
- Negative path: introduce invalid mongod.conf; phase apply should rollback to last-known-good; service healthy; warn-if-restart-required honored; zero-downtime-preferred obeyed.
- Flags coverage: mongodb-tls-min, mongodb-max-incoming, appAccess (auto-approve/enabled/exclude/denylist).

### 6.4 Networking and firewall
- Default bind to localhost + VPN; no public exposure by default.
- Stealth mode: default DROP on public; block ICMP echo on public; allow ICMP on VPN.
- OpenVPN port rate limit: avg 50 pkt/s, burst 200.
- Allowed IPs: opening 27017 only to those IPs; still require x509.
- Flags: allow-ip-add/remove; bind-add/remove; firewall rate/limit flags.
- Persist and idempotence: iptables-save shows stable, deduplicated rules.

### 6.5 VPN and SSH
- OpenVPN server configured with tls-crypt, AES-256-GCM, auth SHA256, TLS1.2, renegSeconds.
- Service enabled at boot; status active; status logs available.
- Human management: issue/revoke/rotate per-human certs; roles admin|viewer.
- SSH policy: VPN-only enforced by firewall; toggles validated; auto-lock after first SSH over VPN; one-time watcher disables itself.
- Viewer chroot: hms-viewer user with internal-sftp; chrootViewRoot; include/exclude paths present; read-only access; no secrets exposed.
- Optional handshake (best effort): start an OpenVPN client inside another container namespace to validate control/data channels.

### 6.6 Onboarding (Cloudflare Quick Tunnel)
- Package flat archive: admin/viewer .ovpn; db-root/admin/app/backup .pem; db-ca pem; date-stamped.
- Launch cloudflared; capture https URL; first download succeeds; second attempts fail (single-use); TTL enforced; auto-shutdown cleans up.
- One-liner outputs correct for Unix and Windows.
- Flags: onboarding method/expiry/singleUse/includeReadme/dateFormat; one-liner generation prints and works.

### 6.7 Backups
- Schedules: daily/weekly/monthly timers default 02:00; quiet-hour ‘auto’ adjusts after monitoring data is present.
- Encryption age + zstd compression; key perms (600) under /etc/harden-mongo-server/keys.
- Initial backup before any changes when existing DB detected.
- Restore from .age archive; decompression + mongorestore succeeds.
- Retention: daily/weekly/monthly counts honored; Quotas: percent, maxGiB, minFreeGiB; safe trim order or skip with alert if quota would be exceeded.
- Flags: enable/disable, now, retention, quotas, target, compression/encryption, schedule auto/HH:MM.

### 6.8 Monitoring
- Lightweight sampling daemon installed and enabled; low CPU/memory.
- Drives quiet-hour learning for backup auto schedule; triggers JIT grant events; logs available.

### 6.9 Failsafe and update policy
- Atomic config writes; last-known-good snapshots.
- Apply path: graceful reload → validate → restart fallback; rollback on validation failure.
- Update policy flags zeroDowntimePreferred and warnIfRestartRequired affect behavior and prompts.

### 6.10 System integration
- Users/groups: harden-mongo-server-admins and harden-mongo-server-viewers; hms-admin (sudo shell), hms-viewer (SFTP-only); polkit rules allow tool usage post-bootstrap.
- SSH drop-ins: PermitRootLogin no; Match Group viewers enforces internal-sftp + ChrootDirectory.
- Sysctls: minimal hardening applied; logrotate rules for mongod and tool logs present.
- Systemd timers/services: backup, cert-rotate, monitor, vpn-lock watcher; Persistent=true; auto-restart policies on mongod.
- Continuous enforcement: drift re-applied on rerun; no-ops when compliant.


## 7) Mapping: blueprint.md → test cases (indicative)
- Onboarding one-liner HTTPS (single-use, TTL): onboarding.bats::onboarding_tunnel_single_use
- Initial encrypted backup pre-change: phases.bats::initial_backup_preflight
- VPN hardened + stealth + rate limits: vpn.bats::server_hardening; firewall.bats::stealth_and_rate_limits
- TLS required; x509-only; rotation: ssl.bats::ca_and_certs; rotation.bats::monthly_rotation
- WiredTiger + FCV + limits: mongodb.bats::hardened_config_and_fcv
- Roles/users/JIT: mongodb.bats::roles_dn_users_jit
- Allowed IP flags: e2e/allow-ip-flags.bats::single_ip_add_remove
- Rollback on unsafe change: failsafe.bats::rollback_on_invalid
- mongod auto-restart + timers persistent: system.bats::unit_auto_restart_and_timers
- Viewer chroot and human VPN roles: vpn.bats::viewer_chroot; system.bats::viewer_chroot_sshd


## 8) Gating and skip policy (inside container)
- Skip with reason only when strictly necessary (e.g., cloudflared cannot reach the internet; OpenVPN handshake tooling missing); all other dependencies are installed in the image.
- Skips emit clear TAP messages; diagnostics still captured.


## 9) CI strategy (Docker-only)
- Build a single test image (tests/Dockerfile) with all dependencies and systemd.
- Job runs the container with --privileged, mounted cgroups, and /dev/net/tun.
- Pipeline:
  1) Unit suites
  2) Integration suites (ssl, mongodb, firewall, backup, onboarding, vpn, rotation, monitoring)
  3) E2E suites (phases, rerun-idempotence, drift correction, flags, rollback)
- Collect artifacts via docker cp after completion.


## 10) Local execution (Docker-only)
- Build image and run:
```bash path=null start=null
# Build the image with all tools and systemd
DOCKER_BUILDKIT=1 docker build -t hms-test:latest -f tests/Dockerfile .

# Execute the whole test plan inside the container
./tests/run-in-docker.sh
```
Where run-in-docker.sh (in-repo helper) runs docker with the required flags and executes all BATS suites.


## 11) Risk and cleanup
- No host execution and no host mutation; everything lives and dies inside Docker.
- Deterministic teardown: stop services, save artifacts, exit 0/1 according to TAP results.
- Sensitive keys remain in the container; exported artifacts must redact secrets where applicable.


## 12) Repository structure (tests)
- tests/
  - Dockerfile (systemd base, all deps)
  - run-in-docker.sh (invokes the container, systemd, BATS)
  - run-all-bats.sh (executes suites in order; collects TAP)
  - helpers/{sandbox.bash, prereqs.bash, assertions.bash}
  - unit/{core.bats, logging.bats, system.bats, failsafe.bats}
  - integration/{ssl.bats, mongodb.bats, firewall.bats, backup.bats, onboarding.bats, vpn.bats, rotation.bats, monitoring.bats, system.bats}
  - e2e/{phases.bats, rerun-idempotence.bats, drift-correction.bats, allow-ip-flags.bats, rollback-negative.bats}
  - fixtures/{config.json, viewer-sshd-snippets.conf, sample-docs.json}

This blueprint is the sole source for test content and scope. It derives exclusively from docs/blueprint.md and intentionally includes advanced features (monitoring, viewer chroot, rate limiting, quotas, per-human VPN management). No stubs. All tests run inside Docker.
