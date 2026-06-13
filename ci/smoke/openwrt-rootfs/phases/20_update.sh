#!/bin/sh
# UPDATE phase: run update.sh and validate key invariants.

set -eu

phase_update() {
  log "UPDATE: running update.sh..."
  ctr_exec ". /root/smoke/smoke.env; cd /root/smoke/repo; ./update.sh"

  log "UPDATE: asserting config preserved..."
  assert_file_exists "/etc/tg-ws-proxy.env" "UPDATE: /etc/tg-ws-proxy.env missing after update"
  assert_stat_eq "/etc/tg-ws-proxy.env" "%a %U %G" "640 root tgproxy" "UPDATE: unexpected config permissions after update"

  log "UPDATE: asserting firewall UCI rule still consistent..."
  idx="$(fw_rule_find_idx_by_name "tg-ws-proxy: drop-wan")"
  [ -n "$idx" ] || die "UPDATE: firewall rule 'tg-ws-proxy: drop-wan' not found after update"

  dest_port="$(fw_rule_get_dest_port "$idx")"
  [ "$dest_port" = "1443" ] || die "UPDATE: firewall dest_port mismatch after update (expected 1443, got '$dest_port')"

  log "UPDATE: validating fw4 ruleset..."
  assert_ctr_contains "fw4 print 2>&1 || true" "Ruleset passes nftables check." "UPDATE: fw4 ruleset did not pass nftables check"

  log "UPDATE: OK."
}
