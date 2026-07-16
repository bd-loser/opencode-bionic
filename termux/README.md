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

The ONLY hard change is in `package.json`:

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
  }
}
```

That's it. No source files modified. The `@xincli/opentui-core@0.4.8` package
(published by [bd-loser/opentui](https://github.com/bd-loser/opentui)) already
has Termux detection baked into its compiled `resolveNativePackage()` — it
checks `process.platform === "android"` OR `(linux && $PREFIX contains
"com.termux")` and loads `@xincli/opentui-core-android-arm64` (the native
`libopentui.so` built against Termux Bionic).

The patch script (`termux/apply-termux-patches.sh`) automates this edit plus
runtime checks (LD_PRELOAD shim, MEMTAG_OPTIONS, clipboard tool).

## Files

| File | Purpose |
|---|---|
| `termux/apply-termux-patches.sh` | Idempotent patcher: edits `package.json`, verifies env |
| `termux/setup-opencode-termux.sh` | One-shot setup: clone → `bun install` → patch → `bun install` |
| `termux/run-opencode-termux.sh` | Launcher: sets env, verifies shim, execs `bun run` |
| `termux/README.md` | This file |
| `termux/scripts/dry-run-patch-test.sh` | Self-test for the JSON patch logic |

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

### opencode crashes on startup with SIGABRT

MTE (Memory Tagging Extension) is tagging heap pointers. Ensure:
```bash
echo "LD_PRELOAD=$LD_PRELOAD"           # should contain libbun-android-fix.so
echo "MEMTAG_OPTIONS=$MEMTAG_OPTIONS"   # should be "off"
```

If missing, you bypassed the bun-termux launcher. Always invoke via:
```bash
$PREFIX/bin/bun run packages/opencode/src/index.ts
```
NOT via `/data/data/com.termux/files/usr/lib/bun-termux/bun` directly.

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
