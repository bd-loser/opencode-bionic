#!/data/data/com.termux/files/usr/bin/bash
# Compile opencode for Android arm64 using the current patched Bun runtime.
# Requires prepared patches and installed dependencies.

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
MUTED='\033[0;2m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; exit 1; }
info() { echo -e "  ${MUTED}       $*${NC}"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

OPENCODE_ROOT="${OPENCODE_ROOT:-$(pwd)}"
BUN_BIN="${BUN_BIN:-$PREFIX/bin/bun}"

if [ ! -f "$OPENCODE_ROOT/package.json" ] || ! grep -q '"name": "opencode"' "$OPENCODE_ROOT/package.json" 2>/dev/null; then
  fail "Not in opencode root. Set OPENCODE_ROOT or run from opencode root."
fi

cd "$OPENCODE_ROOT"

if [ ! -d "node_modules" ]; then
  fail "node_modules not found. Run: bash termux/clean-reinstall.sh"
fi

if [ ! -f "packages/opencode/script/build-termux.ts" ]; then
  fail "Patches not applied — build-termux.ts is missing. Run: bash termux/ci/prepare-build-tree.sh <dir>"
fi

# FFI requires the Bun launcher rather than the raw ELF.
BUN_TYPE=$(file -b "$BUN_BIN" 2>/dev/null || echo "unknown")
case "$BUN_TYPE" in
  *ELF*) fail "$BUN_BIN is raw binary (ELF), not launcher. FFI will crash during build." ;;
esac

echo "=========================================="
echo "Building opencode binary for Termux"
echo "=========================================="
echo "  OPENCODE_ROOT: $OPENCODE_ROOT"
echo "  BUN_BIN:       $BUN_BIN"
echo "  BUN version:   $($BUN_BIN --version)"
echo "=========================================="

info "Running build-termux.ts..."

cd "$OPENCODE_ROOT/packages/opencode"

set +e
"$BUN_BIN" run script/build-termux.ts
BUILD_EXIT=$?
set -e

if [ "$BUILD_EXIT" -ne 0 ]; then
  fail "build-termux.ts failed (exit $BUILD_EXIT)"
fi

BINARY_PATH="$OPENCODE_ROOT/packages/opencode/dist/opencode-android-arm64/bin/opencode"

if [ ! -f "$BINARY_PATH" ]; then
  fail "Binary not found at $BINARY_PATH"
fi

ok "Binary built: $BINARY_PATH"

info "file type: $(file -b "$BINARY_PATH" 2>/dev/null | head -1)"
info "size: $(du -h "$BINARY_PATH" | cut -f1)"

echo ""
echo "=== Smoke test ==="
"$BINARY_PATH" --version && ok "Smoke test passed" || warn "Smoke test failed (binary may still work — try running it)"

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
echo ""
echo "Binary: $BINARY_PATH"
echo ""
echo "To install system-wide:"
echo "  bash termux/install-opencode-termux.sh"
echo "  opencode --version"
echo ""
echo "To run directly:"
echo "  $BINARY_PATH"
