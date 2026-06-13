#!/bin/sh
#
# update.sh - updater for tg-ws-proxy deployment on OpenWrt
#
# - Ensures required packages exist (apk split packages)
# - Updates upstream source (origin/HEAD) OR pins to TGWS_GIT_REF if configured
# - Updates init script, runner, helper, and common library
# - Syncs firewall rule port (and migrates legacy rule name)
# - Warns if .env.example contains new keys missing in /etc/tg-ws-proxy.env
#
set -eu

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

[ "$(id -u)" -eq 0 ] || err "Run as root."

tgws_lock

apk_add_retry() {
  # Retry apk installs to reduce flakiness (transient network / mirror issues).
  # Usage: apk_add_retry <tries> <apk args...>
  tries="${1:-5}"
  shift || true

  i=1
  while :; do
    if apk -U add -q "$@"; then
      return 0
    fi
    if [ "$i" -ge "$tries" ]; then
      return 1
    fi
    warn "apk add failed (attempt $i/$tries). Retrying in 3s..."
    i=$((i + 1))
    sleep 3
  done
}

TARGET_DIR="/usr/lib/tg-ws-proxy"
SRC="$(dirname "$0")/files"
CONFIG_FILE="/etc/tg-ws-proxy.env"
EXAMPLE_FILE="$SRC/etc/tg-ws-proxy.env.example"

log "Checking dependencies..."
for pkg in ca-certificates python3 git \
  python3-cryptography \
  procps-ng-pgrep \
  shadow-useradd shadow-groupadd shadow-usermod shadow-userdel shadow-groupdel; do
  if ! apk info -e "$pkg" >/dev/null 2>&1; then
    warn "Missing package $pkg; installing..."
    apk_add_retry 5 "$pkg"
  fi
done
ok "Dependencies OK."

# Verify required commands (apk split packages can surprise you)
require_cmd apk
require_cmd git
require_cmd python3
require_cmd uci
require_cmd pgrep "Install: apk -U add procps-ng-pgrep"

[ -f "$CONFIG_FILE" ] || err "Missing config: $CONFIG_FILE"

# Load config (TGWS_PORT, TGWS_GIT_REF, etc.)
# shellcheck disable=SC1090
. "$CONFIG_FILE"

resolve_git_ref() {
  local ref="$1"
  git rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1 && {
    echo "$ref"
    return 0
  }
  git rev-parse --verify -q "origin/${ref}^{commit}" >/dev/null 2>&1 && {
    echo "origin/$ref"
    return 0
  }
  git rev-parse --verify -q "refs/tags/${ref}^{commit}" >/dev/null 2>&1 && {
    echo "refs/tags/$ref"
    return 0
  }
  return 1
}

log "Updating upstream source..."
if [ -d "$TARGET_DIR/.git" ]; then
  cd "$TARGET_DIR"
  git fetch --tags origin
  git remote set-head origin -a 2>/dev/null || true

  if [ -n "${TGWS_GIT_REF:-}" ]; then
    RESOLVED="$(resolve_git_ref "$TGWS_GIT_REF")" || err "TGWS_GIT_REF='$TGWS_GIT_REF' not found (commit/tag/branch)."
    git checkout -f "$RESOLVED"
    git reset --hard "$RESOLVED"
    ok "Upstream pinned to: $TGWS_GIT_REF ($RESOLVED)"
  else
    git reset --hard origin/HEAD
    ok "Upstream set to origin/HEAD."
  fi
else
  err "$TARGET_DIR is not a git repository. Run install.sh first."
fi

log "Validating upstream proxy entrypoint..."
if ! python3 /usr/lib/tg-ws-proxy/proxy/tg_ws_proxy.py --help >/dev/null 2>&1; then
  err "Upstream proxy failed to run after update (missing Python deps?)."
fi
ok "Upstream proxy entrypoint OK."

log "Updating system files..."
TEMPLATE="$SRC/etc/init.d/tg-ws-proxy.in"
if [ -f "$TEMPLATE" ]; then
  cp "$TEMPLATE" /etc/init.d/tg-ws-proxy
  chmod 755 /etc/init.d/tg-ws-proxy
  ok "Init script updated."
