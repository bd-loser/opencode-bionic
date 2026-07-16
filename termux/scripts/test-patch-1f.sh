#!/usr/bin/env bash
# Test Patch 1f regex against the real fff.bun.ts
set -euo pipefail

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

cp /home/z/my-project/opencode-bionic/packages/core/src/filesystem/fff.bun.ts "$TMP_DIR/fff.bun.ts"
FFF_FILE="$TMP_DIR/fff.bun.ts"
MARKER="opencode-bionic-patched"

python3 <<PYEOF
import re, sys

with open("$FFF_FILE", "r", encoding="utf-8") as f:
    content = f.read()

marker = "$MARKER"
patched = 0

# Step 1: Replace the static value import
old_import = r'''import \{
  FileFinder,
  type DirItem,
  type DirSearchResult,
  type FileItem,
  type GrepCursor,
  type GrepMatch,
  type GrepResult,
  type InitOptions,
  type MixedItem,
  type MixedSearchResult,
  type SearchResult,
\} from "@ff-labs/fff-bun"'''

new_import = '''import type {
  DirItem,
  DirSearchResult,
  FileItem,
  GrepCursor,
  GrepMatch,
  GrepResult,
  InitOptions,
  MixedItem,
  MixedSearchResult,
  SearchResult,
} from "@ff-labs/fff-bun"

// ''' + marker + ''' [Patch 1f]: Lazy-load @ff-labs/fff-bun runtime value.
type FileFinderType = typeof import("@ff-labs/fff-bun")["FileFinder"]
let FileFinder: FileFinderType | null
try {
  FileFinder = require("@ff-labs/fff-bun").FileFinder
} catch {
  FileFinder = null
}'''

new_content, n = re.subn(old_import, new_import, content, count=1)
if n == 1:
    content = new_content
    patched += 1
    print("    [1f-a] OK: replaced static import with lazy require()")
else:
    print("    [FAIL] could not find the static import block", file=sys.stderr)
    sys.exit(1)

# Step 2: Patch available()
old_available = r'''export function available\(\) \{
  return FileFinder\.isAvailable\(\)
\}'''

new_available = '''export function available() {
  // ''' + marker + ''' [Patch 1f]: null guard
  if (!FileFinder) return false
  return FileFinder.isAvailable()
}'''

new_content, n = re.subn(old_available, new_available, content, count=1)
if n == 1:
    content = new_content
    patched += 1
    print("    [1f-b] OK: patched available()")
else:
    print("    [FAIL] could not find available()", file=sys.stderr)
    sys.exit(1)

# Step 3: Patch create()
old_create = r'''export function create\(opts: Init\): Result<Picker> \{
  const made = FileFinder\.create\(opts\)'''

new_create = '''export function create(opts: Init): Result<Picker> {
  // ''' + marker + ''' [Patch 1f]: null guard
  if (!FileFinder) return { ok: false, error: "fff-bun not installed" }
  const made = FileFinder.create(opts)'''

new_content, n = re.subn(old_create, new_create, content, count=1)
if n == 1:
    content = new_content
    patched += 1
    print("    [1f-c] OK: patched create()")
else:
    print("    [FAIL] could not find create()", file=sys.stderr)
    sys.exit(1)

with open("$FFF_FILE", "w", encoding="utf-8") as f:
    f.write(content)

print(f"\n    Total: {patched}/3 sub-patches applied")
PYEOF

echo ""
echo "=== Verification ==="
if grep -q "$MARKER" "$FFF_FILE" 2>/dev/null; then
  echo "[OK] Marker found in patched file"
else
  echo "[FAIL] Marker not found"
  exit 1
fi

# Show the patched sections
echo ""
echo "=== Patched import section (first 30 lines) ==="
head -30 "$FFF_FILE"

echo ""
echo "=== Patched available() + create() ==="
grep -A 4 "export function available" "$FFF_FILE"
echo "---"
grep -A 4 "export function create" "$FFF_FILE"

echo ""
echo "[ALL OK] Patch 1f works against real fff.bun.ts"
