#!/data/data/com.termux/files/usr/bin/bash
# setup.sh — one-command opencode setup for Termux/Android
#
# Fetches upstream opencode at the version pinned in versions.json,
# applies the config delta (versions.ts) and source patches
# (termux/patches/*), runs bun install, and optionally runs the
# isolated opentui smoke test.
#
# Idempotent: safe to re-run. Delegates to termux/ci/prepare-build-tree.sh
# for the fetch+patch pipeline, so behavior matches CI exactly.
#
# USAGE:
#   bash termux/setup.sh                       # build tree at ~/opencode
#   bash termux/setup.sh /path/to/build/tree   # build tree at custom path
#   OPENCODE_ROOT=/existing bash termux/setup.sh   # only if ALREADY a prepared tree
#
# ENVIRONMENT:
#   OPENCODE_ROOT     Pre-existing prepared tree (skips fetch+patch)
#   SKIP_SMOKE_TEST   "1" to skip the isolated opentui test
#   SKIP_INSTALL      "1" to skip bun install (assume already installed)

set -euo pipefail

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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=ci/versions.sh
. "$SCRIPT_DIR/ci/versions.sh"

header "Step 1: Verify Termux environment"
if [ -z "${PREFIX:-}" ] || [ ! -d "/data/data/com.termux" ]; then
  fail "This script must run inside Termux. PREFIX=${PREFIX:-unset}"
fi
ok "Termux detected: $PREFIX"
command -v git >/dev/null 2>&1 || fail "git not found. Run: pkg install git"
ok "git: $(git --version | head -1)"
command -v bun >/dev/null 2>&1 || fail "bun not found. Install bun-termux:
  curl -fsSL $BUN_TERMUX_INSTALL_URL | bash"
ok "bun: $(bun --version)"

header "Step 2: Prepare build tree (fetch + patch)"
CLONE_TARGET="${1:-$HOME/opencode}"

if [ -n "${OPENCODE_ROOT:-}" ] && [ -d "$OPENCODE_ROOT" ]; then
  ok "Using existing prepared tree: $OPENCODE_ROOT"
  info "(skipping fetch+patch; assuming tree is already prepared)"
else
  OPENCODE_ROOT="$CLONE_TARGET"
  if [ -d "$OPENCODE_ROOT" ]; then
    info "Refreshing tree at $OPENCODE_ROOT (removing existing)"
    rm -rf "$OPENCODE_ROOT"
  fi
  bash "$SCRIPT_DIR/ci/prepare-build-tree.sh" "$OPENCODE_ROOT" \
    || fail "prepare-build-tree.sh failed"
fi

cd "$OPENCODE_ROOT"

if [ "${SKIP_INSTALL:-0}" != "1" ]; then
  header "Step 3: bun install"
  bun install 2>&1 | sed 's/^/  /' || warn "bun install had warnings (may be OK)"
fi

if [ "${SKIP_SMOKE_TEST:-0}" != "1" ]; then
  header "Step 4: Isolated opentui smoke test"
  if [ ! -f "$SCRIPT_DIR/test-opentui-isolated.sh" ]; then
    warn "test-opentui-isolated.sh not found — skipping smoke test"
  else
    OPENCODE_ROOT="$OPENCODE_ROOT" bash "$SCRIPT_DIR/test-opentui-isolated.sh" \
      || warn "smoke test failed (opencode may still work — try running it)"
  fi
fi

header "Setup complete"
echo ""
echo "  build tree:      $OPENCODE_ROOT"
echo "  opencode pinned: $OPENCODE_VERSION_PIN"
echo "  @xincli/core:    $XINCLI_CORE_VERSION"
echo ""
echo "${BOLD}Next:${NC}"
echo "  ${BLUE}dev mode:${NC}      OPENCODE_ROOT=$OPENCODE_ROOT bash $SCRIPT_DIR/run-opencode-termux.sh"
echo "  ${BLUE}build binary:${NC}  OPENCODE_ROOT=$OPENCODE_ROOT bash $SCRIPT_DIR/build-opencode-termux.sh"
echo "  ${BLUE}install:${NC}       OPENCODE_ROOT=$OPENCODE_ROOT bash $SCRIPT_DIR/install-opencode-termux.sh"
