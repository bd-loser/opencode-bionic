#!/usr/bin/env bash
# refresh-patches.sh — Regenerate termux/patches/ from commits in a working tree.
#
# Usage:
#   bash termux/ci/refresh-patches.sh <target_dir>
#
# Expects <target_dir> to be an upstream clone with our patches applied
# (and possibly additional commits on top). Reads the upstream tag from
# versions.json, runs `git format-patch <tag>..HEAD` into termux/patches/,
# replacing the existing patch files.
#
# Filenames come from git's slugified commit subjects, so they're stable
# as long as commit subjects don't change. If you rewrite subjects,
# stale patches with old names will be left behind — this script removes
# any existing termux/patches/*.patch before regenerating to prevent that.

set -euo pipefail

TARGET="${1:?usage: refresh-patches.sh <target_dir>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH_DIR="$REPO_ROOT/termux/patches"

if [ ! -d "$TARGET/.git" ]; then
  echo "error: $TARGET is not a git repository" >&2
  exit 1
fi

VERSION="$(bun "$REPO_ROOT/termux/ci/versions.ts" print | awk -F= '$1=="OPENCODE_VERSION"{print $2}')"
TAG="v${VERSION#v}"

if ! git -C "$TARGET" rev-parse --verify "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG not found in $TARGET." >&2
  echo "  This script assumes the target was created via fetch-upstream.sh." >&2
  exit 1
fi

BASE="$(git -C "$TARGET" rev-parse "$TAG")"
HEAD="$(git -C "$TARGET" rev-parse HEAD)"
if [ "$BASE" = "$HEAD" ]; then
  echo "error: HEAD == $TAG. No commits to turn into patches." >&2
  exit 1
fi

COUNT="$(git -C "$TARGET" rev-list --count "$BASE..HEAD")"
echo "→ regenerating $COUNT patch(es) from $TAG..HEAD"

mkdir -p "$PATCH_DIR"
rm -f "$PATCH_DIR"/*.patch
git -C "$TARGET" format-patch --no-numbered --zero-commit --no-signature \
    -o "$PATCH_DIR" "$BASE..HEAD"

echo "→ wrote:"
ls -1 "$PATCH_DIR"/*.patch | sed 's|^|  |'
