# files/lib/tg-ws-proxy-common.sh
#
# Shared helper library for tg-ws-proxy OpenWrt scripts.
# Source it with:
#   . /path/to/tg-ws-proxy-common.sh
#
# Provides:
# - get_lan_ip(): best-effort LAN IP detection for generating Telegram links.
# - tgws_lock()/tgws_unlock(): global lock to prevent concurrent install/update/uninstall runs.
# - log/ok/warn/err: colored logging helpers.
#

TGWS_LOCKFILE="/var/lock/tg-ws-proxy.lock"

# Best-effort LAN IP detection (tries UCI, then common interfaces).
get_lan_ip() {
  local ip
  ip=$(uci get network.lan.ipaddr 2>/dev/null) && [ -n "$ip" ] && { echo "$ip"; return 0; }
  ip=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1) && [ -n "$ip" ] && { echo "$ip"; return 0; }
  ip=$(ip -4 addr show lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1) && [ -n "$ip" ] && { echo "$ip"; return 0; }
  return 1
}

# Global inter-process lock (prevents running install/update/uninstall concurrently).
tgws_lock() {
  mkdir -p /var/lock 2>/dev/null || true

  if [ -f /lib/functions/lock.sh ]; then
    # shellcheck disable=SC1091
    . /lib/functions/lock.sh
  else
    err "Missing /lib/functions/lock.sh (required for locking)."
  fi

  lock "$TGWS_LOCKFILE"
  # Always release lock on exit/signals
  trap 'tgws_unlock' EXIT INT TERM
}

tgws_unlock() {
  # lock -u is provided by /lib/functions/lock.sh
  if command -v lock >/dev/null 2>&1; then
    lock -u "$TGWS_LOCKFILE" 2>/dev/null || true
  fi
}

# Colored logging helpers
INFO='\033[1;34m'
OK='\033[1;32m'
WARN='\033[1;33m'
ERR='\033[1;31m'
NC='\033[0m'

log()  { echo -e "${INFO}[INFO]${NC} $*"; }
ok()   { echo -e "${OK}[OK]${NC} $*"; }
warn() { echo -e "${WARN}[WARN]${NC} $*" >&2; }
err()  { echo -e "${ERR}[ERROR]${NC} $*" >&2; exit 1; }
