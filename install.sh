#!/bin/sh
# install.sh
#
# Idempotent installer for tg-ws-proxy on OpenWrt 25.12+ (apk).
#
# Responsibilities:
# - Install required packages via apk
# - Create unprivileged user/group tgproxy (shadow utils)
# - Clone/update upstream tg-ws-proxy into /usr/lib/tg-ws-proxy
# - Install Python package via pip (without cache to reduce flash writes)
# - Create /etc/tg-ws-proxy.env if missing (with generated secret)
# - Install init script, runner, and helper utility
# - Create firewall4 DROP-from-WAN rule for TGWS_PORT
# - Add /etc/tg-ws-proxy.env to /etc/sysupgrade.conf for backup
# - Enable and start the service
#
set -eu

# Load library from repository sources
SRC_DIR="$(dirname "$0")/files"
# shellcheck disable=SC1090
. "$SRC_DIR/lib/tg-ws-proxy-common.sh"

# Must be root
[ "$(id -u)" -eq 0 ] || err "Run as root."

# Prevent concurrent install/update/uninstall
tgws_lock

log "Installing dependencies..."
apk -U add -q \
  ca-certificates python3 python3-pip git \
  procps-ng-pgrep \
  shadow-useradd shadow-groupadd shadow-usermod shadow-userdel shadow-groupdel

# Optional: if you want full procps ps instead of busybox ps
# apk -U add -q procps-ng-ps

# Ensure user management tools exist (provided by shadow split packages)
for c in useradd groupadd usermod; do
  command -v "$c" >/dev/null 2>&1 || err "Command $c not found (check shadow-* packages)."
done

log "Creating tgproxy user..."
if ! grep -q '^tgproxy:' /etc/passwd; then
    groupadd tgproxy 2>/dev/null || true
    useradd -r -s /bin/false -d /var/empty -g tgproxy tgproxy
    ok "User tgproxy created."
else
    if grep -q '^tgproxy:.*:/bin/false' /etc/passwd && grep -q '^tgproxy:.*:/var/empty:' /etc/passwd; then
        ok "User tgproxy already exists and looks correct."
    else
        warn "User tgproxy exists but parameters differ. Fixing..."
        usermod -s /bin/false -d /var/empty tgproxy
    fi
fi

log "Updating upstream tg-ws-proxy source..."
REPO_URL="https://github.com/Flowseal/tg-ws-proxy"
TARGET_DIR="/usr/lib/tg-ws-proxy"

# Determine upstream default branch (main/master/etc)
determine_branch() {
  local branch
  branch=$(git ls-remote --symref "$REPO_URL" HEAD 2>/dev/null | awk '/^ref:/{sub("refs/heads/","",$2); print $2}')
  if [ -n "$branch" ]; then
    echo "$branch"
  else
    if git ls-remote --heads "$REPO_URL" main >/dev/null 2>&1; then
      echo "main"
    else
      echo "master"
    fi
  fi
}

if [ -d "$TARGET_DIR/.git" ]; then
    cd "$TARGET_DIR"
    git fetch origin
    git remote set-head origin -a 2>/dev/null || true
    git reset --hard origin/HEAD
    ok "Source code updated."
else
    if [ -d "$TARGET_DIR" ]; then
        warn "$TARGET_DIR exists but is not a git repository. Removing it."
        rm -rf "$TARGET_DIR"
    fi
    BRANCH=$(determine_branch)
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR"
    cd "$TARGET_DIR"
    git remote set-head origin -a 2>/dev/null || true
    ok "Source code cloned."
fi

log "Installing Python package..."
cd "$TARGET_DIR"
# Avoid pip cache on flash + avoid network checks for pip version
PIP_DISABLE_PIP_VERSION_CHECK=1 \
python3 -m pip install --no-cache-dir . -q
ok "tg-ws-proxy Python package installed."

