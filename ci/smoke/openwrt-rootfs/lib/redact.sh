#!/bin/sh
# Redaction helpers for diagnostics bundles (POSIX sh).

set -eu

redact_tgws_env() {
  # Usage: redact_tgws_env <in> <out>
  inp="$1"
  out="$2"

  if [ ! -f "$inp" ]; then
    return 0
  fi

  # Replace TGWS_SECRET="...." with TGWS_SECRET="REDACTED"
  sed -E 's/^(TGWS_SECRET=)".*"/\1"REDACTED"/' "$inp" >"$out"
}
