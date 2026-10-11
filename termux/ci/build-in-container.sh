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
apt install -y git python curl dpkg rust

# Install the bun-termux version pinned in versions.json, not whatever
# /releases/latest happens to point at — the "latest" marker drifting to a
# regressed build is exactly how v1.18.31 shipped a broken chunk graph
# (Bun 1.4.1 splitting bug, oven-sh/bun#42837).
BUN_TERMUX_VERSION="$(python3 -c \
  "import json;print(json.load(open('/workspace/versions.json'))['bunTermux']['version'])")"
BUN_DEB="bun_${BUN_TERMUX_VERSION}_aarch64.deb"
BUN_TMP_DEB="$(mktemp)"
echo "→ installing bun-termux $BUN_TERMUX_VERSION"
curl -fsSL -o "$BUN_TMP_DEB" \
  "https://github.com/bd-loser/bun-termux/releases/download/v${BUN_TERMUX_VERSION}/${BUN_DEB}"
dpkg -i "$BUN_TMP_DEB"
rm -f "$BUN_TMP_DEB"
INSTALLED="$(bun --version)"
if [ "$INSTALLED" != "${BUN_TERMUX_VERSION%%-patched}" ]; then
  echo "error: expected bun ${BUN_TERMUX_VERSION}, got $INSTALLED" >&2
  exit 1
fi
bun --version

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

# Build @opencode-ai/pty from source for Bionic. The prebuilt glibc binary
# won't load on Android; building from source in the container produces a
# compatible binary. Requires Rust + Zig (fetched by opencode-pty's build.rs).
if [ ! -d "$BUILD_ROOT/node_modules/@opencode-ai/pty-linux-arm64-gnu" ] || [ ! -f "$BUILD_ROOT/node_modules/@opencode-ai/pty-linux-arm64-gnu/bin/opencode-pty" ]; then
  echo "→ building @opencode-ai/pty from source for Bionic"

  # Zig 0.16.0 (matches upstream CI) — needed by opencode-pty's build.rs
  # to compile the Ghostty terminal emulation library.
  if ! command -v zig >/dev/null 2>&1; then
    echo "→ installing Zig 0.16.0"
    ZIG_TARBALL="zig-linux-aarch64-0.16.0.tar.xz"
    ZIG_TMP="$(mktemp -d)"
    curl -fsSL -o "$ZIG_TMP/$ZIG_TARBALL" "https://ziglang.org/download/0.16.0/$ZIG_TARBALL" \
      || { echo "error: Zig download failed" >&2; exit 1; }
    tar -xJf "$ZIG_TMP/$ZIG_TARBALL" -C "$ZIG_TMP"
    cp -r "$ZIG_TMP/zig-linux-aarch64-0.16.0" "$PREFIX/opt/zig"
    ln -sf "$PREFIX/opt/zig/zig" "$PREFIX/bin/zig"
    rm -rf "$ZIG_TMP"
    zig version
  fi

  PTY_SRC="$HOME/opencode-pty-src"
  rm -rf "$PTY_SRC"
  git clone --depth 1 https://github.com/anomalyco/opencode-pty.git "$PTY_SRC"
  cd "$PTY_SRC"
  # build.rs fetches Ghostty source and builds it with Zig; cargo builds the service.
  cargo build --release
  PTY_BIN="$(find target/release -name 'opencode-pty' -type f | head -1)"
  if [ -z "$PTY_BIN" ]; then
    echo "error: opencode-pty build produced no binary" >&2
    exit 1
  fi
  PTY_PKG="$BUILD_ROOT/node_modules/@opencode-ai/pty-linux-arm64-gnu"
  mkdir -p "$PTY_PKG/bin"
  cp "$PTY_BIN" "$PTY_PKG/bin/opencode-pty"
  chmod +x "$PTY_PKG/bin/opencode-pty"
  cat > "$PTY_PKG/package.json" <<PKGJSON
{
  "name": "@opencode-ai/pty-linux-arm64-gnu",
  "version": "0.2.0",
  "description": "OpenCode persistent PTY service for linux-arm64 (Bionic build)",
  "license": "MIT",
  "os": ["linux"],
  "cpu": ["arm64"],
  "exports": {
    "./package.json": "./package.json",
    "./bin/opencode-pty": "./bin/opencode-pty"
  },
  "files": ["bin"]
}
PKGJSON
  cd "$BUILD_ROOT"
  echo "→ pty installed: $PTY_PKG/bin/opencode-pty ($(du -h "$PTY_PKG/bin/opencode-pty" | cut -f1))"
fi

cd -

OPENCODE_ROOT="$BUILD_ROOT" \
OPENCODE_CHANNEL="$OPENCODE_CHANNEL" \
OPENCODE_VERSION="$OPENCODE_VERSION" \
  bash /workspace/termux/build-opencode-termux.sh

echo "=== POST-BUILD: publishing artifact ==="
set -x
BIN="$BUILD_ROOT/packages/cli/dist/cli-linux-arm64/bin/opencode"
test -f "$BIN"
test -x "$BIN" || chmod +x "$BIN"
ls -la "$BIN"
cp "$BIN" /out/opencode
chmod 0755 /out/opencode
sha256sum /out/opencode | tee /out/opencode.sha256
ls -la /out/
set +x
echo "=== POST-BUILD: done ==="
