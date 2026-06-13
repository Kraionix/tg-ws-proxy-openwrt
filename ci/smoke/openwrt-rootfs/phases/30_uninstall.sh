#!/bin/sh
# UNINSTALL phase: run uninstall.sh and validate removal.

set -eu

phase_uninstall() {
  log "UNINSTALL: running uninstall.sh..."
  ctr_exec "cd /root/smoke/repo; ./uninstall.sh --force"

  log "UNINSTALL: asserting files removed..."
  assert_file_not_exists "/etc/init.d/tg-ws-proxy" "UNINSTALL: init script still present"
  assert_file_not_exists "/usr/libexec/tg-ws-proxy" "UNINSTALL: libexec dir still present"
  assert_file_not_exists "/usr/bin/tg-ws-proxyctl" "UNINSTALL: tg-ws-proxyctl still present"
  assert_file_not_exists "/usr/lib/tg-ws-proxy-common.sh" "UNINSTALL: common lib still present"
  assert_file_not_exists "/usr/lib/tg-ws-proxy" "UNINSTALL: upstream dir still present"

  log "UNINSTALL: asserting firewall rule removed..."
  if fw_rule_find_idx_by_name "tg-ws-proxy: drop-wan" | grep -q '[0-9]'; then
    die "UNINSTALL: firewall rule still present"
  fi

  log "UNINSTALL: asserting tgproxy user/group removed..."
  if ctr_exec "grep -q '^tgproxy:' /etc/passwd" >/dev/null 2>&1; then
    die "UNINSTALL: tgproxy user still present"
  fi
  if ctr_exec "grep -q '^tgproxy:' /etc/group" >/dev/null 2>&1; then
    die "UNINSTALL: tgproxy group still present"
  fi

  log "UNINSTALL: OK."
}
