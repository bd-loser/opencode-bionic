# opencode-bionic — opencode for Android/Termux

> Fork of [sst/opencode](https://github.com/sst/opencode) that runs on
> Android/Termux under the patched [bun-termux](https://github.com/bd-loser/bun-termux)
> with [@xincli/opentui-*](https://www.npmjs.com/~xincli) native bindings.

## Architecture (v2 — clean catalog pins)

```
┌─────────────────────────────────────────────────────────────────┐
│  npm registry                                                   │
│                                                                 │
│  @xincli/opentui-core@0.4.10              ← compiled JS core     │
│  @xincli/opentui-react@0.4.10             ← React reconciler     │
│  @xincli/opentui-solid@0.4.10             ← SolidJS binding      │
│  @xincli/opentui-keymap@0.4.10            ← keymap utilities     │
│  @xincli/opentui-core-android-arm64@0.4.11 ← native .so (12 MB)  │
│                                                                 │
│  Note: JS packages and the .so are versioned independently.     │
│  The .so is on 0.4.11 to pick up a native-build fix while the   │
│  JS packages remain on 0.4.10.                                  │
└─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ npm: aliases in catalog
                              │
┌─────────────────────────────────────────────────────────────────┐
│  opencode (this fork)                                           │
│                                                                 │
│  package.json:                                                  │
│    workspaces.catalog:                                          │
│      "@opentui/core":  "npm:@xincli/opentui-core@0.4.10"         │
│      "@opentui/solid": "npm:@xincli/opentui-solid@0.4.10"        │
│      "@opentui/keymap":"npm:@xincli/opentui-keymap@0.4.10"       │
│    optionalDependencies:                                        │
│      "@xincli/opentui-core-android-arm64": "0.4.11"              │
│                                                                 │
│  No overrides needed — @xincli packages directly depend on      │
│  each other via npm: aliases in their own dependencies.         │
└─────────────────────────────────────────────────────────────────┘
```

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

# 3. One-command setup (clones opencode, installs deps, patches, smoke test)
bash termux/setup.sh

# 4. Run opencode (dev mode — uses bun run)
bash termux/run-opencode-termux.sh

# 5. Build + install compiled binary (one command)
bash termux/rebuild-opencode.sh

# 6. Run from anywhere
opencode
opencode --version
opencode run 'hello world'
```

## Script Reference

### User-facing scripts (the ones you'll actually run)

| Script | Purpose | When to run |
|---|---|---|
| `setup.sh` | One-command setup: clone opencode, install deps, patch, smoke test | First time, or after a clean checkout |
| `rebuild-opencode.sh` | Pull latest, re-patch, re-install, build binary, install | After a new `@xincli` release, or after opencode upstream changes |
| `run-opencode-termux.sh` | Run opencode in dev mode (`bun run`) | Quick iteration, debugging |
| `release-opentui.sh` | Orchestrate publishing all 5 `@xincli` packages | When you bump versions in the opentui fork |

### Internal scripts (called by the above)

| Script | Purpose |
|---|---|
| `apply-termux-patches.sh` | Apply clean v2 catalog pins + other Termux patches (idempotent) |
| `clean-reinstall.sh` | Nuke `node_modules` + `bun.lock`, fresh install, verify |
| `build-opencode-termux.sh` | Compile opencode into a single binary (`bun build --compile`) |
| `install-opencode-termux.sh` | Copy binary to `$PREFIX/lib/opencode/`, create wrapper at `$PREFIX/bin/opencode` |
| `test-opentui-isolated.sh` | Smoke test: verify `@xincli/opentui-core` + `@xincli/opentui-solid` work on Termux |
| `setup-opencode-termux.sh` | Legacy setup script (use `setup.sh` instead) |

## Common Workflows

### After a new @xincli release

`rebuild-opencode.sh` accepts independent version overrides per package,
because the JS packages and the native `.so` can move at different
cadences (e.g. `.so`-only rebuilds).

```bash
cd ~/opencode-bionic
git pull

# Use whatever the script's built-in defaults are (currently core=0.4.10, so=0.4.11)
bash termux/rebuild-opencode.sh

# Override just the .so version (e.g. after a native-only rebuild)
XINCLI_ANDROID_VERSION=0.4.12 bash termux/rebuild-opencode.sh

# Bump the whole JS stack in one shot (core → also sets solid/keymap/react)
XINCLI_CORE_VERSION=0.4.11 bash termux/rebuild-opencode.sh

# Per-package overrides also work independently:
#   XINCLI_CORE_VERSION, XINCLI_SOLID_VERSION, XINCLI_KEYMAP_VERSION,
#   XINCLI_REACT_VERSION, XINCLI_ANDROID_VERSION
```

The script sweeps stale `.bun` store dirs whose versions don't match the
targets — this is what prevented the earlier bug where nested lockfile
resolution kept bundling a stale `.so`.

### Publishing a new @xincli release

From your phone (or any machine with `GH_TOKEN`):

```bash
# 1. In the opentui fork: bump versions, commit, push
cd ~/opentui
# Edit packages/{core,react,solid,keymap}/package.json → version: "0.4.10"
git add -A
git commit -m "bump: 0.4.10"
git push

# 2. If the .so changed, rebuild it on your phone first:
bash packages/core/scripts/build-native-termux.sh
git add packages/core/prebuilt/
git commit -m "build: native arm64 .so for 0.4.10"
git push

# 3. Orchestrate the release (triggers all 4 workflows in order)
GH_TOKEN=ghp_xxx bash ~/opencode-bionic/termux/release-opentui.sh 0.4.10

# 4. Rebuild opencode with the new packages
cd ~/opencode-bionic
XINCLI_CORE_VERSION=0.4.10 bash termux/rebuild-opencode.sh
```

### Debugging opencode crashes

```bash
# 1. Verify the isolated opentui stack works (rules out opencode itself)
bash termux/test-opentui-isolated.sh

# 2. Check the environment
echo "MEMTAG_OPTIONS=$MEMTAG_OPTIONS"          # must be 'off'
echo "LD_PRELOAD=$LD_PRELOAD"                  # must contain libbun-android-fix.so
file $PREFIX/bin/bun                            # must be 'shell script', NOT 'ELF'

# 3. Check the .so
file node_modules/@xincli/opentui-core-android-arm64/libopentui.so
# must be: ELF 64-bit LSB shared object, ARM aarch64

# 4. Clean reinstall if node_modules is broken
bash termux/clean-reinstall.sh
```

## How it works

### The 0.4.10 compiled binary fix

Previous versions crashed with `opentui is not supported on the current platform: android-arm64` when running the **compiled binary** (but `bun run` worked fine).

**Root cause:** When opentui is bundled into a Bun-compiled binary, the `.so` lives inside bunfs (Bun's virtual embedded filesystem). `dlopen()` is a kernel syscall and cannot read from bunfs — it fails with ENOENT.

**Fix (in `@xincli/opentui-core@0.4.10`):** When `isBunfsPath(targetLibPath)` is true, extract the `.so` to `$TMPDIR/opentui-native/libopentui-<hash>.so` using `readFileSync()` (which Bun intercepts to read from bunfs), then point `targetLibPath` at the extracted file. See `packages/core/src/zig.ts` in the opentui fork.

### The clean v2 catalog pin approach

Previous versions used Bun's `overrides` field to force `@opentui/core` → `@xincli/opentui-core` across the entire workspace. This was necessary because upstream `@opentui/solid@0.4.3` brought its own nested `@opentui/core@0.4.3` (which has no Android branch).

**Since 0.4.10:** `@xincli/opentui-solid` and `@xincli/opentui-keymap` are published to npm with `@opentui/core` aliased to `npm:@xincli/opentui-core` in their own `dependencies` field. So we just pin the catalog entries:

```json
{
  "workspaces": {
    "catalog": {
      "@opentui/core":  "npm:@xincli/opentui-core@0.4.10",
      "@opentui/solid": "npm:@xincli/opentui-solid@0.4.10",
      "@opentui/keymap":"npm:@xincli/opentui-keymap@0.4.10"
    }
  },
  "optionalDependencies": {
    "@xincli/opentui-core-android-arm64": "0.4.11"
  }
}
```

No `overrides` needed — the cascade happens naturally through the `npm:` aliases in each package's `dependencies`.

### The Termux patches (still needed)

These patches are Termux-specific (not opentui-related) and remain necessary:

| Patch | Why |
|---|---|
| Remove `trustedDependencies` | MTE crashes on any install script that loads native N-API modules |
| Remove root `postinstall` + `prepare` | Husky spawns child processes that crash under MTE |
| Remove stale `@ff-labs/fff-bun@0.9.3` patchedDependency | Version mismatch with declared `0.9.4` |
| Patch `fff.bun.ts` for lazy-load | `@ff-labs/fff-bun` has `os: [darwin,linux,win32]` — Bun skips it on Android |

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `opentui is not supported on the current platform: android-arm64` | Compiled binary can't load `.so` from bunfs | Update to `@xincli/opentui-core@0.4.10+` (has the bunfs extraction fix) |
| `SIGABRT` / `Pointer tag for 0x... was truncated` | MTE heap tagging + FFI | Ensure `MEMTAG_OPTIONS=off` and `LD_PRELOAD` contains `libbun-android-fix.so` |
| `Cannot find module '@ff-labs/fff-bun'` | Package has `os:` restriction, skipped on Android | Patch 1f handles this (lazy require + null guard) — run `apply-termux-patches.sh` |
| `@opentui/core is @opentui/core (expected @xincli/opentui-core)` | Catalog pin not applied | Run `apply-termux-patches.sh`, then `bun install` again |
| `libopentui.so: MISSING` | `optionalDependency` not installed | `bun add @xincli/opentui-core-android-arm64@0.4.11 --optional` |
| `@opentui/core not resolvable in any node_modules` | `find` used to miss Bun's isolated symlink layout | Fixed in `rebuild-opencode.sh` — uses explicit path probes + `packages/*/node_modules` glob fallback |
| Stale `.so` bundled after a native-only bump | Nested lockfile resolution reused a stale `.bun` store dir | `rebuild-opencode.sh` now sweeps `.bun` store dirs whose versions don't match target |

## Related repositories

- [bd-loser/opentui](https://github.com/bd-loser/opentui) — the opentui fork (publishes `@xincli/*` packages)
- [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) — patched Bun for Termux (LD_PRELOAD shim, MTE fix)
- [sst/opencode](https://github.com/sst/opencode) — upstream opencode
- [sst/opentui](https://github.com/sst/opentui) — upstream opentui

## License

MIT (same as upstream opencode)
