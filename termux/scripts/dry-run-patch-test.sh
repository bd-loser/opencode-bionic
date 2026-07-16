#!/usr/bin/env bash
# Dry-run test for the patch logic.
# Copies the real opencode package.json + bunfig.toml to a temp location,
# applies the patches, and verifies the result.

set -euo pipefail

TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Copy the real files
cp /home/z/my-project/opencode-bionic/package.json "$TMP_DIR/package.json"
cp /home/z/my-project/opencode-bionic/bunfig.toml "$TMP_DIR/bunfig.toml"

cd "$TMP_DIR"

XINCLI_CORE_VERSION="0.4.8"
XINCLI_ANDROID_VERSION="0.4.8"
PATCH_MARKER="opencode-bionic-patched"
ROOT_PKG_JSON="$TMP_DIR/package.json"
BUNFIG_FILE="$TMP_DIR/bunfig.toml"

echo "=== Patch 1: package.json — npm alias override ==="
python3 <<PYEOF
import json, sys

with open("$ROOT_PKG_JSON", "r", encoding="utf-8") as f:
    pkg = json.load(f)

overrides = pkg.setdefault("overrides", {})
overrides["@opentui/core"] = "npm:@xincli/opentui-core@$XINCLI_CORE_VERSION"

catalog = pkg.get("workspaces", {}).get("catalog", {})
if "@opentui/core" in catalog:
    old_ver = catalog["@opentui/core"]
    catalog["@opentui/core"] = "$XINCLI_CORE_VERSION"
    print(f"    [1a] catalog['@opentui/core']: {old_ver} -> $XINCLI_CORE_VERSION")

opts = pkg.setdefault("optionalDependencies", {})
opts["@xincli/opentui-core-android-arm64"] = "$XINCLI_ANDROID_VERSION"
print(f"    [1b] optionalDependencies['@xincli/opentui-core-android-arm64'] = $XINCLI_ANDROID_VERSION")

pkg["_opencodeBionic"] = {
    "patched": True,
    "version": "$XINCLI_CORE_VERSION",
    "marker": "$PATCH_MARKER",
}

with open("$ROOT_PKG_JSON", "w", encoding="utf-8") as f:
    json.dump(pkg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"    [1c] overrides['@opentui/core'] = npm:@xincli/opentui-core@$XINCLI_CORE_VERSION")
PYEOF

echo ""
echo "=== Patch 1b: bunfig.toml — add @xincli/* to minimumReleaseAgeExcludes ==="
python3 <<PYEOF
import re, sys

with open("$BUNFIG_FILE", "r", encoding="utf-8") as f:
    content = f.read()

pattern = r'(minimumReleaseAgeExcludes\s*=\s*\[)([^\]]*)(\])'
m = re.search(pattern, content)
if not m:
    print("    [FAIL] could not find minimumReleaseAgeExcludes array", file=sys.stderr)
    sys.exit(1)

array_content = m.group(2)
if "@xincli/opentui-core-android-arm64" in array_content:
    print("    [SKIP] @xincli already in excludes")
    sys.exit(0)

stripped = array_content.rstrip()
if stripped and not stripped.endswith(","):
    stripped += ","
if stripped and not stripped.endswith(" "):
    stripped += " "

new_entries = '"@xincli/opentui-core", "@xincli/opentui-core-android-arm64"'
new_array_content = stripped + new_entries

new_content = content[:m.start(2)] + new_array_content + content[m.end(2):]

with open("$BUNFIG_FILE", "w", encoding="utf-8") as f:
    f.write(new_content)

print("    [1b] Added @xincli packages to minimumReleaseAgeExcludes")
PYEOF

echo ""
echo "=== Patch 1c: package.json — remove ALL entries from trustedDependencies ==="
python3 <<PYEOF
import json, sys

with open("$ROOT_PKG_JSON", "r", encoding="utf-8") as f:
    pkg = json.load(f)

td = pkg.get("trustedDependencies", [])
before = len(td)
pkg["trustedDependencies"] = []

with open("$ROOT_PKG_JSON", "w", encoding="utf-8") as f:
    json.dump(pkg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"    [1c] Removed all {before} entries from trustedDependencies")
print(f"    (was: {td})")
PYEOF

echo ""
echo "=== Patch 1d: package.json — remove root postinstall + prepare scripts ==="
python3 <<PYEOF
import json, sys

with open("$ROOT_PKG_JSON", "r", encoding="utf-8") as f:
    pkg = json.load(f)

scripts = pkg.get("scripts", {})
remove_set = {"postinstall", "prepare"}
removed = []
for s in remove_set:
    if s in scripts:
        old_val = scripts.pop(s)
        removed.append(f"{s}={old_val!r}")

with open("$ROOT_PKG_JSON", "w", encoding="utf-8") as f:
    json.dump(pkg, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"    [1d] Removed {len(removed)} root scripts: {removed}")
