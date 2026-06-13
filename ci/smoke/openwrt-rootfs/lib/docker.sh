#!/bin/sh
# Docker helpers for smoke tests (POSIX sh).

set -eu

# These are set by the orchestrator:
# - CTR: container name
# - ARTIFACT_DIR: host path for diagnostics

ctr_exec() {
  # Execute a command inside the container using a stable PATH.
  # Usage: ctr_exec "command"
  # Do not use '-l' (login shell): it triggers /etc/profile and prints banners.
  docker exec "$CTR" sh -c "PATH=/usr/sbin:/usr/bin:/sbin:/bin; $*"
}

ctr_exec_stdin() {
  # Execute a command inside the container while providing stdin.
  # Usage: ctr_exec_stdin "cmd" <<'EOF' ... EOF
  docker exec -i "$CTR" sh -c "PATH=/usr/sbin:/usr/bin:/sbin:/bin; $*"
}

ctr_capture() {
  # Capture stdout+stderr from a container command.
  # Usage: out="$(ctr_capture "command")"
  docker exec "$CTR" sh -c "PATH=/usr/sbin:/usr/bin:/sbin:/bin; $*" 2>&1
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

wait_for_openwrt_ready() {
  # OpenWrt in containers may keep /sbin/init as PID 1 while procd runs as a child.
  # Accept either:
  #   - PID 1 == procd
  #   - PID 1 == init AND procd is running
  timeout="${1:-120}"
  i=0

  while [ "$i" -lt "$timeout" ]; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$CTR"; then
      return 1
    fi

    comm="$(
      docker exec "$CTR" cat /proc/1/comm 2>/dev/null \
        | tr -d '\r' \
        | head -n1 || true
    )"

    case "$comm" in
      procd)
        return 0
        ;;
      init)
        # In some boot stages procd may already be running even if PID 1 is still init.
        if docker exec "$CTR" pidof procd >/dev/null 2>&1; then
          return 0
        fi
        ;;
      *)
        # Keep waiting.
        ;;
    esac

    i=$((i + 1))
    sleep 1
  done

  return 1
}
