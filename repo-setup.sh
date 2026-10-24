#!/data/data/com.termux/files/usr/bin/sh
# One-command setup for the bd-loser/opencode-bionic Termux repository.
# Adds the signing key + sources entry, updates, installs opencode.
#   OPENCODE_CHANNEL=stable|beta|dev   (default: stable)
set -eu
BASE="https://bd-loser.github.io/opencode-bionic"
CH="${OPENCODE_CHANNEL:-stable}"
case "$CH" in stable|beta|dev) ;; *) echo "OPENCODE_CHANNEL must be stable, beta or dev (got: $CH)" >&2; exit 1 ;; esac
[ -n "${PREFIX:-}" ] || { echo "Run this inside Termux." >&2; exit 1; }
command -v curl >/dev/null || { echo "pkg install curl first" >&2; exit 1; }
# Fresh bootstraps may not have the apt dirs yet (no pkg update ever ran).
mkdir -p "$PREFIX/etc/apt/trusted.gpg.d" "$PREFIX/etc/apt/sources.list.d"
# Flaky mobile links: fail fast instead of appearing to hang (#4 follow-up).
curl -fsSL --connect-timeout 10 --max-time 60 "$BASE/opencode-bionic.gpg" \
  -o "$PREFIX/etc/apt/trusted.gpg.d/opencode-bionic.gpg" \
  || { echo "Could not fetch the signing key — check your connection and retry." >&2; exit 1; }
echo "deb [arch=aarch64] $BASE $CH main" > "$PREFIX/etc/apt/sources.list.d/opencode-bionic.list"
pkg update -y
if pkg install -y --allow-downgrades opencode; then
  echo "Installed. pkg upgrade opencode keeps you current; rerun with OPENCODE_CHANNEL=beta or dev to switch lines."
else
  echo "pkg install opencode failed - run it manually to see the error" >&2
  exit 1
fi
