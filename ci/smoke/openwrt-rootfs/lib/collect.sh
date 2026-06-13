#!/bin/sh
# Diagnostics collection for smoke tests (POSIX sh).

set -eu

collect_artifacts() {
  mktempdir "$ARTIFACT_DIR"

  docker_logs_to_file "$ARTIFACT_DIR/docker.log"
  docker_inspect_to_file "$ARTIFACT_DIR/docker-inspect.json"

  ctr_best_effort_to_file "cat /proc/1/comm 2>/dev/null || true" "$ARTIFACT_DIR/proc1-comm.txt"
  ctr_best_effort_to_file "ps w || ps" "$ARTIFACT_DIR/ps.txt"

  ctr_best_effort_to_file "uci show firewall 2>/dev/null || true" "$ARTIFACT_DIR/uci-firewall.txt"
  fw4_print_to_file "$ARTIFACT_DIR/fw4-print.txt"

  set +e
  ctr_capture "cat /etc/tg-ws-proxy.env 2>/dev/null || true" >"$ARTIFACT_DIR/tg-ws-proxy.env.raw" 2>/dev/null
  set -e
  redact_tgws_env "$ARTIFACT_DIR/tg-ws-proxy.env.raw" "$ARTIFACT_DIR/tg-ws-proxy.env"
}