else
  warn "Init template not found: $TEMPLATE (keeping current init script)."
fi

mkdir -p /usr/lib
cp "$SRC/lib/tg-ws-proxy-common.sh" /usr/lib/tg-ws-proxy-common.sh
chmod 644 /usr/lib/tg-ws-proxy-common.sh

mkdir -p /usr/libexec/tg-ws-proxy
cp "$SRC/usr/libexec/tg-ws-proxy/run.sh" /usr/libexec/tg-ws-proxy/run.sh
chmod 755 /usr/libexec/tg-ws-proxy/run.sh

cp "$SRC/usr/bin/tg-ws-proxyctl" /usr/bin/tg-ws-proxyctl
chmod 755 /usr/bin/tg-ws-proxyctl

ok "System files updated."

log "Syncing firewall rule..."
FIREWALL_RULE_NAME="tg-ws-proxy: drop-wan"
LEGACY_FIREWALL_RULE_NAME="Block tg-ws-proxy from WAN"

find_rule_idx_by_name() {
  local name="$1"
  uci show firewall 2>/dev/null | sed -n "s/^firewall\\.\\@rule\\[\\([0-9]\\+\\)\\]\\.name='${name}'$/\\1/p" | head -n1
}

idx="$(find_rule_idx_by_name "$FIREWALL_RULE_NAME")"
if [ -z "$idx" ]; then
  idx="$(find_rule_idx_by_name "$LEGACY_FIREWALL_RULE_NAME")"
  if [ -n "$idx" ]; then
    uci set firewall.@rule["$idx"].name="$FIREWALL_RULE_NAME"
    ok "Legacy firewall rule found and renamed to '$FIREWALL_RULE_NAME'."
  fi
fi

if [ -n "$idx" ]; then
  CUR_PORT=$(uci get firewall.@rule["$idx"].dest_port 2>/dev/null || echo "")
  if [ "$CUR_PORT" != "$TGWS_PORT" ]; then
    uci set firewall.@rule["$idx"].dest_port="$TGWS_PORT"
    uci commit firewall
    /etc/init.d/firewall reload
    ok "Firewall rule port updated to $TGWS_PORT."
  else
    ok "Firewall rule port is up-to-date."
  fi
else
  warn "Firewall rule not found; creating it..."
  uci add firewall rule
  uci set firewall.@rule[-1].name="$FIREWALL_RULE_NAME"
  uci set firewall.@rule[-1].src='wan'
  uci set firewall.@rule[-1].proto='tcp'
  uci set firewall.@rule[-1].dest_port="$TGWS_PORT"
  uci set firewall.@rule[-1].target='DROP'
  uci commit firewall
  /etc/init.d/firewall reload
  ok "Firewall rule created (WAN->DROP) for port $TGWS_PORT."
fi

# Detect new keys in the example env that are missing in the actual config
if [ -f "$EXAMPLE_FILE" ]; then
  MISSING="$(
    python3 - "$EXAMPLE_FILE" "$CONFIG_FILE" <<'PY'
import re, sys
def keys(path):
    out=set()
    with open(path,'r',encoding='utf-8',errors='ignore') as f:
        for line in f:
            m=re.match(r'^([A-Z_]+)=', line)
            if m:
                out.add(m.group(1))
    return out
new=keys(sys.argv[1]); cur=keys(sys.argv[2])
for k in sorted(new-cur):
    print(k)
PY
  )"
  if [ -n "$MISSING" ]; then
    warn "New variables found in .env.example but missing in $CONFIG_FILE:"
    echo "$MISSING"
    warn "Please copy them from $EXAMPLE_FILE and restart the service."
  else
    ok "Config contains all current keys."
  fi
fi

log "Restarting service..."
/etc/init.d/tg-ws-proxy restart

if pgrep -f tg_ws_proxy.py >/dev/null; then
  ok "Service restarted successfully."
else
  err "Service did not start after update. Check logs: logread | grep tg-ws-proxy"
fi
