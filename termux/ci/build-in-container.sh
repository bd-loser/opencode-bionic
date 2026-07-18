#!/data/data/com.termux/files/usr/bin/bash
# Runs INSIDE termux-docker (aarch64). Builds the opencode binary and
# publishes it to /out/opencode (a bind-mounted, world-writable host dir).
#
# Env inputs:
#   OPENCODE_VERSION  version string baked into the binary (default: 0.0.0-termux-ci)
#   OPENCODE_CHANNEL  channel string (default: dev)
#
# Mounts expected:
#   /workspace  = the repo checkout (read-only in practice)
#   /out        = a writable dir on the host, for artifact handoff
#
# The `bash -c '...'` inline form we used before made quoting brittle;
# invoking this file directly keeps it a normal, greppable script.

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

echo "=== diag ==="
id || true
echo "HOME=$HOME PREFIX=${PREFIX:-unset}"
echo "OPENCODE_VERSION=$OPENCODE_VERSION OPENCODE_CHANNEL=$OPENCODE_CHANNEL"
mount | grep -E "workspace|overlay|out" || true
(touch /workspace/.write_test && rm -f /workspace/.write_test && echo "workspace: WRITABLE") \
  || echo "workspace: READ-ONLY for this user"
(touch /out/.write_test && rm -f /out/.write_test && echo "/out: WRITABLE") \
  || { echo "/out: NOT WRITABLE — abort"; exit 1; }
echo "==========="

pkg update -y
pkg install -y git python curl dpkg rsync

# bun-termux install URL is intentionally hardcoded rather than read from
# versions.json — it isn't tied to any opencode version.
curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash

# Copy the checkout into a container-native path where bun install is
# guaranteed to work (real termux filesystem, not the bind mount).
BUILD_ROOT="$HOME/opencode"
mkdir -p "$BUILD_ROOT"
rsync -a --delete \
  --exclude ".git" \
  --exclude "node_modules" \
  /workspace/ "$BUILD_ROOT/"

# Run bun install ourselves — the verifier in clean-reinstall.sh trips on
# monorepo installs (counts only top-level entries in ./node_modules and
# expects 1000+, but per-workspace hoisting legitimately leaves only ~15-20
# there). Setting SKIP_REINSTALL=1 tells setup.sh to trust the node_modules
# we produced here.
cd "$BUILD_ROOT"
bun install
cd -

OPENCODE_ROOT="$BUILD_ROOT" SKIP_REINSTALL=1 SKIP_SMOKE_TEST=1 \
  bash "$BUILD_ROOT/termux/setup.sh"

# build-termux.ts (via packages/script/src/index.ts) calls
# `git branch --show-current` when neither OPENCODE_CHANNEL nor
# OPENCODE_VERSION is set. We rsynced without .git, so provide them
# explicitly so the version-detection branch skips git.
OPENCODE_ROOT="$BUILD_ROOT" \
OPENCODE_CHANNEL="$OPENCODE_CHANNEL" \
OPENCODE_VERSION="$OPENCODE_VERSION" \
  bash "$BUILD_ROOT/termux/build-opencode-termux.sh"

echo "=== POST-BUILD: publishing artifact ==="
set -x
BIN="$BUILD_ROOT/packages/opencode/dist/opencode-android-arm64/bin/opencode"
test -f "$BIN"
test -x "$BIN" || chmod +x "$BIN"
ls -la "$BIN"
cp "$BIN" /out/opencode
chmod 0755 /out/opencode
# Compute sha for later verification.
sha256sum /out/opencode | tee /out/opencode.sha256
ls -la /out/
set +x
echo "=== POST-BUILD: done ==="
