#!/bin/sh
# BOOT phase: validate container booted "as OpenWrt system".
# In containers, PID 1 may remain /sbin/init while procd runs as a child.

set -eu

phase_boot() {
  log "BOOT: waiting for OpenWrt init/procd readiness..."
  if ! wait_for_openwrt_ready "${SMOKE_BOOT_TIMEOUT_SEC:-120}"; then
    die "BOOT: OpenWrt did not become ready within timeout (init/procd)"
  fi
  log "BOOT: OpenWrt init/procd readiness OK."

  log "BOOT: checking required base commands..."
  assert_ctr_ok "command -v apk >/dev/null" "BOOT: missing 'apk'"
  assert_ctr_ok "command -v uci >/dev/null" "BOOT: missing 'uci'"
  assert_ctr_ok "command -v fw4 >/dev/null" "BOOT: missing 'fw4'"
  assert_ctr_ok "command -v nft >/dev/null" "BOOT: missing 'nft'"
  # python3/git are installed by install.sh via apk; do not require them at BOOT.

  log "BOOT: OK."
}
