# opencode-bionic — Termux/Android build system

Fork architecture for shipping [anomalyco/opencode](https://github.com/anomalyco/opencode)
(fka `sst/opencode`) on Android/Termux, using [bun-termux](https://github.com/bd-loser/bun-termux)
and [@xincli/opentui-*](https://www.npmjs.com/~xincli).

## The delta

Upstream opencode has no Android support: its opentui native bindings only
resolve `darwin`/`linux`/`win32`, and the linux binary is glibc — Bionic
rejects it. Our fork adds Termux support with a small, well-scoped delta:

| Kind | File | How it's expressed |
|---|---|---|
| Source | `bunfig.toml` | patch — adds `@xincli/*` to `minimumReleaseAgeExcludes` |
| Source (new file) | `packages/opencode/script/build-termux.ts` | patch — the compile script (embeds bun-termux, targets aarch64) |
| Source | `packages/core/src/filesystem/fff.bun.ts` | patch — lazy-load `@ff-labs/fff-bun` (no Android binary; falls back to ripgrep) |
| Config | `package.json` (root) | `versions.ts` — catalog aliases, `optionalDependencies`, remove `postinstall`/`prepare`/`trustedDeps`/fff-bun patch entry |
| Config | `packages/plugin/package.json` | `versions.ts` — bump version + `peerDependencies` |

Split rationale: **patches** are shape-fragile but greppable — if upstream
renames `fff.bun.ts`, `git am` fails loudly. **`versions.ts`** applies
JSON edits semantically — resilient to reformatting, and re-emits the
correct values on version bumps.

## Directory layout

```
opencode-bionic/                   ← this repo
├── README.md                      ← top-level docs
├── LICENSE
├── install.sh                     ← one-liner for end users (curl | bash)
├── versions.json                  ← single source of truth for all pins
├── .github/workflows/
│   ├── release.yml                ← manual dispatch → build + publish .deb
│   └── watch-upstream.yml         ← cron: detect upstream, bump, dispatch release
└── termux/
    ├── README.md                  ← this file
    ├── patches/                   ← quilt-style unified diffs
    │   ├── 0001-termux-add-xincli-to-minimumReleaseAgeExcludes.patch
    │   ├── 0002-termux-add-build-termux.ts-compile-script.patch
    │   └── 0003-termux-lazy-load-ff-labs-fff-bun.patch
    ├── ci/                        ← build pipeline
    │   ├── versions.ts            ← config-delta applier; canonical version parser
    │   ├── versions.sh            ← same, but sourceable by bash scripts
    │   ├── fetch-upstream.sh      ← clones anomalyco/opencode at a pinned tag
    │   ├── apply-patches.sh       ← git am --3way termux/patches/*.patch
    │   ├── refresh-patches.sh     ← regenerates patches from a build tree
    │   ├── prepare-build-tree.sh  ← chains fetch + versions + apply
    │   ├── build-on-runner.sh     ← GitHub Actions entrypoint (spawns docker)
    │   ├── build-in-container.sh  ← runs inside termux-docker; produces the binary
    │   └── package-deb.sh         ← wraps the binary into a .deb
    ├── setup.sh                   ← local dev bootstrap
    ├── rebuild-opencode.sh        ← local rebuild + reinstall
    ├── build-opencode-termux.sh   ← invokes bun build --compile
    ├── clean-reinstall.sh         ← nuke node_modules and reinstall
    ├── install-opencode-termux.sh ← copy binary to $PREFIX
    ├── run-opencode-termux.sh     ← dev-mode launcher (bun run)
    ├── release-opentui.sh         ← publish @xincli npm packages
    └── test-opentui-isolated.sh   ← smoke test the native binding
```

The repo holds ~30 files. Upstream is fetched fresh at build time — we
never carry a stale copy in the working tree.

## Build flow

Same pipeline for local dev and CI:

```
BUILD_DIR=/some/scratch/dir
bash termux/ci/prepare-build-tree.sh "$BUILD_DIR"    # fetch + config + patches
cd "$BUILD_DIR"
bun install
bun packages/opencode/script/build-termux.ts         # produces the binary
```

`prepare-build-tree.sh` internally runs:

1. `fetch-upstream.sh` — `git clone --depth 1 -b v$(jq .opencode versions.json) anomalyco/opencode`
2. `bun termux/ci/versions.ts apply --target $BUILD_DIR` — apply config delta
3. `apply-patches.sh` — `git am --3way termux/patches/*.patch`

Any of those failing aborts loudly — no half-patched trees.

## Local dev (on your Termux phone)

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

# 3. Bootstrap: prepares a build tree at ~/opencode and runs bun install
bash termux/setup.sh

# 4. Build + install
bash termux/rebuild-opencode.sh
opencode --version
```

`setup.sh` reads `versions.json` and always builds the pinned upstream
version. To rebuild after a version bump, run `rebuild-opencode.sh`
again — it re-runs `prepare-build-tree.sh` to a fresh tree.

## Refreshing patches (when upstream drifts)

If `git am --3way` starts failing after an upstream bump — typically
because upstream renamed a file we patch — refresh the patches:

```bash
# 1. Prepare a build tree; apply-patches will fail, leaving mid-am state
bash termux/ci/prepare-build-tree.sh /tmp/refresh

# 2. cd there, resolve conflicts:
cd /tmp/refresh
$EDITOR path/to/conflicted-file
git add -A
git am --continue

# 3. Regenerate patches back into the repo
bash "$OLDPWD/termux/ci/refresh-patches.sh" /tmp/refresh

# 4. Verify + commit
cd $OLDPWD
git status termux/patches/
git add termux/patches/ && git commit -m "patches: refresh for upstream vX.Y.Z"
```

`refresh-patches.sh` runs `git format-patch v<pinned>..HEAD` and writes
into `termux/patches/`. Patch numbering and subject slugs are
deterministic, so filenames stay stable when the delta doesn't change.

## Bumping opentui or the .so

Everything version-related is in `versions.json`:

```json
{
  "opencode": "1.18.3",
  "opentui": {
    "core": "0.4.10",
    "keymap": "0.4.10",
    "solid": "0.4.10",
    "react": "0.4.10",
    "androidArm64Native": "0.4.11"
  }
}
```

Edit, then:

```bash
bun termux/ci/versions.ts check    # sanity check (no-op if in a bare repo)
bash termux/rebuild-opencode.sh    # rebuilds against a fresh tree
```

CI reads the same file; there is no other place versions are tracked.

## Release + upstream auto-bump

- `release.yml` — manual dispatch. Builds the binary in `termux-docker`,
  wraps it into a `.deb`, publishes to GitHub Releases.
- `watch-upstream.yml` — runs every 2 days:
  1. Reconciles our `prerelease` flag against upstream for existing tags
  2. If upstream has a newer tag, bumps `versions.json`, dry-runs
     `prepare-build-tree.sh` to prove patches still apply, commits, and
     dispatches `release.yml` with `prerelease=<upstream's flag>`
  3. On patch conflict, the workflow fails loudly — human refreshes
     patches, then re-triggers

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `git am --3way` fails at step 3 of `prepare-build-tree.sh` | Upstream renamed or refactored a file we patch | Run the refresh flow (see above) |
| `opencode --version` reports `0.0.0-termux-ci` | `OPENCODE_VERSION` didn't reach `build-termux.ts` | Verify `build-on-runner.sh` writes `$OUT_HOST/build-env.sh` and `build-in-container.sh` sources it |
| `libopentui.so` extraction fails from bunfs | Native `.so` version drift, or the compiled binary shipped with the wrong `.so` | Bump `opentui.androidArm64Native` in `versions.json` and rebuild |
| `Cannot find module '@ff-labs/fff-bun'` at runtime | Patch 0003 didn't apply | `git am --abort` in the build tree; re-run `apply-patches.sh` |

## Design notes

**Why quilt patches over a fork clone?** Upstream ships every 2 days.
Rebasing a fork clone silently accumulates drift; quilt patches either
apply cleanly or fail loudly. Same pattern as Debian, Nixpkgs, Alpine,
Homebrew, Fedora.

**Why split source vs config?** Source patches are shape-fragile — if
upstream renames the file, we want CI to fail. Config edits should
survive upstream reformatting silently, so they're expressed
programmatically in `versions.ts`.

**Why put patches under `termux/patches/`?** Upstream itself uses
top-level `patches/` for its own Bun patch files
(`patches/@ff-labs%2Ffff-bun@0.9.3.patch` etc.). Nesting under `termux/`
avoids the collision.

**Why fetch upstream fresh instead of a git submodule?** Submodules add
a fetch step and pin at commit granularity when we want tag granularity.
A `--depth 1 -b vX.Y.Z` clone in `prepare-build-tree.sh` is cheaper and
transparent about what's being built.
