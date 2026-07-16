#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# run-opencode-termux.sh — launcher for opencode on Termux
# =============================================================================
#
# WHAT THIS DOES:
#   - Ensures the bun-termux LD_PRELOAD shim is active (MTE fix, SELinux
#     syscall interception). If you bypass $PREFIX/bin/bun, the shim is
#     missing and bun's FFI will SIGABRT on the first dlopen.
#   - Sets environment variables opencode + opentui need on Termux:
#       TMPDIR         — Android has no /tmp; bun shim translates /tmp → $TMPDIR
#       OPENTUI_LIBC   — leave unset (Termux is neither glibc nor musl)
#       OPENCODE_LIBC  — same
#       HOME           — make sure $HOME is set (some Termux setups lack it)
#       TERM           — xterm-256color (opencode sets this for pty; matters
#                        for the outer shell so colors work)
#   - Cd's into the opencode root (auto-detected or via OPENCODE_ROOT env)
#   - Execs: bun run --cwd packages/opencode --conditions=browser src/index.ts
#
# WHY --conditions=browser:
#   opencode's dev script (root package.json) uses this flag. It selects the
#   "browser" conditional export from solid-js (and others) so the TUI uses
#   the client-side Solid runtime, not the SSR one. This matches the dev
#   experience on macOS/Linux.
#
# WHY NOT `bun build --compile`:
#   The user's bun-termux already patches `bun build --compile` for Android
#   (the ELF PIE/ASLR fix in src/exe_format/elf.zig). So a single-binary
#   build IS possible. But for the first run, run from source so we can
#   iterate on patches quickly. Once everything works, we can attempt:
#       cd packages/opencode && bun run build -- --single
#   and verify the compiled binary works.
#
# USAGE:
#   bash run-opencode-termux.sh                # run opencode TUI
#   bash run-opencode-termux.sh -- run "hello" # pass args to opencode
#   bash run-opencode-termux.sh -- doctor      # run opencode doctor
#
# ENVIRONMENT:
#   OPENCODE_ROOT  path to opencode checkout (auto-detected if unset)
#   BUN_BIN        override bun binary (default: $PREFIX/bin/bun)
#   OPENCODE_LOG_LEVEL  DEBUG|INFO|WARN|ERROR (default: INFO)
# =============================================================================

set -euo pipefail

# --- Locate opencode root ----------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_ROOT="${OPENCODE_ROOT:-}"
if [ -z "$OPENCODE_ROOT" ]; then
  # Try the script's parent dir, then cwd, then walk up looking for package.json
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

# --- Locate bun (use the launcher, not the raw binary) -----------------------
BUN_BIN="${BUN_BIN:-$PREFIX/bin/bun}"
if [ ! -x "$BUN_BIN" ]; then
  # Try a few fallbacks
  for c in "$PREFIX/bin/bun" "/data/data/com.termux/files/usr/bin/bun" "$(command -v bun 2>/dev/null)"; do
    if [ -x "$c" ]; then
      BUN_BIN="$c"
      break
    fi
  done
fi
if [ ! -x "$BUN_BIN" ]; then
  echo "Error: bun not found. Install bun-termux:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash" >&2
  exit 1
fi

# --- Verify $PREFIX/bin/bun is the launcher (not the raw binary) -------------
# The bun-termux launcher ($PREFIX/bin/bun) is a shell script that sets
# LD_PRELOAD=libbun-android-fix.so + libbun-mte-fix.so and MEMTAG_OPTIONS=off
# before exec'ing the raw bun binary at $PREFIX/lib/bun-termux/bun.
#
# If the user (or a misconfigured install) replaced $PREFIX/bin/bun with the
# raw binary, the shims won't be loaded and FFI will SIGABRT (MTE pointer
# truncation) or SELinux will block directory walks.
#
# Detection: use `file` to check if BUN_BIN is an ELF binary (raw) or not
# (script/text = launcher). We check for "ELF" in the output — if absent,
# it's a text file (the launcher script). This is more robust than matching
# specific script-type strings, which vary across `file` versions.
SHIM="/data/data/com.termux/files/usr/lib/bun-termux/libbun-android-fix.so"

