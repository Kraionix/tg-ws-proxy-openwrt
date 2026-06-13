#!/bin/sh
# Network fixups for OpenWrt rootfs smoke tests (POSIX sh).
#
# Problem:
# - When booting OpenWrt rootfs "as a system" via /sbin/init, netifd may apply
#   a router-like default config (br-lan 192.168.1.1/24) and the container may
#   lose Docker-provided IPv4 + default route.
# - apk downloads then fail with uclient-fetch/wget exit code 4, "Operation not permitted",
#   and truncated files.
#
# Strategy A:
# - Detect missing default route inside container.
# - Derive IPv4/GW/MAC from `docker inspect` (host side).
# - Re-apply IPv4 + default route inside container, preferring br-lan if the
#   Docker veth is enslaved into it.
#
set -eu

docker_inspect_netinfo() {
  # Prints 4 lines to stdout:
  #   ip
  #   prefixlen
  #   gateway
  #   mac
  #
  # Avoid jq dependency: use python3 available on GitHub-hosted runners.
  docker inspect "$CTR" | python3 - <<'PY'
import json, sys

j = json.load(sys.stdin)[0]
nets = (j.get("NetworkSettings") or {}).get("Networks") or {}
net = next(iter(nets.values()), {}) if isinstance(nets, dict) else {}

ip = net.get("IPAddress") or ""
pref = net.get("IPPrefixLen")
gw = net.get("Gateway") or ""
mac = net.get("MacAddress") or ""

print(ip)
print("" if pref is None else pref)
print(gw)
print(mac)
PY
}

validate_ipv4() {
  # validate_ipv4 <ip>
  echo "${1:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

validate_prefixlen() {
  # validate_prefixlen <n>
  n="${1:-}"
  echo "$n" | grep -Eq '^[0-9]+$' || return 1
  [ "$n" -ge 1 ] && [ "$n" -le 32 ]
}

validate_mac() {
  echo "${1:-}" | grep -Eq '^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$'
}

ctr_has_default_route() {
  ctr_exec "ip -4 route show default 2>/dev/null | grep -q '^default '"
}

ensure_outbound_network() {
  log "NET: checking IPv4 default route inside container..."
  if ctr_has_default_route; then
    log "NET: default route OK."
    return 0
  fi

  warn "NET: default route missing; attempting Docker network fixup..."

  netinfo="$(docker_inspect_netinfo)"
  DOCKER_IP="$(printf '%s\n' "$netinfo" | sed -n '1p' | tr -d '\r' | head -n1)"
  DOCKER_PREFIXLEN="$(printf '%s\n' "$netinfo" | sed -n '2p' | tr -d '\r' | head -n1)"
  DOCKER_GW="$(printf '%s\n' "$netinfo" | sed -n '3p' | tr -d '\r' | head -n1)"
  DOCKER_MAC="$(printf '%s\n' "$netinfo" | sed -n '4p' | tr -d '\r' | head -n1)"

  validate_ipv4 "$DOCKER_IP" || die "NET: invalid Docker IPv4 from inspect: '$DOCKER_IP'"
  validate_prefixlen "$DOCKER_PREFIXLEN" || die "NET: invalid Docker prefixlen from inspect: '$DOCKER_PREFIXLEN'"
  validate_ipv4 "$DOCKER_GW" || die "NET: invalid Docker gateway from inspect: '$DOCKER_GW'"
  validate_mac "$DOCKER_MAC" || die "NET: invalid Docker MAC from inspect: '$DOCKER_MAC'"

  log "NET: docker inspect: ip=$DOCKER_IP/$DOCKER_PREFIXLEN gw=$DOCKER_GW mac=$DOCKER_MAC"

  # Apply fixup inside container.
  # Use stdin script to avoid brittle one-liners and quoting issues.
  ctr_exec_stdin "DOCKER_IP='$DOCKER_IP' DOCKER_PREFIXLEN='$DOCKER_PREFIXLEN' DOCKER_GW='$DOCKER_GW' DOCKER_MAC='$DOCKER_MAC' sh -s" <<'SH'
set -eu

ip="${DOCKER_IP:?}"
pref="${DOCKER_PREFIXLEN:?}"
gw="${DOCKER_GW:?}"
mac="$(printf '%s' "${DOCKER_MAC:?}" | tr 'A-F' 'a-f')"

# Find the interface carrying Docker's veth MAC. Fallback to eth0 if not found.
ifname="$(
  ip -o link 2>/dev/null \
    | awk -v mac="$mac" 'tolower($0) ~ mac { gsub(":", "", $2); print $2; exit }'
)"
[ -n "$ifname" ] || ifname="eth0"

# Choose where to put the L3 address:
# - If Docker veth is enslaved into br-lan, assign IPv4 to br-lan (bridge L3 is normal).
# - Otherwise, assign to the interface itself.
l3="$ifname"
if ip link show "$ifname" 2>/dev/null | grep -q "master br-lan"; then
  l3="br-lan"
fi

# Bring links up (best-effort).
ip link set dev "$ifname" up 2>/dev/null || true
ip link set dev "$l3" up 2>/dev/null || true

# Remove any existing IPv4 from the chosen L3 interface to avoid conflicts
# (e.g. default 192.168.1.1/24 on br-lan).
for cidr in $(ip -4 addr show dev "$l3" 2>/dev/null | awk '/inet /{print $2}'); do
  ip addr del "$cidr" dev "$l3" 2>/dev/null || true
done

# Apply Docker IPv4.
ip addr add "$ip/$pref" dev "$l3" 2>/dev/null || true

# Ensure default route exists.
ip route replace default via "$gw" dev "$l3" 2>/dev/null || {
  ip route del default 2>/dev/null || true
  ip route add default via "$gw" dev "$l3"
}

# Small debug dump (kept short; full dumps are collected as artifacts on failure).
ip -4 addr show dev "$l3" 2>/dev/null || true
ip -4 route show default 2>/dev/null || true
SH

  if ! ctr_has_default_route; then
    die "NET: fixup did not restore default route (still missing)."
  fi

  # Prefer not to hard-fail on ICMP in case of policy differences,
  # but this is a strong signal for Docker bridge health.
  if ! ctr_exec "ping -c 1 -W 1 '$DOCKER_GW' >/dev/null 2>&1"; then
    warn "NET: ping to Docker gateway failed; apk may still fail. Continuing to apk update to validate."
  else
    log "NET: ping to Docker gateway OK."
  fi

  log "NET: fixup complete."
}
