#!/usr/bin/env bash
# Runs on the GitHub Actions runner (ubuntu-24.04-arm). Sets up a
# world-writable /out dir on the host, then runs termux-docker with the
# repo mounted at /workspace and the out dir mounted at /out. The
# container script (termux/ci/build-in-container.sh) does the actual work.
#
# Env inputs:
#   GITHUB_WORKSPACE   set by Actions; the checked-out repo
#   OPENCODE_VERSION   optional; forwarded to the container script
#   OPENCODE_CHANNEL   optional; forwarded to the container script
#
# Output:
#   $OUT_HOST/opencode         the built binary
#   $OUT_HOST/opencode.sha256  sha256 of the binary
#
# OUT_HOST is echoed to stdout so callers (release.yml) can capture it.

set -euo pipefail

: "${GITHUB_WORKSPACE:?GITHUB_WORKSPACE must be set}"

# /workspace is READ-ONLY for the container's `system` user (termux-docker
# drops privs regardless of --user), so we mount a SECOND directory that
# the runner pre-creates with world-writable perms.
mkdir -p "$GITHUB_WORKSPACE/../out"
OUT_HOST="$(cd "$GITHUB_WORKSPACE/../out" && pwd)"
chmod 0777 "$OUT_HOST"
echo "OUT_HOST=$OUT_HOST" >&2

# Forward version/channel through docker env; empty values are fine, the
# container script has defaults.
docker run --rm \
  -e "OPENCODE_VERSION=${OPENCODE_VERSION:-}" \
  -e "OPENCODE_CHANNEL=${OPENCODE_CHANNEL:-}" \
  -v "$GITHUB_WORKSPACE:/workspace" \
  -v "$OUT_HOST:/out" \
  -w /workspace \
  termux/termux-docker:aarch64 \
  bash /workspace/termux/ci/build-in-container.sh

# Print the path last so callers can grab it with `tail -n1`.
echo "$OUT_HOST"
