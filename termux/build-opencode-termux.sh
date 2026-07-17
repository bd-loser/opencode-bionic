#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# build-opencode-termux.sh — compile opencode into a single binary on Termux
# =============================================================================
#
# WHAT THIS DOES:
#   Runs `bun build --compile` to produce a single standalone opencode binary
#   that runs on Termux without needing `bun run` + the full source tree.
#
# HOW IT WORKS:
#   opencode's upstream build.ts (packages/opencode/script/build.ts) has a
#   `target` field that tells Bun which runtime to embed:
#     target: "bun-linux-arm64"  → downloads glibc Bun from npm (BREAKS on Termux)
#
#   We can't use the upstream build.ts directly because:
#     1. It has no Android target in allTargets
#     2. The `target: "bun-linux-arm64"` would download a glibc Bun runtime
#        that can't run under Bionic
#     3. The --single flag filters targets to process.platform/process.arch,
#        but on Termux process.platform is "linux" (Bun normalizes android→linux),
#        so it would pick the linux-arm64 target and try to download glibc Bun
#
#   The fix: run a CUSTOM build script (build-termux.ts) that:
#     - Sets `target: "bun"` (use the CURRENT running Bun as the embedded runtime)
#       This is the patched bun-termux binary, which already works on Bionic.
#     - Sets the right bunfsRoot for Linux/Android
#     - Skips the smoke test (the binary is for Termux, can run there)
#     - Skips the web UI embed (not needed for TUI, saves build time)
#
#   Your bun-termux already patches `bun build --compile` for Android:
#     - src/exe_format/elf.zig: fixes PIE/ASLR with Bionic's linker64
#     - Uses last writable PT_LOAD segment, writes offset to BUN_COMPILED
#
# PREREQUISITES:
#   - opencode runs successfully via `bash termux/run-opencode-termux.sh`
#   - node_modules is fully installed (4055 packages)
#   - patches are applied (bash termux/apply-termux-patches.sh)
#
# USAGE:
#   bash termux/build-opencode-termux.sh
#       Produces: packages/opencode/dist/opencode-android-arm64/bin/opencode
#
#   After build, install it:
#       cp packages/opencode/dist/opencode-android-arm64/bin/opencode $PREFIX/bin/opencode
#       chmod +x $PREFIX/bin/opencode
#       opencode --version
#
# =============================================================================

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

# Verify we're in opencode
if [ ! -f "$OPENCODE_ROOT/package.json" ] || ! grep -q '"name": "opencode"' "$OPENCODE_ROOT/package.json" 2>/dev/null; then
  fail "Not in opencode root. Set OPENCODE_ROOT or run from opencode root."
fi

cd "$OPENCODE_ROOT"

# Verify node_modules exists
if [ ! -d "node_modules" ]; then
  fail "node_modules not found. Run: bash termux/clean-reinstall.sh"
fi

# Verify patches applied
if ! grep -q "opencode-bionic-patched" "packages/core/src/filesystem/fff.bun.ts" 2>/dev/null; then
  fail "Patches not applied. Run: bash termux/apply-termux-patches.sh"
fi

# Verify bun is the launcher (not raw binary — FFI would crash during build)
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

# --- Run the custom build script ---------------------------------------------
info "Running build-termux.ts..."

cd "$OPENCODE_ROOT/packages/opencode"

# Capture exit code without triggering set -e (temporarily disable it).
# Without this, a non-zero exit would kill the script before we could
# print a useful error message; the BUILD_EXIT check below would be dead.
set +e
"$BUN_BIN" run script/build-termux.ts
BUILD_EXIT=$?
set -e

if [ "$BUILD_EXIT" -ne 0 ]; then
  fail "build-termux.ts failed (exit $BUILD_EXIT)"
fi

# --- Verify the binary exists ------------------------------------------------
BINARY_PATH="$OPENCODE_ROOT/packages/opencode/dist/opencode-android-arm64/bin/opencode"

if [ ! -f "$BINARY_PATH" ]; then
  fail "Binary not found at $BINARY_PATH"
fi

ok "Binary built: $BINARY_PATH"

# Show file info
info "file type: $(file -b "$BINARY_PATH" 2>/dev/null | head -1)"
info "size: $(du -h "$BINARY_PATH" | cut -f1)"

# --- Smoke test (the binary should run on this Termux) -----------------------
echo ""
echo "=== Smoke test ==="
"$BINARY_PATH" --version && ok "Smoke test passed" || warn "Smoke test failed (binary may still work — try running it)"

# --- Instructions ------------------------------------------------------------
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
