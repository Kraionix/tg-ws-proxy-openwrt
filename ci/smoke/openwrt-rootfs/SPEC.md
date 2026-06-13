# OpenWrt rootfs smoke test (system-like, /sbin/init)

This smoke test runs this repository's deployment scripts against an OpenWrt
rootfs container image from GHCR:

- container entrypoint: `/sbin/init`
- readiness: PID 1 becomes `procd`
- phases: install -> update -> uninstall
- assertions: users/files/permissions/UCI firewall rule/fw4 ruleset validation

## Environment variables

Required:
- ROOTFS_IMAGE: Container image reference (tag or tag@digest).

Optional:
- SMOKE_CONTAINER_NAME: Override container name (default: auto-generated).
- SMOKE_BOOT_TIMEOUT_SEC: Readiness timeout for `procd` PID 1 (default: 120).
- SMOKE_ARTIFACT_DIR: Directory to write diagnostics into (default: $RUNNER_TEMP/...).

## What is validated

Required checks:
- `/proc/1/comm` inside container is `procd`
- `apk`, `uci`, `fw4`, `nft`, `python3`, `git` are present
- `install.sh` succeeds
- `tgproxy` user/group exist
- `/etc/tg-ws-proxy.env` exists with expected owner/group/mode
- key installed files exist and have executable bit where expected
- firewall UCI rule `tg-ws-proxy: drop-wan` exists and matches TGWS_PORT
- `fw4 print` passes nftables check (via `nft -c`)

Update checks:
- `update.sh` succeeds
- config file and permissions are preserved
- firewall rule is still consistent

Uninstall checks:
- `uninstall.sh --force` succeeds
- installed files are removed
- firewall UCI rule is removed
- `tgproxy` user/group are removed

## Diagnostics

On failure, the runner uploads a diagnostics bundle:
- docker logs / inspect
- `ps`, `/proc/1/comm`
- `uci show firewall`
- `fw4 print`
- redacted `/etc/tg-ws-proxy.env`
