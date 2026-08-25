# shellcheck shell=bash
# Load canonical defaults from versions.json without replacing caller overrides.

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
  # Emit KEY=VALUE lines for eval.
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
  : "${ANDROIDTUI_CORE_VERSION:=$__V_CORE}"
  : "${ANDROIDTUI_KEYMAP_VERSION:=$__V_KEYMAP}"
  : "${ANDROIDTUI_SOLID_VERSION:=$__V_SOLID}"
  : "${ANDROIDTUI_REACT_VERSION:=$__V_REACT}"
  : "${ANDROIDTUI_ANDROID_VERSION:=$__V_ANDROID}"
  : "${OPENCODE_VERSION_PIN:=$__V_OPENCODE}"
  export ANDROIDTUI_CORE_VERSION ANDROIDTUI_KEYMAP_VERSION ANDROIDTUI_SOLID_VERSION \
         ANDROIDTUI_REACT_VERSION ANDROIDTUI_ANDROID_VERSION OPENCODE_VERSION_PIN
  unset __V_CORE __V_KEYMAP __V_SOLID __V_REACT __V_ANDROID __V_OPENCODE
fi

unset __versions_json_find __versions_dump_py __versions_json_file
