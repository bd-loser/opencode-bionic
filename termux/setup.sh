#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# setup.sh — one-command opencode setup for Termux/Android
# =============================================================================
#
# WHAT THIS DOES (in order):
#   1. Verifies prerequisites (Termux, bun-termux, git, python)
#   2. Clones or updates opencode source
#   3. Runs clean reinstall (nuke node_modules + bun.lock, fresh install)
#   4. Applies Termux patches (clean v2 catalog pins for @xincli packages)
#   5. Runs isolated opentui smoke test (verifies FFI + .so + solid API)
#   6. Prints next steps
#
# This script is IDEMPOTENT — safe to re-run anytime. It detects existing
# state and skips completed steps.
#
# USAGE:
#   bash termux/setup.sh                           # clone to ~/opencode
#   bash termux/setup.sh /path/to/clone            # clone to specific dir
#   OPENCODE_ROOT=/existing/checkout bash termux/setup.sh
#
# ENVIRONMENT:
#   OPENCODE_ROOT     Path to opencode checkout (auto-detected if unset)
#   XINCLI_CORE_VERSION  Override @xincli/opentui-core version (default: 0.4.9)
#   SKIP_SMOKE_TEST   Set to "1" to skip the isolated opentui test
#   SKIP_REINSTALL    Set to "1" to skip nuke+reinstall (use existing node_modules)
#
# PREREQUISITES (install BEFORE running this):
#   pkg update && pkg upgrade
#   pkg install git python build-essential clang make
#   curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
#
# =============================================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MUTED='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

