#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# run-opencode-termux.sh — dev-mode launcher (bun run against source)
# =============================================================================
#
# For the compiled binary, use $PREFIX/bin/opencode instead.
#
# USAGE:
#   bash termux/run-opencode-termux.sh                # run opencode TUI
#   bash termux/run-opencode-termux.sh -- run "hi"    # pass args to opencode
#   bash termux/run-opencode-termux.sh -- doctor      # run opencode doctor
#
# ENVIRONMENT:
#   OPENCODE_ROOT       path to opencode checkout (auto-detected)
#   BUN_BIN             override bun binary (default: $PREFIX/bin/bun)
#   OPENCODE_LOG_LEVEL  DEBUG|INFO|WARN|ERROR (default: INFO)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_ROOT="${OPENCODE_ROOT:-}"
if [ -z "$OPENCODE_ROOT" ]; then
  for candidate in "$SCRIPT_DIR/.." "$SCRIPT_DIR" "$(pwd)"; do
    if [ -f "$candidate/package.json" ] && grep -q '"name": "opencode"' "$candidate/package.json" 2>/dev/null; then
      OPENCODE_ROOT="$(cd "$candidate" && pwd)"
      break
    fi
  done
fi

if [ -z "$OPENCODE_ROOT" ] || [ ! -f "$OPENCODE_ROOT/package.json" ]; then
  echo "Error: could not locate opencode root." >&2
  echo "Set OPENCODE_ROOT=/path/to/opencode or run this script from inside the repo." >&2
  exit 1
fi

BUN_BIN="${BUN_BIN:-$(command -v bun 2>/dev/null || echo "$PREFIX/bin/bun")}"
if [ ! -x "$BUN_BIN" ]; then
  echo "Error: bun not found. Install bun-termux:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash" >&2
  exit 1
fi

# opentui/fff libc selectors: leave UNSET on Termux (Bionic is neither glibc nor musl).
unset OPENTUI_LIBC OPENCODE_LIBC FFF_LIBC 2>/dev/null || true

export OPENCODE_LOG_LEVEL="${OPENCODE_LOG_LEVEL:-INFO}"

PASS_THROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; PASS_THROUGH+=("$@"); break ;;
    *) PASS_THROUGH+=("$1"); shift ;;
  esac
done

echo "==========================================" >&2
echo "opencode-termux dev launcher" >&2
echo "==========================================" >&2
echo "  OPENCODE_ROOT: $OPENCODE_ROOT" >&2
echo "  BUN_BIN:       $BUN_BIN" >&2
echo "  Args:          ${PASS_THROUGH[*]:-<none>}" >&2
echo "==========================================" >&2

cd "$OPENCODE_ROOT"

# opencode's dev script:
#   bun run --cwd packages/opencode --conditions=browser src/index.ts
exec "$BUN_BIN" run \
  --cwd packages/opencode \
  --conditions=browser \
  src/index.ts \
  "${PASS_THROUGH[@]}"
