#!/data/data/com.termux/files/usr/bin/env bash
# opencode-bionic installer for Termux (aarch64).
#
#   curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | bash
#
# Env overrides:
#   OPENCODE_VERSION  install a specific version (default: latest release)
#   OPENCODE_REPO     github repo (default: bd-loser/opencode-bionic)

set -euo pipefail

REPO="${OPENCODE_REPO:-bd-loser/opencode-bionic}"
VERSION="${OPENCODE_VERSION:-}"

red() { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
grn() { printf '\033[0;32m%s\033[0m\n' "$*"; }
say() { printf '  %s\n' "$*"; }

# --- Sanity checks -----------------------------------------------------------

if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX" ]; then
  red "This installer targets Termux. \$PREFIX is not set — are you running inside Termux?"
  exit 1
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ]; then
  red "Unsupported architecture: $ARCH (only aarch64 is built)"
  exit 1
fi

for cmd in curl dpkg jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    say "Installing missing dependency: $cmd"
    pkg install -y "$cmd" >/dev/null
  fi
done

# --- Resolve version ---------------------------------------------------------

API="https://api.github.com/repos/$REPO"

if [ -z "$VERSION" ]; then
  say "Resolving latest release from $REPO…"
  TAG="$(curl -fsSL "$API/releases/latest" | jq -r .tag_name)"
  if [ -z "$TAG" ] || [ "$TAG" = "null" ]; then
    red "Could not resolve latest release. Set OPENCODE_VERSION explicitly."
    exit 1
  fi
  VERSION="${TAG#v}"
else
  TAG="v${VERSION#v}"
  VERSION="${TAG#v}"
fi

grn "Installing opencode $TAG for Termux (aarch64)"

# --- Download ---------------------------------------------------------------

DEB="opencode_${VERSION}_aarch64.deb"
BASE="https://github.com/$REPO/releases/download/$TAG"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading $DEB"
curl -fL --progress-bar -o "$TMP/$DEB" "$BASE/$DEB"

say "Downloading SHA256SUMS"
curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"

say "Verifying checksum"
( cd "$TMP" && sha256sum -c --ignore-missing SHA256SUMS 2>&1 | grep -F "$DEB" ) \
  || { red "Checksum failed"; exit 1; }

# --- Install ----------------------------------------------------------------

say "Installing via dpkg"
dpkg -i "$TMP/$DEB"

grn "Done. Binary: $(command -v opencode)"
opencode --version
