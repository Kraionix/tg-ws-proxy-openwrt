#!/bin/sh
#
# uninstall.sh - remove tg-ws-proxy deployment from OpenWrt
#
# Options:
#   --dry-run     Show actions without executing them
#   --keep-config Keep /etc/tg-ws-proxy.env
#   --force       Do not ask for confirmation
#
set -eu

# Load common library (prefer installed, fallback to repo for dry-run before installation)
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
  echo -e "${WARN}WARNING: This will remove tg-ws-proxy entirely, including:${NC}"
  echo "  - procd service and init script"
  echo "  - tgproxy user and group"
  echo "  - upstream source directory /usr/lib/tg-ws-proxy"
  echo "  - system files (/usr/libexec/tg-ws-proxy, /usr/bin/tg-ws-proxyctl, /usr/lib/tg-ws-proxy-common.sh)"
  echo "  - firewall rule"
  echo "  - log files (default and TGWS_LOG_FILE if it looks like a tg-ws-proxy log path)"
  if [ "$KEEP_CONFIG" -eq 1 ]; then
    echo "  - config /etc/tg-ws-proxy.env will be KEPT"
  else
    echo "  - config /etc/tg-ws-proxy.env will be REMOVED"
  fi
  echo ""
  printf "Continue? (y/N): "
  read -r CONFIRM
  case "$CONFIRM" in
    y | Y) ;;
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
FIREWALL_RULE_NAME="tg-ws-proxy: drop-wan"
LEGACY_FIREWALL_RULE_NAME="Block tg-ws-proxy from WAN"

for NAME in "$FIREWALL_RULE_NAME" "$LEGACY_FIREWALL_RULE_NAME"; do
  while uci show firewall | grep -q "name='$NAME'"; do
    RULE_INDEX=$(uci show firewall | grep "name='$NAME'" | head -n1 | cut -d'[' -f2 | cut -d']' -f1)
    if [ -n "$RULE_INDEX" ]; then
      run uci delete firewall.@rule["$RULE_INDEX"]
    else
      break
    fi
  done
done

run uci commit firewall
run /etc/init.d/firewall reload
ok "Firewall rules removed."

log "Removing user and group..."
if grep -q '^tgproxy:' /etc/passwd; then
  # If pgrep exists, ensure tgproxy processes are not running
  if [ "$DRY_RUN" -eq 0 ] && command -v pgrep >/dev/null 2>&1; then
    if pgrep -u tgproxy -f 'tg_ws_proxy\.py' >/dev/null 2>&1; then
      warn "tgproxy processes are still running (tg_ws_proxy.py)."
      warn "Stop the service and try again."
      pgrep -a -u tgproxy -f 'tg_ws_proxy\.py' || true
      err "Uninstall aborted."
    fi
  fi
  run userdel tgproxy
  run groupdel tgproxy 2>/dev/null || true
  ok "User/group tgproxy removed."
else
  ok "User tgproxy does not exist."
fi

log "Cleaning sysupgrade.conf..."
if [ -f /etc/sysupgrade.conf ]; then
  SYSUPGRADE_ENTRIES="/etc/tg-ws-proxy.env"
  for entry in $SYSUPGRADE_ENTRIES; do
    escaped_entry=$(echo "$entry" | sed 's/[\/\.]/\\&/g')
    run sed -i "/^${escaped_entry}\$/d" /etc/sysupgrade.conf
  done
  ok "Removed entries from sysupgrade.conf."
else
  ok "sysupgrade.conf not present."
fi

# Log cleanup (supports custom TGWS_LOG_FILE safely)
log "Removing log file(s)..."
DEFAULT_LOG="/var/log/tg-ws-proxy.log"
CONFIG_LOG=""

if [ -f /etc/tg-ws-proxy.env ]; then
  # shellcheck disable=SC1091
  . /etc/tg-ws-proxy.env
  CONFIG_LOG="${TGWS_LOG_FILE:-}"
fi

remove_log_if_safe() {
  # Only delete files that match known tg-ws-proxy log patterns to avoid accidental deletions.
  local f="$1"
  [ -n "$f" ] || return 0

  case "$f" in
    /var/log/tg-ws-proxy*.log | /tmp/tg-ws-proxy*.log)
      if [ -f "$f" ]; then
        run rm -f "$f"
        ok "Removed log file: $f"
      else
        ok "Log file not found: $f"
      fi
      ;;
    *)
      warn "Skipping log removal for '$f' (path does not look like a tg-ws-proxy log)."
      ;;
  esac
}

remove_log_if_safe "$DEFAULT_LOG"
remove_log_if_safe "$CONFIG_LOG"

if [ "$KEEP_CONFIG" -eq 1 ]; then
  log "Keeping config (--keep-config)..."
  ok "Config file /etc/tg-ws-proxy.env kept."
else
  log "Removing config file..."
  if [ -f /etc/tg-ws-proxy.env ]; then
    run rm -f /etc/tg-ws-proxy.env
    ok "Removed /etc/tg-ws-proxy.env."
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

echo ""
echo -e "${OK}Uninstall completed.${NC}"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "This was a dry run. Run without --dry-run to actually remove."
fi
