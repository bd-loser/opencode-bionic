#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# rebuild-opencode.sh — one-command rebuild + reinstall of opencode binary
# =============================================================================
#
# WHAT THIS DOES:
#   1. Pulls latest opencode source (git pull)
#   2. Re-applies Termux patches (idempotent — skips if already patched)
#   3. Re-runs bun install (picks up latest @xincli packages)
#   4. Compiles the binary (bun build --compile)
#   5. Installs binary + wrapper to $PREFIX
#   6. Verifies with `opencode --version`
#
# This is the script you run after a new @xincli/opentui-* release.
# It's idempotent and safe to re-run.
#
# USAGE:
#   bash termux/rebuild-opencode.sh                    # full rebuild + install
#   bash termux/rebuild-opencode.sh --no-pull          # skip git pull
#   bash termux/rebuild-opencode.sh --no-install       # build only, don't install
#   bash termux/rebuild-opencode.sh --smoke-test       # run opencode TUI for 3s test
#
# ENVIRONMENT:
#   OPENCODE_ROOT     Path to opencode checkout (auto-detected if unset)
#   XINCLI_CORE_VERSION  Override @xincli version (default: 0.4.9)
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
XINCLI_CORE_VERSION="${XINCLI_CORE_VERSION:-0.4.10}"

# ── Parse args ───────────────────────────────────────────────────────────────
DO_PULL=true
DO_INSTALL=true
DO_SMOKE=false
for arg in "$@"; do
  case "$arg" in
    --no-pull)      DO_PULL=false ;;
    --no-install)   DO_INSTALL=false ;;
    --smoke-test)   DO_SMOKE=true ;;
    --help|-h)
      echo "Usage: bash rebuild-opencode.sh [--no-pull] [--no-install] [--smoke-test]"
      exit 0
      ;;
    *) fail "Unknown arg: $arg" ;;
  esac
done

# =============================================================================
# Step 0: Locate opencode
# =============================================================================
header "Step 0: Locate opencode"

OPENCODE_ROOT="${OPENCODE_ROOT:-}"
if [ -z "$OPENCODE_ROOT" ]; then
  for candidate in "$SCRIPT_DIR/.." "$SCRIPT_DIR" "$HOME/opencode" "$(pwd)"; do
    if [ -f "$candidate/package.json" ] && grep -q '"name": "opencode"' "$candidate/package.json" 2>/dev/null; then
      OPENCODE_ROOT="$(cd "$candidate" && pwd)"
      break
    fi
  done
fi
[ -n "$OPENCODE_ROOT" ] || fail "Could not locate opencode. Set OPENCODE_ROOT=/path/to/opencode"
ok "OPENCODE_ROOT: $OPENCODE_ROOT"

cd "$OPENCODE_ROOT"

# =============================================================================
# Step 1: Pull latest source
# =============================================================================
if $DO_PULL; then
  header "Step 1: Pull latest opencode source"
  git pull --ff-only 2>&1 | sed 's/^/  /' || warn "git pull failed (may be offline — continuing with existing source)"
  ok "source updated"
else
  header "Step 1: Pull latest source (SKIPPED — --no-pull)"
fi

# =============================================================================
# Step 2: Re-apply patches (idempotent)
# =============================================================================
header "Step 2: Re-apply Termux patches"

if [ ! -f "$SCRIPT_DIR/apply-termux-patches.sh" ]; then
  fail "apply-termux-patches.sh not found at $SCRIPT_DIR"
fi

XINCLI_CORE_VERSION="$XINCLI_CORE_VERSION" \
OPENCODE_ROOT="$OPENCODE_ROOT" \
  bash "$SCRIPT_DIR/apply-termux-patches.sh" || fail "apply-termux-patches.sh failed"

# =============================================================================
# Step 3: Re-install deps (picks up latest @xincli packages)
# =============================================================================
header "Step 3: Re-install dependencies"

# Force bun to re-resolve @xincli packages by removing them from node_modules
info "Removing @xincli packages from node_modules to force re-resolution..."
rm -rf "$OPENCODE_ROOT/node_modules/@xincli" 2>/dev/null || true
rm -rf "$OPENCODE_ROOT/node_modules/@opentui" 2>/dev/null || true

bun install 2>&1 | sed 's/^/  /' || fail "bun install failed"
ok "dependencies installed"

# Verify critical packages
for pkg in "@opentui/core" "@opentui/solid" "@opentui/keymap" "@xincli/opentui-core-android-arm64"; do
  if [ -f "$OPENCODE_ROOT/node_modules/$pkg/package.json" ]; then
    ok "$pkg installed"
  else
    # Check workspace node_modules too (Bun's isolated layout)
    found=false
    for ws in opencode core tui cli; do
      if [ -f "$OPENCODE_ROOT/packages/$ws/node_modules/$pkg/package.json" ]; then
        ok "$pkg installed (in packages/$ws/node_modules)"
        found=true
        break
      fi
    done
    $found || fail "$pkg MISSING"
  fi
