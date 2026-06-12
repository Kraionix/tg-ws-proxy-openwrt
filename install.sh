#!/bin/sh
#
# install.sh - idempotent installer for tg-ws-proxy on OpenWrt 25.12+ (apk)
#
# - Installs dependencies via apk
# - Creates tgproxy user/group (shadow split packages)
# - Clones/updates upstream Flowseal/tg-ws-proxy into /usr/lib/tg-ws-proxy
# - Supports upstream pinning via TGWS_GIT_REF in /etc/tg-ws-proxy.env
# - Installs Python package via pip (reduced flash wear settings)
# - Installs procd init script, runner, and tg-ws-proxyctl helper
# - Creates firewall4 WAN->DROP rule for TGWS_PORT (local proxy default)
# - Backs up only /etc/tg-ws-proxy.env via /etc/sysupgrade.conf
#
set -eu

SRC_DIR="$(dirname "$0")/files"
# shellcheck disable=SC1090
. "$SRC_DIR/lib/tg-ws-proxy-common.sh"

[ "$(id -u)" -eq 0 ] || err "Run as root."

tgws_lock

log "Installing dependencies..."
apk -U add -q \
  ca-certificates python3 python3-pip git \
  procps-ng-pgrep \
  shadow-useradd shadow-groupadd shadow-usermod shadow-userdel shadow-groupdel

# Optional:
# apk -U add -q procps-ng-ps

# Reduce surprises from apk split packages: verify required commands exist
require_cmd apk
require_cmd git
require_cmd python3
require_cmd uci
require_cmd pgrep "Install: apk -U add procps-ng-pgrep"
require_cmd useradd "Install: apk -U add shadow-useradd"
require_cmd groupadd "Install: apk -U add shadow-groupadd"
require_cmd usermod "Install: apk -U add shadow-usermod"
require_cmd userdel "Install: apk -U add shadow-userdel"
require_cmd groupdel "Install: apk -U add shadow-groupdel"

log "Ensuring tgproxy user exists..."
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

log "Configuring /etc/tg-ws-proxy.env..."
CONFIG_FILE="/etc/tg-ws-proxy.env"
EXAMPLE_FILE="$SRC_DIR/etc/tg-ws-proxy.env.example"

escape_sed_repl() {
  # Escape string for sed replacement context.
  echo "$1" | sed 's/[\/&]/\\&/g'
}

if [ ! -f "$CONFIG_FILE" ]; then
  if [ -n "${TGWS_SECRET:-}" ]; then
    SECRET="$TGWS_SECRET"
  else
    SECRET=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  fi

  sed "s/PLACEHOLDER_SECRET/$SECRET/" "$EXAMPLE_FILE" >"$CONFIG_FILE"

  # If TGWS_GIT_REF passed as environment variable during first install, persist it.
  if [ -n "${TGWS_GIT_REF:-}" ]; then
    esc_ref="$(escape_sed_repl "$TGWS_GIT_REF")"
    if grep -q '^TGWS_GIT_REF=' "$CONFIG_FILE"; then
      sed -i "s|^TGWS_GIT_REF=.*$|TGWS_GIT_REF=\"${esc_ref}\"|g" "$CONFIG_FILE"
    else
      echo "TGWS_GIT_REF=\"${TGWS_GIT_REF}\"" >>"$CONFIG_FILE"
    fi
  fi

  chown root:tgproxy "$CONFIG_FILE"
  chmod 640 "$CONFIG_FILE"
  ok "Created new config file: $CONFIG_FILE"
else
  ok "Config file already exists, not modifying it."
fi

# Restore permissions (idempotent)
chown root:tgproxy "$CONFIG_FILE" 2>/dev/null || true
chmod 640 "$CONFIG_FILE" 2>/dev/null || true

# Load config for TGWS_PORT / TGWS_GIT_REF
# shellcheck disable=SC1090
. "$CONFIG_FILE"

log "Preparing upstream tg-ws-proxy source..."
REPO_URL="https://github.com/Flowseal/tg-ws-proxy"
TARGET_DIR="/usr/lib/tg-ws-proxy"

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