if [ -f "$SHIM" ]; then
  BUN_TYPE=$(file -b "$BUN_BIN" 2>/dev/null || echo "unknown")

  case "$BUN_TYPE" in
    *ELF*)
      # It's an ELF binary — the raw bun, NOT the launcher
      if [ -x "$PREFIX/bin/bun" ] && [ "$BUN_BIN" != "$PREFIX/bin/bun" ]; then
        echo "Warning: $BUN_BIN is the raw bun binary (ELF), not the launcher." >&2
        echo "  Switching to $PREFIX/bin/bun (the launcher) which sets LD_PRELOAD + MEMTAG_OPTIONS." >&2
        BUN_BIN="$PREFIX/bin/bun"
      else
        echo "Warning: $BUN_BIN is an ELF binary, not the launcher script." >&2
        echo "  FFI may SIGABRT. Install/reinstall bun-termux:" >&2
        echo "  curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash" >&2
      fi
      ;;
    *)
      # Not an ELF — it's a text/script file (the launcher). Good.
      :
      ;;
  esac
fi

# --- Set Termux-friendly environment -----------------------------------------
export TMPDIR="${TMPDIR:-$PREFIX/tmp}"
mkdir -p "$TMPDIR" 2>/dev/null || true

# HOME must be set (some Termux invocations lose it).
export HOME="${HOME:-$PREFIX/home}"
mkdir -p "$HOME" 2>/dev/null || true

# TERM: opencode's pty.ts hardcodes TERM=xterm-256color for spawned shells,
# but the OUTER shell also needs a TERM so the TUI render works.
export TERM="${TERM:-xterm-256color}"

# Disable MTE (Memory Tagging Extension) — same as launcher-bun.sh.
# Bionic's scudo allocator tags heap pointers; bun's FFI passes tagged
# pointers to free() which SIGABRTs. The launcher already sets this, but
# set it again defensively in case our env was scrubbed.
export MEMTAG_OPTIONS="${MEMTAG_OPTIONS:-off}"

# opentui/opencode libc selectors: leave UNSET on Termux.
# - OPENTUI_LIBC only accepts glibc/musl. Termux is Bionic.
# - OPENCODE_LIBC is the same.
# - FFF_LIBC is the same.
# If any are set to glibc/musl, opentui/fff will try to load the wrong .so.
unset OPENTUI_LIBC 2>/dev/null || true
unset OPENCODE_LIBC 2>/dev/null || true
unset FFF_LIBC 2>/dev/null || true

# opencode log level
export OPENCODE_LOG_LEVEL="${OPENCODE_LOG_LEVEL:-INFO}"

# Make sure bun doesn't try to auto-update (the auto-updater would download
# a non-Termux bun binary, breaking everything).
export BUN_INSTALL_BIN="${BUN_INSTALL_BIN:-$PREFIX/bin}"
export BUN_INSTALL_CACHE="${BUN_INSTALL_CACHE:-$HOME/.bun/install/cache}"

# --- Parse args (everything after `--` goes to opencode) ---------------------
PASS_THROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --) shift; PASS_THROUGH+=("$@"); break ;;
    *) PASS_THROUGH+=("$1"); shift ;;
  esac
done

# --- Print environment summary (for debugging) -------------------------------
# Note: LD_PRELOAD shown here is the PARENT shell's value. The bun launcher
# ($BUN_BIN) will set its own LD_PRELOAD when it execs the raw bun binary.
# So even if LD_PRELOAD shows only termux-exec here, the actual bun process
# WILL have libbun-android-fix.so + libbun-mte-fix.so loaded (because
# $BUN_BIN is the launcher script, not the raw binary).
echo "==========================================" >&2
echo "opencode-termux launcher" >&2
echo "==========================================" >&2
echo "  OPENCODE_ROOT : $OPENCODE_ROOT" >&2
echo "  BUN_BIN       : $BUN_BIN" >&2
echo "  BUN_BIN type  : $(file -b "$BUN_BIN" 2>/dev/null | head -1 || echo '?')" >&2
echo "  PREFIX        : ${PREFIX:-<unset>}" >&2
echo "  TMPDIR        : $TMPDIR" >&2
echo "  HOME          : $HOME" >&2
echo "  TERM          : $TERM" >&2
echo "  MEMTAG_OPTIONS: $MEMTAG_OPTIONS (will be picked up by bun launcher)" >&2
echo "  Args          : ${PASS_THROUGH[*]:-<none>}" >&2
echo "==========================================" >&2

