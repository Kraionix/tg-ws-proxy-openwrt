# tg-ws-proxy for OpenWrt (25.12+, apk)

A small deployment toolkit to install, update, manage, and remove
 on OpenWrt 25.12+ (apk).

## Features
- Runs the proxy as an unprivileged user `tgproxy` (via shadow split packages).
- procd supervision (`respawn`).
- procd reload triggers on UCI commits for `firewall` and `network` (reload = restart).
- Log file is created with correct ownership (respects `TGWS_LOG_FILE`).
- firewall4 (fw4 / nftables) safety for a **local** proxy:
  - a WAN->DROP rule is created for `TGWS_PORT`,
  - rule name is unique to reduce collisions,
  - legacy rule name is migrated automatically,
  - rule port is synced on service start.
- Idempotent install (safe to run multiple times).
- Full uninstall (optionally keep config).
- `tg-ws-proxyctl` helper utility:
  - service status/restart/log/stats,
  - generates Telegram client links (supports `dd-secret` and `ee-secret` / FakeTLS).
- Upstream pinning: lock upstream to a tag/commit/branch via `TGWS_GIT_REF`.

## Requirements
- OpenWrt **25.12 or newer** (package manager: **apk**).
- Internet access to install packages and clone upstream.
- Enough overlay space (git clone + pip).

## Quick install
1. Install git (if missing):
   ```sh
   apk -U add git
   ```

2. Clone this repository:
   ```sh
   git clone https://github.com/yourname/tg-ws-proxy-openwrt.git
   cd tg-ws-proxy-openwrt
   ```

3. Run the installer:
   ```sh
   chmod +x install.sh
   ./install.sh
   ```

   On first run it will create `/etc/tg-ws-proxy.env` with a random secret.

   You can provide your own secret:
   ```sh
   TGWS_SECRET=your_32_hex_secret ./install.sh
   ```

## Getting the Telegram link
For security/UX reasons, `install.sh` does **not** print the Telegram link automatically.
After install, run:

```sh
tg-ws-proxyctl link
```

(That link contains the secret as part of the URL, as expected by Telegram.)

## WAN note (this is a local proxy by default)
This toolkit creates a firewall4 rule that **drops TCP traffic from `wan` to `TGWS_PORT`**.

If you change `TGWS_PORT` and run:
```sh
service tg-ws-proxy restart
```
the init script will sync the firewall rule port automatically.

## Management
- `tg-ws-proxyctl status` – service status
- `tg-ws-proxyctl restart` – restart
- `tg-ws-proxyctl log` – follow log
- `tg-ws-proxyctl stats` – last stats line
- `tg-ws-proxyctl link` – print Telegram link

## Configuration
Configuration is stored in `/etc/tg-ws-proxy.env`.

### Environment variables

| Variable | Description | Default |
|---|---|---|
| `TGWS_HOST` | Bind address (IP or `0.0.0.0`) | `192.168.1.1` |
| `TGWS_PORT` | Listen port | `1443` |
| `TGWS_SECRET` | 32 hex chars (proxy secret) | generated |
| `TGWS_DC_IPS` | `DC:IP` pairs separated by spaces (optional) | `2:149.154.167.220 4:149.154.167.220` |
| `TGWS_LOG_FILE` | Log file path | `/var/log/tg-ws-proxy.log` |
| `TGWS_LOG_MAX_MB` | Max log size (MB) | `5` |
| `TGWS_LOG_BACKUPS` | Number of rotated files | `2` |
| `TGWS_VERBOSE` | Enable verbose (`-v`) | `false` |
| `TGWS_BUF_KB` | `--buf-kb` (socket buffer) | `256` |
| `TGWS_POOL_SIZE` | `--pool-size` | `4` |
| `TGWS_NO_CFPROXY` | `--no-cfproxy` disables CF fallback | `false` |
| `TGWS_CFPROXY_DOMAIN` | `--cfproxy-domain` (space-separated list) | empty |
| `TGWS_CFPROXY_WORKER_DOMAIN` | `--cfproxy-worker-domain` (space-separated list) | empty |
| `TGWS_FAKE_TLS_DOMAIN` | `--fake-tls-domain` (enables `ee-secret`) | empty |
| `TGWS_PROXY_PROTOCOL` | `--proxy-protocol` (v1) | `false` |
| `TGWS_GIT_REF` | Upstream pin (tag/commit/branch). Empty = upstream HEAD | empty |

After changing config:
```sh
tg-ws-proxyctl restart
```

## Update
Run from this repo directory:
```sh
./update.sh
```

If `TGWS_GIT_REF` is set, updates will keep the proxy pinned to that revision.

## Recovery after sysupgrade
This project backs up **only** `/etc/tg-ws-proxy.env` via `/etc/sysupgrade.conf`.

After `sysupgrade -k`, re-run:
```sh
./install.sh
```
It will reinstall packages/files while keeping your existing config.

## Important: do not use `apk upgrade` as a way to upgrade OpenWrt
OpenWrt is upgraded via **firmware images** (`sysupgrade`, Attended Sysupgrade, `owut`), not via a full
distro-style package upgrade.

- `apk upgrade` does not upgrade OpenWrt itself and does not replace sysupgrade.
- Mass-upgrading all packages can increase the chance of mismatches and conflicts.

Rule of thumb:
- Updating a few packages you installed yourself is usually fine.
- Use sysupgrade/ASU/owut to upgrade OpenWrt.

## CI / quality (lint gate)
This repo includes a GitHub Actions workflow that checks:
- shellcheck (POSIX sh),
- checkbashisms (bash-only syntax),
- shfmt (format).

## Local development (pre-commit)
This repo ships a local `pre-commit` setup to auto-format shell scripts with `shfmt`
before committing (and fix trivial whitespace issues).

One-time setup:
```sh
python3 -m pip install --user pre-commit
pre-commit install --install-hooks
```

Run on demand:
```sh
pre-commit run --all-files
```

## Uninstall
```sh
./uninstall.sh [--dry-run] [--keep-config] [--force]
```
- `--dry-run` – show planned actions without executing them
- `--keep-config` – keep `/etc/tg-ws-proxy.env`
- `--force` – remove without confirmation
```
