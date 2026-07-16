# opencode-bionic

> Fork of [sst/opencode](https://github.com/sst/opencode) patched to run on
> Android/Termux under [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux)
> with [@xincli/opentui-core](https://www.npmjs.com/package/@xincli/opentui-core)
> native binding.

[![Termux](https://img.shields.io/badge/Platform-Termux%20Android-black.svg)](https://termux.dev)
[![Bun](https://img.shields.io/badge/Bun-1.3.14%20(bd--loser%20fork)-blue.svg)](https://github.com/bd-loser/bun-termux)
[![opentui](https://img.shields.io/badge/opentui-@xincli%2Fopentui--core%400.4.8-green.svg)](https://www.npmjs.com/package/@xincli/opentui-core)

## Why this fork exists

opencode's TUI is powered by [opentui](https://opentui.com) — a native Zig
library with TypeScript bindings. Upstream `@opentui/core@0.4.3` has no
Android/Termux support: its `resolveNativePackage()` only knows
darwin/linux/win32, and the linux variant is a glibc binary that Bionic's
linker rejects.

This fork uses the user's `@xincli/opentui-core@0.4.8` npm package (which
has Termux detection baked in) via Bun's `overrides` field. **No source
files are modified** — only `package.json` is patched.

## Quick Start

```bash
# 1. Prerequisites (one-time)
pkg update && pkg upgrade
pkg install git python build-essential clang make

# Install patched bun-termux
curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash

# 2. Clone this fork
git clone https://github.com/bd-loser/opencode-bionic.git
cd opencode-bionic

# 3. Install dependencies
bun install

# 4. Apply Termux patches (edits package.json, verifies env)
bash termux/apply-termux-patches.sh

# 5. Install again to pick up the new override + optionalDependency
bun install

# 6. Run opencode
bash termux/run-opencode-termux.sh
```

Or use the one-shot setup script:
```bash
git clone https://github.com/bd-loser/opencode-bionic.git
cd opencode-bionic
bash termux/setup-opencode-termux.sh
```

## Documentation

- **[termux/README.md](termux/README.md)** — Full root-cause analysis, debugging
  guide, compatibility matrix
- **[termux/apply-termux-patches.sh](termux/apply-termux-patches.sh)** — The
  patcher (idempotent, verify-each, marked)
- **[termux/run-opencode-termux.sh](termux/run-opencode-termux.sh)** — Launcher
  with env setup + LD_PRELOAD verification

## Related repos

| Repo | Purpose |
|---|---|
| [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) | Bun v1.3.14 patched for Android (FFI, TinyCC, MTE, SELinux) |
| [bd-loser/opentui](https://github.com/bd-loser/opentui) | opentui fork with Termux support + `@xincli` npm packages |
| **bd-loser/opencode-bionic** (this repo) | opencode fork that ties it all together |

## npm packages used

| Package | Version | Purpose |
|---|---|---|
| `@xincli/opentui-core` | 0.4.8 | Compiled opentui core JS with Termux detection |
| `@xincli/opentui-core-android-arm64` | 0.4.8 | Native `libopentui.so` for Android arm64 (Bionic) |

## Status

- ✅ Patch script works (verified via `termux/scripts/dry-run-patch-test.sh`)
- ⚠️ Runtime on real Termux UNVERIFIED — needs testing on a phone
- ⚠️ `bun-pty` (used for terminal sessions) is unverified on Android
- ⚠️ `@opentui/solid@0.4.3` API compatibility with `@xincli/opentui-core@0.4.8`
  is unverified

## Iterating

This is a debug-as-we-go effort. When you hit an issue on the phone:

1. Capture the full stderr + stack trace
2. Check `termux/README.md` → "Debugging" section
3. If new, paste the error — we'll find root cause before any further code edits

## License

MIT (same as upstream opencode)
