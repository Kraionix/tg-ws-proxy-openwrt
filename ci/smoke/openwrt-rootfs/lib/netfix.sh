#!/bin/sh
# Network fixups for OpenWrt rootfs smoke tests (POSIX sh).
#
# Root cause analysis (three iterations):
#
# Iteration 1 — hypothesis: netifd hotplug → fw4 reload aborts TCP connections.
#   Status: DISPROVED. Shield was applied successfully but apk still failed.
#
# Iteration 2 — hypothesis: IPv6 link-local → uclient-fetch tries IPv6 → EPERM.
#   Status: DISPROVED. IPv6 was disabled via sysctl but apk still failed.
#   (smoke apk update works; install.sh apk -U add fails on package download.)
#
# Iteration 3 — confirmed root cause: netifd policy routing (ip rules).
#   When OpenWrt boots via /sbin/init, netifd configures br-lan with
#   192.168.1.1/24 and injects policy routing rules into the kernel
#   ("ip rule add from 192.168.1.0/24 lookup lan" etc.). When uclient-fetch
#   inside apk calls connect() to download package files, the kernel selects
#   192.168.1.1 (br-lan) as the source address. The policy rule routes this
#   traffic through the "lan" table, which has no default route to the Docker
#   gateway. The connect() fails with EADDRNOTAVAIL / EHOSTUNREACH, which
#   uclient-fetch surfaces as "Operation not permitted" / wget error 4.
#
#   This explains the asymmetry:
#   - smoke apk update (run directly via ctr_exec right after ensure_outbound_network)
#     succeeds because netifd has not yet finished injecting ip rules.
#   - install.sh apk -U add (run seconds later via a new ctr_exec) fails because
#     by then netifd has fully applied its policy routing table.
#
# Fix strategy (defence in depth):
#   A. disable_ipv6_in_container: kept from iteration 2 (belt-and-suspenders).
#   B. shield_firewall_hotplug: kept from iteration 1 (belt-and-suspenders).
#   C. ensure_outbound_network (extended):
#      1. Flush all policy routing rules and restore the single default lookup main.
#      2. Remove any IP addresses from br-lan to prevent it from being selected
#         as source address.
#      3. Verify Docker IPv4 is present on the correct L3 interface.
#      4. Verify source address selection via `ip route get 8.8.8.8`.
#      5. Run an actual HTTPS connectivity probe (wget against the OpenWrt
#         download server) to confirm apk will work before launching install.sh.
#
set -eu

# ---------------------------------------------------------------------------
# Fix A: disable IPv6 (kept from iteration 2)
# ---------------------------------------------------------------------------

disable_ipv6_in_container() {
  log "IPV6: disabling IPv6 on all interfaces (sysctl)..."
  ctr_exec "sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true"
  ctr_exec "sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true"
  ctr_exec "
    for iface in \$(ip -6 addr show 2>/dev/null \
        | awk '/^[0-9]+:/{gsub(\":\",\"\",\$2); print \$2}'); do
      ip -6 addr flush dev \"\$iface\" 2>/dev/null || true
    done
  "
  log "IPV6: IPv6 disabled and existing addresses flushed."
}

# ---------------------------------------------------------------------------
# Fix B: firewall hotplug shield (kept from iteration 1)
# ---------------------------------------------------------------------------

_HOTPLUG_FW="/etc/hotplug.d/iface/20-firewall"
_HOTPLUG_FW_DISABLED="/etc/hotplug.d/iface/20-firewall.smoke-disabled"

shield_firewall_hotplug() {
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
  if ctr_exec "[ -f '$_HOTPLUG_FW_DISABLED' ]" >/dev/null 2>&1; then
    ctr_exec "mv '$_HOTPLUG_FW_DISABLED' '$_HOTPLUG_FW'"
    log "FW-SHIELD: netifd→fw4 hotplug trigger restored."
  else
    log "FW-SHIELD: no shielded trigger to restore (noop)."
  fi
}

# ---------------------------------------------------------------------------
# Fix C: full network stabilisation (extended in iteration 3)
# ---------------------------------------------------------------------------

docker_inspect_netinfo() {
  # Prefer the default "bridge" network (common for `docker run` without --network).
  # Otherwise, fall back to the first attached network name.
  #
  # We intentionally avoid parsing JSON with python/heredoc here because stdin
  # redirections (heredoc) conflict with pipe-based input and can break in CI.
  net="$(
    docker inspect -f '{{with (index .NetworkSettings.Networks "bridge")}}bridge{{end}}' "$CTR" 2>/dev/null \
      | tr -d '\r' \
      | head -n1
  )"

  if [ -z "$net" ]; then
    net="$(
      docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$CTR" 2>/dev/null \
        | tr -d '\r' \
        | head -n1
    )"
  fi

  [ -n "$net" ] || die "NET: unable to determine Docker network name from inspect output"

  # Print 4 lines:
  #   1) IPAddress
  #   2) IPPrefixLen
  #   3) Gateway
  #   4) MacAddress
  #
  # Note: docker inspect supports Go templates via --format/-f.
  docker inspect -f "{{with (index .NetworkSettings.Networks \"${net}\")}}{{println .IPAddress}}{{println .IPPrefixLen}}{{println .Gateway}}{{println .MacAddress}}{{end}}" "$CTR" 2>/dev/null \
    | tr -d '\r'
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

