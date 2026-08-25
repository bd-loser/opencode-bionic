#!/data/data/com.termux/files/usr/bin/bash
# Runs INSIDE termux-docker (aarch64). Fetches upstream opencode fresh at
# the version pinned by versions.json, applies our config delta + patches,
# builds, and publishes the binary to /out/opencode.
#
# Env inputs:
#   OPENCODE_VERSION  version string baked into the binary (also decides
#                     which upstream tag to check out; default: 0.0.0-termux-ci)
#   OPENCODE_CHANNEL  channel string (default: dev)
#   OPENCODE_UPSTREAM_REF
#                     optional; build from this branch/commit instead of the
#                     tag implied by OPENCODE_VERSION. Set for dev
#                     prereleases, where the stamped version (e.g.
#                     1.18.15-dev.fe82a1b6) is not a tag upstream has.
#
# Mounts expected:
#   /workspace  = the opencode-bionic checkout (this fork; read-only in practice)
#   /out        = a writable dir on the host, for artifact handoff
#
# Under the quilt-style architecture, /workspace no longer contains upstream
# opencode source — only our patches, scripts, and versions.json. Upstream
# is cloned fresh here so we always build against a clean, known tag.

set -euo pipefail

# termux-docker's entrypoint strips inherited env when switching to the
# `system` user, so build-on-runner.sh drops the real values into an env
# file on /out. Source it if present; fall back to conservative defaults.
if [ -f /out/build-env.sh ]; then
  # shellcheck disable=SC1091
  . /out/build-env.sh
fi
OPENCODE_VERSION="${OPENCODE_VERSION:-0.0.0-termux-ci}"
OPENCODE_CHANNEL="${OPENCODE_CHANNEL:-dev}"
OPENCODE_UPSTREAM_REF="${OPENCODE_UPSTREAM_REF:-}"
export OPENCODE_UPSTREAM_REF

echo "=== diag ==="
id || true
echo "HOME=$HOME PREFIX=${PREFIX:-unset}"
echo "OPENCODE_VERSION=$OPENCODE_VERSION OPENCODE_CHANNEL=$OPENCODE_CHANNEL"
echo "OPENCODE_UPSTREAM_REF=${OPENCODE_UPSTREAM_REF:-<none, using tag>}"
mount | grep -E "workspace|overlay|out" || true
(touch /workspace/.write_test && rm -f /workspace/.write_test && echo "workspace: WRITABLE") \
  || echo "workspace: READ-ONLY for this user"
(touch /out/.write_test && rm -f /out/.write_test && echo "/out: WRITABLE") \
  || { echo "/out: NOT WRITABLE — abort"; exit 1; }
echo "==========="

# Pin the canonical mirror so package versions remain consistent.
echo "deb https://packages.termux.dev/apt/termux-main stable main" \
  > "${PREFIX:-/data/data/com.termux/files/usr}/etc/apt/sources.list"
apt update -y
apt install -y git python curl dpkg

curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash

BUILD_ROOT="$HOME/opencode"
rm -rf "$BUILD_ROOT"

# Use versions.json unless a specific upstream ref or release was requested.
FETCH_ARGS=("$BUILD_ROOT")
if [ -z "$OPENCODE_UPSTREAM_REF" ] && [ "$OPENCODE_VERSION" != "0.0.0-termux-ci" ]; then
  FETCH_ARGS+=("v$OPENCODE_VERSION")
fi

bash /workspace/termux/ci/prepare-build-tree.sh "${FETCH_ARGS[@]}"

cd "$BUILD_ROOT"
bun install
cd -

OPENCODE_ROOT="$BUILD_ROOT" \
OPENCODE_CHANNEL="$OPENCODE_CHANNEL" \
OPENCODE_VERSION="$OPENCODE_VERSION" \
  bash /workspace/termux/build-opencode-termux.sh

echo "=== POST-BUILD: publishing artifact ==="
set -x
BIN="$BUILD_ROOT/packages/opencode/dist/opencode-android-arm64/bin/opencode"
test -f "$BIN"
test -x "$BIN" || chmod +x "$BIN"
ls -la "$BIN"
cp "$BIN" /out/opencode
chmod 0755 /out/opencode
sha256sum /out/opencode | tee /out/opencode.sha256
ls -la /out/
set +x
echo "=== POST-BUILD: done ==="
