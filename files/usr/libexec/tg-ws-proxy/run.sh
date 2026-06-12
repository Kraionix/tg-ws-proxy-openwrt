#!/bin/sh
#
# tg-ws-proxy procd runner
#
# - Sources /etc/tg-ws-proxy.env
# - Validates TGWS_HOST / TGWS_PORT / TGWS_SECRET
# - Translates env vars into tg_ws_proxy.py CLI flags
# - Executes upstream tg_ws_proxy.py
#
set -eu

# If PYTHONPYCACHEPREFIX is set (via procd env), ensure the directory exists.
# /tmp is tmpfs (RAM), so this reduces flash/overlay writes.
[ -n "${PYTHONPYCACHEPREFIX:-}" ] && mkdir -p "$PYTHONPYCACHEPREFIX" 2>/dev/null || true

ENV_FILE="/etc/tg-ws-proxy.env"
[ -f "$ENV_FILE" ] || { echo "Error: missing $ENV_FILE" >&2; exit 1; }

# shellcheck disable=SC1090
. "$ENV_FILE"

# Defaults (in case the config is partial)
: "${TGWS_HOST:=127.0.0.1}"
: "${TGWS_PORT:=1443}"
: "${TGWS_LOG_FILE:=/var/log/tg-ws-proxy.log}"
: "${TGWS_LOG_MAX_MB:=5}"
: "${TGWS_LOG_BACKUPS:=0}"
: "${TGWS_BUF_KB:=256}"
: "${TGWS_POOL_SIZE:=4}"
: "${TGWS_DC_IPS:=}"
: "${TGWS_VERBOSE:=false}"

: "${TGWS_NO_CFPROXY:=false}"
: "${TGWS_CFPROXY_DOMAIN:=}"
: "${TGWS_CFPROXY_WORKER_DOMAIN:=}"

: "${TGWS_FAKE_TLS_DOMAIN:=}"
: "${TGWS_PROXY_PROTOCOL:=false}"

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

validate_port() {
  # Must be an integer in range 1..65535.
  local p="${1:-}"
  echo "$p" | grep -Eq '^[0-9]+$' || { echo "Error: TGWS_PORT must be a number (1..65535)" >&2; exit 1; }
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { echo "Error: TGWS_PORT is out of range (1..65535)" >&2; exit 1; }
}

validate_host() {
  # Allow common bind formats: IPv4/IPv6/hostname/0.0.0.0
  local h="${1:-}"
  [ -n "$h" ] || { echo "Error: TGWS_HOST is empty" >&2; exit 1; }
  echo "$h" | grep -q '[[:space:]]' && { echo "Error: TGWS_HOST contains whitespace" >&2; exit 1; }
  echo "$h" | grep -Eq '^[0-9A-Za-z:.%-]+$' || { echo "Error: TGWS_HOST contains invalid characters" >&2; exit 1; }
}

validate_host "$TGWS_HOST"
validate_port "$TGWS_PORT"

# Validate secret: exactly 32 hex chars.
if [ -z "${TGWS_SECRET:-}" ] || [ "$TGWS_SECRET" = "PLACEHOLDER_SECRET" ] || ! echo "$TGWS_SECRET" | grep -Eq '^[0-9a-fA-F]{32}$'; then
  echo "Error: TGWS_SECRET is missing or invalid (must be 32 hex characters)." >&2
  exit 1
fi

# Base args
set -- \
  --host "$TGWS_HOST" \
  --port "$TGWS_PORT" \
  --secret "$TGWS_SECRET" \
  --log-file "$TGWS_LOG_FILE" \
  --log-max-mb "$TGWS_LOG_MAX_MB" \
  --log-backups "$TGWS_LOG_BACKUPS" \
  --buf-kb "$TGWS_BUF_KB" \
  --pool-size "$TGWS_POOL_SIZE"

# Verbose logging
if is_true "$TGWS_VERBOSE"; then
  set -- "$@" -v
fi

# DC mappings
for x in $TGWS_DC_IPS; do
  set -- "$@" --dc-ip "$x"
done

# Cloudflare fallback options
if is_true "$TGWS_NO_CFPROXY"; then
  set -- "$@" --no-cfproxy
else
  for d in $TGWS_CFPROXY_DOMAIN; do
    [ -n "$d" ] && set -- "$@" --cfproxy-domain "$d"
  done
  for d in $TGWS_CFPROXY_WORKER_DOMAIN; do
    [ -n "$d" ] && set -- "$@" --cfproxy-worker-domain "$d"
  done
fi

# Fake TLS (ee-secret masking)
if [ -n "$TGWS_FAKE_TLS_DOMAIN" ]; then
  set -- "$@" --fake-tls-domain "$TGWS_FAKE_TLS_DOMAIN"
fi

# PROXY protocol v1
if is_true "$TGWS_PROXY_PROTOCOL"; then
  set -- "$@" --proxy-protocol
fi

exec /usr/bin/python3 /usr/lib/tg-ws-proxy/proxy/tg_ws_proxy.py "$@"