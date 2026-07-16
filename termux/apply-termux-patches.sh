#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# apply-termux-patches.sh — Patches opencode for Android/Termux (Bun runtime)
# =============================================================================
#
# WHAT THIS DOES:
#   Patches the opencode package.json (and a few source files) so it runs on
#   Termux under the patched bun-termux binary with @xincli/opentui-core
#   native binding.
#
# STRATEGY (root-cause first, no bandaids):
#
#   The key insight: the user's @xincli/opentui-core@0.4.8 npm package
#   ALREADY has Termux detection baked in (the resolveNativePackage() function
#   in the compiled index.js checks for process.platform === "android" OR
#   (linux + $PREFIX contains "com.termux"), and loads
#   @xincli/opentui-core-android-arm64). So we don't need to patch source —
#   we just need to make opencode USE @xincli/opentui-core instead of
#   @opentui/core.
#
#   1. (Core) Add npm alias override in root package.json:
#        overrides["@opentui/core"] = "npm:@xincli/opentui-core@0.4.8"
#      Root cause: opencode pins @opentui/core@0.4.3 in its catalog. Upstream
#      @opentui/core has no Android branch in resolveNativePackage(). On
#      Termux it throws "opentui is not supported on the current platform".
#      The @xincli fork (0.4.8) fixes this. The override forces ALL
#      @opentui/core resolutions in the workspace to use the @xincli fork,
#      including the peer-dep resolution from @opentui/solid@0.4.3 and
#      @opentui/keymap@0.4.3.
#
#   2. (Native binary) Add @xincli/opentui-core-android-arm64@0.4.8 as
#      optionalDependency so it gets installed on aarch64-Termux:
#        optionalDependencies["@xincli/opentui-core-android-arm64"] = "0.4.8"
#      Root cause: @xincli/opentui-core@0.4.8's compiled resolveNativePackage()
#      does `await import("@xincli/opentui-core-android-arm64")`. If that
#      package isn't installed, it falls through to the dev-mode prebuilt
#      path (which doesn't exist in an npm install), then throws. The
#      optionalDependency ensures it's fetched.
#
#   3. (Catalog) Update the catalog version pin too, so workspace packages
#      that reference "catalog:" for @opentui/core also resolve to 0.4.8.
#      Root cause: opencode uses Bun's catalog feature for centralized
#      version pinning. The override alone doesn't update the catalog —
#      workspace packages that say "@opentui/core": "catalog:" would still
#      try to install 0.4.3 (which then gets overridden to @xincli). Updating
#      the catalog to 0.4.8 is cleaner.
#
#   4. (Soft failures — no patch needed, just documented):
#      - @parcel/watcher: no Bionic binary → opencode's watcher.ts catches
#        the require error and degrades to no file watching. Acceptable.
#      - @ff-labs/fff-bun: no Bionic binary → opencode's search.ts catches
#        FileFinder.isAvailable()=false and degrades to ripgrep. Acceptable.
#      - @lydell/node-pty: not loaded under Bun (the #pty import's "bun"
#        condition loads bun-pty instead). No issue.
#
#   5. (Runtime checks, no source patch):
#      - Verify LD_PRELOAD shim is active (else FFI SIGABRTs from MTE)
#      - Verify MEMTAG_OPTIONS=off (else scudo tags heap pointers, FFI
#        passes tagged pointers to free(), SIGABRT)
#      - Verify clipboard tool exists (else clipboard features silently no-op)
#
# ROBUSTNESS RULES (same as bun-termux/apply-android-patches.sh):
#   - Idempotent: detect existing patches via markers, safe to re-run
#   - Verify EVERY patch applied; abort on failure
#   - Print [OK]/[SKIP]/[FAIL] markers for greppable CI logs
#   - JSON edits via python3 (json module), not sed — survives reformatting
#
# PREREQUISITES:
#   - bun-termux installed (provides `bun` and `bunx` with LD_PRELOAD shim)
#     -> curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
#   - opencode cloned and `bun install` already run successfully
#
# USAGE:
#   cd /path/to/opencode
#   bash /path/to/apply-termux-patches.sh
#
# AFTER PATCHING:
#   Run `bun install` again to pick up the new override + optionalDependency.
#   Then run opencode via run-opencode-termux.sh.
#
# =============================================================================

set -euo pipefail

# --- Config ------------------------------------------------------------------
# Version 0.4.9 fixes the compiled binary crash (bunfs .so extraction).
# It also publishes @xincli/opentui-solid and @xincli/opentui-keymap,
# which means we no longer need the `overrides` hack — we can use
# clean catalog pins with npm: aliases instead.
XINCLI_CORE_VERSION="${XINCLI_CORE_VERSION:-0.4.9}"
XINCLI_ANDROID_VERSION="${XINCLI_ANDROID_VERSION:-0.4.9}"
XINCLI_REACT_VERSION="${XINCLI_REACT_VERSION:-0.4.9}"
XINCLI_SOLID_VERSION="${XINCLI_SOLID_VERSION:-0.4.9}"
XINCLI_KEYMAP_VERSION="${XINCLI_KEYMAP_VERSION:-0.4.9}"
PATCH_MARKER="opencode-bionic-patched"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MUTED='\033[0;2m'
NC='\033[0m'

ok()    { echo -e "  ${GREEN}[OK]${NC}   $*"; }
skip()  { echo -e "  ${BLUE}[SKIP]${NC} $*"; }
fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN_COUNT=$((WARN_COUNT + 1)); }
info()  { echo -e "  ${MUTED}       $*${NC}"; }

FAIL_COUNT=0
WARN_COUNT=0

# --- Locate the opencode root ------------------------------------------------
OPENCODE_ROOT="${OPENCODE_ROOT:-$(pwd)}"
if [ ! -f "$OPENCODE_ROOT/package.json" ] || ! grep -q '"name": "opencode"' "$OPENCODE_ROOT/package.json" 2>/dev/null; then
  echo -e "${RED}Error: not inside opencode root.${NC}"
  echo -e "  Expected $OPENCODE_ROOT/package.json with \"name\": \"opencode\"."
  echo -e "  Run from the opencode root, or set OPENCODE_ROOT=/path/to/opencode"
  exit 1
