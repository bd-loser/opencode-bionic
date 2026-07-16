#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# install-opencode-termux.sh — install the compiled opencode binary system-wide
# =============================================================================
#
# WHAT THIS DOES:
#   1. Copies the compiled binary to $PREFIX/lib/opencode/opencode
#   2. Creates a launcher wrapper at $PREFIX/bin/opencode that sets:
#      - PREFIX (so @xincli/opentui-core's Termux detection works)
#      - MEMTAG_OPTIONS=off (so FFI doesn't SIGABRT from MTE)
#      - LD_PRELOAD=libbun-android-fix.so (SELinux syscall interception)
#   3. Verifies the install with `opencode --version`
#
# WHY A WRAPPER:
#   The compiled binary has @xincli/opentui-core baked in. Its Termux detection
#   checks: process.env.PREFIX includes "com.termux". When you run the binary
#   directly (./opencode), $PREFIX might not be set, so detection fails with:
#     "opentui is not supported on the current platform: android-arm64"
#
#   The wrapper ensures PREFIX is always set, plus the LD_PRELOAD shim (needed
#   for FFI — the compiled binary still calls dlopen on libopentui.so).
#
# PREREQUISITES:
#   - Binary already compiled: bash termux/build-opencode-termux.sh
#   - Binary at: packages/opencode/dist/opencode-android-arm64/bin/opencode
#
# USAGE:
#   bash termux/install-opencode-termux.sh
#
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; exit 1; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

OPENCODE_ROOT="${OPENCODE_ROOT:-$(pwd)}"

# --- Verify prerequisites ----------------------------------------------------
if [ -z "${PREFIX:-}" ]; then
  fail "PREFIX not set. This script must run inside Termux."
fi

BINARY="$OPENCODE_ROOT/packages/opencode/dist/opencode-android-arm64/bin/opencode"

if [ ! -f "$BINARY" ]; then
  fail "Binary not found at $BINARY"
  echo "Run: bash termux/build-opencode-termux.sh" >&2
  exit 1
fi

# Verify bun-termux shim exists (needed for LD_PRELOAD)
SHIM="/data/data/com.termux/files/usr/lib/bun-termux/libbun-android-fix.so"
if [ ! -f "$SHIM" ]; then
  fail "bun-termux shim not found at $SHIM"
  echo "Install bun-termux: curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash" >&2
  exit 1
fi

echo "=========================================="
echo "Installing opencode binary"
echo "=========================================="
echo "  Binary:  $BINARY"
echo "  Target:  $PREFIX/lib/opencode/opencode"
echo "  Wrapper: $PREFIX/bin/opencode"
echo "=========================================="

# --- Step 1: Copy binary to $PREFIX/lib/opencode/ ----------------------------
echo ""
echo "=== Step 1: Copy binary ==="
mkdir -p "$PREFIX/lib/opencode"
cp "$BINARY" "$PREFIX/lib/opencode/opencode"
chmod 755 "$PREFIX/lib/opencode/opencode"
ok "Binary copied to $PREFIX/lib/opencode/opencode"

# --- Step 2: Create launcher wrapper at $PREFIX/bin/opencode -----------------
echo ""
echo "=== Step 2: Create launcher wrapper ==="

cat > "$PREFIX/bin/opencode" << 'WRAPPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# opencode launcher for Termux
# Sets up the environment the compiled binary needs:
#   - PREFIX: so @xincli/opentui-core's Termux detection works
#   - MEMTAG_OPTIONS=off: so FFI doesn't SIGABRT from MTE pointer tagging
#   - LD_PRELOAD: libbun-android-fix.so for SELinux syscall interception

set -euo pipefail

# PREFIX must be set for @xincli/opentui-core's Termux detection
# (checks process.env.PREFIX.includes("com.termux"))
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# MEMTAG_OPTIONS=off — Bionic's scudo allocator tags heap pointers; the
# compiled binary's FFI passes tagged pointers to free() which SIGABRTs.
export MEMTAG_OPTIONS=off

# LD_PRELOAD the bun-termux shim — intercepts SELinux-restricted syscalls
# (openat on / and /data, linkat, symlinkat, etc.) that the compiled binary
# still calls during module resolution. Try a few candidate paths in case
# bun-termux is installed under a non-standard PREFIX.
SHIM=""
for candidate in \
  "$PREFIX/lib/bun-termux/libbun-android-fix.so" \
  "/data/data/com.termux/files/usr/lib/bun-termux/libbun-android-fix.so"
do
  if [ -f "$candidate" ]; then
    SHIM="$candidate"
    break
  fi
done
if [ -n "$SHIM" ]; then
  if [ -z "${LD_PRELOAD:-}" ]; then
    export LD_PRELOAD="$SHIM"
  else
    case ":$LD_PRELOAD:" in
      *":$SHIM:"*) ;;  # already loaded
      *) export LD_PRELOAD="$SHIM:$LD_PRELOAD" ;;
    esac
  fi
else
  echo "warning: bun-termux LD_PRELOAD shim not found — FFI may crash" >&2
fi

# TMPDIR — Android has no /tmp; the shim translates /tmp → $TMPDIR
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
mkdir -p "$TMPDIR" 2>/dev/null || true

# HOME — some Termux invocations lose it
export HOME="${HOME:-$PREFIX/home}"

# TERM — opencode's TUI needs a terminal type
export TERM="${TERM:-xterm-256color}"

# Exec the compiled binary
exec /data/data/com.termux/files/usr/lib/opencode/opencode "$@"
WRAPPER_EOF

chmod 755 "$PREFIX/bin/opencode"
ok "Wrapper created at $PREFIX/bin/opencode"

# --- Step 3: Verify install --------------------------------------------------
echo ""
echo "=== Step 3: Verify install ==="

# Run opencode --version through the wrapper
VERSION_OUTPUT=$("$PREFIX/bin/opencode" --version 2>&1) || true
if [ -n "$VERSION_OUTPUT" ]; then
  ok "opencode --version: $VERSION_OUTPUT"
else
  warn "opencode --version produced no output (may need debugging)"
fi

echo ""
echo "=========================================="
echo "Install complete!"
echo "=========================================="
echo ""
INSTALLED_SIZE=$(du -h "$PREFIX/lib/opencode/opencode" 2>/dev/null | cut -f1 || echo "?")
echo "Binary:  $PREFIX/lib/opencode/opencode ($INSTALLED_SIZE)"
echo "Wrapper: $PREFIX/bin/opencode"
echo ""
echo "Now you can run opencode from anywhere:"
echo "  opencode"
echo "  opencode --version"
echo "  opencode run 'hello world'"
echo ""
echo "The wrapper sets PREFIX, MEMTAG_OPTIONS=off, and LD_PRELOAD automatically."
