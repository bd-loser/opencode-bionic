# opencode-bionic — opencode for Android / Termux (aarch64)

> **Run [opencode](https://opencode.ai) — the open-source AI coding agent —
> natively on your Android phone.** No proot, no chroot, no Linux VM. This
> repo ships a Bionic-libc aarch64 build of opencode as a Termux `.deb`,
> installable with one `curl | bash`.

[![Termux](https://img.shields.io/badge/Platform-Termux%20Android%20arm64-black.svg)](https://termux.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/bd-loser/opencode-bionic?display_name=tag)](https://github.com/bd-loser/opencode-bionic/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/bd-loser/opencode-bionic/total.svg)](https://github.com/bd-loser/opencode-bionic/releases)
[![Bun](https://img.shields.io/badge/Bun-1.3.14%20(bd--loser%20fork)-blue.svg)](https://github.com/bd-loser/bun-termux)
<!-- versions:badges -->
[![opentui-js](https://img.shields.io/badge/opentui--js-@xincli%400.4.10-green.svg)](https://www.npmjs.com/package/@xincli/opentui-core)
[![opentui-so](https://img.shields.io/badge/libopentui.so-@xincli%400.4.11-green.svg)](https://www.npmjs.com/package/@xincli/opentui-core-android-arm64)
<!-- /versions:badges -->

**Keywords:** opencode android · opencode termux · opencode aarch64 ·
AI coding agent android · Claude Code alternative on phone · LLM CLI
termux · sst opencode android port.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | bash
```

Grabs the latest `.deb` from [Releases](https://github.com/bd-loser/opencode-bionic/releases),
verifies its SHA256 checksum, and installs via `dpkg`. Pin a specific
version with:

```bash
OPENCODE_VERSION=1.18.4 curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | bash
```

Manual install:

```bash
curl -LO https://github.com/bd-loser/opencode-bionic/releases/latest/download/opencode_<version>_aarch64.deb
dpkg -i opencode_<version>_aarch64.deb
opencode --version
```

## What is opencode?

[opencode](https://opencode.ai) is an open-source, terminal-based AI coding
agent — think Claude Code / Cursor / Aider, but MIT-licensed and
model-agnostic (Anthropic, OpenAI, local models via any OpenAI-compatible
endpoint). Upstream is developed at
[anomalyco/opencode](https://github.com/anomalyco/opencode) (formerly
`sst/opencode`) and ships prebuilt binaries for macOS, Linux, and Windows —
**but not Android / Termux**. That's what this repo fixes.

## Why this fork exists (the hard part)

opencode's TUI is powered by [opentui](https://opentui.com) — a native Zig
library with TypeScript bindings. Upstream `@opentui/core` supports only
darwin / linux / win32, and the Linux binary is a **glibc** build that
Android's Bionic linker rejects outright. Making opencode run on Termux
required three separate pieces of work, all maintained in this org:

| Component | What was done | Repo |
|---|---|---|
| **Bun runtime** | Patched Bun 1.3.14 to run under Bionic libc — FFI, TinyCC, MTE, SELinux fixes. Ships as a Termux `.deb`. | [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) (original, not a fork) |
| **opentui native lib** | Rebuilt `libopentui.so` for `android-arm64` (Bionic ABI, 16 KiB page-size aligned). Published as [`@xincli/opentui-core-android-arm64`](https://www.npmjs.com/package/@xincli/opentui-core-android-arm64) plus the `@xincli/opentui-{core,keymap,solid}` JS packages that route to it. | [bd-loser/opentui](https://github.com/bd-loser/opentui) (fork of anomalyco/opentui) |
| **opencode delta** | Quilt-style patch set on top of upstream opencode that swaps `@opentui/*` for the `@xincli/*` builds via Bun workspace catalog pins, and fixes the Termux-specific build script. | **bd-loser/opencode-bionic** (this repo, original) |

Everything above was authored by [@bd-loser](https://github.com/bd-loser).
Upstream credit goes to [opencode](https://github.com/anomalyco/opencode)
(the coding agent itself) and [opentui](https://github.com/anomalyco/opentui)
(the TUI library).

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
picks up the bump on its next run.

<!-- versions:table -->
| Component | Version |
|---|---|
| opencode (upstream) | `1.18.4` |
| `@opentui/{core,keymap,solid}` (JS, via `@xincli`) | `0.4.10` |
| `@xincli/opentui-core-android-arm64` (native `.so`) | `0.4.11` |
| `bun-termux` runtime | tracked at [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) |
<!-- /versions:table -->

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

## FAQ

**Does this work on non-rooted Android?**
Yes. Termux runs unrooted. This is a plain Termux `.deb` — no root, no
proot, no chroot.

**Does it work on 32-bit ARM (armv7) or x86 Android?**
No. Only aarch64 (arm64-v8a) is built. That covers essentially every
Android device made in the last ~7 years.

**Which minimum Android version?**
Anything Termux supports (Android 7.0+). Bionic-libc compatibility is
handled by the patched Bun.

**Is this the same as running `npm install -g opencode` in Termux?**
No, and that path is broken. Upstream opencode pulls in `@opentui/core`,
which tries to load a glibc `.so` — Bionic rejects it. This build swaps in
`@xincli/opentui-*` (Bionic-native) and ships a single self-contained
`opencode` binary compiled by Bun.

**Which LLM providers work?**
Same as upstream opencode: Anthropic Claude, OpenAI, and any
OpenAI-compatible endpoint (OpenRouter, Groq, local Ollama, etc.).
Configuration is identical to upstream — see
[opencode docs](https://opencode.ai/docs).

**Is it up to date with upstream?**
Yes. `.github/workflows/watch-upstream.yml` polls upstream every 2 days,
bumps `versions.json`, rebuilds, and publishes a matching release
automatically. Version parity is a design goal.

**How does it compare to Claude Code / Cursor / Aider?**
opencode is the underlying agent — this repo just makes it run on Android.
Feature comparisons belong to upstream opencode.

## Related repos (all maintained by [@bd-loser](https://github.com/bd-loser))

| Repo | Purpose | Fork? |
|---|---|---|
| [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) | Bun v1.3.14 patched for Bionic Android (FFI, TinyCC, MTE, SELinux). | Original |
| [bd-loser/opentui](https://github.com/bd-loser/opentui) | opentui + native `libopentui.so` rebuilt for android-arm64. Publishes the `@xincli/*` npm packages. | Fork of [anomalyco/opentui](https://github.com/anomalyco/opentui) |
| **bd-loser/opencode-bionic** (this repo) | opencode delta + release pipeline that ties it all together. | Original |

## License

MIT — same as upstream [opencode](https://github.com/anomalyco/opencode).
See [LICENSE](./LICENSE).
