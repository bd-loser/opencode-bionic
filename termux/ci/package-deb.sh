#!/usr/bin/env bash
# Package a built opencode binary as a Termux .deb.
#
# Layout follows Termux conventions:
#   Architecture: aarch64
#   Install path: data/data/com.termux/files/usr/bin/opencode
#   No Depends: the binary is a bun-compile output, statically self-contained
#               except for the Bionic dynamic linker (present on every Termux
#               device by definition).
#
# Usage:
#   package-deb.sh <binary> <version> <outdir>
#     <binary>   path to the built opencode binary
#     <version>  e.g. "1.18.2"
#     <outdir>   dir to write opencode_${version}_aarch64.deb into
#
# Requires: dpkg-deb on PATH (already present on ubuntu-24.04-arm runners).

set -euo pipefail

usage() {
  echo "usage: $0 <binary> <version> <outdir>" >&2
  exit 2
}

BIN="${1:-}"
VERSION="${2:-}"
OUTDIR="${3:-}"
[ -z "$BIN" ] || [ -z "$VERSION" ] || [ -z "$OUTDIR" ] && usage
[ -f "$BIN" ] || { echo "error: $BIN not found" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb not on PATH" >&2; exit 1; }

ARCH="aarch64"
PKG="opencode"
# Force a sane umask — some runners (and Termux locally) default to 077,
# which makes dpkg-deb reject DEBIAN/ for being mode 0700.
umask 0022
STAGE="$(mktemp -d)"
chmod 0755 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

# Termux install prefix, relative to the deb root.
INSTALL_PREFIX="data/data/com.termux/files/usr"
mkdir -p "$STAGE/$INSTALL_PREFIX/bin"
cp "$BIN" "$STAGE/$INSTALL_PREFIX/bin/opencode"
chmod 0755 "$STAGE/$INSTALL_PREFIX/bin/opencode"

# Installed-Size is in KiB, rounded up. dpkg uses this only for UX; be
# approximate but not wildly wrong.
SIZE_KB=$(( ( $(stat -c%s "$BIN") + 1023 ) / 1024 ))

mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: $ARCH
Maintainer: opencode-bionic <noreply@github.com>
Installed-Size: $SIZE_KB
Section: devel
Priority: optional
Homepage: https://github.com/bd-loser/opencode-bionic
Description: AI-powered development tool, Termux/Bionic native build
 opencode compiled with a bun-termux runtime so it runs natively on
 Android/Termux (aarch64) without a glibc shim.
EOF

mkdir -p "$OUTDIR"
DEB="$OUTDIR/${PKG}_${VERSION}_${ARCH}.deb"
# Pin the compressor to xz. Never rely on the builder's default: Ubuntu patches
# dpkg to default to zstd (Debian upstream still defaults to xz), so building on
# an ubuntu-* runner silently emits control.tar.zst + data.tar.zst. dpkg only
# handles zstd internally if it was built against libzstd, and otherwise shells
# out to a `zstd` binary that no Termux bootstrap ships — so on a device with an
# older dpkg the install dies with:
#   unable to execute decompressing archive ... member "control.tar" (zstd):
#   No such file or directory
# xz is the widest intersection: Termux's own repository shipped xz debs for
# years, so any dpkg old enough to be a problem still decompresses it, and
# every Termux dpkg links liblzma. Level is left at dpkg's default on purpose —
# -z9/-Sextreme would shrink the deb but inflate the decompression dictionary,
# which is a bad trade on a low-RAM phone.
dpkg-deb -Zxz --build --root-owner-group "$STAGE" "$DEB" >/dev/null
echo "$DEB"
