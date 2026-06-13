#!/bin/sh
#
# OpenWrt rootfs smoke test orchestrator (GitHub-hosted runner).
#
# Runs inside GitHub-hosted Ubuntu runner and uses Docker to start an OpenWrt
# rootfs container "as a system" via /sbin/init. Then it runs:
#   install.sh -> update.sh -> uninstall.sh
# and validates the expected invariants.
#
# All output and diagnostics are kept English-only.
#
set -eu

SMOKE_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SMOKE_DIR/../../.." && pwd)"

# shellcheck disable=SC1091
. "$SMOKE_DIR/lib/core.sh"
# shellcheck disable=SC1091
. "$SMOKE_DIR/lib/docker.sh"
# shellcheck disable=SC1091
. "$SMOKE_DIR/lib/assert.sh"
# shellcheck disable=SC1091
. "$SMOKE_DIR/lib/uci_fw4.sh"
# shellcheck disable=SC1091
. "$SMOKE_DIR/lib/redact.sh"
# shellcheck disable=SC1091
. "$SMOKE_DIR/lib/collect.sh"

need_env ROOTFS_IMAGE

ARTIFACT_DIR="${SMOKE_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/openwrt-rootfs-smoke}"
SMOKE_BOOT_TIMEOUT_SEC="${SMOKE_BOOT_TIMEOUT_SEC:-120}"

CTR="${SMOKE_CONTAINER_NAME:-openwrt-rootfs-smoke-${GITHUB_RUN_ID:-local}-$RANDOM}"

cleanup() {
  code="$?"
  log "Collecting diagnostics (exit code: $code)..."
  collect_artifacts || true

  log "Cleaning up container..."
  docker_best_effort docker rm -f "$CTR"
  exit "$code"
}

trap cleanup EXIT INT TERM

log "Smoke config:"
log "  ROOTFS_IMAGE=$ROOTFS_IMAGE"
log "  CTR=$CTR"
log "  ARTIFACT_DIR=$ARTIFACT_DIR"

log "Pulling rootfs image..."
docker pull "$ROOTFS_IMAGE" >/dev/null

log "Starting OpenWrt container with /sbin/init..."
docker run -d --name "$CTR" --privileged "$ROOTFS_IMAGE" /sbin/init >/dev/null

# shellcheck disable=SC1090
. "$SMOKE_DIR/phases/00_boot.sh"
# shellcheck disable=SC1090
. "$SMOKE_DIR/phases/10_install.sh"
# shellcheck disable=SC1090
. "$SMOKE_DIR/phases/20_update.sh"
# shellcheck disable=SC1090
. "$SMOKE_DIR/phases/30_uninstall.sh"

phase_boot
phase_install
phase_update
phase_uninstall

log "Smoke test completed successfully."
