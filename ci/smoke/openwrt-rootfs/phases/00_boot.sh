#!/bin/sh
# BOOT phase: validate container booted "as OpenWrt system" (procd is PID 1).

set -eu

phase_boot() {
  log "BOOT: waiting for procd as PID 1..."
  if ! wait_for_procd_pid1 "${SMOKE_BOOT_TIMEOUT_SEC:-120}"; then
    die "BOOT: procd did not become PID 1 within timeout"
  fi
  log "BOOT: procd is PID 1."

  log "BOOT: checking required commands..."
  assert_ctr_ok "command -v apk >/dev/null" "BOOT: missing 'apk'"
  assert_ctr_ok "command -v uci >/dev/null" "BOOT: missing 'uci'"
  assert_ctr_ok "command -v fw4 >/dev/null" "BOOT: missing 'fw4'"
  assert_ctr_ok "command -v nft >/dev/null" "BOOT: missing 'nft'"
  assert_ctr_ok "command -v python3 >/dev/null" "BOOT: missing 'python3'"
  assert_ctr_ok "command -v git >/dev/null" "BOOT: missing 'git'"

  log "BOOT: OK."
}
