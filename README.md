# opencode for Android — native Termux build

> Run [opencode](https://opencode.ai), the open-source AI coding agent,
> **natively on your Android phone**. No proot, no chroot, no Linux VM,
> no root. A Bionic-native aarch64 build, packaged for Termux.

[![Termux](https://img.shields.io/badge/Termux-Android%20arm64-black?logo=android&logoColor=white)](https://termux.dev)
[![Latest release](https://img.shields.io/github/v/release/bd-loser/opencode-bionic?display_name=tag&color=blue)](https://github.com/bd-loser/opencode-bionic/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/bd-loser/opencode-bionic/total?color=blueviolet)](https://github.com/bd-loser/opencode-bionic/releases)
[![Release workflow](https://github.com/bd-loser/opencode-bionic/actions/workflows/opencode.yml/badge.svg)](https://github.com/bd-loser/opencode-bionic/actions/workflows/opencode.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](./LICENSE)
<!-- versions:badges -->
[![opentui-js](https://img.shields.io/badge/opentui--js-@androidtui%400.6.6-green.svg)](https://www.npmjs.com/package/@androidtui/core)
[![opentui-so](https://img.shields.io/badge/libopentui.so-@androidtui%400.6.6-green.svg)](https://www.npmjs.com/package/@androidtui/core-android-arm64)
<!-- /versions:badges -->

## Install

One command, inside [Termux](https://termux.dev) (F-Droid or GitHub — not
the Play Store build):

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | bash
```

Grabs the latest **stable** `.deb`, verifies its SHA256, installs with
`dpkg`. Then just run `opencode`.

### Channels

Upstream ships three release lines; we mirror all of them, within minutes:

| Channel | Built from | Our tag pattern | Env |
|---|---|---|---|
| **stable** *(default)* | upstream release tags | `vX.Y.Z` | — |
| **beta** | upstream `beta` branch | `vX.Y.Z-beta.<sha8>` | `OPENCODE_CHANNEL=beta` |
| **dev** | upstream `dev` branch | `vX.Y.Z-dev.<sha8>` | `OPENCODE_CHANNEL=dev` |

```bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | OPENCODE_CHANNEL=beta bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | OPENCODE_CHANNEL=dev bash

# pin an exact release (any channel) or an upstream commit
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | OPENCODE_VERSION=<version> bash
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | OPENCODE_COMMIT=<sha> bash
```

`/releases/latest` only ever points at **stable** — beta and dev builds are
prereleases and can never reach you unless you ask. Browse the artifacts
directly instead of installing: [all releases](https://github.com/bd-loser/opencode-bionic/releases)
· [beta & dev](https://github.com/bd-loser/opencode-bionic/releases?q=prerelease%3Atrue&expanded=true)
· [tags](https://github.com/bd-loser/opencode-bionic/tags). Everything is
automated: new upstream moves are detected and mirrored without a human
pressing anything, usually within minutes.

## How it compares

[Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux) and
[guysoft/opencode-termux](https://github.com/guysoft/opencode-termux) also ship
native-Bionic OpenCode and both have bigger communities than this repo. What
is different here:

| | opencode-bionic | Hope2333/opencode-termux | guysoft/opencode-termux |
|---|---|---|---|
| libc | native Bionic | native Bionic | native Bionic |
| release lines | stable + beta + dev, built automatically from upstream | v1 + v2 | v1 + v2 side-by-side |
| dev freshness | tracks upstream commits within minutes | — | — |
| terminal sessions (PTY) | works, bun-pty rebuilt for Bionic | — | — |
| what you install | one self-contained .deb | one of five package families | package + wrapper + libs |
| exact pinning | by version or upstream commit | — | — |

Blank cells: not verified, read their README.

## Roadmap

- .deb repository, so `pkg upgrade opencode` works
- TUI screenshots
- an `opencode-upgrade` helper, for switching channels without the curl line

## What is opencode?

An open-source, terminal-based AI coding agent — MIT-licensed and
model-agnostic (Anthropic, OpenAI, OpenRouter, local models via any
OpenAI-compatible endpoint). Developed at
[anomalyco/opencode](https://github.com/anomalyco/opencode), with prebuilt
binaries for macOS, Linux, and Windows — **but none for Android**.
This repo provides the Android line.

## Why a separate build is needed

opencode's TUI runs on [opentui](https://opentui.com), a native Zig
library. Upstream ships only glibc binaries; Android's Bionic linker
rejects them outright. This project assembles the three pieces that make
opencode run natively on Bionic:

- a **Bun runtime** patched for Bionic libc (SELinux-safe JIT, syscall
  traps, shebang remap, FFI paths),
- **opentui rebuilt for android-arm64**, published as `@androidtui/*`
  npm packages (16 KiB-page-aligned Bionic `.so`),
- **this repo**: the patch delta + version pins + release pipeline that
  ties it together and ships a single self-contained binary.

## Docs

- [Architecture & release pipeline](./docs/ARCHITECTURE.md)
- [Building on device / from source](./docs/BUILDING.md)

## Current pins

This channel's exact build inputs, regenerated automatically on every
release. Other channels live on their own branch
([beta](https://github.com/bd-loser/opencode-bionic/tree/beta) /
[dev](https://github.com/bd-loser/opencode-bionic/tree/dev)), all sourced from
[`versions.json`](./versions.json).

<!-- versions:table -->
| Component | Version |
|---|---|
| opencode (upstream) | `2.0.30` |
| `@opentui/{core,keymap,solid}` (JS, via `@androidtui`) | `0.6.6` |
| `@androidtui/core-android-arm64` (native `.so`) | `0.6.6` |
| `bun-termux` runtime | `1.4.3-patched` ([bd-loser/bun-termux](https://github.com/bd-loser/bun-termux)) |
<!-- /versions:table -->

## FAQ

<details>
<summary><b>Root needed? 32-bit? Which Android version?</b></summary>

No root, no proot, no chroot. Only aarch64 (arm64-v8a) is built, which
covers essentially every Android device from the last ~7 years. Minimum
Android version: whatever Termux itself supports (7.0+).
</details>

<details>
<summary><b>Why not just `npm install -g opencode` in Termux?</b></summary>

Because it's broken: opencode pulls in `@opentui/core`, which loads a
glibc `.so` that Bionic refuses. This build substitutes the Bionic-native
`@androidtui/*` packages and compiles everything into one self-contained
binary.
</details>

<details>
<summary><b>Which LLM providers work?</b></summary>

All of upstream's: Anthropic, OpenAI, and any OpenAI-compatible endpoint
(OpenRouter, Groq, Ollama, …). Configuration is identical to upstream —
see [opencode.ai/docs](https://opencode.ai/docs).
</details>

<details>
<summary><b>How fast do updates land?</b></summary>

Automatically, within minutes — upstream stable, beta, and dev activity
each trigger a matching build and release here. Version parity is a
design goal, not a task. See [Channels](#channels).
</details>

## Related repos

| Repo | Role |
|---|---|
| [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) | Bun runtime patched for Bionic (original) |
| [bd-loser/opentui](https://github.com/bd-loser/opentui) | opentui android-arm64 rebuild, publishes `@androidtui/*` (fork of [anomalyco/opentui](https://github.com/anomalyco/opentui)) |

Upstream credit: [anomalyco/opencode](https://github.com/anomalyco/opencode)
and [anomalyco/opentui](https://github.com/anomalyco/opentui).

## License

MIT — same as upstream opencode. See [LICENSE](./LICENSE).