PYEOF

echo ""
echo "=== Patch 1e: package.json — remove stale @ff-labs/fff-bun patchedDependency ==="
python3 <<PYEOF
import json, sys

with open("$ROOT_PKG_JSON", "r", encoding="utf-8") as f:
    pkg = json.load(f)

patched = pkg.get("patchedDependencies", {})
key = "@ff-labs/fff-bun@0.9.3"
if key in patched:
    patch_file = patched.pop(key)
    print(f"    [1e] Removed {key!r} -> {patch_file!r}")
else:
    print(f"    [1e] {key!r} not found (already removed)")

with open("$ROOT_PKG_JSON", "w", encoding="utf-8") as f:
    json.dump(pkg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF

echo ""
echo "=== Verification ==="

python3 - "$TMP_DIR/package.json" "$TMP_DIR/bunfig.toml" <<'PYEOF'
import json, sys, re

pkg_json, bunfig = sys.argv[1], sys.argv[2]

with open(pkg_json) as f: pkg = json.load(f)
with open(bunfig) as f: bunfig_content = f.read()

checks = []

# Patch 1 checks
checks.append(("overrides['@opentui/core']",
               pkg.get("overrides",{}).get("@opentui/core"),
               "npm:@xincli/opentui-core@0.4.8"))
checks.append(("catalog['@opentui/core']",
               pkg.get("workspaces",{}).get("catalog",{}).get("@opentui/core"),
               "0.4.8"))
checks.append(("optionalDeps['@xincli/opentui-core-android-arm64']",
               pkg.get("optionalDependencies",{}).get("@xincli/opentui-core-android-arm64"),
               "0.4.8"))
checks.append(("marker _opencodeBionic",
               pkg.get("_opencodeBionic",{}).get("marker"),
               "opencode-bionic-patched"))

# Patch 1b checks — bunfig.toml
m = re.search(r'minimumReleaseAgeExcludes\s*=\s*\[([^\]]*)\]', bunfig_content)
if m:
    excludes = m.group(1)
    checks.append(("bunfig has @xincli/opentui-core in excludes",
                   "@xincli/opentui-core" in excludes, True))
    checks.append(("bunfig has @xincli/opentui-core-android-arm64 in excludes",
                   "@xincli/opentui-core-android-arm64" in excludes, True))
else:
    checks.append(("bunfig minimumReleaseAgeExcludes found", False, True))

# Patch 1c checks — trustedDependencies should be EMPTY
td = pkg.get("trustedDependencies", [])
checks.append(("trustedDependencies is empty (all install scripts skipped)",
               td, []))

# Patch 1d checks — postinstall + prepare removed from scripts
scripts = pkg.get("scripts", {})
checks.append(("postinstall removed from scripts",
               "postinstall" not in scripts, True))
checks.append(("prepare removed from scripts",
               "prepare" not in scripts, True))
# Other scripts should still be there
checks.append(("dev script preserved",
               "dev" in scripts, True))
checks.append(("typecheck script preserved",
               "typecheck" in scripts, True))

# Patch 1e checks — @ff-labs/fff-bun removed from patchedDependencies
patched = pkg.get("patchedDependencies", {})
checks.append(("@ff-labs/fff-bun@0.9.3 removed from patchedDependencies",
               "@ff-labs/fff-bun@0.9.3" not in patched, True))
# Other patchedDependencies should still be there
checks.append(("solid-js patch preserved",
               "solid-js@1.9.10" in patched, True))
checks.append(("effect patch preserved",
               "effect@4.0.0-beta.83" in patched, True))
checks.append(("photon-node patch preserved",
               "@silvia-odwyer/photon-node@0.3.4" in patched, True))

# Existing fields intact
checks.append(("name", pkg.get("name"), "opencode"))
checks.append(("packageManager", pkg.get("packageManager"), "bun@1.3.14"))
checks.append(("catalog @opentui/solid unchanged",
               pkg.get("workspaces",{}).get("catalog",{}).get("@opentui/solid"), "0.4.3"))

all_ok = True
for label, actual, expected in checks:
    if actual == expected:
        print(f"  [OK]   {label}")
    else:
        print(f"  [FAIL] {label}")
        print(f"         expected: {expected!r}")
        print(f"         actual:   {actual!r}")
        all_ok = False

sys.exit(0 if all_ok else 1)
PYEOF

if [ $? -eq 0 ]; then
  echo ""
  echo "[ALL OK] All patches work correctly."
  echo ""
  echo "=== Patched bunfig.toml (minimumReleaseAgeExcludes line) ==="
  grep "minimumReleaseAgeExcludes" "$TMP_DIR/bunfig.toml" | head -c 200
  echo "..."
else
  echo ""
  echo "[FAIL] Some patches have issues."
  exit 1
fi