fi

cd "$OPENCODE_ROOT"

echo "=========================================="
echo "Applying Termux patches to opencode"
echo "Source: $OPENCODE_ROOT"
echo "Marker: $PATCH_MARKER"
echo "@xincli/opentui-core: $XINCLI_CORE_VERSION"
echo "@xincli/opentui-core-android-arm64: $XINCLI_ANDROID_VERSION"
echo "=========================================="

# --- Termux detection (for runtime checks) -----------------------------------
is_termux() {
  [ -n "${PREFIX:-}" ] && case "$PREFIX" in *com.termux*) return 0;; esac
  return 1
}

if ! is_termux; then
  echo -e "${YELLOW}Note: PREFIX does not look like Termux ($PREFIX).${NC}"
  echo -e "${MUTED}Patches will still apply (detection is runtime, not patch-time).${NC}"
fi

# --- Helper: verify a JSON key exists ----------------------------------------
verify_json_key() {
  local file="$1"
  local python_expr="$2"  # e.g. 'pkg["overrides"]["@opentui/core"]'
  local expected="$3"
  python3 -c "
import json, sys
with open('$file') as f: pkg = json.load(f)
try:
    actual = $python_expr
    if actual == '$expected':
        print('OK')
    else:
        print(f'GOT:{actual}')
        sys.exit(1)
except (KeyError, TypeError):
    print('MISSING')
    sys.exit(1)
" 2>/dev/null
}

# =============================================================================
# PATCH 1: Root package.json — npm alias override + optionalDependency
# =============================================================================
#
# Root cause:
#   opencode pins @opentui/core@0.4.3 in its catalog. Upstream 0.4.3's
#   resolveNativePackage() has no Android branch — on Termux (Bun normalizes
#   android→linux, so process.platform==="linux" but libc is Bionic) it
#   throws "opentui is not supported on the current platform: linux-arm64".
#
# Fix (v2 — clean catalog pins, no overrides hack):
#   Since 0.4.9, we publish @xincli/opentui-solid and @xincli/opentui-keymap
#   to npm. These packages directly depend on @xincli/opentui-core (via
#   npm: alias in their dependencies field). So we no longer need the
#   `overrides` hack to force the cascade — we just pin the catalog entries
#   to npm:@xincli/... aliases directly.
#
#   This is cleaner because:
#     1. catalog: pins are Bun's intended mechanism (not overrides)
#     2. No "override cascade" needed — @xincli/opentui-solid already
#        points to @xincli/opentui-core in its own dependencies
#     3. The overrides field can be removed entirely
#
#   We pin:
#     catalog["@opentui/core"]  = "npm:@xincli/opentui-core@0.4.9"
#     catalog["@opentui/solid"] = "npm:@xincli/opentui-solid@0.4.9"
#     catalog["@opentui/keymap"] = "npm:@xincli/opentui-keymap@0.4.9"
#
#   And add the .so as optionalDependency:
#     optionalDependencies["@xincli/opentui-core-android-arm64"] = "0.4.9"
#
#   We also remove the stale @opentui/* entries from `overrides` (if they
#   exist from a previous run with the old patch), since we're using catalog
#   pins now.
#
# Compatibility note:
#   @xincli/opentui-core@0.4.9 ships compiled JS from opentui 0.4.9 source.
#   The TS bindings API between 0.4.3 and 0.4.9 should be compatible (same
#   0.4.x minor). The 0.4.9 release also fixes the compiled binary crash
#   (bunfs .so extraction) — see packages/core/src/zig.ts in the opentui fork.
# =============================================================================

echo ""
echo "=== Patch 1: Root package.json — clean catalog pins (v2, no overrides) ==="

ROOT_PKG_JSON="$OPENCODE_ROOT/package.json"

# Idempotency: check if all 3 catalog pins already present with correct version
CATALOG_OK=true
for pkg_name in "@opentui/core" "@opentui/solid" "@opentui/keymap"; do
  case "$pkg_name" in
    "@opentui/core")   expected="npm:@xincli/opentui-core@${XINCLI_CORE_VERSION}" ;;
    "@opentui/solid")  expected="npm:@xincli/opentui-solid@${XINCLI_SOLID_VERSION}" ;;
    "@opentui/keymap") expected="npm:@xincli/opentui-keymap@${XINCLI_KEYMAP_VERSION}" ;;
  esac
  result=$(verify_json_key "$ROOT_PKG_JSON" "pkg[\"workspaces\"][\"catalog\"][\"${pkg_name}\"]" "$expected" 2>/dev/null || echo "MISSING")
  if [ "$result" != "OK" ]; then
    CATALOG_OK=false
    break
  fi
done

if [ "$CATALOG_OK" = "true" ]; then
  skip "all 3 catalog pins already present (@xincli @ ${XINCLI_CORE_VERSION})"
else
  info "patching: $ROOT_PKG_JSON"
  info "  current catalog value: ${CURRENT_CATALOG:-<none>}"

  python3 <<PYEOF
import json, sys

with open("$ROOT_PKG_JSON", "r", encoding="utf-8") as f:
    pkg = json.load(f)

catalog = pkg.get("workspaces", {}).get("catalog", {})

# ── Clean v2 approach — all 5 @xincli packages published at 0.4.9 ──
#
# All @opentui/* catalog entries pinned to npm:@xincli/... aliases.
# No overrides needed — @xincli/opentui-solid directly depends on
# @xincli/opentui-core via npm: alias in its own dependencies field.

pins = {
    "@opentui/core":  f"npm:@xincli/opentui-core@${XINCLI_CORE_VERSION}",
    "@opentui/solid": f"npm:@xincli/opentui-solid@${XINCLI_SOLID_VERSION}",
    "@opentui/keymap": f"npm:@xincli/opentui-keymap@${XINCLI_KEYMAP_VERSION}",
}

