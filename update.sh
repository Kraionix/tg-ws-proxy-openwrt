#!/bin/sh
# update.sh
#
# Updater for tg-ws-proxy on OpenWrt.
#
# Responsibilities:
# - Ensure required packages are installed
# - Update upstream git source in /usr/lib/tg-ws-proxy (fast-forward)
# - Reinstall Python package via pip (no cache)
# - Update init script, runner, helper, and common library
# - Sync firewall rule port (DROP from WAN)
# - Warn if .env.example contains variables missing from /etc/tg-ws-proxy.env
#
set -eu

# Load common library (prefer installed copy, fallback to repo copy)
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

# Prevent concurrent install/update/uninstall
tgws_lock

TARGET_DIR="/usr/lib/tg-ws-proxy"
SRC="$(dirname "$0")/files"
CONFIG_FILE="/etc/tg-ws-proxy.env"
EXAMPLE_FILE="$SRC/etc/tg-ws-proxy.env.example"

log "Checking system dependencies..."
for pkg in ca-certificates python3 python3-pip git \
  procps-ng-pgrep \
  shadow-useradd shadow-groupadd shadow-usermod shadow-userdel shadow-groupdel
do
    if ! apk info -e "$pkg" >/dev/null 2>&1; then
        warn "Package $pkg is missing, installing..."
        apk -U add -q "$pkg"
    fi
done
ok "Dependencies are installed."

log "Updating tg-ws-proxy upstream source..."
if [ -d "$TARGET_DIR/.git" ]; then
    cd "$TARGET_DIR"
    git fetch origin
    git remote set-head origin -a 2>/dev/null || true
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse origin/HEAD)
    if [ "$LOCAL" != "$REMOTE" ]; then
        git merge --ff-only origin/HEAD
        ok "Upstream source updated (fast-forward)."
    else
        ok "Upstream source already up-to-date."
    fi
else
    err "$TARGET_DIR is not a git repository. Run install.sh first."
fi

log "Reinstalling Python package..."
cd "$TARGET_DIR"
PIP_DISABLE_PIP_VERSION_CHECK=1 \
python3 -m pip install --no-cache-dir . -q
ok "Python package updated."

log "Updating system files..."
TEMPLATE="$SRC/etc/init.d/tg-ws-proxy.in"
if [ -f "$TEMPLATE" ]; then
    cp "$TEMPLATE" /etc/init.d/tg-ws-proxy
    chmod 755 /etc/init.d/tg-ws-proxy
    ok "Init script updated."
else
    warn "Init template $TEMPLATE not found; init script left unchanged."
fi

# Install latest library
mkdir -p /usr/lib
cp "$SRC/lib/tg-ws-proxy-common.sh" /usr/lib/tg-ws-proxy-common.sh
chmod 644 /usr/lib/tg-ws-proxy-common.sh

# Install latest runner
mkdir -p /usr/libexec/tg-ws-proxy
cp "$SRC/usr/libexec/tg-ws-proxy/run.sh" /usr/libexec/tg-ws-proxy/run.sh
chmod 755 /usr/libexec/tg-ws-proxy/run.sh

# Install latest CLI helper
cp "$SRC/usr/bin/tg-ws-proxyctl" /usr/bin/tg-ws-proxyctl
chmod 755 /usr/bin/tg-ws-proxyctl

ok "System files updated."

# Sync firewall rule port with current config (if rule exists)
log "Syncing firewall rule..."
FIREWALL_RULE_NAME="Block tg-ws-proxy from WAN"
if uci show firewall | grep -q "name='$FIREWALL_RULE_NAME'"; then
    idx=$(uci show firewall | grep "name='$FIREWALL_RULE_NAME'" | head -n1 | cut -d'[' -f2 | cut -d']' -f1)
    if [ -n "$idx" ]; then
        # Load config to read TGWS_PORT
        if [ -f "$CONFIG_FILE" ]; then
          # shellcheck disable=SC1090
          . "$CONFIG_FILE"
        fi
        CUR_PORT=$(uci get firewall.@rule["$idx"].dest_port 2>/dev/null || echo "")
        if [ "${TGWS_PORT:-}" != "" ] && [ "$CUR_PORT" != "$TGWS_PORT" ]; then
            uci set firewall.@rule["$idx"].dest_port="$TGWS_PORT"
            uci commit firewall
            /etc/init.d/firewall reload
            ok "Firewall rule port updated to $TGWS_PORT."
        else
            ok "Firewall rule port is up-to-date."
        fi
    fi
else
    warn "Firewall rule not found. Run install.sh to create it."
fi

# Check for new variables in .env.example that are missing in current config
if [ -f "$EXAMPLE_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    # No bashisms and no temp files: use python3 to diff keys
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

new = keys(sys.argv[1])
cur = keys(sys.argv[2])

for k in sorted(new - cur):
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
