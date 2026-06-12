# tg-ws-proxy for OpenWrt (25.12+, apk)

Automated deployment, update, recovery, and removal of `tg-ws-proxy`
on an OpenWrt router.

## Features
- Runs the proxy as an unprivileged user `tgproxy` (via shadow utils).
- Automatic restart via `procd` (`respawn`).
- Log file is created and gets correct permissions using `TGWS_LOG_FILE`.
- Protection from external connections via firewall4 (fw4 / nftables):
  a **DROP from WAN** rule is kept in sync with the current `TGWS_PORT` at service start.
- Idempotent installation (safe to run multiple times).
- Full removal of all components (optionally keep configuration).
- `tg-ws-proxyctl` helper utility to manage the service and generate Telegram links
  (supports `dd-secret` and `ee-secret` / FakeTLS).

## Requirements
- OpenWrt **25.12 or newer** (package manager: **apk**).
- Internet access to install packages and clone the upstream `tg-ws-proxy` repository.
- Enough free overlay space (git clone + pip).

## Quick install
1. Install git (if missing):
   ```sh
   apk -U add git
   ```
   (On OpenWrt 25.12+, the recommended pattern is `apk -U add ...`.)

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
   On the first run it will create `/etc/tg-ws-proxy.env` with a random secret.

   You can provide your own secret via an environment variable:
   ```sh
   TGWS_SECRET=your_secret ./install.sh
   ```

After installation, you will get a Telegram client link.

### Important note about WAN
This is a **local** proxy by default: the installer creates a firewall4 rule that blocks incoming connections
to the proxy port from the `wan` zone (DROP).

If you change `TGWS_PORT` and simply run `service tg-ws-proxy restart`, the init script will automatically
sync the firewall rule `dest_port` with the current port.

## Management
`tg-ws-proxyctl status` – show service status.  
`tg-ws-proxyctl restart` – restart the service.  
`tg-ws-proxyctl log` – follow log in real-time.  
`tg-ws-proxyctl stats` – show last stats entry from the log.  
`tg-ws-proxyctl link` – print the current Telegram client link.

## Configuration
Settings are stored in `/etc/tg-ws-proxy.env`.

### Environment variables

| Variable | Description | Default |
|---|---|---|
| `TGWS_HOST` | Bind address (IP or `0.0.0.0`) | `192.168.1.1` |
| `TGWS_PORT` | Listen port | `1443` |
| `TGWS_SECRET` | 32 hex chars (proxy secret) | generated |
| `TGWS_DC_IPS` | `DC:IP` pairs separated by spaces (optional) | `2:149.154.167.220 4:149.154.167.220` |
| `TGWS_LOG_FILE` | Log file path | `/var/log/tg-ws-proxy.log` |
| `TGWS_LOG_MAX_MB` | Max log size (MB) | `5` |
| `TGWS_LOG_BACKUPS` | Number of rotated log files | `2` |
| `TGWS_VERBOSE` | Enable verbose logging (`-v`) | `false` |
| `TGWS_BUF_KB` | `--buf-kb` (socket buffer) | `256` |
| `TGWS_POOL_SIZE` | `--pool-size` | `4` |
| `TGWS_NO_CFPROXY` | `--no-cfproxy` disables CF fallback | `false` |
| `TGWS_CFPROXY_DOMAIN` | `--cfproxy-domain` (space-separated list) | empty |
| `TGWS_CFPROXY_WORKER_DOMAIN` | `--cfproxy-worker-domain` (space-separated list) | empty |
| `TGWS_FAKE_TLS_DOMAIN` | `--fake-tls-domain` (enables `ee-secret`) | empty |
| `TGWS_PROXY_PROTOCOL` | `--proxy-protocol` (v1) | `false` |

After changing the configuration:
```sh
tg-ws-proxyctl restart
```

## Update
To update `tg-ws-proxy` and service files, run from the repository directory:
```sh
./update.sh
```
This script updates the upstream source code, the Python package, system files, and the firewall rule.
If new variables appear in `.env.example`, the script will warn you.

## Recovery after sysupgrade
This project backs up **only** `/etc/tg-ws-proxy.env` via `/etc/sysupgrade.conf`.

After `sysupgrade -k` the config will be restored, but packages/sources/system files must be installed again —
so simply re-run `install.sh` (it is idempotent and will not overwrite your config).

## Important: do not use `apk upgrade` as a way to “upgrade OpenWrt”
OpenWrt is upgraded via **firmware images** (image-based) using `sysupgrade` (or Attended Sysupgrade / `owut`),
not by doing a full distro-style package upgrade.

Why:
- `apk upgrade` (and previously `opkg upgrade`) **does not upgrade OpenWrt itself** and is not a replacement for sysupgrade.
- `sysupgrade` backs up selected configs, replaces the root filesystem with a new OpenWrt version, and restores configs.
  That is the recommended way to keep the system consistent.

Practical rule of thumb:
- Upgrading a few packages you installed yourself (luci-app-*, utilities) is usually fine.
- Doing a “mass” `apk upgrade` of everything without a clear need can increase the risk of version mismatches and conflicts,
  and it does not replace sysupgrade anyway.

## Uninstall
```sh
./uninstall.sh [--dry-run] [--keep-config] [--force]
```
- `--dry-run` – print planned actions without executing them.
- `--keep-config` – keep `/etc/tg-ws-proxy.env`.
- `--force` – remove without confirmation.
