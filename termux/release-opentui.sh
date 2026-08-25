#!/data/data/com.termux/files/usr/bin/bash
# Publish @androidtui packages in dependency order through GitHub Actions.
# Usage: GH_TOKEN=... bash release-opentui.sh <version> [--skip-so]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MUTED='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

ok()    { echo -e "  ${GREEN}[OK]${NC}   $*"; }
fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; exit 1; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
info()  { echo -e "  ${MUTED}       $*${NC}"; }
header(){ echo -e "\n${BOLD}${BLUE}=== $* ===${NC}"; }

VERSION="${1:-}"
SKIP_SO=false
[ "${2:-}" = "--skip-so" ] && SKIP_SO=true

[ -n "$VERSION" ] || fail "Usage: GH_TOKEN=ghp_xxx bash release-opentui.sh <version> [--skip-so]"
[ -n "${GH_TOKEN:-}" ] || fail "GH_TOKEN env var not set"

REPO="bd-loser/opentui"
API="https://api.github.com/repos/${REPO}"

echo "=========================================="
echo "opentui release orchestrator"
echo "=========================================="
echo "  version:  $VERSION"
echo "  repo:     $REPO"
echo "  skip .so: $SKIP_SO"
echo "=========================================="

trigger_workflow() {
  local workflow_file="$1"
  local inputs_json="$2"
  local label="$3"

  header "Trigger: $label"

  local dispatch_resp
  dispatch_resp=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/actions/workflows/${workflow_file}/dispatches" \
    -d "{\"ref\":\"main\",\"inputs\":${inputs_json}}" 2>&1)

  local http_code=$(echo "$dispatch_resp" | tail -1)
  if [ "$http_code" != "204" ]; then
    fail "Workflow dispatch failed (HTTP $http_code): $dispatch_resp"
  fi
  ok "dispatched"

  info "waiting for run to start..."
  local run_id=""
  for i in $(seq 1 12); do
    sleep 5
    run_id=$(curl -s \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API}/actions/runs?per_page=5" 2>&1 | \
      python3 -c "
import json, sys
data = json.load(sys.stdin)
for run in data.get('workflow_runs', []):
    if run['path'] == '.github/workflows/${workflow_file}' and run['status'] in ('in_progress', 'queued'):
        print(run['id'])
        break
" 2>/dev/null)
    [ -n "$run_id" ] && break
  done
  [ -n "$run_id" ] || fail "could not find run for $workflow_file"
  ok "run started: $run_id"
  info "  https://github.com/${REPO}/actions/runs/${run_id}"

  # Poll for completion (cap at 30 min — GH Actions jobs shouldn't take longer;
  # if they do, something is wedged and we'd rather fail loud than hang forever).
  info "waiting for completion (max 30 min)..."
  local status="in_progress"
  local conclusion=""
  local max_iters=120  # 120 * 15s = 30 min
  local iter=0
  while [ "$status" != "completed" ]; do
    if [ "$iter" -ge "$max_iters" ]; then
      echo ""
      fail "$label workflow did not complete within 30 min (run: https://github.com/${REPO}/actions/runs/${run_id})"
    fi
    sleep 15
    iter=$((iter + 1))
    local run_data
    run_data=$(curl -s \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "${API}/actions/runs/${run_id}" 2>&1)
    status=$(echo "$run_data" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unknown")
    conclusion=$(echo "$run_data" | python3 -c "import json,sys; print(json.load(sys.stdin).get('conclusion','') or 'pending')" 2>/dev/null || echo "pending")
    echo -ne "\r  status: ${status}/${conclusion} (${iter}/${max_iters})    "
  done
  echo ""

  if [ "$conclusion" != "success" ]; then
    fail "$label workflow failed (conclusion: $conclusion)"
    info "  https://github.com/${REPO}/actions/runs/${run_id}"
  fi
  ok "$label workflow succeeded"
}

verify_npm() {
  local pkg="$1"
  local ver="$2"
  local label="$3"

  info "verifying ${pkg}@${ver} on npm..."
  local found=""
  for i in $(seq 1 20); do
    found=$(npm view "${pkg}@${ver}" version 2>/dev/null | tail -1)
    if [ "$found" = "$ver" ]; then
      ok "$label: ${pkg}@${ver} on npm ✅"
      return 0
    fi
    sleep 10
    echo -ne "\r  waiting for npm propagation... (${i}s)    "
  done
  echo ""
  fail "$label: ${pkg}@${ver} NOT found on npm after 200s"
}

if $SKIP_SO; then
  header "Step 1: Publish .so (SKIPPED — --skip-so)"
  info "the existing .so will be repackaged at $VERSION by package-prebuilt.yml"
  info "but we're skipping the .so workflow. Only do this if the .so binary"
  info "is unchanged and you only bumped the JS package versions."
else
  trigger_workflow "package-prebuilt.yml" '{}' "Package Prebuilt Native (.so)"
  verify_npm "@androidtui/core-android-arm64" "$VERSION" "Step 1"
fi

trigger_workflow "publish-js-library.yml" "{\"version\":\"${VERSION}\",\"publish\":\"true\"}" "Publish JS Library (core + react)"
verify_npm "@androidtui/core" "$VERSION" "Step 2a"
verify_npm "@androidtui/react" "$VERSION" "Step 2b"

trigger_workflow "publish-solid.yml" "{\"version\":\"${VERSION}\",\"publish\":\"true\"}" "Publish opentui-solid"
verify_npm "@androidtui/solid" "$VERSION" "Step 3"

trigger_workflow "publish-keymap.yml" "{\"version\":\"${VERSION}\",\"publish\":\"true\"}" "Publish opentui-keymap"
verify_npm "@androidtui/keymap" "$VERSION" "Step 4"

header "Release ${VERSION} complete!"

echo ""
echo "  All 5 @androidtui packages published:"
echo "    ✅ @androidtui/core@${VERSION}"
echo "    ✅ @androidtui/react@${VERSION}"
echo "    ✅ @androidtui/solid@${VERSION}"
echo "    ✅ @androidtui/keymap@${VERSION}"
echo "    ✅ @androidtui/core-android-arm64@${VERSION}"
echo ""
echo "${BOLD}Next: rebuild opencode to use the new packages${NC}"
echo "  cd ~/opencode-bionic"
echo "  ANDROIDTUI_CORE_VERSION=${VERSION} bash termux/rebuild-opencode.sh"
