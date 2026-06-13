#!/bin/sh
# Diagnostics collection for smoke tests (POSIX sh).

set -eu

collect_artifacts() {
  mktempdir "$ARTIFACT_DIR"

  docker_logs_to_file "$ARTIFACT_DIR/docker.log"
  docker_inspect_to_file "$ARTIFACT_DIR/docker-inspect.json"

  ctr_best_effort_to_file "cat /proc/1/comm 2>/dev/null || true" "$ARTIFACT_DIR/proc1-comm.txt"
  ctr_best_effort_to_file "ps w || ps" "$ARTIFACT_DIR/ps.txt"

  # Network state (critical for apk issues)
  ctr_best_effort_to_file "ip link show || true" "$ARTIFACT_DIR/ip-link.txt"
  ctr_best_effort_to_file "ip -4 addr show || true" "$ARTIFACT_DIR/ip-addr.txt"
  ctr_best_effort_to_file "ip -4 route show || true" "$ARTIFACT_DIR/ip-route.txt"
  ctr_best_effort_to_file "ip rule show || true" "$ARTIFACT_DIR/ip-rule.txt"
  ctr_best_effort_to_file "cat /etc/resolv.conf 2>/dev/null || true" "$ARTIFACT_DIR/resolv.conf.txt"

  # OpenWrt network config/runtime
  ctr_best_effort_to_file "cat /etc/config/network 2>/dev/null || true" "$ARTIFACT_DIR/etc-config-network.txt"
  ctr_best_effort_to_file "ubus call network.interface dump 2>/dev/null || true" "$ARTIFACT_DIR/ubus-network-interface-dump.json"
  ctr_best_effort_to_file "logread 2>/dev/null || true" "$ARTIFACT_DIR/logread.txt"

  # Firewall state
  ctr_best_effort_to_file "uci show firewall 2>/dev/null || true" "$ARTIFACT_DIR/uci-firewall.txt"
  fw4_print_to_file "$ARTIFACT_DIR/fw4-print.txt"
  ctr_best_effort_to_file "nft list ruleset 2>/dev/null || true" "$ARTIFACT_DIR/nft-ruleset.txt"

  set +e
  ctr_capture "cat /etc/tg-ws-proxy.env 2>/dev/null || true" >"$ARTIFACT_DIR/tg-ws-proxy.env.raw" 2>/dev/null
  set -e
  redact_tgws_env "$ARTIFACT_DIR/tg-ws-proxy.env.raw" "$ARTIFACT_DIR/tg-ws-proxy.env"
}
