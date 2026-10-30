#!/usr/bin/env bash
# fetch-upstream.sh — Clone anomalyco/opencode at the pinned version.
#
# Usage:
#   bash termux/ci/fetch-upstream.sh <target_dir> [version]
#
# If version is omitted, reads it from versions.json (versions.ts print).
# The target dir must not exist (we clone fresh; refuse to overwrite).
#
# Uses `git clone --depth 1 -b vX.Y.Z` so we get the tagged commit and
# nothing else. The clone is real git — refresh-patches.sh regenerates our
# patches from it with `git diff`.
#
# Env:
#   OPENCODE_UPSTREAM_REF  build from this branch or commit instead of a
#                          release tag — how a dev prerelease is cut.
#
# The ref is a separate variable rather than an overload of <version>
# because on that path the two genuinely differ: <version> is the string
# stamped into the binary (1.18.15-dev.fe82a1b6, no such tag upstream) and
# the ref is what git can actually resolve (`dev`, or that commit).

set -euo pipefail

TARGET="${1:?usage: fetch-upstream.sh <target_dir> [version]}"
VERSION="${2:-}"
REF="${OPENCODE_UPSTREAM_REF:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "$REF" ]; then
  if [ -z "$VERSION" ]; then
    VERSION="$(bun "$REPO_ROOT/termux/ci/versions.ts" print | awk -F= '$1=="OPENCODE_VERSION"{print $2}')"
  fi
  if [ -z "$VERSION" ]; then
    echo "error: could not resolve opencode version" >&2
    exit 1
  fi
fi

if [ -e "$TARGET" ]; then
  echo "error: target already exists: $TARGET" >&2
  echo "  remove it first or point to a new path." >&2
  exit 1
fi

if [ -n "$REF" ]; then
  # `git clone -b` only takes a branch or tag name, so a commit sha has to
  # go through init+fetch. GitHub serves fetch-by-sha, so passing the exact
  # commit is what makes a dev build reproducible — `dev` moves under us.
  echo "→ fetching anomalyco/opencode at ref $REF into $TARGET"
  mkdir -p "$TARGET"
  git -C "$TARGET" init -q
  git -C "$TARGET" remote add origin https://github.com/anomalyco/opencode.git
  git -C "$TARGET" fetch -q --depth 1 origin "$REF"
  git -C "$TARGET" checkout -q FETCH_HEAD
  DESC="$REF"
else
  TAG="v${VERSION#v}"
  echo "→ cloning anomalyco/opencode $TAG into $TARGET"
  git clone --depth 1 -b "$TAG" https://github.com/anomalyco/opencode.git "$TARGET"
  DESC="$TAG"
fi

# Set a local git identity so `git am` can commit patches. GHA runners
# don't have one by default and Termux users may not either.
git -C "$TARGET" config user.email "opencode-bionic@localhost"
git -C "$TARGET" config user.name  "opencode-bionic build"

echo "→ fetched $DESC (commit: $(git -C "$TARGET" rev-parse --short HEAD))"
