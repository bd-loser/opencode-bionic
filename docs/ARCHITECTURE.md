# Architecture

## Delta model

This repo does **not** vendor an upstream clone. It holds only the delta:
pinned versions, patches, and pipeline scripts. Upstream
[opencode](https://github.com/anomalyco/opencode) is fetched fresh at build
time, exactly like Debian/Nixpkgs/Alpine/Homebrew maintain downstream
packages — patches either apply cleanly or CI fails loudly.

```
opencode-bionic/
├── versions.json              # all pins: upstream version, @androidtui, bun-termux
├── install.sh                 # curl | bash installer (stable / beta / dev / pin)
├── termux/
│   ├── patches/               # unified diffs applied to upstream
│   ├── ci/
│   │   ├── fetch-upstream.sh    # git clone --depth 1 -b vX.Y.Z
│   │   ├── versions.ts          # config delta: package.json/catalog rewrites
│   │   ├── apply-patches.sh     # patch -p1 --forward termux/patches/*
│   │   ├── prepare-build-tree.sh# fetch + versions + patch, one command
│   │   ├── refresh-patches.sh   # regenerate patches after upstream drift
│   │   ├── build-on-runner.sh   # CI runner side
│   │   ├── build-in-container.sh# build side: bun install + compile
│   │   └── package-deb.sh       # wraps the binary as a .deb
│   └── setup.sh, rebuild-opencode.sh, ...   # local dev workflows
└── .github/workflows/
    └── opencode.yml           # one multi-flow workflow for all channels
```

## Build flow

1. **Detect** — compare upstream releases/branch heads against our releases;
   emit one build "leg" per pending channel line.
2. **Kit** — each leg checks out its channel branch (`main` / `beta` /
   `dev`), which carries that line's pins in `versions.json` and matching
   patches in `termux/patches/`.
3. **Prepare** — shallow-clone upstream at the pinned ref → `versions.ts`
   rewrites package.json (catalog aliases → `@androidtui/*`, optionalDeps,
   install-hook removal) → `patch -p1 --forward` applies the source patches.
4. **Build** — Bun compiles opencode into a single Bionic aarch64 binary.
5. **Publish** — `.deb` + checksum. Stable tags are immutable; rolling
   prerelease tags (`*-beta.<sha8>`, `*-dev.<sha8>`) are mutable and
   auto-replaced on rebuild.

## Patches

- Pinned upstream **stable** line gets its own patch series; `beta` and
  `dev` kits carry their own (upstream refactors between majors move patch
  context — that is why pins and patches live together per channel
  branch).
- Every patch must apply with `patch -p1 --forward` to a shallow clone.

## Refreshing patches after upstream drift

If `apply-patches.sh` fails after a version bump:

```bash
# Prepare a working tree with the current patches applied on the new version
bash termux/ci/prepare-build-tree.sh /tmp/refresh
cd /tmp/refresh

# Fix conflicts / edit files
$EDITOR packages/core/src/filesystem/fff.bun.ts
git add -A && git commit --amend --no-edit

# Regenerate patches back into the repo
bash "$OLDPWD/termux/ci/refresh-patches.sh" /tmp/refresh
```
