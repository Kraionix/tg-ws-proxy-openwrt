#!/bin/sh
# INSTALL phase: run install.sh and validate key invariants.

set -eu

phase_install() {
  log "INSTALL: staging repo into container..."
  ctr_exec "mkdir -p /root/smoke/repo /root/smoke"

  docker cp "$REPO_ROOT/." "$CTR:/root/smoke/repo"
  docker cp "$SMOKE_DIR/config/env-test-defaults" "$CTR:/root/smoke/smoke.env"

  # Normalize line endings to LF. BusyBox sh may choke on CRLF env files.
  ctr_exec "tr -d '\r' </root/smoke/smoke.env >/root/smoke/smoke.env.lf && mv /root/smoke/smoke.env.lf /root/smoke/smoke.env"

  ctr_exec "cd /root/smoke/repo && chmod +x install.sh update.sh uninstall.sh"

  log "INSTALL: ensuring apk can reach repositories (apk update)..."
  ctr_exec "apk update >/dev/null"

  log "INSTALL: running install.sh..."
  ctr_exec ". /root/smoke/smoke.env; cd /root/smoke/repo; ./install.sh"

  log "INSTALL: asserting tgproxy user/group..."
  assert_ctr_ok "grep -q '^tgproxy:' /etc/passwd" "INSTALL: tgproxy user missing"
  assert_ctr_ok "grep -q '^tgproxy:' /etc/group" "INSTALL: tgproxy group missing"

  log "INSTALL: asserting config file exists and permissions..."
  assert_file_exists "/etc/tg-ws-proxy.env" "INSTALL: /etc/tg-ws-proxy.env missing"
  assert_stat_eq "/etc/tg-ws-proxy.env" "%a %U %G" "640 root tgproxy" "INSTALL: unexpected config permissions"

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
  [ "$dest_port" = "1443" ] || die "INSTALL: firewall dest_port mismatch (expected 1443, got '$dest_port')"

  log "INSTALL: validating fw4 ruleset via 'fw4 print'..."
  assert_ctr_contains "fw4 print 2>&1 || true" "Ruleset passes nftables check." "INSTALL: fw4 ruleset did not pass nftables check"

  log "INSTALL: OK."
}
