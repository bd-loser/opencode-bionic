# Contributing to opencode-bionic

Thanks for your interest! This repo is a **build kit**, not the OpenCode
source: it pins, patches and compiles [opencode](https://github.com/anomalyco/opencode)
for Android/Termux (Bionic libc, aarch64) and publishes `.deb` releases on a
schedule.

## How the repo works

| Branch      | Channel | Releases |
|-------------|---------|----------|
| `main`      | stable  | `vX.Y.Z` (explicit versions) |
| `beta`      | beta    | `vX.Y.Z-beta.<sha>` (rolling, tag replaced) |
| `dev`       | dev     | `vX.Y.Z-dev.<sha>` (rolling, tag replaced) |

- GitHub Actions workflows **must stay byte-identical across all three
  branches** — child workflows are looked up by tag, so a diverged workflow
  would rebuild a different kit.
- `versions.json` pins every component (opencode, opentui→@androidtui,
  bun-termux, bun-pty). `bun termux/ci/versions.ts check` validates pins;
  `apply` rewrites patches/README.
- The rolling-pin detects upstream commits hourly and ships prebuilt releases;
  there is no need to open PRs that only bump versions.

## Useful contributions

- Android/Bionic build fixes (patches under `termux/`)
- PTY / TUI native fixes (bun-pty, AndroidTUI `@androidtui/*` mirrors)
- Documentation, install instructions, troubleshooting notes

## Reporting bugs

Please use the bug issue template and include: channel + version
(`opencode --version`), device/Android version, and logs
(`OPENCODE_LOGLEVEL=DEBUG opencode ... 2>&1 | head -100`).

## Notes

- Bundled OpenCode, Bun and other binaries keep their upstream licenses
  (OpenCode is MIT); this repo's own tooling is MIT too.
- Releases are built in CI (termux-docker). Local builds are possible but the
  container is the source of truth.
