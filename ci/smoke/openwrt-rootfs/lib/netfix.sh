#!/bin/sh
# Network fixups for OpenWrt rootfs smoke tests (POSIX sh).
#
# Root cause (confirmed by OpenWrt issue #12138):
#   uclient-fetch (used by apk) calls getaddrinfo() which returns both A and
#   AAAA records. Docker automatically assigns an IPv6 link-local address
#   (fe80::/64) to every veth interface via kernel autoconfiguration. There is
#   no IPv6 default route and no IPv6 uplink. uclient-fetch attempts a
#   connect() to the global IPv6 address; this fails with EPERM because either:
#     (a) OpenWrt's nftables OUTPUT chain (loaded by fw4 at boot) blocks
#         unrouted IPv6 egress, or
#     (b) the kernel's own IPv6 source-address selection picks the link-local
#         address and the connect() fails immediately for global destinations.
#   Symptom: "Failed to send request: Operation not permitted" / wget error 4.
#   Confirmed fix: disable IPv6 on all interfaces → uclient-fetch falls back
#   to IPv4-only DNS and connect().
#
# Fix A — disable_ipv6:
#   Set net.ipv6.conf.all.disable_ipv6=1 and net.ipv6.conf.default.disable_ipv6=1
#   via sysctl inside the container. This removes all IPv6 addresses from all
#   interfaces and prevents new link-local addresses from being assigned.
#   uclient-fetch then resolves only A records and connects over IPv4.
#
# Fix B — shield_firewall_hotplug / unshield_firewall_hotplug:
#   Kept as a belt-and-suspenders measure. Renames the netifd→fw4 hotplug
#   trigger so IFUP/IFUPDATE events cannot reload nftables mid-download.
#   (This was the primary fix in the previous iteration; it alone was
#   insufficient because the IPv6 issue is independent of nftables state.)
#
# Fix C — ensure_outbound_network:
#   Detects a missing IPv4 default route (netifd may clobber it with a
#   router-like br-lan config) and re-applies Docker networking from
#   `docker inspect` output.
#
set -eu

# ---------------------------------------------------------------------------
# Fix A: disable IPv6 inside the container
# ---------------------------------------------------------------------------

disable_ipv6_in_container() {
  # Disable IPv6 kernel stack on all current and future interfaces.
  # This is the primary fix for uclient-fetch "Operation not permitted":
  # with no IPv6 addresses, getaddrinfo returns only A records and
  # uclient-fetch never attempts an IPv6 connect().
  #
  # sysctl is available on OpenWrt (busybox applet).
  # The container runs with --privileged so sysctl writes are permitted.
  log "IPV6: disabling IPv6 on all interfaces (sysctl)..."

  ctr_exec "sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true"
  ctr_exec "sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true"

  # Also flush any existing IPv6 addresses that were already assigned
  # before the sysctl took effect (e.g. link-local on eth0/br-lan).
  ctr_exec "
    for iface in \$(ip -6 addr show 2>/dev/null \
        | awk '/^[0-9]+:/{gsub(\":\",\"\",\$2); print \$2}'); do
      ip -6 addr flush dev \"\$iface\" 2>/dev/null || true
    done
  "

  log "IPV6: IPv6 disabled and existing addresses flushed."
}

# ---------------------------------------------------------------------------
# Fix B: firewall hotplug shield (belt-and-suspenders)
# ---------------------------------------------------------------------------

_HOTPLUG_FW="/etc/hotplug.d/iface/20-firewall"
_HOTPLUG_FW_DISABLED="/etc/hotplug.d/iface/20-firewall.smoke-disabled"

shield_firewall_hotplug() {
  # Rename the netifd→fw4 hotplug trigger to prevent IFUP/IFUPDATE events
  # from reloading nftables and aborting in-flight TCP connections.
  if ctr_exec "[ -f '$_HOTPLUG_FW' ]" >/dev/null 2>&1; then
    ctr_exec "mv '$_HOTPLUG_FW' '$_HOTPLUG_FW_DISABLED'"
    log "FW-SHIELD: netifd→fw4 hotplug trigger disabled (renamed to .smoke-disabled)."
  elif ctr_exec "[ -f '$_HOTPLUG_FW_DISABLED' ]" >/dev/null 2>&1; then
    log "FW-SHIELD: hotplug trigger already shielded (noop)."
  else
    log "FW-SHIELD: hotplug trigger not present in image (noop)."
  fi
}

