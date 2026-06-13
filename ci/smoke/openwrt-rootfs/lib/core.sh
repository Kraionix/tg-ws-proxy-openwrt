#!/bin/sh
# Common helpers for OpenWrt rootfs smoke tests (POSIX sh).

set -eu

log() { printf '%s\n' "[smoke] $*"; }
warn() { printf '%s\n' "[smoke][warn] $*" >&2; }
die() {
  printf '%s\n' "[smoke][error] $*" >&2
  exit 1
}

need_env() {
  # need_env VAR
  v="$1"
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "Missing required env var: $v"
}

mktempdir() {
  d="${1:-}"
  [ -n "$d" ] || die "mktempdir: missing path"
  mkdir -p "$d"
}
