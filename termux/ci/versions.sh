# shellcheck shell=bash
# Source this file to load the canonical version pins from versions.json into
# your shell script. Sets XINCLI_*_VERSION variables that termux/*.sh scripts
# already expect.
#
# Usage:
#   # near the top of your script, after `set -euo pipefail`:
#   . "$(dirname "$0")/ci/versions.sh"      # from termux/foo.sh
#   . "$(dirname "$0")/../ci/versions.sh"   # from termux/ci/foo.sh
#
# Behavior:
#   - If versions.json exists, its values become the defaults.
#   - Environment vars set BEFORE sourcing this file win — so ad-hoc overrides
#     (e.g. `XINCLI_CORE_VERSION=0.4.11 bash termux/rebuild-opencode.sh`) still
#     work, and CI still gets its pinned values.
#   - If versions.json is missing (e.g. running outside the repo), the file is
#     a no-op and callers use their own hardcoded fallbacks.
#
# Deps: jq (already required by other scripts).

__opencode_bionic_versions_sh_loaded=1

__versions_json_find() {
  # Walk up from $PWD looking for versions.json. Safer than assuming a fixed
  # relative path since setup.sh cd's around during install.
  local d="$PWD"
  while [ "$d" != "/" ]; do
    if [ -f "$d/versions.json" ]; then
      printf '%s\n' "$d/versions.json"
      return 0
    fi
    d="$(dirname "$d")"
  done
  # Fall back to the location relative to this file.
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  if [ -f "$self_dir/versions.json" ]; then
    printf '%s\n' "$self_dir/versions.json"
    return 0
  fi
  return 1
}

__versions_json_file="$(__versions_json_find || true)"

__versions_dump_py() {
  # $1 = path to versions.json
  # Emits KEY=VALUE lines that `eval` can consume. python3 is already
  # required by setup.sh's Termux prereqs, so no new dependency.
  python3 - "$1" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
o = v["opentui"]
print(f"__V_CORE={o['core']}")
print(f"__V_KEYMAP={o['keymap']}")
print(f"__V_SOLID={o['solid']}")
print(f"__V_REACT={o['react']}")
print(f"__V_ANDROID={o['androidArm64Native']}")
print(f"__V_OPENCODE={v['opencode']}")
PY
}

if [ -n "$__versions_json_file" ] && command -v python3 >/dev/null 2>&1; then
  eval "$(__versions_dump_py "$__versions_json_file")"
  # Only set each variable if the caller has not already set it, so:
  #   XINCLI_CORE_VERSION=0.4.11 bash rebuild-opencode.sh
  # still wins for local experiments.
  : "${XINCLI_CORE_VERSION:=$__V_CORE}"
  : "${XINCLI_KEYMAP_VERSION:=$__V_KEYMAP}"
  : "${XINCLI_SOLID_VERSION:=$__V_SOLID}"
  : "${XINCLI_REACT_VERSION:=$__V_REACT}"
  : "${XINCLI_ANDROID_VERSION:=$__V_ANDROID}"
  : "${OPENCODE_VERSION_PIN:=$__V_OPENCODE}"
  export XINCLI_CORE_VERSION XINCLI_KEYMAP_VERSION XINCLI_SOLID_VERSION \
         XINCLI_REACT_VERSION XINCLI_ANDROID_VERSION OPENCODE_VERSION_PIN
  unset __V_CORE __V_KEYMAP __V_SOLID __V_REACT __V_ANDROID __V_OPENCODE
fi

unset __versions_json_find __versions_dump_py __versions_json_file
