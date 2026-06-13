#!/bin/sh
# INSTALL phase: run install.sh and validate key invariants.
#
# Network stability strategy (iteration 3 — policy routing fix):
#   1. Stop firewall service and flush nft ruleset.
#   2. Disable IPv6 (prevents uclient-fetch IPv6 attempt on IPv4-only uplink).
#   3. Shield netifd→fw4 hotplug trigger (prevents nftables reload mid-download).
#   4. Stabilise container network:
#      a. Flush netifd policy routing rules (ip rule) — PRIMARY FIX for EPERM.
#      b. Remove IPv4 addresses from br-lan (prevents wrong source selection).
#      c. Verify/restore Docker IP on veth and default route.
#      d. Verify source address via `ip route get 8.8.8.8`.
#      e. HTTPS connectivity probe against downloads.openwrt.org.
#   5. Run smoke-controlled apk update (belt-and-suspenders retry).
#   6. Run install.sh.
#   7. Unshield hotplug trigger.
#   8. Post-install assertions.

set -eu

phase_install() {
  log "INSTALL: staging repo into container..."
  ctr_exec "mkdir -p /root/smoke/repo /root/smoke"

  docker cp "$REPO_ROOT/." "$CTR:/root/smoke/repo"
  docker cp "$SMOKE_DIR/config/env-test-defaults" "$CTR:/root/smoke/smoke.env"

  # Normalise line endings to LF; BusyBox sh chokes on CRLF env files.
  ctr_exec "tr -d '\r' </root/smoke/smoke.env >/root/smoke/smoke.env.lf \
    && mv /root/smoke/smoke.env.lf /root/smoke/smoke.env"

  ctr_exec "cd /root/smoke/repo && chmod +x install.sh update.sh uninstall.sh"

  # --- Network preparation (ordered; see netfix.sh for rationale) ---------

  log "INSTALL: stopping firewall service and flushing nft ruleset..."
  ctr_exec "/etc/init.d/firewall stop >/dev/null 2>&1 || true"
  ctr_exec "nft flush ruleset >/dev/null 2>&1 || true"

  disable_ipv6_in_container
  shield_firewall_hotplug
  ensure_outbound_network   # flush ip rules + br-lan cleanup + probe

  # --- apk update (smoke-controlled, with retry) --------------------------

  log "INSTALL: syncing apk package index (apk update, up to 5 attempts)..."
  ctr_exec '
    i=1
    while :; do
      if apk update >/dev/null 2>&1; then
        exit 0
      fi
      [ "$i" -ge 5 ] && break
      echo "[smoke] apk update failed (attempt $i/5); retrying in 3s..." >&2
      i=$((i + 1))
      sleep 3
    done
    echo "[smoke] apk update failed after 5 attempts" >&2
    exit 1
  '

  # --- install.sh ---------------------------------------------------------

  log "INSTALL: running install.sh..."
  ctr_exec ". /root/smoke/smoke.env; cd /root/smoke/repo; ./install.sh"

  log "INSTALL: restoring netifd→fw4 hotplug trigger..."
  unshield_firewall_hotplug

  # --- Post-install assertions --------------------------------------------

  log "INSTALL: asserting tgproxy user/group..."
  assert_ctr_ok "grep -q '^tgproxy:' /etc/passwd" "INSTALL: tgproxy user missing"
  assert_ctr_ok "grep -q '^tgproxy:' /etc/group" "INSTALL: tgproxy group missing"

  log "INSTALL: asserting config file exists and permissions..."
  assert_file_exists "/etc/tg-ws-proxy.env" "INSTALL: /etc/tg-ws-proxy.env missing"
  assert_stat_eq "/etc/tg-ws-proxy.env" "%a %U %G" "640 root tgproxy" \
    "INSTALL: unexpected config permissions"

  log "INSTALL: asserting installed files..."
  assert_file_exists "/etc/init.d/tg-ws-proxy" "INSTALL: init script not installed"
  assert_executable "/etc/init.d/tg-ws-proxy" "INSTALL: init script not executable"

  assert_file_exists "/usr/libexec/tg-ws-proxy/run.sh" "INSTALL: runner not installed"
  assert_executable "/usr/libexec/tg-ws-proxy/run.sh" "INSTALL: runner not executable"

  assert_file_exists "/usr/bin/tg-ws-proxyctl" "INSTALL: tg-ws-proxyctl not installed"
  assert_executable "/usr/bin/tg-ws-proxyctl" "INSTALL: tg-ws-proxyctl not executable"

  assert_file_exists "/usr/lib/tg-ws-proxy-common.sh" "INSTALL: common lib not installed"

  log "INSTALL: asserting firewall UCI rule..."
  idx="$(fw_rule_find_idx_by_name "tg-ws-proxy: drop-wan")"
  [ -n "$idx" ] || die "INSTALL: firewall rule 'tg-ws-proxy: drop-wan' not found"

  dest_port="$(fw_rule_get_dest_port "$idx")"
  [ "$dest_port" = "1443" ] || \
    die "INSTALL: firewall dest_port mismatch (expected 1443, got '$dest_port')"

  log "INSTALL: validating fw4 ruleset via 'fw4 print'..."
  assert_ctr_contains "fw4 print 2>&1 || true" \
    "Ruleset passes nftables check." \
    "INSTALL: fw4 ruleset did not pass nftables check"

  log "INSTALL: OK."
}