ok()    { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; exit 1; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
info()  { echo -e "  ${MUTED}       $*${NC}"; }
header(){ echo -e "\n${BOLD}${BLUE}=== $* ===${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Default config ───────────────────────────────────────────────────────────
XINCLI_CORE_VERSION="${XINCLI_CORE_VERSION:-0.4.9}"

# =============================================================================
# Step 1: Verify Termux environment
# =============================================================================
header "Step 1: Verify Termux environment"

if [ -z "${PREFIX:-}" ] || [ ! -d "/data/data/com.termux" ]; then
  fail "This script must run inside Termux. PREFIX=$PREFIX"
fi
ok "Termux detected: $PREFIX"

# Verify prerequisites
command -v git >/dev/null 2>&1 || fail "git not found. Run: pkg install git"
ok "git: $(git --version | head -1)"

command -v python3 >/dev/null 2>&1 || fail "python3 not found. Run: pkg install python"
ok "python3: $(python3 --version)"

command -v bun >/dev/null 2>&1 || fail "bun not found. Install bun-termux:
  curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash"
ok "bun: $(bun --version)"

# Verify bun is the launcher (not raw binary — FFI would crash during build)
BUN_TYPE=$(file -b "$PREFIX/bin/bun" 2>/dev/null || echo "unknown")
case "$BUN_TYPE" in
  *ELF*) fail "$PREFIX/bin/bun is raw binary (ELF), not launcher. FFI will crash. Reinstall bun-termux." ;;
esac
ok "bun is the launcher script (not raw binary)"

# Verify bun-termux shim
SHIM="/data/data/com.termux/files/usr/lib/bun-termux/libbun-android-fix.so"
if [ ! -f "$SHIM" ]; then
  warn "bun-termux shim not found at $SHIM"
  info "FFI may SIGABRT. Reinstall bun-termux if opencode crashes on startup."
else
  ok "bun-termux shim present"
fi

# =============================================================================
# Step 2: Locate or clone opencode
# =============================================================================
header "Step 2: Locate or clone opencode source"

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
    git clone --depth 50 https://github.com/sst/opencode.git "$CLONE_TARGET" || fail "git clone failed"
    OPENCODE_ROOT="$CLONE_TARGET"
    ok "Cloned to $OPENCODE_ROOT"
  fi
else
  OPENCODE_ROOT="$HOME/opencode"
  if [ -d "$OPENCODE_ROOT" ]; then
    ok "Using existing: $OPENCODE_ROOT"
  else
    info "Cloning opencode to: $OPENCODE_ROOT"
    git clone --depth 50 https://github.com/sst/opencode.git "$OPENCODE_ROOT" || fail "git clone failed"
    ok "Cloned to $OPENCODE_ROOT"
  fi
fi

# Verify it's actually opencode
if [ ! -f "$OPENCODE_ROOT/package.json" ] || ! grep -q '"name": "opencode"' "$OPENCODE_ROOT/package.json" 2>/dev/null; then
  fail "$OPENCODE_ROOT does not look like opencode (no package.json with name=opencode)"
fi

cd "$OPENCODE_ROOT"

# =============================================================================
# Step 3: Clean reinstall (optional — skip with SKIP_REINSTALL=1)
# =============================================================================
header "Step 3: Install dependencies"

if [ "${SKIP_REINSTALL:-0}" = "1" ] && [ -d "$OPENCODE_ROOT/node_modules" ]; then
  ok "SKIP_REINSTALL=1 — using existing node_modules"
else
  if [ ! -f "$SCRIPT_DIR/clean-reinstall.sh" ]; then
    fail "clean-reinstall.sh not found at $SCRIPT_DIR/clean-reinstall.sh"
  fi
  OPENCODE_ROOT="$OPENCODE_ROOT" bash "$SCRIPT_DIR/clean-reinstall.sh" || fail "clean-reinstall.sh failed"
fi

# =============================================================================
# Step 4: Apply Termux patches
# =============================================================================
header "Step 4: Apply Termux patches"

if [ ! -f "$SCRIPT_DIR/apply-termux-patches.sh" ]; then
  fail "apply-termux-patches.sh not found at $SCRIPT_DIR/apply-termux-patches.sh"
fi

XINCLI_CORE_VERSION="$XINCLI_CORE_VERSION" \
OPENCODE_ROOT="$OPENCODE_ROOT" \
  bash "$SCRIPT_DIR/apply-termux-patches.sh" || fail "apply-termux-patches.sh failed"

# Re-run bun install to pick up the new catalog pins + optionalDependency
header "Step 4b: Re-install with @xincli catalog pins"
cd "$OPENCODE_ROOT"
bun install 2>&1 | sed 's/^/  /' || warn "bun install had warnings (may be OK)"

# =============================================================================
# Step 5: Isolated opentui smoke test (optional)
# =============================================================================
if [ "${SKIP_SMOKE_TEST:-0}" != "1" ]; then
  header "Step 5: Isolated opentui smoke test"

  if [ ! -f "$SCRIPT_DIR/test-opentui-isolated.sh" ]; then
    warn "test-opentui-isolated.sh not found — skipping smoke test"
  else
    bash "$SCRIPT_DIR/test-opentui-isolated.sh" || warn "smoke test failed (opencode may still work — try running it)"
  fi
fi

# =============================================================================
# Step 6: Summary + next steps
# =============================================================================
header "Setup complete!"

echo ""
echo "  opencode source: $OPENCODE_ROOT"
echo "  @xincli version: $XINCLI_CORE_VERSION"
echo ""
echo "${BOLD}Next steps:${NC}"
echo ""
echo "  ${BLUE}1. Run opencode (dev mode):${NC}"
echo "     bash $SCRIPT_DIR/run-opencode-termux.sh"
echo ""
echo "  ${BLUE}2. Build compiled binary:${NC}"
echo "     bash $SCRIPT_DIR/build-opencode-termux.sh"
echo ""
echo "  ${BLUE}3. Install binary system-wide:${NC}"
echo "     bash $SCRIPT_DIR/install-opencode-termux.sh"
echo "     opencode --version"
echo ""
echo "  ${BLUE}4. Run opencode TUI:${NC}"
echo "     opencode"
echo ""
echo "${MUTED}If opencode crashes on startup, check:${NC}"
echo "${MUTED}  1. LD_PRELOAD contains libbun-android-fix.so${NC}"
echo "${MUTED}  2. MEMTAG_OPTIONS=off is set${NC}"
echo "${MUTED}  3. @xincli/opentui-core-android-arm64 is in node_modules/${NC}"
echo "${MUTED}  4. The .so is ARM64 ELF:${NC}"
echo "${MUTED}     file node_modules/@xincli/opentui-core-android-arm64/libopentui.so${NC}"
