# opencode for Termux — native Android build (Bionic aarch64)

> [opencode](https://opencode.ai), the open-source AI coding agent, running
> **natively on your Android phone** through Termux. No proot, no chroot, no
> VM, no root, no glibc. One self-contained binary, a signed apt repository,
> two channels (stable and dev).

<!-- versions:badges -->
[![opentui-js](https://img.shields.io/badge/opentui--js-@androidtui%400.6.8-green.svg)](https://www.npmjs.com/package/@androidtui/core)
[![opentui-so](https://img.shields.io/badge/libopentui.so-@androidtui%400.6.8-green.svg)](https://www.npmjs.com/package/@androidtui/core-android-arm64)
<!-- /versions:badges -->

## Screenshots

Native TUI, rendered on-device — no proot, no VNC, no WebView:

<p align="center">
  <img src="https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/docs/assets/tui-welcome.png" width="49%" alt="opencode welcome page in Termux on Android">
  <img src="https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/docs/assets/tui-models.png" width="49%" alt="opencode model picker in Termux, including free models">
</p>

Free models are in the picker too — you can start coding without paying for
anything.

## Install

Pick a line, paste one command inside Termux:

**Stable** *(newest upstream release — default, recommended)* — copy, paste, run:

```sh
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/repo-setup.sh | bash
```

**v1** *(legacy 1.x line)*:

```sh
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/repo-setup.sh | OPENCODE_CHANNEL=v1 bash
```

**Dev** *(bleeding edge)*:

```sh
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/repo-setup.sh | OPENCODE_CHANNEL=dev bash
```

The script installs the signing key, points apt at this repo, and installs
opencode. From then on `pkg upgrade opencode` keeps you current. Prefer
typing the commands yourself?

```bash
mkdir -p $PREFIX/etc/apt/trusted.gpg.d $PREFIX/etc/apt/sources.list.d
curl -fsSL https://bd-loser.github.io/opencode-bionic/opencode-bionic.gpg \
  -o $PREFIX/etc/apt/trusted.gpg.d/opencode-bionic.gpg
echo "deb [arch=aarch64] https://bd-loser.github.io/opencode-bionic stable main" \
  > $PREFIX/etc/apt/sources.list.d/opencode-bionic.list
pkg update && pkg install opencode
```

To switch lines — say, stable to v1 — rerun the one-liner for the other line
(it rewrites the sources entry and installs across downgrades), or edit the
suite (`stable`/`v1`/`dev`) in
`$PREFIX/etc/apt/sources.list.d/opencode-bionic.list` yourself. The package
is `opencode` on every line.

### Channels

All lines build automatically from upstream — an hourly watcher mirrors
upstream moves, at most about an hour behind, one release per upstream
version:

| Channel | Tracks | Releases |
|---|---|---|
| **stable** *(default)* | newest upstream release (now 2.x) | [tags](https://github.com/bd-loser/opencode-bionic/releases) |
| **v1** | newest upstream 1.x release | [prereleases](https://github.com/bd-loser/opencode-bionic/releases?q=prerelease%3Atrue&expanded=true) |
| **dev** | upstream `dev` branch | [prereleases](https://github.com/bd-loser/opencode-bionic/releases?q=prerelease%3Atrue&expanded=true) |

**stable tracks whatever upstream tags newest — currently the 2.x line — so it is
the recommended start.** Still on 1.x? The **v1** channel keeps shipping 1.x
releases. Live package index:
[bd-loser.github.io/opencode-bionic](https://bd-loser.github.io/opencode-bionic/).

## How it compares

[Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux) and
[guysoft/opencode-termux](https://github.com/guysoft/opencode-termux) also ship
native-Bionic OpenCode and both have bigger communities than this repo. What
is different here:

| | opencode-bionic | Hope2333/opencode-termux | guysoft/opencode-termux |
|---|---|---|---|
| libc | native Bionic | native Bionic | native Bionic |
| release lines | stable + v1 + dev, built automatically from upstream | v1 + v2 | v1 + v2 side-by-side |
| dev freshness | tracks upstream commits hourly | — | — |
| terminal sessions (PTY) | works, bun-pty rebuilt for Bionic | — | — |
| what you install | one self-contained .deb | one of five package families | package + wrapper + libs |
| exact pinning | by version or upstream commit, curl or apt | — | — |

Blank cells: not verified, read their README.

## What is opencode?

An open-source, terminal-based AI coding agent — MIT-licensed and
model-agnostic (Anthropic, OpenAI, OpenRouter, local models via any
OpenAI-compatible endpoint). Developed at
[anomalyco/opencode](https://github.com/anomalyco/opencode) with prebuilt
binaries for macOS, Linux, and Windows — **but none for Android**. This repo
provides the Android line.

## Why a separate build is needed

opencode's TUI runs on [opentui](https://opentui.com), a native Zig library.
Upstream ships only glibc binaries; Android's Bionic linker rejects them.
This project assembles the three pieces that make opencode run on Bionic:

- a **Bun runtime** patched for Bionic (SELinux-safe JIT, syscall traps,
  shebang remap, FFI paths),
- **opentui rebuilt for android-arm64**, published as `@androidtui/*` npm
  packages (16 KiB-page-aligned Bionic `.so`),
- **this repo** — patch delta, version pins, release pipeline: one command
  installs a single self-contained binary.

## Docs

- [Architecture & release pipeline](./docs/ARCHITECTURE.md)
- [Building on device / from source](./docs/BUILDING.md)

## Current pins

This channel's exact build inputs, regenerated automatically on every
release. The other channel lives on its own branch
([dev](https://github.com/bd-loser/opencode-bionic/tree/dev)), all sourced from
[`versions.json`](./versions.json).

<!-- versions:table -->
| Component | Version |
|---|---|
| opencode (upstream) | `2.2.4` |
| `@opentui/{core,keymap,solid}` (JS, via `@androidtui`) | `0.6.8` |
| `@androidtui/core-android-arm64` (native `.so`) | `0.6.8` |
| `bun-termux` runtime | `1.4.4-patched` ([bd-loser/bun-termux](https://github.com/bd-loser/bun-termux)) |
| `bun-pty` (Bionic pty `.so`, embedded) | `0.4.11` ([release asset](https://github.com/bd-loser/bun-termux/releases/tag/bun-pty-v0.4.11)) |

<!-- /versions:table -->

## FAQ

<details>
<summary><b>Root? 32-bit? Minimum Android?</b></summary>

No root, no proot, no chroot. Only aarch64 (arm64-v8a) is built, covering
essentially every Android device from the last ~7 years. Minimum: **Android
10** — the patched Bun runtime needs API 29.
</details>

<details>
<summary><b>Why not just <code>npm install -g opencode</code> in Termux?</b></summary>

Broken: opencode pulls in <code>@opentui/core</code>, whose glibc
<code>.so</code> Bionic refuses. This build substitutes the Bionic-native
<code>@androidtui/*</code> packages and compiles everything into one
self-contained binary.
</details>

<details>
<summary><b>Which LLM providers work?</b></summary>

All of upstream's: Anthropic, OpenAI, and any OpenAI-compatible endpoint
(OpenRouter, Groq, Ollama, …). Configuration is identical to upstream —
see <a href="https://opencode.ai/docs">opencode.ai/docs</a>.
</details>

<details>
<summary><b>How fast do updates land?</b></summary>

Automatically, within about an hour: upstream stable and dev activity each
trigger a matching build here (one release per upstream version).
See <a href="#channels">Channels</a>.
</details>

## Related repos

| Repo | Role |
|---|---|
| [bd-loser/bun-termux](https://github.com/bd-loser/bun-termux) | Bun runtime patched for Bionic |
| [bd-loser/opentui](https://github.com/bd-loser/opentui) | opentui android-arm64 rebuild, publishes `@androidtui/*` (fork of [anomalyco/opentui](https://github.com/anomalyco/opentui)) |

Upstream credit: [anomalyco/opencode](https://github.com/anomalyco/opencode)
and [anomalyco/opentui](https://github.com/anomalyco/opentui).

## License

MIT — same as upstream opencode. See [LICENSE](./LICENSE).