# --- Pre-flight checks (WARNINGS ONLY — never hard-fail) --------------------
# Bun's workspace install puts packages in the WORKSPACE PACKAGE's own
# node_modules/ (e.g. packages/opencode/node_modules/@opentui/solid), NOT the
# root node_modules/. The root node_modules/ only has the root package's direct
# devDeps. So we check BOTH locations. We NEVER hard-fail — if something is
# genuinely missing, opencode will give a clear "Cannot find module" error at
# the actual import site, which is more useful than our pre-flight guess.

# Helper: find a package's package.json in root OR workspace node_modules
find_pkg() {
  local pkg="$1"
  # Check root node_modules (root devDeps + optionalDeps)
  if [ -f "$OPENCODE_ROOT/node_modules/$pkg/package.json" ]; then
    echo "$OPENCODE_ROOT/node_modules/$pkg/package.json"
    return 0
  fi
  # Check workspace packages' node_modules (Bun's isolated layout)
  for ws in opencode core tui cli; do
    if [ -f "$OPENCODE_ROOT/packages/$ws/node_modules/$pkg/package.json" ]; then
      echo "$OPENCODE_ROOT/packages/$ws/node_modules/$pkg/package.json"
      return 0
    fi
  done
  return 1
}

# Check: @opentui/core (should be the @xincli fork via override)
OPENTUI_CORE_PATH=$(find_pkg "@opentui/core" 2>/dev/null || true)
if [ -n "$OPENTUI_CORE_PATH" ]; then
  CORE_NAME=$(python3 -c "import json; print(json.load(open('$OPENTUI_CORE_PATH')).get('name','?'))" 2>/dev/null)
  if [ "$CORE_NAME" = "@xincli/opentui-core" ]; then
    : # good — @xincli fork via override
  else
    echo "Warning: @opentui/core is $CORE_NAME (expected @xincli/opentui-core)" >&2
  fi
else
  echo "Warning: @opentui/core not found in any node_modules" >&2
fi

# Check: native .so (root optionalDependency — should be a symlink in root node_modules)
SO_PATH="$OPENCODE_ROOT/node_modules/@xincli/opentui-core-android-arm64/libopentui.so"
if [ ! -f "$SO_PATH" ]; then
  echo "Warning: libopentui.so not found at $SO_PATH" >&2
fi

# Check: fff.bun.ts patched (handles missing @ff-labs/fff-bun on Termux)
FFF_TS="$OPENCODE_ROOT/packages/core/src/filesystem/fff.bun.ts"
if ! grep -q "opencode-bionic-patched" "$FFF_TS" 2>/dev/null; then
  echo "Warning: fff.bun.ts not patched. Run: bash termux/apply-termux-patches.sh" >&2
fi

# Check: critical packages (informational only — do NOT hard-fail)
CRITICAL_PACKAGES=("@opentui/solid" "@opentui/keymap" "solid-js" "effect" "yargs" "zod")
MISSING=()
for pkg in "${CRITICAL_PACKAGES[@]}"; do
  if ! find_pkg "$pkg" >/dev/null 2>&1; then
    MISSING+=("$pkg")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Warning: some packages not found in root or workspace node_modules:" >&2
  for p in "${MISSING[@]}"; do echo "  - $p" >&2; done
  echo "  (This may be OK — Bun's module resolution walks up the directory tree." >&2
  echo "   If opencode fails with 'Cannot find module', run: bash termux/clean-reinstall.sh)" >&2
fi

# --- Exec opencode -----------------------------------------------------------
cd "$OPENCODE_ROOT"

# opencode's dev script:
#   bun run --cwd packages/opencode --conditions=browser src/index.ts
exec "$BUN_BIN" run \
  --cwd packages/opencode \
  --conditions=browser \
  src/index.ts \
  "${PASS_THROUGH[@]}"
