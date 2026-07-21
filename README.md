# opencode-bionic

> Termux/Android port of [anomalyco/opencode](https://github.com/anomalyco/opencode)
> (formerly `sst/opencode`), built as a quilt-style patch set on top of
> upstream. Runs under [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux)
> with [@xincli/opentui-*](https://www.npmjs.com/~xincli) native bindings.

[![Termux](https://img.shields.io/badge/Platform-Termux%20Android%20arm64-black.svg)](https://termux.dev)
[![Bun](https://img.shields.io/badge/Bun-1.3.14%20(bd--loser%20fork)-blue.svg)](https://github.com/bd-loser/bun-termux)
<!-- versions:badges -->
[![opentui-js](https://img.shields.io/badge/opentui--js-@xincli%400.4.10-green.svg)](https://www.npmjs.com/package/@xincli/opentui-core)
[![opentui-so](https://img.shields.io/badge/libopentui.so-@xincli%400.4.11-green.svg)](https://www.npmjs.com/package/@xincli/opentui-core-android-arm64)
<!-- /versions:badges -->

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | bash
```

Grabs the latest `.deb` from [Releases](https://github.com/bd-loser/opencode-bionic/releases),
verifies its checksum, and installs via `dpkg`. Pin a version with
`OPENCODE_VERSION=1.18.3 curl … | bash`.

Manual install:

```bash
curl -LO https://github.com/bd-loser/opencode-bionic/releases/latest/download/opencode_<version>_aarch64.deb
dpkg -i opencode_<version>_aarch64.deb
opencode --version
```

## Architecture

This repo does **not** vendor an upstream clone. It holds only the delta:

```
opencode-bionic/
├── versions.json              # pinned upstream version + @xincli versions
├── install.sh                 # curl | bash installer
├── termux/
│   ├── patches/               # unified-diff patches applied to upstream
│   │   ├── 0001-*.patch         (bunfig.toml: release-age exclusions)
│   │   ├── 0002-*.patch         (packages/opencode/script/build-termux.ts)
│   │   └── 0003-*.patch         (packages/core/…/fff.bun.ts: lazy require)
│   ├── ci/
│   │   ├── fetch-upstream.sh    # git clone --depth 1 -b vX.Y.Z
│   │   ├── versions.ts          # apply config delta (package.json edits)
│   │   ├── apply-patches.sh     # git am --3way termux/patches/*
│   │   ├── prepare-build-tree.sh# fetch + versions + patch, one command
│   │   ├── refresh-patches.sh   # regenerate patches after upstream bump
│   │   ├── build-on-runner.sh   # GHA runner side: launches termux-docker
│   │   ├── build-in-container.sh# inside termux-docker: bun install + build
│   │   └── package-deb.sh       # wraps binary as .deb
│   └── setup.sh, rebuild-opencode.sh, ...   # local dev workflows
└── .github/workflows/
    ├── release.yml              # build + publish a .deb + create release
    └── watch-upstream.yml       # every 2 days: bump versions.json + release
```

Upstream is fetched fresh at build time via `git clone --depth 1 -b v$(jq -r
.opencode versions.json)`, then `versions.ts` mutates package.json files
(catalog aliases, optionalDeps, install-hook removal), then `git am --3way`
applies the source patches. This mirrors how Debian, Nixpkgs, Alpine, and
Homebrew maintain downstream deltas — patches either apply cleanly or CI
fails loudly.

## Bundled versions

Everything is pinned in [`versions.json`](./versions.json). Bump that file
and everything else follows: `versions.ts` rewrites config, `watch-upstream`
sees the bump on its next run.

<!-- versions:table -->
| Component | Version |
|---|---|
| opencode (upstream) | `1.18.4` |
| `@opentui/{core,keymap,solid}` (JS, via `@xincli`) | `0.4.10` |
| `@xincli/opentui-core-android-arm64` (native `.so`) | `0.4.11` |
| `bun-termux` runtime | tracked at [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) |
<!-- /versions:table -->

## Why this fork exists

opencode's TUI is powered by [opentui](https://opentui.com) — a native Zig
library with TypeScript bindings. Upstream `@opentui/core` has no
Android/Termux support: its `resolveNativePackage()` only knows
darwin/linux/win32, and the linux variant is a glibc binary that Bionic's
linker rejects.

The fork routes `@opentui/core`, `@opentui/solid`, and `@opentui/keymap` to
their [`@xincli` counterparts](https://github.com/bd-loser/opentui) via Bun
workspace **catalog pins**, and adds `@xincli/opentui-core-android-arm64`
as an `optionalDependency` so the native `libopentui.so` gets installed on
arm64 Android only. All of that is applied by `termux/ci/versions.ts`
without needing a source patch.

## Quick Start (local dev on your Termux phone)

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

# 3. One-command setup (fetches upstream, applies delta, installs deps)
bash termux/setup.sh

# 4. Build + install the compiled binary
bash termux/rebuild-opencode.sh

# 5. Run from anywhere
opencode
opencode --version
```

## Refreshing patches after upstream drift

If `apply-patches.sh` fails after an upstream bump, the patches need
rebasing:

```bash
# Prepare a working tree with the current patches applied on the new version
bash termux/ci/prepare-build-tree.sh /tmp/refresh

# Fix conflicts / edit files
cd /tmp/refresh
$EDITOR packages/core/src/filesystem/fff.bun.ts
git add -A && git commit --amend --no-edit  # or make new commits

# Regenerate patches back into repo
bash "$OLDPWD/termux/ci/refresh-patches.sh" /tmp/refresh
```

## Related repos

| Repo | Purpose |
|---|---|
| [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) | Bun v1.3.14 patched for Android (FFI, TinyCC, MTE, SELinux) |
| [bd-loser/opentui](https://github.com/bd-loser/opentui) | opentui fork with Termux support + `@xincli` npm packages |
| **bd-loser/opencode-bionic** (this repo) | opencode delta that ties it all together |

## License

MIT (same as upstream opencode)
