#!/bin/sh
# tg-ws-proxy-common.sh
#
# Common helper library for tg-ws-proxy OpenWrt scripts.
#
# This file is primarily meant to be sourced, but we keep a shebang to make
# tools like checkbashisms treat it as a shell script.
#
# Provides:
# - get_lan_ip(): best-effort LAN IP detection (for tg:// link generation)
# - tgws_lock()/tgws_unlock(): global lock to prevent concurrent install/update/uninstall
# - require_cmd(): fail fast if a required command is missing (helps with apk split packages)
# - In minimal/container OpenWrt environments, /lib/functions/lock.sh may be missing.
#   We provide a safe fallback lock implementation to keep scripts usable.
# - log/ok/warn/err: colored logging helpers
#

TGWS_LOCKFILE="/var/lock/tg-ws-proxy.lock"

get_lan_ip() {
  local ip
  ip=$(uci get network.lan.ipaddr 2>/dev/null) && [ -n "$ip" ] && {
    echo "$ip"
    return 0
  }
  ip=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1) && [ -n "$ip" ] && {
    echo "$ip"
    return 0
  }
  ip=$(ip -4 addr show lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1) && [ -n "$ip" ] && {
    echo "$ip"
    return 0
  }
  return 1
}

tgws_lock() {
  mkdir -p /var/lock 2>/dev/null || true

  if [ -f /lib/functions/lock.sh ]; then
    # shellcheck disable=SC1091
    . /lib/functions/lock.sh
    lock "$TGWS_LOCKFILE"
    trap 'tgws_unlock' EXIT INT TERM
    return 0
  fi

  # Fallback locking when OpenWrt lock helpers are not available (e.g. rootfs container).
  # Use an atomic mkdir-based lock directory next to the lockfile path.
  local lockdir
  lockdir="${TGWS_LOCKFILE}.d"

  if mkdir "$lockdir" 2>/dev/null; then
    echo "$$" >"${lockdir}/pid" 2>/dev/null || true
    trap 'tgws_unlock' EXIT INT TERM
    return 0
  fi

  err "Another tg-ws-proxy operation is already running (lock: $TGWS_LOCKFILE)."
}

tgws_unlock() {
  if command -v lock >/dev/null 2>&1; then
    lock -u "$TGWS_LOCKFILE" 2>/dev/null || true
  fi

  # Fallback lock cleanup (see tgws_lock()).
  rm -rf "${TGWS_LOCKFILE}.d" 2>/dev/null || true
}

require_cmd() {
  # Usage: require_cmd <cmd> [hint...]
  # Example: require_cmd pgrep "Install procps-ng-pgrep"
  local c="${1:-}"
  shift || true
  command -v "$c" >/dev/null 2>&1 || err "Missing command '$c'. ${*:-}"
}

INFO='\033[1;34m'
OK='\033[1;32m'
WARN='\033[1;33m'
ERR='\033[1;31m'
NC='\033[0m'

log() { echo -e "${INFO}[INFO]${NC} $*"; }
ok() { echo -e "${OK}[OK]${NC} $*"; }
warn() { echo -e "${WARN}[WARN]${NC} $*" >&2; }
err() {
  echo -e "${ERR}[ERROR]${NC} $*" >&2
  exit 1
}
