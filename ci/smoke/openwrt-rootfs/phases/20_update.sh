#!/bin/sh
# UPDATE phase: run update.sh and validate key invariants.
#
# update.sh performs git fetch (network I/O) and may call apk add for missing
# packages. Apply the same network fixups as the install phase:
#   - IPv6 was already disabled in the install phase (sysctl persists for the
#     container lifetime); no need to disable again.
#   - Shield the netifd→fw4 hotplug trigger for the duration of update.sh to
#     prevent any late IFUP events from reloading nftables mid-download.

set -eu

phase_update() {
  # Shield before update.sh starts network operations (git fetch, apk).
  log "UPDATE: shielding netifd→fw4 hotplug trigger..."
  shield_firewall_hotplug

  log "UPDATE: running update.sh..."
  ctr_exec ". /root/smoke/smoke.env; cd /root/smoke/repo; ./update.sh"

  # Restore hotplug trigger before assertions so fw4 state is normal.
  log "UPDATE: restoring netifd→fw4 hotplug trigger..."
  unshield_firewall_hotplug

  log "UPDATE: asserting config preserved..."
  assert_file_exists "/etc/tg-ws-proxy.env" \
    "UPDATE: /etc/tg-ws-proxy.env missing after update"
  assert_stat_eq "/etc/tg-ws-proxy.env" "%a %U %G" "640 root tgproxy" \
    "UPDATE: unexpected config permissions after update"

  log "UPDATE: asserting firewall UCI rule still consistent..."
  idx="$(fw_rule_find_idx_by_name "tg-ws-proxy: drop-wan")"
  [ -n "$idx" ] || die "UPDATE: firewall rule 'tg-ws-proxy: drop-wan' not found after update"

  dest_port="$(fw_rule_get_dest_port "$idx")"
  [ "$dest_port" = "1443" ] || \
    die "UPDATE: firewall dest_port mismatch after update (expected 1443, got '$dest_port')"

  log "UPDATE: validating fw4 ruleset..."
  assert_ctr_contains "fw4 print 2>&1 || true" \
    "Ruleset passes nftables check." \
    "UPDATE: fw4 ruleset did not pass nftables check"

  log "UPDATE: OK."
}