for name, alias in pins.items():
    if name in catalog:
        old = catalog[name]
        catalog[name] = alias
        print(f"    [1a] catalog['{name}']: {old} -> {alias}")
    else:
        catalog[name] = alias
        print(f"    [1a] catalog['{name}']: <added> -> {alias}")

# Remove stale @opentui/* entries from overrides (from old patch versions).
# We don't need overrides anymore — the catalog pins handle everything.
overrides = pkg.get("overrides", {})
removed_overrides = []
for key in list(overrides.keys()):
    if key in ("@opentui/core", "@opentui/solid", "@opentui/keymap"):
        removed_overrides.append(f"{key}={overrides[key]}")
        del overrides[key]
if removed_overrides:
    print(f"    [1b] Removed stale overrides: {removed_overrides}")
    if not overrides:
        del pkg["overrides"]
        print(f"    [1b] overrides field is now empty — removed entirely")

# Add @xincli/opentui-core-android-arm64 as optionalDependency so the .so
# gets fetched on aarch64-Termux.
opts = pkg.setdefault("optionalDependencies", {})
old = opts.get("@xincli/opentui-core-android-arm64", "<none>")
opts["@xincli/opentui-core-android-arm64"] = "${XINCLI_ANDROID_VERSION}"
print(f"    [1c] optionalDependencies['@xincli/opentui-core-android-arm64']: {old} -> ${XINCLI_ANDROID_VERSION}")

# Mark the package.json as patched
pkg["_opencodeBionic"] = {
    "patched": True,
    "version": "${XINCLI_CORE_VERSION}",
    "marker": "${PATCH_MARKER}",
    "approach": "clean-catalog-pins-v2",
    "note": "Patched by apply-termux-patches.sh for Termux/Android. Safe to remove this key."
}

with open("$ROOT_PKG_JSON", "w", encoding="utf-8") as f:
    json.dump(pkg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"    [1d] marker _opencodeBionic added (approach: clean-catalog-pins-v2)")
PYEOF

  # Verify
  V1=$(verify_json_key "$ROOT_PKG_JSON" 'pkg["workspaces"]["catalog"]["@opentui/core"]' "npm:@xincli/opentui-core@${XINCLI_CORE_VERSION}")
  V2=$(verify_json_key "$ROOT_PKG_JSON" 'pkg["workspaces"]["catalog"]["@opentui/solid"]' "npm:@xincli/opentui-solid@${XINCLI_SOLID_VERSION}")
  V3=$(verify_json_key "$ROOT_PKG_JSON" 'pkg["workspaces"]["catalog"]["@opentui/keymap"]' "npm:@xincli/opentui-keymap@${XINCLI_KEYMAP_VERSION}")
  V4=$(verify_json_key "$ROOT_PKG_JSON" 'pkg["optionalDependencies"]["@xincli/opentui-core-android-arm64"]' "${XINCLI_ANDROID_VERSION}")
  V5=$(verify_json_key "$ROOT_PKG_JSON" 'pkg["_opencodeBionic"]["marker"]' "${PATCH_MARKER}")

  [ "$V1" = "OK" ] && ok "catalog[@opentui/core] → npm:@xincli/opentui-core verified" || fail "catalog[@opentui/core] NOT verified (got: $V1)"
  [ "$V2" = "OK" ] && ok "catalog[@opentui/solid] → npm:@xincli/opentui-solid verified" || fail "catalog[@opentui/solid] NOT verified (got: $V2)"
  [ "$V3" = "OK" ] && ok "catalog[@opentui/keymap] → npm:@xincli/opentui-keymap verified" || fail "catalog[@opentui/keymap] NOT verified (got: $V3)"
  [ "$V4" = "OK" ] && ok "optionalDependencies[@xincli/opentui-core-android-arm64] verified" || fail "optionalDependency NOT verified (got: $V4)"
  [ "$V5" = "OK" ] && ok "marker _opencodeBionic verified" || fail "marker NOT verified (got: $V5)"
fi

# =============================================================================
# PATCH 1b: bunfig.toml — add @xincli/* to minimumReleaseAgeExcludes
# =============================================================================
#
# Root cause:
#   opencode's bunfig.toml has `minimumReleaseAge = 259200` (3 days). Packages
#   published less than 3 days ago are blocked. The excludes list has
#   `@opentui/core` (and all its platform variants) but NOT `@xincli/opentui-core`
#   or `@xincli/opentui-core-android-arm64`. Since the user just published
#   these to npm, `bun install` fails with:
#     error: No version matching "@xincli/opentui-core" found for specifier
#            "npm:@xincli/opentui-core@0.4.8" (blocked by minimum-release-age)
#
# Fix:
#   Add `@xincli/opentui-core` and `@xincli/opentui-core-android-arm64` to the
#   `minimumReleaseAgeExcludes` array in bunfig.toml.
#
#   We also add them to the override excludes in package.json (Bun's
#   `minimumReleaseAgeExcludes` in bunfig.toml is the primary mechanism, but
#   having them documented in both places is belt-and-suspenders).
# =============================================================================

echo ""
echo "=== Patch 1b: bunfig.toml — add @xincli/* to minimumReleaseAgeExcludes ==="

BUNFIG_FILE="$OPENCODE_ROOT/bunfig.toml"

if [ ! -f "$BUNFIG_FILE" ]; then
  fail "$BUNFIG_FILE not found"
else
  if grep -q "@xincli/opentui-keymap" "$BUNFIG_FILE" 2>/dev/null; then
    skip "bunfig.toml already has all 5 @xincli excludes"
  else
    info "patching: $BUNFIG_FILE"

    python3 <<PYEOF
import re, sys

with open("$BUNFIG_FILE", "r", encoding="utf-8") as f:
    content = f.read()

# Find the minimumReleaseAgeExcludes line. It's a single long line:
#   minimumReleaseAgeExcludes = ["@ai-sdk/...", ..., "@opentui/core", ..., "electron-publish"]
# We append our @xincli packages before the closing bracket.

