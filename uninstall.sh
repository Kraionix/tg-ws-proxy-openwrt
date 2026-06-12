#!/bin/sh
# uninstall.sh
#
# Uninstaller for tg-ws-proxy on OpenWrt.
#
# Removes:
# - procd service + init script
# - tgproxy user/group
# - upstream source directory /usr/lib/tg-ws-proxy
# - installed helper files:
#   /usr/libexec/tg-ws-proxy
#   /usr/bin/tg-ws-proxyctl
#   /usr/lib/tg-ws-proxy-common.sh
# - firewall rule
# - log file
#
# Options:
#   --dry-run     Print actions without executing them
#   --keep-config Keep /etc/tg-ws-proxy.env
#   --force       Do not ask for confirmation
#
set -eu

# Load common library (from system, fallback to repo for dry-run before installation)
if [ -f /usr/lib/tg-ws-proxy-common.sh ]; then
  # shellcheck disable=SC1091
  . /usr/lib/tg-ws-proxy-common.sh
else
  SRC_DIR="$(dirname "$0")/files"
  if [ -f "$SRC_DIR/lib/tg-ws-proxy-common.sh" ]; then
    # shellcheck disable=SC1090
    . "$SRC_DIR/lib/tg-ws-proxy-common.sh"
  else
    echo "Error: tg-ws-proxy-common.sh not found" >&2
    exit 1
  fi
fi

# Parse args
DRY_RUN=0
KEEP_CONFIG=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --keep-config) KEEP_CONFIG=1 ;;
        --force) FORCE=1 ;;
        *)
            echo "Usage: $0 [--dry-run] [--keep-config] [--force]" >&2
            exit 2
            ;;
    esac
done

[ "$(id -u)" -eq 0 ] || err "Run as root."

# Lock only for real removal
if [ "$DRY_RUN" -eq 0 ]; then
  tgws_lock
fi

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [DRY-RUN] $*"
    else
        "$@"
    fi
}

if [ "$DRY_RUN" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    echo -e "${WARN}WARNING: This will completely remove tg-ws-proxy, including:${NC}"
    echo "  - procd service and init script"
    echo "  - tgproxy user and group"
    echo "  - upstream source directory /usr/lib/tg-ws-proxy"
    echo "  - system files /usr/libexec/tg-ws-proxy, /usr/bin/tg-ws-proxyctl, /usr/lib/tg-ws-proxy-common.sh"
    echo "  - firewall4 rule"
    echo "  - logs /var/log/tg-ws-proxy.log"
    if [ "$KEEP_CONFIG" -eq 1 ]; then
        echo "  - configuration /etc/tg-ws-proxy.env will be KEPT"
    else
        echo "  - configuration /etc/tg-ws-proxy.env will be REMOVED"
    fi
    echo ""
    printf "Continue? (y/N): "
    read -r CONFIRM
    case "$CONFIRM" in
        y|Y) ;;
        *) err "Uninstall cancelled." ;;
    esac
fi

log "Stopping service..."
if [ -x /etc/init.d/tg-ws-proxy ]; then
    run /etc/init.d/tg-ws-proxy stop || true
    run /etc/init.d/tg-ws-proxy disable || true
    ok "Service stopped and disabled."
else
    ok "Init script not found; service not running."
fi

log "Removing firewall rules..."
FIREWALL_RULE_NAME="Block tg-ws-proxy from WAN"
while uci show firewall | grep -q "name='$FIREWALL_RULE_NAME'"; do
    RULE_INDEX=$(uci show firewall | grep "name='$FIREWALL_RULE_NAME'" | head -n1 | cut -d'[' -f2 | cut -d']' -f1)
    if [ -n "$RULE_INDEX" ]; then
        run uci delete firewall.@rule["$RULE_INDEX"]
    else
        break
    fi
done
run uci commit firewall
run /etc/init.d/firewall reload
ok "All firewall rules for tg-ws-proxy removed."

log "Removing user and group..."
if grep -q '^tgproxy:' /etc/passwd; then
    # If pgrep is available, ensure tgproxy processes are not running
    if [ "$DRY_RUN" -eq 0 ] && command -v pgrep >/dev/null 2>&1; then
        if pgrep -u tgproxy -f 'tg_ws_proxy\.py' >/dev/null 2>&1; then
            warn "Processes for user tgproxy are still running (tg_ws_proxy.py)."
            warn "Stop the service and try again."
            pgrep -a -u tgproxy -f 'tg_ws_proxy\.py' || true
            err "Uninstall aborted."
        fi
    fi
    run userdel tgproxy
    run groupdel tgproxy 2>/dev/null || true
    ok "User and group tgproxy removed."
else
    ok "User tgproxy does not exist."
fi

log "Cleaning sysupgrade.conf..."
if [ -f /etc/sysupgrade.conf ]; then
    # Remove only exact lines that we added
    SYSUPGRADE_ENTRIES="/etc/tg-ws-proxy.env"
    for entry in $SYSUPGRADE_ENTRIES; do
        escaped_entry=$(echo "$entry" | sed 's/[\/\.]/\\&/g')
        run sed -i "/^${escaped_entry}\$/d" /etc/sysupgrade.conf
    done
    ok "Removed entries from sysupgrade.conf."
else
    ok "sysupgrade.conf not present."
fi

if [ "$KEEP_CONFIG" -eq 1 ]; then
    log "Keeping config (--keep-config)..."
    ok "Config file /etc/tg-ws-proxy.env kept."
else
    log "Removing config file..."
    if [ -f /etc/tg-ws-proxy.env ]; then
        run rm -f /etc/tg-ws-proxy.env
        ok "Config file /etc/tg-ws-proxy.env removed."
    else
        ok "Config file not found."
    fi
fi

log "Removing system files..."
run rm -f /etc/init.d/tg-ws-proxy
run rm -rf /usr/libexec/tg-ws-proxy
run rm -f /usr/bin/tg-ws-proxyctl
run rm -f /usr/lib/tg-ws-proxy-common.sh
ok "System files removed."

log "Removing upstream source..."
if [ -d /usr/lib/tg-ws-proxy ]; then
    run rm -rf /usr/lib/tg-ws-proxy
    ok "Removed /usr/lib/tg-ws-proxy."
else
    ok "Upstream source directory not found."
fi

log "Removing log file..."
if [ -f /var/log/tg-ws-proxy.log ]; then
    run rm -f /var/log/tg-ws-proxy.log
    ok "Log file removed."
else
    ok "Log file not found."
fi

echo ""
echo -e "${OK}tg-ws-proxy uninstall completed.${NC}"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "This was a dry run. Run without --dry-run to actually remove."
fi