flush_policy_routing() {
  # Flush all policy routing rules injected by netifd and restore the single
  # default rule: priority 32766 lookup main.
  # Without this, netifd's "from <lan-subnet> lookup lan" rules cause
  # source-address selection to route apk traffic through the "lan" table,
  # which has no default route to the Docker gateway → EHOSTUNREACH / EPERM.
  log "NET: flushing netifd policy routing rules (ip rule flush + restore default)..."
  ctr_exec "
    # Save and restore only the mandatory kernel rules (local=0, main=32766, default=32767).
    ip rule flush 2>/dev/null || true
    ip rule add priority 0   lookup local   2>/dev/null || true
    ip rule add priority 32766 lookup main  2>/dev/null || true
    ip rule add priority 32767 lookup default 2>/dev/null || true
  "
  log "NET: policy routing rules flushed and restored to kernel defaults."
}

remove_brl_an_addresses() {
  # Remove all IPv4 addresses from br-lan so that the kernel cannot select
  # 192.168.1.1 as a source address for outbound connections.
  # br-lan being addressless is fine for smoke purposes: we only need eth0
  # (the Docker veth) to have the Docker-assigned IP.
  log "NET: removing IPv4 addresses from br-lan (if any)..."
  ctr_exec "
    if ip link show br-lan >/dev/null 2>&1; then
      for cidr in \$(ip -4 addr show dev br-lan 2>/dev/null | awk '/inet /{print \$2}'); do
        ip addr del \"\$cidr\" dev br-lan 2>/dev/null || true
      done
    fi
  "
}

ensure_docker_ip_on_veth() {
  # Verify that the Docker-assigned IP is present on the correct interface.
  # If netifd removed it (by enslaving eth0 into br-lan and re-assigning L3),
  # re-apply it.
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

# Find the veth interface by MAC.
ifname="$(
  ip -o link 2>/dev/null \
    | awk -v mac="$mac" 'tolower($0) ~ mac { gsub(":", "", $2); print $2; exit }'
)"
[ -n "$ifname" ] || ifname="eth0"

# Always assign the Docker IP directly to the veth, not to br-lan.
# If the veth is enslaved into br-lan, bring br-lan down to release it,
# then bring the veth up standalone.
if ip link show "$ifname" 2>/dev/null | grep -q "master br-lan"; then
  ip link set dev br-lan down 2>/dev/null || true
fi

ip link set dev "$ifname" up 2>/dev/null || true

# Remove any addresses that may conflict.
for cidr in $(ip -4 addr show dev "$ifname" 2>/dev/null | awk '/inet /{print $2}'); do
  ip addr del "$cidr" dev "$ifname" 2>/dev/null || true
done

# Apply Docker IP to the veth directly.
ip addr add "$ip/$pref" dev "$ifname" 2>/dev/null || true

# Ensure default route via Docker gateway on the veth.
ip route replace default via "$gw" dev "$ifname" 2>/dev/null || {
  ip route del default 2>/dev/null || true
  ip route add default via "$gw" dev "$ifname"
}

echo "[smoke] NET: veth=$ifname ip=$ip/$pref gw=$gw"
ip -4 addr show dev "$ifname" 2>/dev/null || true
ip -4 route show default 2>/dev/null || true
SH
}

verify_source_address() {
  # Check that `ip route get 8.8.8.8` returns the Docker IP as src,
  # not 192.168.1.1 or any other br-lan address.
  log "NET: verifying source address selection for outbound traffic..."
  src="$(ctr_capture "ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if(\$i==\"src\") print \$(i+1)}'" \
    | tr -d '\r' | head -n1)"
  log "NET: ip route get 8.8.8.8 → src=$src"
  if [ -z "$src" ]; then
    die "NET: cannot determine source address for outbound traffic (no route to 8.8.8.8)"
  fi
  # Warn if br-lan default address is selected (routing will fail).
  case "$src" in
    192.168.1.*) warn "NET: source address $src looks like br-lan; apk may fail." ;;
    *) log "NET: source address $src looks correct." ;;
  esac
}

probe_https_connectivity() {
  # Run an actual HTTPS GET against the OpenWrt download server before
  # launching install.sh. This catches any remaining network misconfiguration
  # that would cause apk to fail, and gives a clear diagnostic message.
  probe_url="https://downloads.openwrt.org/releases/25.12.4/targets/x86/64/packages/packages.adb"
  log "NET: probing HTTPS connectivity to downloads.openwrt.org..."

  i=1
  while [ "$i" -le 5 ]; do
    if ctr_exec "uclient-fetch -q -O /dev/null '$probe_url' 2>/dev/null"; then
      log "NET: HTTPS probe OK (attempt $i)."
      return 0
    fi
    warn "NET: HTTPS probe failed (attempt $i/5); retrying in 3s..."
    i=$((i + 1))
    sleep 3
  done
  die "NET: HTTPS connectivity to downloads.openwrt.org failed after 5 attempts. \
Cannot proceed with apk downloads."
}

ensure_outbound_network() {
  log "NET: stabilising container network for apk downloads..."

  # Step 1: flush netifd policy routing rules.
  flush_policy_routing

  # Step 2: remove IP addresses from br-lan (prevent wrong source selection).
  remove_brl_an_addresses

  # Step 3: verify/restore Docker IP on the veth and default route.
  ensure_docker_ip_on_veth

  # Step 4: verify source address selection.
  verify_source_address

  # Step 5: HTTPS connectivity probe (fail fast with clear message).
  probe_https_connectivity

  log "NET: network stabilisation complete."
}