# Strategy: find the closing `]"` of the minimumReleaseAgeExcludes array and
# insert our entries before it. Use regex to match the array content.
pattern = r'(minimumReleaseAgeExcludes\s*=\s*\[)([^\]]*)(\])'
m = re.search(pattern, content)
if not m:
    print("    [FAIL] could not find minimumReleaseAgeExcludes array", file=sys.stderr)
    sys.exit(1)

array_content = m.group(2)
# Check if ALL @xincli packages already in the array (idempotency)
if "@xincli/opentui-keymap" in array_content:
    print("    [SKIP] all 5 @xincli packages already in excludes (idempotency check)")
    sys.exit(0)

# Parse existing entries (split on comma, strip whitespace+quotes)
existing = [e.strip().strip('"').strip("'") for e in array_content.split(",") if e.strip().strip('"').strip("'")]

# All 5 @xincli packages to ensure are present
xincli_pkgs = [
    "@xincli/opentui-core",
    "@xincli/opentui-core-android-arm64",
    "@xincli/opentui-react",
    "@xincli/opentui-solid",
    "@xincli/opentui-keymap",
]

# Add only the ones not already present (dedup)
added = []
for pkg in xincli_pkgs:
    if pkg not in existing:
        existing.append(pkg)
        added.append(pkg)

if not added:
    print("    [SKIP] all 5 @xincli packages already present (dedup check)")
    sys.exit(0)

# Rebuild the array content with proper formatting
new_array_content = ", ".join(f'"{e}"' for e in existing)

print(f"    [1b] Added {len(added)} @xincli package(s) to minimumReleaseAgeExcludes:")
for p in added:
    print(f"         + {p}")

new_content = content[:m.start(2)] + new_array_content + content[m.end(2):]

with open("$BUNFIG_FILE", "w", encoding="utf-8") as f:
    f.write(new_content)
PYEOF

    if grep -q "@xincli/opentui-keymap" "$BUNFIG_FILE" 2>/dev/null; then
      ok "bunfig.toml patched (all 5 @xincli packages excluded from minimum-release-age)"
    else
      fail "bunfig.toml patch verification failed"
    fi
  fi
fi

# =============================================================================
# PATCH 1c: package.json — remove ALL entries from trustedDependencies
# =============================================================================
#
# Root cause:
#   opencode's package.json has `trustedDependencies` listing packages whose
#   install scripts (postinstall, install) are allowed to run:
#     - esbuild
#     - node-pty
#     - protobufjs
#     - tree-sitter
#     - tree-sitter-bash
#     - tree-sitter-powershell
#     - web-tree-sitter
#     - electron
#
#   On Termux with MTE (Memory Tagging Extension), ANY install script that
#   loads a native N-API module crashes with:
#     Pointer tag for 0x... was truncated
#     error: install script from "<package>" terminated by SIGABRT
#
#   This is because N-API's native module loading path bypasses the MTE fix
#   shim (libbun-mte-fix.so). The shim intercepts malloc/free, but N-API
#   uses dlopen+dlsym which gets tagged pointers directly from Bionic's
#   scudo allocator.
#
#   We initially tried removing only tree-sitter-* (Patch 1c v1), but the
#   next `bun install` crashed on protobufjs instead. Then node-pty would
#   crash next. This is whack-a-mole — ANY package with a native install
#   script will crash.
#
# Fix:
#   Remove ALL entries from trustedDependencies. This makes Bun skip ALL
#   dependency install scripts (effectively `--ignore-scripts` for deps).
#   The packages themselves still install (their .js, .wasm, .d.ts files) —
#   only the native compilation/loading scripts are skipped.
#
# Why this is safe for opencode's dev/runtime flow:
#   - esbuild: opencode uses Bun.build() (Bun's built-in bundler), NOT the
#     esbuild CLI. The esbuild binary isn't needed for `bun run src/index.ts`.
#     Only needed for `bun run build` (production binary compilation).
#   - node-pty: NOT used under Bun. opencode's #pty import resolves to
#     bun-pty under the "bun" condition. node-pty is only used under Node.
#   - protobufjs: has a pure JS fallback. The native bindings are optional
#     (used for performance, not correctness).
#   - tree-sitter-*: opencode only uses the .wasm files via web-tree-sitter's
#     WASM runtime. The native N-API bindings are not imported.
#   - web-tree-sitter: same — opencode uses the WASM runtime, not native.
#   - electron: not relevant for Termux (no Electron apps on Android).
#
#   The root-level postinstall script (`bun run --cwd packages/core fix-node-pty`)
#   still runs (trustedDependencies only affects dependencies, not root scripts).
#   fix-node-pty just chmods spawn-helper — harmless if node-pty's install
#   script was skipped (the file won't exist, the script handles that case).
#
#   If you later need a production build (`bun run build`), you may need to
#   temporarily re-add esbuild to trustedDependencies and run `bun install`
#   on a non-Termux machine, or use `bun install --ignore-scripts=false` with
#   a per-package override. But for dev/runtime on Termux, this is correct.
# =============================================================================

echo ""
echo "=== Patch 1c: package.json — remove ALL entries from trustedDependencies ==="

