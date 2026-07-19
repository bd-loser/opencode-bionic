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
# nothing else. The clone is real git — `git am --3way` in apply-patches.sh
# needs a repo, not a raw tree.

set -euo pipefail

TARGET="${1:?usage: fetch-upstream.sh <target_dir> [version]}"
VERSION="${2:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "$VERSION" ]; then
  VERSION="$(bun "$REPO_ROOT/termux/ci/versions.ts" print | awk -F= '$1=="OPENCODE_VERSION"{print $2}')"
fi
if [ -z "$VERSION" ]; then
  echo "error: could not resolve opencode version" >&2
  exit 1
fi

TAG="v${VERSION#v}"

if [ -e "$TARGET" ]; then
  echo "error: target already exists: $TARGET" >&2
  echo "  remove it first or point to a new path." >&2
  exit 1
fi

echo "→ cloning anomalyco/opencode $TAG into $TARGET"
git clone --depth 1 -b "$TAG" https://github.com/anomalyco/opencode.git "$TARGET"

# Set a local git identity so `git am` can commit patches. GHA runners
# don't have one by default and Termux users may not either.
git -C "$TARGET" config user.email "opencode-bionic@localhost"
git -C "$TARGET" config user.name  "opencode-bionic build"

echo "→ fetched $TAG (commit: $(git -C "$TARGET" rev-parse --short HEAD))"
