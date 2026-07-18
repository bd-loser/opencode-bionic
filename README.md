# opencode-bionic

> Fork of [sst/opencode](https://github.com/sst/opencode) patched to run on
> Android/Termux under [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux)
> with [@xincli/opentui-*](https://www.npmjs.com/~xincli) native bindings.

[![Termux](https://img.shields.io/badge/Platform-Termux%20Android%20arm64-black.svg)](https://termux.dev)
[![Bun](https://img.shields.io/badge/Bun-1.3.14%20(bd--loser%20fork)-blue.svg)](https://github.com/bd-loser/bun-termux)
[![opentui-js](https://img.shields.io/badge/opentui--js-@xincli%400.4.10-green.svg)](https://www.npmjs.com/package/@xincli/opentui-core)
[![opentui-so](https://img.shields.io/badge/libopentui.so-@xincli%400.4.11-green.svg)](https://www.npmjs.com/package/@xincli/opentui-core-android-arm64)

## Install

One-liner in Termux:

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | bash
```

This grabs the latest `.deb` from [Releases](https://github.com/bd-loser/opencode-bionic/releases),
verifies its checksum, and installs it via `dpkg`. Pin a version with
`OPENCODE_VERSION=1.18.2 curl … | bash`.

Manual install:

```bash
curl -LO https://github.com/bd-loser/opencode-bionic/releases/latest/download/opencode_<version>_aarch64.deb
dpkg -i opencode_<version>_aarch64.deb
opencode --version
```

## Status

✅ **Working.** Both `bun run` (dev mode) and the compiled `opencode` binary
launch the TUI on Termux/Android arm64. The `0.4.10` release fixed the
compiled-binary crash (`.so` extraction from bunfs), and `0.4.11` refreshes
the native `libopentui.so` build.

## Bundled versions

Everything is pinned in [`versions.json`](./versions.json) at the repo root.
Bump that file and run `bun termux/ci/versions.ts apply` to sync every
consumer package.json. CI's release workflow reads the same file.

| Component | Version |
|---|---|
| opencode (upstream) | `1.18.2` |
| `@opentui/{core,keymap,solid}` (JS, via `@xincli`) | `0.4.10` |
| `@xincli/opentui-core-android-arm64` (native `.so`) | `0.4.11` |
| `bun-termux` runtime | tracked at [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) |

## Why this fork exists

opencode's TUI is powered by [opentui](https://opentui.com) — a native Zig
library with TypeScript bindings. Upstream `@opentui/core` has no
Android/Termux support: its `resolveNativePackage()` only knows
darwin/linux/win32, and the linux variant is a glibc binary that Bionic's
linker rejects.

This fork routes `@opentui/core`, `@opentui/solid`, and `@opentui/keymap`
to their [`@xincli` counterparts](https://github.com/bd-loser/opentui)
via Bun workspace **catalog pins** (no `overrides` needed since 0.4.10),
and adds `@xincli/opentui-core-android-arm64` as an `optionalDependency`
so the native `libopentui.so` gets installed on arm64 Android only.

## Quick Start

```bash
# 1. Prerequisites (one-time)
pkg update && pkg upgrade
pkg install git python build-essential clang make

# Install patched bun-termux
curl -fsSL https://raw.githubusercontent.com/bd-loser/bun-termux/main/scripts/install.sh | bash
bun --version   # should print 1.3.14

# 2. Clone this fork
git clone https://github.com/bd-loser/opencode-bionic.git ~/opencode-bionic
cd ~/opencode-bionic

# 3. One-command setup (clones opencode, installs deps, patches, smoke test)
bash termux/setup.sh

# 4. Build + install the compiled binary
bash termux/rebuild-opencode.sh

# 5. Run from anywhere
opencode
opencode --version
opencode run 'hello world'
```

For dev-mode iteration (no compile step), use `bash termux/run-opencode-termux.sh`.

## Documentation

- **[termux/README.md](termux/README.md)** — full architecture, script reference,
  workflows (rebuild, release, debug), troubleshooting matrix
- **[termux/apply-termux-patches.sh](termux/apply-termux-patches.sh)** — the
  patcher (idempotent, verify-each, marked)
- **[termux/rebuild-opencode.sh](termux/rebuild-opencode.sh)** — one-command
  pull + patch + install + build + install for the compiled binary
- **[termux/release-opentui.sh](termux/release-opentui.sh)** — orchestrate
  publishing the 5 `@xincli` packages via GitHub Actions

## Related repos

| Repo | Purpose |
|---|---|
| [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) | Bun v1.3.14 patched for Android (FFI, TinyCC, MTE, SELinux) |
| [bd-loser/opentui](https://github.com/bd-loser/opentui) | opentui fork with Termux support + `@xincli` npm packages |
| **bd-loser/opencode-bionic** (this repo) | opencode fork that ties it all together |

## npm packages used

| Package | Version | Purpose |
|---|---|---|
| `@xincli/opentui-core` | 0.4.10 | Compiled opentui core JS with Termux detection + bunfs `.so` extraction |
| `@xincli/opentui-react` | 0.4.10 | React reconciler |
| `@xincli/opentui-solid` | 0.4.10 | SolidJS binding (depends on `@xincli/opentui-core` directly) |
| `@xincli/opentui-keymap` | 0.4.10 | Keymap utilities |
| `@xincli/opentui-core-android-arm64` | 0.4.11 | Native `libopentui.so` for Android arm64 (Bionic) |

JS packages and the native `.so` are versioned independently — the `.so` can
be re-published without a JS bump if only the native build changes.

## License

MIT (same as upstream opencode)
