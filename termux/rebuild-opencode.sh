#!/data/data/com.termux/files/usr/bin/bash
# rebuild-opencode.sh — one-command rebuild + reinstall on Termux.
#
# Under the quilt-style architecture, this repo doesn't hold an opencode
# checkout — we fetch upstream fresh and apply patches every time. That
# gives us a clean, reproducible tree with no drift.
#
# Steps: prepare-build-tree.sh → bun install → build-opencode-termux.sh →
# install-opencode-termux.sh.
#
# Usage:
#   bash termux/rebuild-opencode.sh                    # full rebuild + install
#   bash termux/rebuild-opencode.sh --no-install       # build only
#   bash termux/rebuild-opencode.sh --smoke-test       # 3s TUI check post-install
#   BUILD_DIR=/path/to/tree bash termux/rebuild-opencode.sh  # reuse a tree

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; MUTED='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
ok()    { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; exit 1; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
info()  { echo -e "  ${MUTED}       $*${NC}"; }
header(){ echo -e "\n${BOLD}${BLUE}=== $* ===${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DO_INSTALL=true
DO_SMOKE=false
for arg in "$@"; do
  case "$arg" in
    --no-install) DO_INSTALL=false ;;
    --smoke-test) DO_SMOKE=true ;;
    --help|-h)
      echo "Usage: bash rebuild-opencode.sh [--no-install] [--smoke-test]"
      exit 0
      ;;
    *) fail "Unknown arg: $arg" ;;
  esac
done

# Prep environment (Termux only)
if [ -z "${PREFIX:-}" ] || [ ! -d "/data/data/com.termux" ]; then
  fail "This script runs inside Termux. In CI, use termux/ci/build-in-container.sh."
fi
command -v bun >/dev/null 2>&1 || fail "bun not found. Install bun-termux first."

# Where the built tree will live. Reusing a BUILD_DIR skips re-cloning on
# subsequent runs — prepare-build-tree.sh detects an existing tree and
# reuses it verbatim.
BUILD_DIR="${BUILD_DIR:-$HOME/.cache/opencode-bionic/build}"

header "Step 1: Prepare build tree (fetch upstream + apply patches)"
REPO_ROOT="$REPO_ROOT" bash "$SCRIPT_DIR/ci/prepare-build-tree.sh" "$BUILD_DIR"

header "Step 2: bun install"
cd "$BUILD_DIR"
bun install 2>&1 | sed 's/^/  /' || fail "bun install failed"

# Verify @opentui/core resolves to @xincli fork. Bun's isolated linker
# places it in packages/<ws>/node_modules; we probe known locations.
CORE_PKG_PATH=""
for cand in \
  "$BUILD_DIR/node_modules/@opentui/core/package.json" \
  "$BUILD_DIR/packages/opencode/node_modules/@opentui/core/package.json" \
  "$BUILD_DIR/packages/tui/node_modules/@opentui/core/package.json" \
  "$BUILD_DIR/packages/core/node_modules/@opentui/core/package.json"
do
  [ -f "$cand" ] && { CORE_PKG_PATH="$cand"; break; }
done
[ -n "$CORE_PKG_PATH" ] || fail "@opentui/core not resolvable — catalog pin missing?"
CORE_NAME=$(python3 -c "import json; print(json.load(open('$CORE_PKG_PATH')).get('name','?'))")
[ "$CORE_NAME" = "@xincli/opentui-core" ] || fail "@opentui/core is $CORE_NAME (expected @xincli/opentui-core)"
ok "@opentui/core → @xincli/opentui-core"

header "Step 3: Build compiled binary"
OPENCODE_ROOT="$BUILD_DIR" bash "$SCRIPT_DIR/build-opencode-termux.sh"

BINARY="$BUILD_DIR/packages/opencode/dist/opencode-android-arm64/bin/opencode"
[ -f "$BINARY" ] || fail "Binary not found at $BINARY"
ok "Binary: $BINARY ($(du -h "$BINARY" | cut -f1))"

if $DO_INSTALL; then
  header "Step 4: Install"
  OPENCODE_ROOT="$BUILD_DIR" bash "$SCRIPT_DIR/install-opencode-termux.sh"
  VERSION_OUTPUT=$("$PREFIX/bin/opencode" --version 2>&1) || true
  [ -n "$VERSION_OUTPUT" ] && ok "opencode --version: $VERSION_OUTPUT" || warn "opencode --version produced no output"
fi

if $DO_SMOKE; then
  header "Step 5: Smoke test (3s)"
  timeout 3 opencode 2>&1 | head -20 || true
  ok "Smoke test done"
fi

header "Rebuild complete!"
echo ""
echo "  Build tree: $BUILD_DIR"
echo "  Binary:     $PREFIX/bin/opencode"
