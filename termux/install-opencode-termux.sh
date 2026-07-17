#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# install-opencode-termux.sh — install the compiled opencode binary system-wide
# =============================================================================
#
# WHAT THIS DOES:
#   1. Copies the compiled binary to $PREFIX/lib/opencode/opencode
#   2. Symlinks $PREFIX/bin/opencode -> the compiled binary
#   3. Verifies the install with `opencode --version`
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

if [ -z "${PREFIX:-}" ]; then
  fail "PREFIX not set. This script must run inside Termux."
fi

BINARY="$OPENCODE_ROOT/packages/opencode/dist/opencode-android-arm64/bin/opencode"

if [ ! -f "$BINARY" ]; then
  fail "Binary not found at $BINARY — run: bash termux/build-opencode-termux.sh"
fi

echo "=========================================="
echo "Installing opencode binary"
echo "=========================================="
echo "  Binary:   $BINARY"
echo "  Target:   $PREFIX/lib/opencode/opencode"
echo "  Symlink:  $PREFIX/bin/opencode"
echo "=========================================="

echo ""
echo "=== Step 1: Copy binary ==="
mkdir -p "$PREFIX/lib/opencode"
cp "$BINARY" "$PREFIX/lib/opencode/opencode"
chmod 755 "$PREFIX/lib/opencode/opencode"
ok "Binary copied to $PREFIX/lib/opencode/opencode"

echo ""
echo "=== Step 2: Create symlink ==="
ln -sf "$PREFIX/lib/opencode/opencode" "$PREFIX/bin/opencode"
ok "Symlink created at $PREFIX/bin/opencode"

echo ""
echo "=== Step 3: Verify install ==="
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
echo "Symlink: $PREFIX/bin/opencode -> $PREFIX/lib/opencode/opencode"
echo ""
echo "Now you can run opencode from anywhere:"
echo "  opencode"
echo "  opencode --version"
echo "  opencode run 'hello world'"
