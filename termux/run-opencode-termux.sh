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

# --- Verify patches are applied ----------------------------------------------
# With Approach B, @opentui/core is overridden to @xincli/opentui-core which
# ships compiled JS (index.js), not TS source. Check for both layouts.

# Check 1: is @opentui/core installed at all?
OPENTUI_CORE_FOUND=""
for p in \
  "$OPENCODE_ROOT/node_modules/@opentui/core/package.json" \
  "$OPENCODE_ROOT/node_modules/@xincli/opentui-core/package.json"; do
  if [ -f "$p" ]; then
    OPENTUI_CORE_FOUND="$p"
    break
  fi
done

if [ -z "$OPENTUI_CORE_FOUND" ]; then
  echo "Warning: @opentui/core not found in node_modules." >&2
  echo "  Run 'bun install' in $OPENCODE_ROOT first." >&2
else
  # Check 2: is it the @xincli fork (Approach B) or upstream (Approach A)?
  OPENTUI_CORE_NAME=$(python3 -c "import json; print(json.load(open('$OPENTUI_CORE_FOUND')).get('name','?'))" 2>/dev/null)
  if [ "$OPENTUI_CORE_NAME" = "@xincli/opentui-core" ]; then
    # Approach B: verify the compiled JS has Termux detection
    if grep -rq "com.termux" "$OPENCODE_ROOT/node_modules/@opentui/core/" 2>/dev/null; then
      :
    else
      echo "Warning: @xincli/opentui-core is installed but Termux detection not found in compiled JS." >&2
      echo "  The package may be corrupted. Try: rm -rf node_modules/@opentui && bun install" >&2
    fi
  fi
fi

# Check 3: is the native .so installed?
SO_PATH="$OPENCODE_ROOT/node_modules/@xincli/opentui-core-android-arm64/libopentui.so"
if [ -f "$SO_PATH" ]; then
  :
else
  echo "Warning: @xincli/opentui-core-android-arm64/libopentui.so not found." >&2
  echo "  Run: bash $SCRIPT_DIR/apply-termux-patches.sh && bun install" >&2
  echo "  (warning only — opencode will crash at startup if .so is missing)" >&2
fi

# --- Exec opencode -----------------------------------------------------------
cd "$OPENCODE_ROOT"

# opencode's dev script:
#   bun run --cwd packages/opencode --conditions=browser src/index.ts
# We replicate it here so the user has full control over args.
exec "$BUN_BIN" run \
  --cwd packages/opencode \
  --conditions=browser \
  src/index.ts \
  "${PASS_THROUGH[@]}"
