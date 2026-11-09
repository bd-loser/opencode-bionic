# Shared Termux APT repository

This repository publishes signed aarch64 packages for OpenCode, Camoufox, Obscura and future projects at the existing GitHub Pages URL. Existing signing keys and stable/v1/dev source lines remain valid. OpenCode follows its channel; shared projects appear in all three channels.

Already configured? Run `pkg update`, then `pkg install obscura` or `pkg install camoufox`.

For a new installation:

```sh
pkg install curl
curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/repo-setup.sh | TERMUX_PACKAGE=obscura bash
```

## Adding projects

Add an entry to `projects.json`. Use `format: deb` for existing release packages, with a GitHub repository, release tag, package name and asset glob. Each matching package is checksum-verified and its identity checked; the highest Debian version is selected. Provide a pinned `sha256`, GitHub asset digest, or a matching `.sha256` sidecar. Only aarch64 packages are accepted.

For a release containing standalone binaries, use `format: binary-tar` with an exact asset name, pinned SHA-256, Debian version, description and binary filenames. Only explicitly listed regular files are copied into the Termux prefix. Obscura uses this adapter, preserving the existing release archive and its binaries. Package version 0.2.6-1 tracks upstream v0.2.6; the binary itself reports upstream's workspace version.

Run the `termux-repo` workflow manually after updating this list. The existing release and weekly triggers remain; pushes do not trigger this publisher. Any failed download, checksum, or package validation stops publication and leaves the deployed repository intact. GitHub Pages is replaced only after signing succeeds.

This is an APT repository. ZIP and pacman release assets are separate formats and are not indexed by APT.
