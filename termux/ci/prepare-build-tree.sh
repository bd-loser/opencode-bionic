#!/usr/bin/env bash
# prepare-build-tree.sh — One command: fetch upstream, apply config, apply patches.
#
# Usage:
#   bash termux/ci/prepare-build-tree.sh <target_dir> [version]
#
# After this returns, <target_dir> contains a ready-to-build opencode tree
# at the pinned version with all our modifications applied. Callers can
# then `cd <target_dir> && bun install && bun packages/opencode/script/build-termux.ts`.

set -euo pipefail

TARGET="${1:?usage: prepare-build-tree.sh <target_dir> [version]}"
VERSION="${2:-}"

CI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CI_DIR/../.." && pwd)"

echo "=== step 1/3: fetch upstream ==="
bash "$CI_DIR/fetch-upstream.sh" "$TARGET" "$VERSION"

echo ""
echo "=== step 2/3: apply config delta (versions.ts) ==="
bun "$CI_DIR/versions.ts" apply --target "$TARGET"

# Commit the config edits so patches apply on a clean tree. Without this,
# `git am --3way` refuses because the working tree is dirty.
git -C "$TARGET" add -A
git -C "$TARGET" commit -m "opencode-bionic: config delta (versions.ts)" >/dev/null

echo ""
echo "=== step 3/3: apply source patches ==="
bash "$CI_DIR/apply-patches.sh" "$TARGET"

echo ""
echo "→ build tree ready at $TARGET"
echo "  cd $TARGET && bun install && bun packages/opencode/script/build-termux.ts"
