# opencode-bionic — opencode patched for Android/Termux

> Fork of [sst/opencode](https://github.com/sst/opencode) that runs on
> Android/Termux under the patched [bun-termux](https://github.com/bd-loser/bun-termux)
> with [@xincli/opentui-core](https://www.npmjs.com/package/@xincli/opentui-core)
> native binding.

## Quick Start (on your Termux phone)

```bash
# 1. Prerequisites (one-time)
pkg update && pkg upgrade
pkg install git python build-essential clang make

# Install patched bun-termux
curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
bun --version  # should print 1.3.14

# 2. Clone this fork
git clone https://github.com/bd-loser/opencode-bionic.git ~/opencode-bionic
cd ~/opencode-bionic

# 3. Install dependencies (bun-termux launcher handles LD_PRELOAD shim)
bun install

# 4. Apply Termux patches (idempotent — safe to re-run)
bash termux/apply-termux-patches.sh

# 5. Install again to pick up the new override + optionalDependency
bun install

# 6. Run opencode
bash termux/run-opencode-termux.sh
```

## What This Fork Does

The changes are in `package.json` and `bunfig.toml` (no source files modified):

**`package.json`**:
```jsonc
{
  "overrides": {
    "@opentui/core": "npm:@xincli/opentui-core@0.4.8"
  },
  "optionalDependencies": {
    "@xincli/opentui-core-android-arm64": "0.4.8"
  },
  "workspaces": {
    "catalog": {
      "@opentui/core": "0.4.8"  // was 0.4.3
    }
  },
  "trustedDependencies": [
    // ALL entries removed — ANY install script that loads a native N-API
    // module SIGABRTs on Termux (MTE pointer truncation). This affected
    // tree-sitter-powershell, protobufjs, and would affect node-pty next.
    // opencode's dev/runtime flow doesn't need any of these install scripts:
    //   - esbuild: only needed for `bun run build`, not `bun run src/index.ts`
    //   - node-pty: not used under Bun (bun-pty is used instead)
    //   - protobufjs: pure JS fallback works
    //   - tree-sitter-*: only .wasm files used (via web-tree-sitter WASM runtime)
    //   - electron: not relevant for Android
  ],
  "scripts": {
    // postinstall + prepare REMOVED — they're ROOT package scripts that
    // ALWAYS run on `bun install` (trustedDependencies only affects deps).
    // postinstall (fix-node-pty) is pointless when node-pty isn't used.
    // prepare (husky) sets up git hooks for opencode development — not
    // needed to RUN opencode, and husky crashes with MTE SIGABRT.
    "dev": "...",
    "typecheck": "...",
    // ... (other scripts preserved)
  }
}
```

**`bunfig.toml`**:
```toml
[install]
minimumReleaseAge = 259200
minimumReleaseAgeExcludes = [
  # ... existing excludes ...
  "@xincli/opentui-core",                    # ADDED — newly published
  "@xincli/opentui-core-android-arm64"       # ADDED — newly published
]
```

The `@xincli/opentui-core@0.4.8` package (published by
[bd-loser/opentui](https://github.com/bd-loser/opentui)) already has Termux
detection baked into its compiled `resolveNativePackage()` — it checks
`process.platform === "android"` OR `(linux && $PREFIX contains "com.termux")`
and loads `@xincli/opentui-core-android-arm64` (the native `libopentui.so`
built against Termux Bionic).

The patch script (`termux/apply-termux-patches.sh`) automates all these edits
plus runtime checks (LD_PRELOAD shim, MEMTAG_OPTIONS, clipboard tool).

## Files

| File | Purpose |
|---|---|
| `termux/apply-termux-patches.sh` | Idempotent patcher: edits `package.json` + `bunfig.toml`, verifies env |
| `termux/setup-opencode-termux.sh` | One-shot setup: clone → `bun install` → patch → `bun install` |
| `termux/run-opencode-termux.sh` | Launcher: sets env, verifies shim, execs `bun run` |
| `termux/test-opentui-isolated.sh` | **Smoke test**: verifies @xincli/opentui-core + @opentui/solid work in isolation (3 deps, no opencode) |
| `termux/README.md` | This file |
| `termux/scripts/dry-run-patch-test.sh` | Self-test for the JSON patch logic |

## Isolated Opentui Smoke Test (run this FIRST)

Before fighting with opencode's 2000+ dependencies, verify the opentui layer
works in isolation. This test creates a minimal project with only 3 deps
(`@xincli/opentui-core`, `@xincli/opentui-core-android-arm64`, `@opentui/solid`)
and renders a `<box>` with a `<text>` child for 3 seconds.

```bash
bash termux/test-opentui-isolated.sh
```

**If this test passes**: opentui FFI works, @opentui/solid@0.4.3 is API-compatible
with @xincli/opentui-core@0.4.8. Any opencode failure is in opencode itself
(bun-pty, sqlite, opencode's own code).

**If this test fails**: the error tells you exactly what's broken:
- "opentui is not supported on the current platform" → .so not found
- "undefined symbol: opentui_*" → ABI mismatch (rebuild .so)
- "Pointer tag ... truncated" + SIGABRT → MTE issue (check launcher)
- "Cannot find export X in @xincli/opentui-core" → solid API break (need @xincli/opentui-solid fork)

## Why This Works (Root-Cause Analysis)

### The one hard blocker

**`@opentui/core@0.4.3`'s `resolveNativePackage()` has no Android branch.**

Upstream (paraphrased):
```ts
async function resolveNativePackage() {
  if (process.platform === "darwin") { ... }
  if (process.platform === "linux")  { return await import("@opentui/core-linux-arm64") }
  if (process.platform === "win32")  { ... }
  throw new Error(`opentui is not supported on the current platform: ${process.platform}-${process.arch}`)
}
```

On Termux:
- **Under Bun**: `process.platform === "linux"` (Bun normalizes `android` → `linux`).
  Upstream tries to load `@opentui/core-linux-arm64` (glibc binary). Bionic's
  `linker64` rejects it → throws.
- **Under Node**: `process.platform === "android"`. No branch matches → throws
  `"opentui is not supported on the current platform: android-arm64"`.

Either way, `createCliRenderer()` throws on startup. opencode's TUI never renders.

### The fix

The user's `@xincli/opentui-core@0.4.8` npm package already fixes this — its
compiled `resolveNativePackage()` has the Termux branch:
```js
const isTermux = typeof process.env.PREFIX === "string" && process.env.PREFIX.includes("com.termux");
if (process.platform === "android" || process.platform === "linux" && isTermux) {
  try {
    if (process.arch === "arm64") {
      return await import("@xincli/opentui-core-android-arm64");
    }
  } catch {}
  // ... dev-mode fallback ...
}
```

So instead of patching source, we just make opencode USE `@xincli/opentui-core`
via Bun's `overrides` field. The override forces ALL `@opentui/core` resolutions
in the workspace (including peer-dep resolutions from `@opentui/solid@0.4.3`
and `@opentui/keymap@0.4.3`) to use the `@xincli` fork.

### Soft failures (degrade gracefully, no patch needed)

| Dep | What happens on Termux | opencode's handling |
|---|---|---|
| `@parcel/watcher` | `require("@parcel/watcher-linux-arm64-glibc")` throws (Bionic) | `watcher()` returns `undefined`, Layer returns empty Service. File watching disabled. |
| `@ff-labs/fff-bun` | `require("@ff-labs/fff-bin-linux-arm64-gnu/libfff_c.so")` throws | `FileFinder.isAvailable()` returns `false`, `search.ts` falls back to ripgrep. |
| `@lydell/node-pty` | Not loaded under Bun (`#pty` import's `bun` condition loads `bun-pty` instead) | No issue. |
| `tree-sitter-*` | `node-gyp` compilation may fail | Run `bun install --ignore-scripts` to skip. opentui syntax highlighting won't work, but opencode core will. |

### Already-correct behaviors (no patch needed)

- **`/etc/shells` doesn't exist on Termux**: `shell.ts` reads it, catches the
  error, falls back to `which("bash")` which finds `$PREFIX/bin/bash`.
- **`/tmp` paths**: handled by your `libbun-android-fix.so` LD_PRELOAD shim
  (translates `/tmp` → `$TMPDIR`).
- **`cross-spawn`, `which`, `glob`**: pure JS, work out of the box.
- **`@opentui/solid/preload`**: Bun transform plugin, pure TS, works.

## Runtime Checks (in `apply-termux-patches.sh`)

The patch script also verifies (warns, doesn't fail):

1. **`LD_PRELOAD` contains `libbun-android-fix.so`** — else FFI SIGABRTs
   (SELinux blocks `openat(O_DIRECTORY)` on `/` during Bun's resolver walk)
2. **`MEMTAG_OPTIONS=off`** — else Bionic's scudo allocator tags heap pointers;
   bun's FFI passes tagged pointers to `free()` which SIGABRTs
3. **Clipboard tool exists** — else clipboard features silently no-op

## Debugging

### `bun install` fails with "blocked by minimum-release-age"

opencode's `bunfig.toml` has `minimumReleaseAge = 259200` (3 days). Packages
published less than 3 days ago are blocked. The patch script adds
`@xincli/opentui-core` and `@xincli/opentui-core-android-arm64` to the
excludes list, but if you hit this for another package:

```bash
# Check if the package is in the excludes list
grep "your-package-name" bunfig.toml

# If not, add it manually:
# Edit bunfig.toml → minimumReleaseAgeExcludes array → add "your-package-name"
# Then re-run bun install
```

### `bun install` fails with "... terminated by SIGABRT" (tree-sitter, protobufjs, node-pty, etc.)

ANY install script that loads a native N-API module will SIGABRT on Termux
with MTE (Memory Tagging Extension):
```
Pointer tag for 0x... was truncated
error: install script from "protobufjs" terminated by SIGABRT
```

The MTE fix shim (libbun-mte-fix.so) intercepts malloc/free, but N-API's
module loading path (dlopen+dlsym) bypasses it — tagged pointers from
Bionic's scudo allocator reach the N-API loader and crash.

The patch script removes ALL entries from `trustedDependencies`, so Bun
skips ALL dependency install scripts. The packages still install (their
`.js`, `.wasm`, `.d.ts` files) — only native compilation/loading is skipped.
This is safe because:
- `esbuild`: only needed for `bun run build`, not dev/runtime
- `node-pty`: not used under Bun (bun-pty is used instead)
- `protobufjs`: pure JS fallback works
- `tree-sitter-*`: only `.wasm` files used (via web-tree-sitter WASM runtime)
- `electron`: not relevant for Android

If you hit a SIGABRT for a package NOT in the original trustedDependencies
list, it means the package has an install script that wasn't trusted (so it
was already being skipped) — the crash is from a different cause. Check the
full error message.

### `bun install` fails with "ENOENT reading .../@babel+core@..."

This means a previous `bun install` was interrupted (e.g. by the tree-sitter
SIGABRT) and `node_modules` is in a partially-installed state. Fix:
```bash
rm -rf node_modules
bun install
```

### `bun install` fails with "prepare script from opencode terminated by SIGABRT"

The ROOT `package.json` has `"prepare": "husky"` which runs after `bun install`.
`husky` (git hooks manager) spawns child processes that trigger the same MTE
pointer truncation as the dependency install scripts. `trustedDependencies`
only affects DEPENDENCY install scripts — root package scripts ALWAYS run.

The patch script removes `prepare` (and `postinstall: fix-node-pty` which is
also pointless on Termux) from the root scripts. If you hit this, ensure
Patch 1d ran:
```bash
python3 -c "import json; s=json.load(open('package.json'))['scripts']; print('prepare' in s, 'postinstall' in s)"
# Should print: False False
```

If it prints `True`, re-run `bash termux/apply-termux-patches.sh`.

### opencode crashes on startup with SIGABRT

MTE (Memory Tagging Extension) is tagging heap pointers. Ensure:
```bash
echo "LD_PRELOAD=$LD_PRELOAD"           # parent shell value (may differ from bun's)
echo "MEMTAG_OPTIONS=$MEMTAG_OPTIONS"   # should be "off"
file $PREFIX/bin/bun                    # should be "shell script" (launcher), NOT "ELF"
```

If `$PREFIX/bin/bun` is an ELF binary (not a shell script), the bun-termux
launcher isn't installed. Reinstall:
```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
```

The launcher (`$PREFIX/bin/bun`) is a shell script that sets `LD_PRELOAD` to
`libbun-android-fix.so:libbun-mte-fix.so` and `MEMTAG_OPTIONS=off` before
exec'ing the raw bun binary at `$PREFIX/lib/bun-termux/bun`.

### opencode crashes with "opentui is not supported on the current platform"

The override didn't apply. Verify:
```bash
grep -A 1 '"overrides"' package.json
# should show: "@opentui/core": "npm:@xincli/opentui-core@0.4.8"

ls node_modules/@opentui/core/package.json
# should be the @xincli fork — check with:
cat node_modules/@opentui/core/package.json | python3 -c "import sys,json; print(json.load(sys.stdin).get('name'))"
# should print: @xincli/opentui-core
```

### opencode crashes with "Cannot find module '@xincli/opentui-core-android-arm64'"

The optionalDependency didn't install. Run:
```bash
bun add @xincli/opentui-core-android-arm64@0.4.8 --optional
ls node_modules/@xincli/opentui-core-android-arm64/libopentui.so
file node_modules/@xincli/opentui-core-android-arm64/libopentui.so
# should print: ELF 64-bit LSB shared object, ARM aarch64
```

### opencode crashes with "undefined symbol: opentui_*"

ABI mismatch between `@xincli/opentui-core@0.4.8` (TS bindings) and
`@xincli/opentui-core-android-arm64@0.4.8` (the `.so`). Both should be 0.4.8.
If you rebuilt the `.so` from a different opentui version, bump both versions
together and re-publish.

### opencode starts but `@opentui/solid` import fails

`@opentui/solid@0.4.3` expects `@opentui/core@0.4.3` API. With our override
it gets `@xincli/opentui-core@0.4.8`. If 0.4.8 has breaking API changes,
you'll see `Cannot find export X in @xincli/opentui-core`.

**Fix**: downgrade the override:
```bash
XINCLI_CORE_VERSION=0.4.7 bash termux/apply-termux-patches.sh
bun install
```

Or fork `@opentui/solid` and `@opentui/keymap` (currently only
`@xincli/opentui-core` and `@xincli/opentui-react` are published — solid/keymap
are NOT yet published under `@xincli`).

### `bun install` fails on tree-sitter

```bash
bun install --ignore-scripts
```
Skips native compilation. opentui syntax highlighting won't work, but opencode
core functionality will.

## Iteration Loop

When you hit an issue on the phone:

1. **Capture the full error** — stderr + stack trace + the failing opencode command
2. **Identify the failing layer** — opentui (FFI), bun-pty (PTY), @parcel/watcher
   (file watching), @ff-labs/fff-bun (file search), or opencode itself?
3. **Check this README's "Debugging" section** — if listed, follow the fix
4. **If new**: paste the error in the GitHub issue tracker and we'll diagnose
   root cause + add a patch

## Compatibility Matrix

| Component | Version | Termux Status |
|---|---|---|
| bun | 1.3.14 (bd-loser/bun-termux) | ✅ patched |
| @opentui/core | overridden → @xincli/opentui-core@0.4.8 | ✅ Termux detection baked in |
| @xincli/opentui-core-android-arm64 | 0.4.8 | ✅ published |
| @opentui/solid | 0.4.3 (catalog pin, unchanged) | ⚠️ gets @xincli via override — API compat unverified |
| @opentui/keymap | 0.4.3 (catalog pin, unchanged) | ⚠️ same |
| bun-pty | 0.4.8 | ⚠️ unverified on Android |
| @lydell/node-pty | 1.2.0-beta.12 | N/A (not used under Bun) |
| @parcel/watcher | 2.5.1 | ⚠️ degrades (no Bionic binary) |
| @ff-labs/fff-bun | 0.9.3 (opencode's existing patch) | ⚠️ degrades to ripgrep |
| @silvia-odwyer/photon-node | 0.3.4 (opencode's existing patch) | ✅ WASM |
| bun:sqlite | builtin | ✅ |
| cross-spawn | 7.0.6 | ✅ pure JS |
| tree-sitter-* | various | ⚠️ may need --ignore-scripts |