unshield_firewall_hotplug() {
  # Restore the hotplug trigger after all network I/O is complete.
  if ctr_exec "[ -f '$_HOTPLUG_FW_DISABLED' ]" >/dev/null 2>&1; then
    ctr_exec "mv '$_HOTPLUG_FW_DISABLED' '$_HOTPLUG_FW'"
    log "FW-SHIELD: netifd→fw4 hotplug trigger restored."
  else
    log "FW-SHIELD: no shielded trigger to restore (noop)."
  fi
}

# ---------------------------------------------------------------------------
# Fix C: Docker default route recovery
# ---------------------------------------------------------------------------

docker_inspect_netinfo() {
  # Prints 4 lines to stdout: ip / prefixlen / gateway / mac
  # Uses python3 (available on GitHub-hosted runners) to avoid jq dependency.
  docker inspect "$CTR" | python3 - <<'PY'
import json, sys

j = json.load(sys.stdin)[0]
nets = (j.get("NetworkSettings") or {}).get("Networks") or {}
net = next(iter(nets.values()), {}) if isinstance(nets, dict) else {}

ip   = net.get("IPAddress") or ""
pref = net.get("IPPrefixLen")
gw   = net.get("Gateway") or ""
mac  = net.get("MacAddress") or ""

print(ip)
print("" if pref is None else pref)
print(gw)
print(mac)
PY
}

validate_ipv4() {
  echo "${1:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

validate_prefixlen() {
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
  validate_prefixlen "$DOCKER_PREFIXLEN" \
    || die "NET: invalid Docker prefixlen from inspect: '$DOCKER_PREFIXLEN'"
  validate_ipv4 "$DOCKER_GW" || die "NET: invalid Docker gateway from inspect: '$DOCKER_GW'"
  validate_mac "$DOCKER_MAC" || die "NET: invalid Docker MAC from inspect: '$DOCKER_MAC'"

  log "NET: docker inspect: ip=$DOCKER_IP/$DOCKER_PREFIXLEN gw=$DOCKER_GW mac=$DOCKER_MAC"

  ctr_exec_stdin \
    "DOCKER_IP='$DOCKER_IP' DOCKER_PREFIXLEN='$DOCKER_PREFIXLEN' \
     DOCKER_GW='$DOCKER_GW' DOCKER_MAC='$DOCKER_MAC' sh -s" <<'SH'
set -eu

ip="${DOCKER_IP:?}"
pref="${DOCKER_PREFIXLEN:?}"
gw="${DOCKER_GW:?}"
mac="$(printf '%s' "${DOCKER_MAC:?}" | tr 'A-F' 'a-f')"

# Find the interface carrying Docker's veth MAC; fallback to eth0.
ifname="$(
  ip -o link 2>/dev/null \
    | awk -v mac="$mac" 'tolower($0) ~ mac { gsub(":", "", $2); print $2; exit }'
)"
[ -n "$ifname" ] || ifname="eth0"

# Prefer br-lan for L3 assignment if the veth is enslaved into it.
l3="$ifname"
if ip link show "$ifname" 2>/dev/null | grep -q "master br-lan"; then
  l3="br-lan"
fi

ip link set dev "$ifname" up 2>/dev/null || true
ip link set dev "$l3" up 2>/dev/null || true

# Remove conflicting IPv4 addresses (e.g. default 192.168.1.1/24 on br-lan).
for cidr in $(ip -4 addr show dev "$l3" 2>/dev/null | awk '/inet /{print $2}'); do
  ip addr del "$cidr" dev "$l3" 2>/dev/null || true
done

ip addr add "$ip/$pref" dev "$l3" 2>/dev/null || true

ip route replace default via "$gw" dev "$l3" 2>/dev/null || {
  ip route del default 2>/dev/null || true
  ip route add default via "$gw" dev "$l3"
}

ip -4 addr show dev "$l3" 2>/dev/null || true
ip -4 route show default 2>/dev/null || true
SH

  if ! ctr_has_default_route; then
    die "NET: fixup did not restore default route (still missing)."
  fi

  if ! ctr_exec "ping -c 1 -W 1 '$DOCKER_GW' >/dev/null 2>&1"; then
    warn "NET: ping to Docker gateway failed; apk may still fail. Continuing."
  else
    log "NET: ping to Docker gateway OK."
  fi

  log "NET: fixup complete."
}
