#!/bin/sh
# UCI/fw4 helpers for smoke tests (POSIX sh).

set -eu

fw_rule_find_idx_by_name() {
  # Prints the first firewall.@rule[index] that matches the given .name
  name="$1"
  ctr_capture "uci show firewall 2>/dev/null | sed -n \"s/^firewall\\\\.\\\\@rule\\\\[\\\\([0-9]\\\\+\\\\)\\\\]\\\\.name='${name}'\$/\\\\1/p\" | head -n1" \
    | tr -d '\r' | tail -n1
}

fw_rule_get_dest_port() {
  idx="$1"
  ctr_capture "uci get firewall.@rule[${idx}].dest_port 2>/dev/null || true" | tr -d '\r' | tail -n1
}

fw4_print_to_file() {
  # Capture fw4 print output (best-effort).
  # Usage: fw4_print_to_file /host/path
  out="$1"
  ctr_best_effort_to_file "fw4 print" "$out"
}
