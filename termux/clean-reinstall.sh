#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# clean-reinstall.sh — nuke node_modules + bun.lock, verify, reinstall
# =============================================================================
#
# WHY THIS EXISTS:
#   On Termux's slow filesystem, `rm -rf node_modules` on 4000+ packages can
#   take a LONG time and may appear to complete when it hasn't. If the user
#   runs `bun install` before the deletion finishes, node_modules ends up in
#   a broken state where only root devDeps (12 packages) are installed.
#
#   This script:
#     1. Deletes node_modules + bun.lock
#     2. VERIFIES the deletion completed (waits if needed)
#     3. Runs bun install
#     4. Verifies the install actually worked (package count + critical packages)
#
# USAGE:
#   bash termux/clean-reinstall.sh
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

cd "$OPENCODE_ROOT"

echo "=========================================="
echo "clean-reinstall: nuke + verify + reinstall"
echo "=========================================="
echo "  OPENCODE_ROOT: $OPENCODE_ROOT"
echo "  BUN_BIN:       $BUN_BIN"
echo "=========================================="

# --- Step 1: Delete node_modules + bun.lock ----------------------------------
echo ""
echo "=== Step 1: Delete node_modules + bun.lock ==="

if [ -d node_modules ]; then
  NM_SIZE=$(du -sh node_modules 2>/dev/null | cut -f1 || echo "?")
  info "node_modules exists ($NM_SIZE) — deleting (this may take a minute on slow fs)"
  rm -rf node_modules
  # Wait for deletion to complete — on Termux's slow filesystem, rm -rf on
  # 4000+ packages can return before the directory is fully gone.
  echo -n "  waiting for deletion to complete"
  for i in $(seq 1 60); do
    if [ ! -d node_modules ]; then
      echo ""
      ok "node_modules deleted"
      break
    fi
    echo -n "."
    sleep 1
    if [ $i -eq 60 ]; then
      echo ""
      warn "node_modules still exists after 60s — trying again"
      rm -rf node_modules
      sleep 2
      if [ -d node_modules ]; then
        fail "could not delete node_modules after 2 attempts"
      fi
      ok "node_modules deleted (second attempt)"
    fi
  done
else
  ok "node_modules already gone"
fi

if [ -f bun.lock ]; then
  rm -f bun.lock
  ok "bun.lock deleted"
else
  ok "bun.lock already gone"
fi

# --- Step 2: Verify clean state ---------------------------------------------
echo ""
echo "=== Step 2: Verify clean state ==="

if [ -d node_modules ]; then
  fail "node_modules STILL EXISTS — deletion failed"
fi
if [ -f bun.lock ]; then
  fail "bun.lock STILL EXISTS — deletion failed"
fi
ok "clean state verified"

# --- Step 3: Run bun install -------------------------------------------------
echo ""
echo "=== Step 3: Run bun install ==="
echo "  (this will take 2-5 minutes on first install — 4000+ packages)"
echo ""

if "$BUN_BIN" install 2>&1 | tee /tmp/bun-install.log; then
  ok "bun install completed"
else
  INSTALL_EXIT=$?
  fail "bun install failed (exit $INSTALL_EXIT)"
fi

# --- Step 4: Verify install worked -------------------------------------------
echo ""
echo "=== Step 4: Verify install ==="

# Check node_modules exists
if [ ! -d node_modules ]; then
  fail "node_modules does not exist after install"
fi

# Count packages
NM_COUNT=$(ls -1 node_modules 2>/dev/null | wc -l)
info "node_modules has $NM_COUNT top-level entries"

if [ "$NM_COUNT" -lt 100 ]; then
  warn "only $NM_COUNT packages installed — expected 1000+"
  warn "this suggests workspace packages were not resolved"
  info ""
  info "Checking if workspace packages exist..."
  for pkg in @opentui/solid @opentui/keymap solid-js effect yargs zod; do
    if [ -f "node_modules/$pkg/package.json" ]; then
      ok "  $pkg: installed"
    else
      fail "  $pkg: MISSING"
    fi
  done
  fail "install incomplete — only $NM_COUNT packages (expected 1000+)"
fi

ok "$NM_COUNT packages installed"

# Check critical packages
echo ""
echo "=== Critical package check ==="
CRITICAL_OK=0
CRITICAL_FAIL=0
for pkg in @opentui/solid @opentui/keymap solid-js effect yargs zod @xincli/opentui-core-android-arm64; do
  if [ -f "node_modules/$pkg/package.json" ]; then
    ok "$pkg"
    CRITICAL_OK=$((CRITICAL_OK + 1))
  else
    fail "$pkg MISSING"
    CRITICAL_FAIL=$((CRITICAL_FAIL + 1))
  fi
done

# Check @ff-labs/fff-bun — this WILL be missing on Termux (os restriction)
# That's OK — Patch 1f handles it in source.
if [ -f "node_modules/@ff-labs/fff-bun/package.json" ]; then
  ok "@ff-labs/fff-bun (unexpected on Termux — os restriction should skip it)"
else
  info "@ff-labs/fff-bun: NOT installed (expected on Termux — Patch 1f handles this)"
fi

# Check native .so
SO_PATH="node_modules/@xincli/opentui-core-android-arm64/libopentui.so"
if [ -f "$SO_PATH" ]; then
  ok "libopentui.so: present"
else
  fail "libopentui.so: MISSING"
fi

echo ""
echo "=========================================="
echo "Reinstall summary"
echo "=========================================="
echo -e "  ${GREEN}OK:${NC}   $CRITICAL_OK critical packages"
echo -e "  ${RED}FAIL:${NC} $CRITICAL_FAIL critical packages missing"

if [ "$CRITICAL_FAIL" -gt 0 ]; then
  echo ""
  echo -e "${RED}Some critical packages are missing. opencode will not start.${NC}"
  echo "Check the bun install output above for errors."
  exit 1
fi

echo ""
ok "Install verified. Ready to run opencode:"
echo "  bash termux/run-opencode-termux.sh"
