#!/bin/sh
# Assertions for smoke tests (POSIX sh).

set -eu

assert_ctr_ok() {
  # Usage: assert_ctr_ok "cmd" "message"
  cmd="$1"
  msg="$2"
  if ! ctr_exec "$cmd" >/dev/null 2>&1; then
    die "$msg"
  fi
}

assert_ctr_contains() {
  # Usage: assert_ctr_contains "cmd" "needle" "message"
  cmd="$1"
  needle="$2"
  msg="$3"
  out="$(ctr_capture "$cmd" || true)"
  echo "$out" | grep -Fq "$needle" || die "$msg"
}

assert_file_exists() {
  # Usage: assert_file_exists /path "message"
  f="$1"
  msg="$2"
  assert_ctr_ok "[ -e '$f' ]" "$msg"
}

assert_file_not_exists() {
  # Usage: assert_file_not_exists /path "message"
  f="$1"
  msg="$2"
  if ctr_exec "[ -e '$f' ]" >/dev/null 2>&1; then
    die "$msg"
  fi
}

assert_executable() {
  # Usage: assert_executable /path "message"
  f="$1"
  msg="$2"
  assert_ctr_ok "[ -x '$f' ]" "$msg"
}

assert_stat_eq() {
  # Usage: assert_stat_eq /path "%a %U %G" "expected" "message"
  f="$1"
  fmt="$2"
  expected="$3"
  msg="$4"

  got="$(ctr_capture "stat -c '$fmt' '$f' 2>/dev/null" | tr -d '\r' | tail -n1)"
  [ "$got" = "$expected" ] || die "$msg (expected '$expected', got '$got')"
}
