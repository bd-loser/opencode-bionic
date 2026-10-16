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
curl -fsSL "$BASE/opencode-bionic.gpg" -o "$PREFIX/etc/apt/trusted.gpg.d/opencode-bionic.gpg"
echo "deb [arch=aarch64] $BASE $CH main" > "$PREFIX/etc/apt/sources.list.d/opencode-bionic.list"
pkg update -y
if pkg install -y opencode; then
  echo "Installed. From now on: pkg upgrade opencode keeps you current."
else
  echo "pkg install opencode failed - run it manually to see the error" >&2
  exit 1
fi
