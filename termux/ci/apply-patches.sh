#!/usr/bin/env bash
# apply-patches.sh — Apply our source-delta patches on top of an upstream clone.
#
# Usage:
#   bash termux/ci/apply-patches.sh <target_dir>
#
# Runs `patch -p1 --forward` for every termux/patches/*.patch, in filename
# order. On a rejected hunk, exits non-zero so CI fails loudly at the patch
# step (not the build step) when upstream drifts.

set -euo pipefail

TARGET="${1:?usage: apply-patches.sh <target_dir>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PATCH_DIR="$REPO_ROOT/termux/patches"

if [ ! -d "$TARGET/.git" ]; then
  echo "error: $TARGET is not a git repository (fetch-upstream.sh clones with .git — did you delete it?)" >&2
  exit 1
fi

# Sorted glob; patch order is intentional and encoded in filenames (0001, 0002, ...).
shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob

if [ ${#PATCHES[@]} -eq 0 ]; then
  echo "→ no patches in $PATCH_DIR (nothing to apply)"
  exit 0
fi

echo "→ applying ${#PATCHES[@]} patch(es) to $TARGET"
for p in "${PATCHES[@]}"; do
  echo "  ▸ $(basename "$p")"
done

# Use patch -p1 --forward directly. git am --3way fails on shallow clones
# (no parent blobs) and leaves the tree partially modified, which then makes
# patch -p1 see changes as "already applied".
for p in "${PATCHES[@]}"; do
  patch -d "$TARGET" -p1 --forward -i "$p" || {
    echo "" >&2
    echo "error: patch -p1 failed for $(basename "$p")." >&2
    echo "" >&2
    echo "  If upstream renamed or restructured files, regenerate patches:" >&2
    echo "    1. Resolve the conflict in $TARGET (edit, git add)" >&2
    echo "    2. bash termux/ci/refresh-patches.sh $TARGET" >&2
    echo "" >&2
    exit 1
  }
done

echo "→ patches applied cleanly."
