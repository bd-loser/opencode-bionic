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
apt install -y git python curl dpkg rust zig

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

# Terminal sessions ride on bun-pty, whose npm prebuilt is glibc-linked
# (libpthread.so.0) and cannot dlopen on Bionic. Overwrite the npm artifact
# with the Bionic build published by bun-termux, matched to the bun-pty
# version upstream pins: bun-pty picks its .so via a statically analyzed
# require(), so this on-disk file is what the compiled binary embeds.
BUN_PTY_VERSION="$(python3 -c \
  "import json;print(json.load(open('/workspace/versions.json'))['bunPty']['version'])")"
BUN_PTY_URL="$(python3 -c \
  "import json;print(json.load(open('/workspace/versions.json'))['bunPty']['assetUrl'])")"
BUN_PTY_DIR="$(find "$BUILD_ROOT" -type d -path '*bun-pty/rust-pty/target/release' 2>/dev/null | head -1 || true)"
if [ -z "$BUN_PTY_DIR" ]; then
  echo "error: bun-pty package not found under node_modules — cannot embed Bionic pty" >&2
  exit 1
fi
echo "→ embedding Bionic bun-pty $BUN_PTY_VERSION (npm prebuilt is glibc-only)"
curl -fsSL -o "$BUN_PTY_DIR/librust_pty_arm64.so" "$BUN_PTY_URL"
# The container ships no usable `file`/`readelf`; verify the ELF with python.
if ! python3 - "$BUN_PTY_DIR/librust_pty_arm64.so" <<'PYELF'
import struct, sys
h = open(sys.argv[1], "rb").read(20)
assert h[:4] == b"\x7fELF", "not an ELF"
assert h[4] == 2, "not 64-bit"
assert h[5] == 1, "not little-endian"
machine = struct.unpack_from("<H", h, 18)[0]
assert machine == 183, f"not AArch64 (e_machine={machine})"
PYELF
then
  echo "error: bun-pty Bionic .so is not an aarch64 ELF" >&2
  exit 1
fi
echo "→ bun-pty Bionic embedded: $BUN_PTY_DIR/librust_pty_arm64.so"

# Persistent terminal daemon (@opencode-ai/pty). The official wheels cannot
# run on Android: the gnu wheel links glibc, and the musl wheel hardcodes its
# Unix socket under /tmp, which is read-only. bun-termux builds the daemon for
# Bionic with the socket routed through OPENCODE_PTY_SOCKET_DIR/TMPDIR — this
# embeds it into the compiled binary as the gnu wheel the resolver looks up.
# The kernel execs it as a child process; its default runtime dir sits under
# XDG_STATE_HOME, which Termux resolves to a writable path.
if [ "${OPENCODE_EMBED_PTY:-1}" = "1" ]; then
PTYD_VERSION="$(python3 -c \
  "import json;print(json.load(open('/workspace/versions.json'))['ptyService']['version'])")"
PTYD_URL="$(python3 -c \
  "import json;print(json.load(open('/workspace/versions.json'))['ptyService']['assetUrl'])")"
PTYD_PKG="$BUILD_ROOT/node_modules/@opencode-ai/pty-linux-arm64-gnu"
mkdir -p "$PTYD_PKG/bin"
echo "→ fetching Bionic opencode-pty daemon $PTYD_VERSION"
curl -fsSL -o "$PTYD_PKG/bin/opencode-pty" "$PTYD_URL"
chmod 0755 "$PTYD_PKG/bin/opencode-pty"
if ! python3 - "$PTYD_PKG/bin/opencode-pty" <<'PYELF'
import struct, sys
h = open(sys.argv[1], "rb").read(20)
assert h[:4] == b"\x7fELF", "not an ELF"
assert h[4] == 2, "not 64-bit"
assert h[5] == 1, "not little-endian"
machine = struct.unpack_from("<H", h, 18)[0]
assert machine == 183, f"not AArch64 (e_machine={machine})"
PYELF
then
  echo "error: pty daemon is not an aarch64 ELF" >&2
  exit 1
fi
cat > "$PTYD_PKG/package.json" <<PKGJSON
{
  "name": "@opencode-ai/pty-linux-arm64-gnu",
  "version": "$PTYD_VERSION",
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
echo "→ pty daemon embedded: $PTYD_PKG/bin/opencode-pty"
else
  echo "→ skipping pty daemon embed (OPENCODE_EMBED_PTY=0); binding compiles to undefined"
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