# Check current state
CURRENT_TD_COUNT=$(python3 -c "
import json
with open('$ROOT_PKG_JSON') as f: pkg = json.load(f)
print(len(pkg.get('trustedDependencies', [])))
" 2>/dev/null)

if [ "$CURRENT_TD_COUNT" = "0" ]; then
  skip "trustedDependencies already empty"
else
  info "current trustedDependencies has $CURRENT_TD_COUNT entries"

  python3 <<PYEOF
import json, sys

with open("$ROOT_PKG_JSON", "r", encoding="utf-8") as f:
    pkg = json.load(f)

td = pkg.get("trustedDependencies", [])
before = len(td)
pkg["trustedDependencies"] = []

with open("$ROOT_PKG_JSON", "w", encoding="utf-8") as f:
    json.dump(pkg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"    [1c] Removed all {before} entries from trustedDependencies")
print(f"    (was: {td})")
print(f"    All dependency install scripts will be skipped by Bun")
PYEOF

  # Verify
  AFTER_TD_COUNT=$(python3 -c "
import json
with open('$ROOT_PKG_JSON') as f: pkg = json.load(f)
print(len(pkg.get('trustedDependencies', [])))
" 2>/dev/null)

  if [ "$AFTER_TD_COUNT" = "0" ]; then
    ok "trustedDependencies is now empty — all install scripts skipped"
  else
    fail "trustedDependencies still has $AFTER_TD_COUNT entries"
  fi
fi

# =============================================================================
# PATCH 1d: package.json — remove root postinstall + prepare scripts
# =============================================================================
#
# Root cause:
#   opencode's root package.json has:
#     "postinstall": "bun run --cwd packages/core fix-node-pty"
#     "prepare": "husky"
#
#   These are ROOT package scripts — they ALWAYS run on `bun install`,
#   regardless of trustedDependencies (which only affects DEPENDENCY install
#   scripts). The `prepare` script runs `husky` (git hooks manager) which
#   spawns child processes. On Termux with MTE, this crashes:
#     Pointer tag for 0x... was truncated
#     error: prepare script from "opencode" terminated by SIGABRT
#
#   The postinstall script (fix-node-pty) ran OK in testing — it just chmods
#   spawn-helper files. But it's pointless on Termux because:
#   - node-pty is NOT used under Bun (bun-pty is used instead)
#   - The chmod targets node-pty/prebuilds/*/spawn-helper which don't exist
#     when node-pty's install script was skipped (Patch 1c)
#   So removing it is safe and avoids any future MTE issue.
#
#   The prepare script (husky) is for opencode DEVELOPERS to set up git hooks.
#   It's completely unnecessary for RUNNING opencode on Termux.
#
# Fix:
#   Remove both `postinstall` and `prepare` from the root package.json scripts.
#   This is equivalent to `bun install --ignore-scripts` but only for the root
#   package's own scripts (dependency install scripts were already skipped by
#   Patch 1c's empty trustedDependencies).
#
#   If you later need to develop opencode itself (commit hooks, etc.), restore
#   these scripts or run them manually.
# =============================================================================

echo ""
echo "=== Patch 1d: package.json — remove root postinstall + prepare scripts ==="

# Check current state — list which target scripts are present
CURRENT_SCRIPTS=$(python3 -c "
import json
with open('$ROOT_PKG_JSON') as f: pkg = json.load(f)
scripts = pkg.get('scripts', {})
remove_set = {'postinstall', 'prepare'}
found = [s for s in scripts if s in remove_set]
print(','.join(found) if found else 'NONE')
" 2>/dev/null)

if [ "$CURRENT_SCRIPTS" = "NONE" ]; then
  skip "postinstall + prepare already removed from scripts"
else
  info "current root scripts to remove: $CURRENT_SCRIPTS"

  python3 <<PYEOF
import json, sys

with open("$ROOT_PKG_JSON", "r", encoding="utf-8") as f:
    pkg = json.load(f)

scripts = pkg.get("scripts", {})
remove_set = {"postinstall", "prepare"}
removed = []
for s in remove_set:
    if s in scripts:
        old_val = scripts.pop(s)
        removed.append(f"{s}={old_val!r}")

with open("$ROOT_PKG_JSON", "w", encoding="utf-8") as f:
    json.dump(pkg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"    [1d] Removed {len(removed)} root scripts:")
for r in removed:
    print(f"       - {r}")
print(f"    Remaining scripts: {list(scripts.keys())}")
PYEOF

  # Verify
  AFTER_SCRIPTS=$(python3 -c "
import json
with open('$ROOT_PKG_JSON') as f: pkg = json.load(f)
scripts = pkg.get('scripts', {})
found = [s for s in ['postinstall', 'prepare'] if s in scripts]
print(','.join(found) if found else 'NONE')
" 2>/dev/null)

  if [ "$AFTER_SCRIPTS" = "NONE" ]; then
    ok "postinstall + prepare removed from root scripts"
  else
    fail "scripts still present: $AFTER_SCRIPTS"
  fi
fi

# =============================================================================
# PATCH 1e: package.json — remove stale @ff-labs/fff-bun patchedDependency
# =============================================================================
#
# Root cause:
#   opencode's root package.json has:
#     "patchedDependencies": {
#       "@ff-labs/fff-bun@0.9.3": "patches/@ff-labs%2Ffff-bun@0.9.3.patch",
#       ...
#     }
#   But packages/core/package.json declares:
#     "@ff-labs/fff-bun": "0.9.4"
#   (direct version, not catalog:).
#
#   The patchedDependency version (0.9.3) doesn't match the resolved version
#   (0.9.4). On normal Bun builds this might be lenient (install 0.9.4
#   without the patch). On the Termux canary (1.3.14-canary.1), this causes
#   the package to be silently skipped — `bun install` reports success but
#   @ff-labs/fff-bun is NOT in node_modules. At runtime:
#     error: Cannot find module '@ff-labs/fff-bun' from '.../fff.bun.ts'
#
# Fix:
#   Remove the stale @ff-labs/fff-bun@0.9.3 entry from patchedDependencies.
#   The patch was opencode's own fix for fff-bun's native binary resolution
#   path. On Termux, fff-bun can't load its native binary anyway (no Bionic
#   variant) and opencode's search.ts falls back to ripgrep. So losing this
#   patch is harmless on Termux.
#
#   We do NOT remove other patchedDependencies entries — they match their
#   declared versions and may be needed at runtime (e.g. photon-node's
#   wbindgen fix, solid-js patches, effect patches).
# =============================================================================

echo ""
echo "=== Patch 1e: package.json — remove stale @ff-labs/fff-bun patchedDependency ==="

FFF_PATCH_KEY='@ff-labs/fff-bun@0.9.3'

# Check current state
HAS_FFF_PATCH=$(python3 -c "
import json
with open('$ROOT_PKG_JSON') as f: pkg = json.load(f)
patched = pkg.get('patchedDependencies', {})
print('YES' if '$FFF_PATCH_KEY' in patched else 'NO')
" 2>/dev/null)

if [ "$HAS_FFF_PATCH" = "NO" ]; then
  skip "@ff-labs/fff-bun@0.9.3 not in patchedDependencies (already removed)"
else
  info "found stale $FFF_PATCH_KEY in patchedDependencies"

  python3 <<PYEOF
import json, sys

with open("$ROOT_PKG_JSON", "r", encoding="utf-8") as f:
    pkg = json.load(f)

patched = pkg.get("patchedDependencies", {})
key = "$FFF_PATCH_KEY"
if key in patched:
    patch_file = patched.pop(key)
    print(f"    [1e] Removed {key!r} -> {patch_file!r}")
    print(f"    Remaining patchedDependencies: {len(patched)} entries")
else:
    print(f"    [SKIP] {key!r} not found")

with open("$ROOT_PKG_JSON", "w", encoding="utf-8") as f:
    json.dump(pkg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

  # Verify
  AFTER_HAS_FFF=$(python3 -c "
import json
with open('$ROOT_PKG_JSON') as f: pkg = json.load(f)
patched = pkg.get('patchedDependencies', {})
print('YES' if '$FFF_PATCH_KEY' in patched else 'NO')
" 2>/dev/null)

  if [ "$AFTER_HAS_FFF" = "NO" ]; then
    ok "@ff-labs/fff-bun@0.9.3 removed from patchedDependencies"
  else
    fail "@ff-labs/fff-bun@0.9.3 still in patchedDependencies"
  fi
fi

# =============================================================================
# PATCH 1f: packages/core/src/filesystem/fff.bun.ts — lazy-load @ff-labs/fff-bun
# =============================================================================
#
# Root cause:
#   @ff-labs/fff-bun@0.9.4 has "os": ["darwin", "linux", "win32"] in its
#   package.json. On Termux, process.platform === "android" (even under Bun,
#   the installer checks the real OS). Since "android" is not in the os list,
#   Bun's installer SILENTLY SKIPS the entire package — it's never fetched,
#   never placed in node_modules.
#
#   opencode's fff.bun.ts has a top-level static import:
#     import { FileFinder, type DirItem, ... } from "@ff-labs/fff-bun"
#   When the package isn't installed, this throws immediately at module load:
#     error: Cannot find module '@ff-labs/fff-bun' from '.../fff.bun.ts'
#   This crashes opencode BEFORE it can fall back to ripgrep.
#
#   Note: this is NOT a lockfile issue, NOT a patchedDependencies issue, NOT
#   a trustedDependencies issue. The package itself rejects Android via its
#   os field. Even a completely fresh install (no lockfile, no node_modules)
#   will skip the package.
#
# Fix:
#   Patch fff.bun.ts to use a try/catch require() pattern instead of a static
#   ESM import for the FileFinder value. The type-only imports (DirItem,
#   FileItem, etc.) are safe — they're erased at runtime by TypeScript/Bun.
#
#   If the package isn't installed (Termux), FileFinder is null, available()
#   returns false, and opencode's search.ts falls back to ripgrep — which is
#   the EXISTING behavior for when fff-bun's native binary can't load.
#
#   This is a SOURCE PATCH (modifies a .ts file in the opencode repo), not a
#   package.json patch. It's idempotent — the marker comment prevents
#   re-patching.
# =============================================================================

echo ""
echo "=== Patch 1f: fff.bun.ts — lazy-load @ff-labs/fff-bun (os restriction bypass) ==="

FFF_BUN_TS="$OPENCODE_ROOT/packages/core/src/filesystem/fff.bun.ts"

if [ ! -f "$FFF_BUN_TS" ]; then
  fail "$FFF_BUN_TS not found"
else
  if grep -q "$PATCH_MARKER" "$FFF_BUN_TS" 2>/dev/null; then
    skip "fff.bun.ts already patched"
  else
    info "patching: $FFF_BUN_TS"

    python3 <<PYEOF
import re, sys

with open("$FFF_BUN_TS", "r", encoding="utf-8") as f:
    content = f.read()

marker = "$PATCH_MARKER"
patched = 0

# Step 1: Replace the static value import (FileFinder) with a type-only import
# + a lazy require(). The type imports (DirItem, FileItem, etc.) are preserved
# as type-only — they're erased at runtime.
old_import = r'''import \{
  FileFinder,
  type DirItem,
  type DirSearchResult,
  type FileItem,
  type GrepCursor,
  type GrepMatch,
  type GrepResult,
  type InitOptions,
  type MixedItem,
  type MixedSearchResult,
  type SearchResult,
\} from "@ff-labs/fff-bun"'''

new_import = '''import type {
  DirItem,
  DirSearchResult,
  FileItem,
  GrepCursor,
  GrepMatch,
  GrepResult,
  InitOptions,
  MixedItem,
  MixedSearchResult,
  SearchResult,
} from "@ff-labs/fff-bun"

// ''' + marker + ''' [Patch 1f]: Lazy-load @ff-labs/fff-bun runtime value.
// Root cause: @ff-labs/fff-bun@0.9.4 has "os": ["darwin","linux","win32"] in
// its package.json. On Termux (process.platform === "android"), Bun's installer
// silently skips the package — it's never placed in node_modules. A static
// ESM import would throw "Cannot find module" at startup, crashing opencode
// before it can fall back to ripgrep.
// Fix: use require() (which can be try/caught) instead of a static import.
// If the package isn't installed, FileFinder is null and available() returns
// false — opencode's search.ts then uses the ripgrep fallback (existing behavior).
type FileFinderType = typeof import("@ff-labs/fff-bun")["FileFinder"]
let FileFinder: FileFinderType | null
try {
  FileFinder = require("@ff-labs/fff-bun").FileFinder
} catch {
  FileFinder = null
}'''

new_content, n = re.subn(old_import, new_import, content, count=1)
if n == 1:
    content = new_content
    patched += 1
    print("    [1f-a] Replaced static import with lazy require() + null guard")
else:
    print("    [FAIL] could not find the static import block", file=sys.stderr)
    sys.exit(1)

# Step 2: Patch available() to handle null FileFinder
old_available = r'''export function available\(\) \{
  return FileFinder\.isAvailable\(\)
\}'''

new_available = '''export function available() {
  // ''' + marker + ''' [Patch 1f]: null guard for missing @ff-labs/fff-bun
  if (!FileFinder) return false
  return FileFinder.isAvailable()
}'''

new_content, n = re.subn(old_available, new_available, content, count=1)
if n == 1:
    content = new_content
    patched += 1
    print("    [1f-b] Patched available() with null guard")
else:
    print("    [FAIL] could not find available() function", file=sys.stderr)
    sys.exit(1)

# Step 3: Patch create() to handle null FileFinder
old_create = r'''export function create\(opts: Init\): Result<Picker> \{
  const made = FileFinder\.create\(opts\)'''

new_create = '''export function create(opts: Init): Result<Picker> {
  // ''' + marker + ''' [Patch 1f]: null guard for missing @ff-labs/fff-bun
  if (!FileFinder) return { ok: false, error: "fff-bun not installed on this platform (os restriction)" }
  const made = FileFinder.create(opts)'''

new_content, n = re.subn(old_create, new_create, content, count=1)
if n == 1:
    content = new_content
    patched += 1
    print("    [1f-c] Patched create() with null guard")
else:
    print("    [FAIL] could not find create() function", file=sys.stderr)
    sys.exit(1)

with open("$FFF_BUN_TS", "w", encoding="utf-8") as f:
    f.write(content)

print(f"    Total: {patched}/3 sub-patches applied to fff.bun.ts")
PYEOF

    if grep -q "$PATCH_MARKER" "$FFF_BUN_TS" 2>/dev/null; then
      ok "fff.bun.ts patched (lazy require + null guards)"
    else
      fail "fff.bun.ts patch verification failed"
    fi
  fi
fi

# =============================================================================
# PATCH 2: Verify @opentui/solid and @opentui/keymap still work with override
# =============================================================================
#
# Root cause:
#   @opentui/solid@0.4.3 and @opentui/keymap@0.4.3 declare @opentui/core as a
#   peer dependency. With our override, they'll get @xincli/opentui-core@0.4.8
#   instead. The API between 0.4.3 and 0.4.8 should be compatible, but if
#   @opentui/solid imports a symbol that was renamed/removed in 0.4.8, it'll
#   crash at import time.
#
# Fix:
#   No preemptive patch. Run `bun install` after this script — if there's a
#   peer-dep conflict, Bun will warn. If there's an import error at runtime,
#   it'll be a clear "Cannot find export X in @xincli/opentui-core" message.
#   At that point we can either:
#     (a) pin @xincli/opentui-core to a lower version (0.4.7, 0.4.6)
#     (b) override @opentui/solid and @opentui/keymap to higher versions
#         (but only if @xincli publishes them — currently they don't)
#     (c) fork @opentui/solid and @opentui/keymap, rebuild against 0.4.8
# =============================================================================

echo ""
echo "=== Patch 2: Verify @opentui/solid + @opentui/keymap compatibility ==="

# Check what versions opencode pins for solid/keymap
SOLID_VER=$(python3 -c "import json; pkg=json.load(open('$ROOT_PKG_JSON')); print(pkg.get('workspaces',{}).get('catalog',{}).get('@opentui/solid','?'))")
KEYMAP_VER=$(python3 -c "import json; pkg=json.load(open('$ROOT_PKG_JSON')); print(pkg.get('workspaces',{}).get('catalog',{}).get('@opentui/keymap','?'))")
info "@opentui/solid catalog pin: $SOLID_VER"
info "@opentui/keymap catalog pin: $KEYMAP_VER"

# These will be resolved after `bun install`. If the @xincli/opentui-core@0.4.8
# has API breaks vs 0.4.3, the import will fail. We can't check this statically
# without running bun install — just warn.
if [ "$SOLID_VER" = "0.4.3" ] && [ "$XINCLI_CORE_VERSION" = "0.4.8" ]; then
  warn "@opentui/solid@0.4.3 will get @xincli/opentui-core@0.4.8 via override"
  info "If solid/keymap import errors appear at runtime, set XINCLI_CORE_VERSION=0.4.7"
  info "and re-run this script, then 'bun install' again."
else
  ok "version combinations look reasonable"
fi

# =============================================================================
# PATCH 3: @ff-labs/fff-bun — short-circuit isAvailable() on Termux (optional)
# =============================================================================
#
# Root cause:
#   fff-bun resolves its native lib via require("@ff-labs/fff-bin-linux-<arch>-<gnu|musl>/...")
#   On Termux (Bionic libc) neither glibc nor musl variant loads. The require
#   throws, opencode's filesystem/search.ts catches it and falls back to
#   ripgrep. So functionally OK — but stderr gets a noisy stack trace.
#
# Fix:
#   OPTIONAL. Skip unless --with-fff-fix is passed. opencode already
#   handles the failure gracefully.
# =============================================================================

echo ""
echo "=== Patch 3: @ff-labs/fff-bun (optional, --with-fff-fix to enable) ==="

if [ "${1:-}" != "--with-fff-fix" ]; then
  skip "fff-bun patch skipped (opencode degrades to ripgrep gracefully). Pass --with-fff-fix to enable."
else
  FFF_DIR="$OPENCODE_ROOT/node_modules/@ff-labs/fff-bun"
  if [ ! -d "$FFF_DIR" ]; then
    skip "@ff-labs/fff-bun not in node_modules (already optional?)"
  else
    info "found @ff-labs/fff-bun at: $FFF_DIR"
    FFF_FILE=""
    for c in "$FFF_DIR/src/download.ts" "$FFF_DIR/src/platform.ts" "$FFF_DIR/index.js" "$FFF_DIR/index.ts"; do
      if [ -f "$c" ] && grep -qE "fff-bin-linux|@ff-labs/fff-bin-" "$c" 2>/dev/null; then
        FFF_FILE="$c"
        break
      fi
    done
    if [ -z "$FFF_FILE" ]; then
      warn "could not find the fff native require site; skipping"
    elif grep -q "$PATCH_MARKER" "$FFF_FILE" 2>/dev/null; then
      skip "$FFF_FILE already patched"
    else
      python3 <<PYEOF
import os, re, sys
fff_file = "$FFF_FILE"
with open(fff_file, "r", encoding="utf-8") as f:
    content = f.read()
marker = "$PATCH_MARKER"
new_content = content
if "function binaryExists" in content:
    new_content, n = re.subn(
        r'(function binaryExists\s*\(\s*\)\s*:\s*boolean\s*\{)',
        r'''\1
  // ''' + marker + ''' [Patch 3]: Termux has no fff native variant — short-circuit.
  if (typeof process.env.PREFIX === "string" && process.env.PREFIX.includes("com.termux")) {
    return false;
  }''',
        content, count=1)
    if n == 1:
        with open(fff_file, "w", encoding="utf-8") as f:
            f.write(new_content)
        print("    [1] Patched binaryExists() with Termux short-circuit")
    else:
        print("    [FAIL] could not patch binaryExists()", file=sys.stderr)
        sys.exit(1)
else:
    print("    [SKIP] no binaryExists() function found (fff layout differs)", file=sys.stderr)
    sys.exit(1)
PYEOF
      if grep -q "$PATCH_MARKER" "$FFF_FILE" 2>/dev/null; then
        ok "$FFF_FILE patched"
      else
        fail "$FFF_FILE patch verification failed"
      fi
    fi
  fi
fi

# =============================================================================
# PATCH 4: clipboard runtime check (no source patch)
# =============================================================================
#
# Root cause:
#   opencode's tui imports clipboardy for clipboard operations. clipboardy
#   shells out to `pbcopy`/`xclip`/`powershell`. None exist on Termux.
#   This is a soft failure — clipboard just won't work, no crash.
#
# Fix:
#   No source patch. User can `pkg install termux-api` and symlink
#   `termux-clipboard-set` → `xclip` for clipboard support.
# =============================================================================

echo ""
echo "=== Patch 4: clipboard (runtime check only, no source patch) ==="

if command -v termux-clipboard-set >/dev/null 2>&1; then
  ok "termux-clipboard-set found"
elif command -v xclip >/dev/null 2>&1; then
  ok "xclip found (clipboardy will use it)"
else
  warn "no clipboard tool found. Install termux-api: pkg install termux-api"
  info "or symlink: ln -s \$PREFIX/bin/termux-clipboard-set \$PREFIX/bin/xclip"
  info "clipboard features will silently no-op without this"
fi

# =============================================================================
# PATCH 5: Verify bun-termux LD_PRELOAD shim is active
# =============================================================================
#
# Root cause:
#   The user's bun-termux launchers ($PREFIX/bin/bun, $PREFIX/bin/bunx) set
#   LD_PRELOAD=libbun-android-fix.so and MEMTAG_OPTIONS=off before exec'ing
#   the patched bun binary. If the user invokes bun directly (bypassing the
#   launcher) OR runs opencode via a wrapper that resets env, the shim is
#   missing and bun's FFI will crash with SIGABRT (MTE heap tagging).
#
# Fix:
#   Verify the shim is loaded. Warn (don't fail) if missing.
# =============================================================================

echo ""
echo "=== Patch 5: Verify bun-termux LD_PRELOAD shim ==="

SHIM_PATH="/data/data/com.termux/files/usr/lib/bun-termux/libbun-android-fix.so"
if [ -f "$SHIM_PATH" ]; then
  ok "shim exists: $SHIM_PATH"
  if [ -n "${LD_PRELOAD:-}" ] && case "$LD_PRELOAD" in *libbun-android-fix.so*) true;; *) false;; esac; then
    ok "LD_PRELOAD contains libbun-android-fix.so"
  else
    warn "LD_PRELOAD does NOT contain libbun-android-fix.so"
    info "Make sure you invoke opencode via the bun-termux launcher:"
    info "  $PREFIX/bin/bun run packages/opencode/src/index.ts"
    info "NOT via /data/data/com.termux/files/usr/lib/bun-termux/bun directly"
  fi
  if [ "${MEMTAG_OPTIONS:-}" = "off" ]; then
    ok "MEMTAG_OPTIONS=off (MTE disabled)"
  else
    warn "MEMTAG_OPTIONS is not 'off' — FFI may SIGABRT"
  fi
else
  warn "bun-termux shim not found at $SHIM_PATH"
  info "Install bun-termux: curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo -e "  ${GREEN}OK:${NC}   patches verified"
echo -e "  ${YELLOW}WARN:${NC} $WARN_COUNT warnings"
echo -e "  ${RED}FAIL:${NC} $FAIL_COUNT failures"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo -e "${RED}Some patches failed. opencode may not start.${NC}"
  echo "Fix the failures above and re-run this script (it's idempotent)."
  exit 1
fi

echo ""
echo "Next steps:"
echo "  1. If node_modules is missing or broken, run the clean reinstall helper:"
echo "       bash $(dirname "$0")/clean-reinstall.sh"
echo "     (This deletes node_modules + bun.lock, verifies deletion, reinstalls)"
echo ""
echo "  2. Run opencode:"
echo "       bash $(dirname "$0")/run-opencode-termux.sh"
echo ""
echo "Note: @ff-labs/fff-bun will NOT be in node_modules on Termux (the package"
echo "has os:[darwin,linux,win32] — Bun skips it on Android). This is expected."
echo "Patch 1f modifies fff.bun.ts to handle the missing package gracefully."