resolve_git_ref() {
  # Resolve pin ref to something git can checkout reliably.
  # Accepts: commit hash, tag, branch name, origin/branch.
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

if [ -d "$TARGET_DIR/.git" ]; then
  cd "$TARGET_DIR"
  git fetch --tags origin
  git remote set-head origin -a 2>/dev/null || true
  ok "Upstream remote fetched."
else
  if [ -d "$TARGET_DIR" ]; then
    warn "$TARGET_DIR exists but is not a git repo. Removing it."
    rm -rf "$TARGET_DIR"
  fi
  BRANCH=$(determine_branch)
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR"
  cd "$TARGET_DIR"
  git fetch --tags origin
  git remote set-head origin -a 2>/dev/null || true
  ok "Upstream source cloned."
fi

if [ -n "${TGWS_GIT_REF:-}" ]; then
  RESOLVED="$(resolve_git_ref "$TGWS_GIT_REF")" || err "TGWS_GIT_REF='$TGWS_GIT_REF' not found (commit/tag/branch)."
  git checkout -f "$RESOLVED"
  git reset --hard "$RESOLVED"
  ok "Upstream pinned to: $TGWS_GIT_REF ($RESOLVED)"
else
  git reset --hard origin/HEAD
  ok "Upstream set to origin/HEAD."
fi

log "Installing Python package..."
cd "$TARGET_DIR"

# Reduce flash wear:
# - no pip cache
# - no .pyc compilation during install
# - redirect pycache to /tmp (RAM)
mkdir -p /tmp/tg-ws-proxy-pycache 2>/dev/null || true
PIP_DISABLE_PIP_VERSION_CHECK=1 \
  PYTHONDONTWRITEBYTECODE=1 \
  PYTHONPYCACHEPREFIX=/tmp/tg-ws-proxy-pycache \
  python3 -m pip install --no-cache-dir --no-compile . -q

ok "Python package installed."

log "Installing init script..."
TEMPLATE="$SRC_DIR/etc/init.d/tg-ws-proxy.in"
[ -f "$TEMPLATE" ] || err "Init template not found: $TEMPLATE"
cp "$TEMPLATE" /etc/init.d/tg-ws-proxy
chmod 755 /etc/init.d/tg-ws-proxy
ok "Init script installed."

log "Installing system files..."
mkdir -p /usr/lib
cp "$SRC_DIR/lib/tg-ws-proxy-common.sh" /usr/lib/tg-ws-proxy-common.sh
chmod 644 /usr/lib/tg-ws-proxy-common.sh

mkdir -p /usr/libexec/tg-ws-proxy
cp "$SRC_DIR/usr/libexec/tg-ws-proxy/run.sh" /usr/libexec/tg-ws-proxy/run.sh
chmod 755 /usr/libexec/tg-ws-proxy/run.sh

cp "$SRC_DIR/usr/bin/tg-ws-proxyctl" /usr/bin/tg-ws-proxyctl
chmod 755 /usr/bin/tg-ws-proxyctl

ok "System files installed."

log "Configuring firewall4..."
FIREWALL_RULE_NAME="tg-ws-proxy: drop-wan"
LEGACY_FIREWALL_RULE_NAME="Block tg-ws-proxy from WAN"

# Remove duplicates for both names
for NAME in "$FIREWALL_RULE_NAME" "$LEGACY_FIREWALL_RULE_NAME"; do
  while uci show firewall | grep -q "name='$NAME'"; do
    idx=$(uci show firewall | grep "name='$NAME'" | head -n1 | cut -d'[' -f2 | cut -d']' -f1)
    [ -n "$idx" ] && uci delete firewall.@rule["$idx"]
  done
done

# Add WAN->DROP rule for current TGWS_PORT
uci add firewall rule
uci set firewall.@rule[-1].name="$FIREWALL_RULE_NAME"
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port="$TGWS_PORT"
uci set firewall.@rule[-1].target='DROP'
uci commit firewall
/etc/init.d/firewall reload
ok "Firewall rule configured (WAN->DROP) for port $TGWS_PORT."

log "Configuring sysupgrade backup..."
SYSUPGRADE_CONF="/etc/sysupgrade.conf"
ENTRIES="/etc/tg-ws-proxy.env"
for entry in $ENTRIES; do
  if ! grep -q "^$entry\$" "$SYSUPGRADE_CONF" 2>/dev/null; then
    echo "$entry" >>"$SYSUPGRADE_CONF"
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

echo ""
echo "To print the Telegram client link, run:"
echo "  tg-ws-proxyctl link"

echo -e "${OK}Installation completed successfully.${NC}"