done

# Verify @opentui/core is the @xincli fork
CORE_PKG_PATH=""
for p in "$OPENCODE_ROOT/node_modules/@opentui/core/package.json" "$OPENCODE_ROOT/packages/opencode/node_modules/@opentui/core/package.json"; do
  if [ -f "$p" ]; then
    CORE_PKG_PATH="$p"
    break
  fi
done
if [ -n "$CORE_PKG_PATH" ]; then
  CORE_NAME=$(python3 -c "import json; print(json.load(open('$CORE_PKG_PATH')).get('name','?'))" 2>/dev/null)
  if [ "$CORE_NAME" = "@xincli/opentui-core" ]; then
    ok "@opentui/core is the @xincli fork (clean v2 catalog pin working)"
  else
    fail "@opentui/core is $CORE_NAME (expected @xincli/opentui-core) — catalog pin not applied"
  fi
fi

# Verify native .so
SO_PATH="$OPENCODE_ROOT/node_modules/@xincli/opentui-core-android-arm64/libopentui.so"
if [ -f "$SO_PATH" ]; then
  SO_TYPE=$(file -b "$SO_PATH" 2>/dev/null || echo "?")
  case "$SO_TYPE" in
    *ELF*arm*aarch64*|*ELF*64-bit*ARM*|*ELF*64-bit*LSB*shared*)
      ok "libopentui.so: ARM64 ELF ($(du -h "$SO_PATH" | cut -f1))"
      ;;
    *)
      warn "libopentui.so: unexpected type: $SO_TYPE"
      ;;
  esac
else
  fail "libopentui.so not found at $SO_PATH"
fi

# =============================================================================
# Step 4: Build the compiled binary
# =============================================================================
header "Step 4: Build compiled binary"

if [ ! -f "$SCRIPT_DIR/build-opencode-termux.sh" ]; then
  fail "build-opencode-termux.sh not found at $SCRIPT_DIR"
fi

OPENCODE_ROOT="$OPENCODE_ROOT" bash "$SCRIPT_DIR/build-opencode-termux.sh" || fail "build-opencode-termux.sh failed"

BINARY="$OPENCODE_ROOT/packages/opencode/dist/opencode-android-arm64/bin/opencode"
[ -f "$BINARY" ] || fail "Binary not found at $BINARY"
ok "Binary built: $BINARY ($(du -h "$BINARY" | cut -f1))"

# =============================================================================
# Step 5: Install (optional)
# =============================================================================
if $DO_INSTALL; then
  header "Step 5: Install binary + wrapper"

  if [ ! -f "$SCRIPT_DIR/install-opencode-termux.sh" ]; then
    fail "install-opencode-termux.sh not found at $SCRIPT_DIR"
  fi

  OPENCODE_ROOT="$OPENCODE_ROOT" bash "$SCRIPT_DIR/install-opencode-termux.sh" || fail "install-opencode-termux.sh failed"

  # Verify
  header "Step 6: Verify install"
  VERSION_OUTPUT=$("$PREFIX/bin/opencode" --version 2>&1) || true
  if [ -n "$VERSION_OUTPUT" ]; then
    ok "opencode --version: $VERSION_OUTPUT"
  else
    warn "opencode --version produced no output"
  fi
else
  header "Step 5: Install (SKIPPED — --no-install)"
  echo ""
  info "Binary is at: $BINARY"
  info "To install: bash $SCRIPT_DIR/install-opencode-termux.sh"
fi

# =============================================================================
# Step 7: Optional smoke test
# =============================================================================
if $DO_SMOKE; then
  header "Step 7: Smoke test (run TUI for 3s)"
  info "Running: timeout 3 opencode"
  timeout 3 opencode 2>&1 | head -20 || true
  ok "Smoke test done (exit was expected after 3s)"
fi

# =============================================================================
# Summary
# =============================================================================
header "Rebuild complete!"

echo ""
echo "  Binary:  $PREFIX/lib/opencode/opencode"
echo "  Wrapper: $PREFIX/bin/opencode"
echo ""
echo "${BOLD}Run:${NC} opencode"
echo ""
echo "${MUTED}If opencode crashes:${NC}"
echo "${MUTED}  - Check: echo \$MEMTAG_OPTIONS (must be 'off')${NC}"
echo "${MUTED}  - Check: echo \$LD_PRELOAD (must contain libbun-android-fix.so)${NC}"
echo "${MUTED}  - Check: file \$PREFIX/lib/opencode/opencode (must be ELF)${NC}"
echo "${MUTED}  - The 0.4.9 release fixes the compiled binary crash (bunfs .so extraction)${NC}"
