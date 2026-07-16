#!/usr/bin/env bash
# Dry-run test for the new Approach B (npm alias override) patch.
# Copies the real opencode package.json to a temp location, applies the
# patch, and verifies the result.

set -euo pipefail

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Copy the real opencode package.json
cp /home/z/my-project/opencode-termux/opencode/package.json "$TMP_DIR/package.json"

cd "$TMP_DIR"

# Run the JSON patch logic (extracted from apply-termux-patches.sh Patch 1)
XINCLI_CORE_VERSION="0.4.8"
XINCLI_ANDROID_VERSION="0.4.8"
PATCH_MARKER="opencode-bionic-patched"
ROOT_PKG_JSON="$TMP_DIR/package.json"

python3 <<PYEOF
import json, sys

with open("$ROOT_PKG_JSON", "r", encoding="utf-8") as f:
    pkg = json.load(f)

# Add the npm alias override
overrides = pkg.setdefault("overrides", {})
overrides["@opentui/core"] = "npm:@xincli/opentui-core@$XINCLI_CORE_VERSION"

# Update the catalog entry
catalog = pkg.get("workspaces", {}).get("catalog", {})
if "@opentui/core" in catalog:
    old_ver = catalog["@opentui/core"]
    catalog["@opentui/core"] = "$XINCLI_CORE_VERSION"
    print(f"    [1a] catalog['@opentui/core']: {old_ver} -> $XINCLI_CORE_VERSION")

# Add @xincli/opentui-core-android-arm64 as optionalDependency
opts = pkg.setdefault("optionalDependencies", {})
old = opts.get("@xincli/opentui-core-android-arm64", "<none>")
opts["@xincli/opentui-core-android-arm64"] = "$XINCLI_ANDROID_VERSION"
print(f"    [1b] optionalDependencies['@xincli/opentui-core-android-arm64']: {old} -> $XINCLI_ANDROID_VERSION")

# Marker
pkg["_opencodeBionic"] = {
    "patched": True,
    "version": "$XINCLI_CORE_VERSION",
    "marker": "$PATCH_MARKER",
    "note": "Patched by apply-termux-patches.sh for Termux/Android."
}

with open("$ROOT_PKG_JSON", "w", encoding="utf-8") as f:
    json.dump(pkg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"    [1c] overrides['@opentui/core'] = npm:@xincli/opentui-core@$XINCLI_CORE_VERSION")
print(f"    [1d] marker _opencodeBionic added")
PYEOF

echo ""
echo "=== Verification ==="

python3 - "$TMP_DIR/package.json" <<'PYEOF'
import json, sys
fname = sys.argv[1]
with open(fname) as f:
    pkg = json.load(f)

checks = [
    ("overrides['@opentui/core']", pkg.get("overrides",{}).get("@opentui/core"), "npm:@xincli/opentui-core@0.4.8"),
    ("catalog['@opentui/core']", pkg.get("workspaces",{}).get("catalog",{}).get("@opentui/core"), "0.4.8"),
    ("optionalDeps['@xincli/...-android-arm64']", pkg.get("optionalDependencies",{}).get("@xincli/opentui-core-android-arm64"), "0.4.8"),
    ("marker _opencodeBionic", pkg.get("_opencodeBionic",{}).get("marker"), "opencode-bionic-patched"),
]

all_ok = True
for label, actual, expected in checks:
    if actual == expected:
        print(f"  [OK]   {label} = {actual}")
    else:
        print(f"  [FAIL] {label} = {actual!r} (expected {expected!r})")
        all_ok = False

# Also verify existing fields are intact
existing_checks = [
    ("name", pkg.get("name"), "opencode"),
    ("packageManager", pkg.get("packageManager"), "bun@1.3.14"),
    ("catalog @opentui/solid unchanged", pkg.get("workspaces",{}).get("catalog",{}).get("@opentui/solid"), "0.4.3"),
    ("catalog @opentui/keymap unchanged", pkg.get("workspaces",{}).get("catalog",{}).get("@opentui/keymap"), "0.4.3"),
    ("existing patchedDependencies preserved", len(pkg.get("patchedDependencies",{})) >= 11, True),
]
print()
for label, actual, expected in existing_checks:
    if str(actual) == str(expected):
        print(f"  [OK]   {label} = {actual}")
    else:
        print(f"  [FAIL] {label} = {actual!r} (expected {expected!r})")
        all_ok = False

sys.exit(0 if all_ok else 1)
PYEOF

if [ $? -eq 0 ]; then
  echo ""
  echo "[ALL OK] Approach B patch works correctly."
  echo ""
  echo "Patched package.json (relevant sections):"
  python3 -c "
import json
with open('$TMP_DIR/package.json') as f: pkg = json.load(f)
print('  overrides[\"@opentui/core\"]:', pkg['overrides']['@opentui/core'])
print('  catalog[\"@opentui/core\"]:', pkg['workspaces']['catalog']['@opentui/core'])
print('  optionalDependencies[\"@xincli/opentui-core-android-arm64\"]:', pkg['optionalDependencies']['@xincli/opentui-core-android-arm64'])
print('  _opencodeBionic.marker:', pkg['_opencodeBionic']['marker'])
"
else
  echo ""
  echo "[FAIL] Approach B patch has issues."
  exit 1
fi
