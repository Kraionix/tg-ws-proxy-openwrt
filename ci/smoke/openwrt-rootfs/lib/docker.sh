#!/bin/sh
# Docker helpers for smoke tests (POSIX sh).

set -eu

# These are set by the orchestrator:
# - CTR: container name
# - ARTIFACT_DIR: host path for diagnostics

ctr_exec() {
  # Execute a command inside the container using a stable PATH.
  # Usage: ctr_exec "command"
  docker exec "$CTR" sh -lc "PATH=/usr/sbin:/usr/bin:/sbin:/bin; $*"
}

ctr_capture() {
  # Capture stdout+stderr from a container command.
  # Usage: out="$(ctr_capture "command")"
  docker exec "$CTR" sh -lc "PATH=/usr/sbin:/usr/bin:/sbin:/bin; $*" 2>&1
}

ctr_best_effort_to_file() {
  # Usage: ctr_best_effort_to_file "cmd" "/host/file"
  cmd="$1"
  out="$2"
  set +e
  ctr_capture "$cmd" >"$out"
  set -e
}

docker_best_effort() {
  # Usage: docker_best_effort docker ...args...
  set +e
  "$@" >/dev/null 2>&1
  set -e
}

docker_logs_to_file() {
  f="$1"
  set +e
  docker logs "$CTR" >"$f" 2>&1
  set -e
}

docker_inspect_to_file() {
  f="$1"
  set +e
  docker inspect "$CTR" >"$f" 2>&1
  set -e
}

wait_for_procd_pid1() {
  timeout="${1:-120}"
  i=0
  while [ "$i" -lt "$timeout" ]; do
    if docker ps --format '{{.Names}}' | grep -qx "$CTR"; then
      comm="$(ctr_capture 'cat /proc/1/comm 2>/dev/null || true' | tr -d '\r' | head -n1)"
      if [ "$comm" = "procd" ]; then
        return 0
      fi
    else
      return 1
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}
