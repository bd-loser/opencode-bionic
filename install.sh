#!/data/data/com.termux/files/usr/bin/env bash
# opencode-bionic installer for Termux (aarch64).
#
#   curl -fsSL https://raw.githubusercontent.com/bd-loser/opencode-bionic/main/install.sh | bash
#
# Installs the newest STABLE release by default. Stable builds come from an
# upstream opencode release tag; prereleases are built from upstream's `dev`
# branch and are named <version>-dev.<short-sha>.
#
# Env overrides:
#   OPENCODE_CHANNEL  stable (default) | prerelease
#   OPENCODE_VERSION  exact version or tag, e.g. 1.18.15 or
#                     1.18.15-dev.fe82a1b6 (takes precedence over CHANNEL)
#   OPENCODE_COMMIT   install the dev build made from this upstream commit;
#                     any sha prefix of 4+ hex chars
#   OPENCODE_REPO     github repo (default: bd-loser/opencode-bionic)
#
# Examples:
#   curl -fsSL .../install.sh | bash                              # stable
#   curl -fsSL .../install.sh | OPENCODE_CHANNEL=prerelease bash  # newest dev
#   curl -fsSL .../install.sh | OPENCODE_COMMIT=fe82a1b6 bash     # one commit

set -euo pipefail

REPO="${OPENCODE_REPO:-bd-loser/opencode-bionic}"
VERSION="${OPENCODE_VERSION:-}"
CHANNEL="${OPENCODE_CHANNEL:-stable}"
COMMIT="${OPENCODE_COMMIT:-}"

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

case "$CHANNEL" in
  stable | prerelease) ;;
  *)
    red "OPENCODE_CHANNEL must be 'stable' or 'prerelease', got: $CHANNEL"
    exit 1
    ;;
esac

# Newest release matching a jq filter, from the paginated list. /releases is
# ordered newest-first and, unlike /releases/latest, includes prereleases.
#
# `latest` is a GitHub-computed pointer that skips prereleases entirely — it
# is exactly right for the stable channel and useless for the other two, so
# both of those read the full list instead.
pick_release() {
  curl -fsSL "$API/releases?per_page=100" \
    | jq -r "[.[] | select(.draft | not) | $1] | .[0].tag_name // empty"
}

if [ -n "$COMMIT" ]; then
  # A dev tag embeds the short sha: v1.18.15-dev.fe82a1b6. Accept any prefix
  # the user pasted, so `OPENCODE_COMMIT=fe82a1b` works as well as the full
  # 40-char sha they copied out of a GitHub URL.
  if ! printf '%s' "$COMMIT" | grep -Eq '^[0-9a-fA-F]{4,40}$'; then
    red "OPENCODE_COMMIT must be a hex sha (4+ chars), got: $COMMIT"
    exit 1
  fi
  SHORT="$(printf '%s' "$COMMIT" | tr 'A-Z' 'a-z' | cut -c1-8)"
  say "Looking for the build made from commit $SHORT…"
  TAG="$(pick_release "select(.tag_name | test(\"-dev\\\\.$SHORT\"))")"
  if [ -z "$TAG" ]; then
    red "No release built from commit $SHORT."
    say "Dev builds exist only for commits the release workflow was run on:"
    curl -fsSL "$API/releases?per_page=100" \
      | jq -r '[.[] | select(.draft | not) | select(.tag_name | test("-dev\\."))
               | "    " + .tag_name] | .[0:10] | .[]' >&2 || true
    exit 1
  fi
elif [ -n "$VERSION" ]; then
  TAG="v${VERSION#v}"
elif [ "$CHANNEL" = "prerelease" ]; then
  # Newest of either kind: a stable release published after the last dev
  # build is strictly newer, and pinning users to a stale dev build because
  # it happens to be flagged prerelease would be the wrong answer.
  say "Resolving newest release (including prereleases) from $REPO…"
  TAG="$(pick_release ".")"
  if [ -z "$TAG" ]; then
    red "Could not resolve any release. Set OPENCODE_VERSION explicitly."
    exit 1
  fi
else
  say "Resolving latest stable release from $REPO…"
  TAG="$(curl -fsSL "$API/releases/latest" | jq -r '.tag_name // empty')"
  if [ -z "$TAG" ]; then
    red "Could not resolve latest release. Set OPENCODE_VERSION explicitly."
    exit 1
  fi
fi

VERSION="${TAG#v}"

grn "Installing opencode $TAG for Termux (aarch64)"
case "$VERSION" in
  *-dev.*) say "This is a development build from upstream's dev branch." ;;
esac

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

# Releases built before the switch to xz are zstd-compressed. An older Termux
# bootstrap ships a dpkg built without libzstd, which then shells out to a
# `zstd` binary that is not in the bootstrap either, and the install dies with
# `member "control.tar" (zstd): No such file or directory`. Current releases are
# xz so this never triggers, but pinning an old OPENCODE_VERSION can still land
# a zstd deb. The ar member names are ASCII within the first ~200 bytes
# (control.tar.* starts at byte 72), so this needs no `ar` — binutils is not in
# the bootstrap. Matched with `case` rather than `head | grep -q`, which can
# report failure under `pipefail` when grep short-circuits and SIGPIPEs head.
# Best-effort: if the fetch fails, fall through and let dpkg report the problem.
DEB_HEADER="$(head -c 200 "$TMP/$DEB" | tr -d '\0')"
case "$DEB_HEADER" in
  *.tar.zst*)
    if ! command -v zstd >/dev/null 2>&1; then
      say "Archive is zstd-compressed; installing zstd"
      pkg install -y zstd >/dev/null 2>&1 || true
    fi
    ;;
esac

say "Installing via dpkg"
dpkg -i "$TMP/$DEB"

grn "Done. Binary: $(command -v opencode)"
opencode --version