log "Configuring /etc/tg-ws-proxy.env..."
CONFIG_FILE="/etc/tg-ws-proxy.env"
EXAMPLE_FILE="$SRC_DIR/etc/tg-ws-proxy.env.example"

if [ ! -f "$CONFIG_FILE" ]; then
    if [ -n "${TGWS_SECRET:-}" ]; then
        SECRET="$TGWS_SECRET"
    else
        SECRET=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
    fi
    sed "s/PLACEHOLDER_SECRET/$SECRET/" "$EXAMPLE_FILE" > "$CONFIG_FILE"
    chown root:tgproxy "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    ok "Created new config file with secret: $SECRET"
    echo "Secret saved in $CONFIG_FILE"
else
    ok "Config file already exists, not modifying it."
fi

# Restore permissions (idempotent)
chown root:tgproxy "$CONFIG_FILE" 2>/dev/null || true
chmod 640 "$CONFIG_FILE" 2>/dev/null || true

log "Installing init script..."
TEMPLATE="$SRC_DIR/etc/init.d/tg-ws-proxy.in"
[ -f "$TEMPLATE" ] || err "Init template not found: $TEMPLATE"
cp "$TEMPLATE" /etc/init.d/tg-ws-proxy
chmod 755 /etc/init.d/tg-ws-proxy
ok "Init script installed."

log "Installing system files..."
# Common library
mkdir -p /usr/lib
cp "$SRC_DIR/lib/tg-ws-proxy-common.sh" /usr/lib/tg-ws-proxy-common.sh
chmod 644 /usr/lib/tg-ws-proxy-common.sh

# Runner
mkdir -p /usr/libexec/tg-ws-proxy
cp "$SRC_DIR/usr/libexec/tg-ws-proxy/run.sh" /usr/libexec/tg-ws-proxy/run.sh
chmod 755 /usr/libexec/tg-ws-proxy/run.sh

# CLI helper
cp "$SRC_DIR/usr/bin/tg-ws-proxyctl" /usr/bin/tg-ws-proxyctl
chmod 755 /usr/bin/tg-ws-proxyctl

ok "System files installed."

log "Configuring firewall4..."
FIREWALL_RULE_NAME="Block tg-ws-proxy from WAN"

# Remove all existing rules with the same name (avoid duplicates)
while uci show firewall | grep -q "name='$FIREWALL_RULE_NAME'"; do
    idx=$(uci show firewall | grep "name='$FIREWALL_RULE_NAME'" | head -n1 | cut -d'[' -f2 | cut -d']' -f1)
    [ -n "$idx" ] && uci delete firewall.@rule["$idx"]
done

# Add new DROP rule for current TGWS_PORT
uci add firewall rule
uci set firewall.@rule[-1].name="$FIREWALL_RULE_NAME"
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port="$TGWS_PORT"
uci set firewall.@rule[-1].target='DROP'
uci commit firewall
/etc/init.d/firewall reload
ok "Firewall rule synced for port $TGWS_PORT."

log "Configuring sysupgrade backup..."
SYSUPGRADE_CONF="/etc/sysupgrade.conf"
ENTRIES="/etc/tg-ws-proxy.env"

for entry in $ENTRIES; do
    if ! grep -q "^$entry\$" "$SYSUPGRADE_CONF" 2>/dev/null; then
        echo "$entry" >> "$SYSUPGRADE_CONF"
    fi
done
ok "Backup paths added to sysupgrade.conf."

log "Enabling and starting service..."
/etc/init.d/tg-ws-proxy enable
/etc/init.d/tg-ws-proxy restart
ok "tg-ws-proxy service started."

echo ""
echo -e "${INFO}=== Service status ===${NC}"
/etc/init.d/tg-ws-proxy status 2>/dev/null || true

if command -v tg-ws-proxyctl >/dev/null; then
    echo -e "${INFO}=== Telegram client link ===${NC}"
    tg-ws-proxyctl link
fi

echo -e "${OK}Installation completed successfully.${NC}"
