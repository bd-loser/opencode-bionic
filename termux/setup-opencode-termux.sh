#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# setup-opencode-termux.sh — one-shot setup for opencode on Termux
# =============================================================================
#
# WHAT THIS DOES:
#   1. Verifies prerequisites (Termux, bun-termux, git)
#   2. Clones opencode (or uses existing checkout at $OPENCODE_ROOT)
#   3. Runs `bun install` (the bun-termux launcher handles LD_PRELOAD)
#   4. Applies Termux patches (apply-termux-patches.sh)
#   5. Verifies the result and prints next steps
#
# USAGE:
#   bash setup-opencode-termux.sh                  # clone to ~/opencode
#   bash setup-opencode-termux.sh /path/to/clone   # clone to specific dir
#   OPENCODE_ROOT=/existing/checkout bash setup-opencode-termux.sh
#
# PREREQUISITES (install BEFORE running this):
#   pkg update && pkg upgrade
#   pkg install git python build-essential clang make
#   curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MUTED='\033[0;2m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; exit 1; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
info() { echo -e "  ${MUTED}       $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "opencode-termux setup"
echo "=========================================="

# --- 1. Verify Termux --------------------------------------------------------
if [ -z "${PREFIX:-}" ] || [ ! -d "/data/data/com.termux" ]; then
  fail "This script must be run inside Termux. PREFIX=$PREFIX"
fi
ok "Termux detected: $PREFIX"

# --- 2. Verify prerequisites -------------------------------------------------
echo ""
echo "Checking prerequisites..."

command -v git >/dev/null 2>&1 || fail "git not found. Run: pkg install git"
ok "git: $(git --version | head -1)"

command -v python3 >/dev/null 2>&1 || fail "python3 not found. Run: pkg install python"
ok "python3: $(python3 --version)"

command -v bun >/dev/null 2>&1 || fail "bun not found. Install bun-termux:
  curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash"
ok "bun: $(bun --version)"

# Verify bun is the patched Termux build (check LD_PRELOAD shim exists)
SHIM="/data/data/com.termux/files/usr/lib/bun-termux/libbun-android-fix.so"
if [ ! -f "$SHIM" ]; then
  warn "bun-termux shim not found at $SHIM"
  info "FFI may SIGABRT. Reinstall bun-termux if opencode crashes on startup."
else
  ok "bun-termux shim present"
fi

# --- 3. Locate or clone opencode ---------------------------------------------
echo ""
echo "Locating opencode source..."

OPENCODE_ROOT="${OPENCODE_ROOT:-}"
CLONE_TARGET="${1:-}"

if [ -n "$OPENCODE_ROOT" ] && [ -d "$OPENCODE_ROOT" ]; then
  ok "Using existing checkout: $OPENCODE_ROOT"
elif [ -n "$CLONE_TARGET" ]; then
  if [ -d "$CLONE_TARGET" ]; then
    OPENCODE_ROOT="$CLONE_TARGET"
    ok "Using existing dir: $OPENCODE_ROOT"
  else
    info "Cloning opencode to: $CLONE_TARGET"
    git clone --depth 50 https://github.com/sst/opencode.git "$CLONE_TARGET" || \
      fail "git clone failed"
    OPENCODE_ROOT="$CLONE_TARGET"
    ok "Cloned to $OPENCODE_ROOT"
  fi
else
  OPENCODE_ROOT="$HOME/opencode"
  if [ -d "$OPENCODE_ROOT" ]; then
    ok "Using existing: $OPENCODE_ROOT"
  else
    info "Cloning opencode to: $OPENCODE_ROOT"
    git clone --depth 50 https://github.com/sst/opencode.git "$OPENCODE_ROOT" || \
      fail "git clone failed"
    ok "Cloned to $OPENCODE_ROOT"
  fi
fi

# Verify it's actually opencode
if [ ! -f "$OPENCODE_ROOT/package.json" ] || ! grep -q '"name": "opencode"' "$OPENCODE_ROOT/package.json" 2>/dev/null; then
  fail "$OPENCODE_ROOT does not look like an opencode checkout (no package.json with name=opencode)"
fi

cd "$OPENCODE_ROOT"

# --- 4. bun install ----------------------------------------------------------
echo ""
echo "Running bun install (this may take a while on first run)..."

# Patched bun already handles /tmp, /etc/resolv.conf, linkat, etc. via the
# LD_PRELOAD shim. Just run it.
if [ -d "$OPENCODE_ROOT/node_modules" ]; then
  warn "node_modules already exists. Skipping install."
  warn "If you hit issues, run: rm -rf node_modules && bun install"
else
  if bun install 2>&1 | sed 's/^/  /'; then
    ok "bun install succeeded"
  else
    fail "bun install failed. See logs above."
  fi
fi

# --- 5. Apply Termux patches -------------------------------------------------
echo ""
echo "Applying Termux patches..."

if [ ! -f "$SCRIPT_DIR/apply-termux-patches.sh" ]; then
  fail "apply-termux-patches.sh not found next to this script ($SCRIPT_DIR)"
fi

OPENCODE_ROOT="$OPENCODE_ROOT" bash "$SCRIPT_DIR/apply-termux-patches.sh" || \
  fail "apply-termux-patches.sh failed"

# --- 6. Final verification ---------------------------------------------------
echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "opencode is at: $OPENCODE_ROOT"
echo ""
echo "Next: launch opencode with:"
echo "  bash $SCRIPT_DIR/run-opencode-termux.sh"
echo ""
echo "Or pass arguments:"
echo "  bash $SCRIPT_DIR/run-opencode-termux.sh -- run 'hello world'"
echo "  bash $SCRIPT_DIR/run-opencode-termux.sh -- doctor"
echo ""
echo "If opencode crashes on startup, check:"
echo "  1. LD_PRELOAD contains libbun-android-fix.so"
echo "  2. MEMTAG_OPTIONS=off is set"
echo "  3. @xincli/opentui-core-android-arm64 is in node_modules/"
echo "  4. The .so is ARM64 ELF: file node_modules/@xincli/opentui-core-android-arm64/libopentui.so"
echo ""
echo "Report issues with full output. Be precise about the failing step."
