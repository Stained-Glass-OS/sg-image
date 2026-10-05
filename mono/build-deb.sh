#!/bin/bash
# Package our Wine Mono as a .deb: sg-wine-mono.
#
#   mono/build-deb.sh TARBALL OUT_DIR
#
# TARBALL is the pinned build (the Makefile's MONO_URL/MONO_SHA256, made by
# mono/build-wine-mono.sh); mono/mono-fixes.sh is applied to it. Installed as
# /usr/share/wine/mono/wine-mono-<version>, where Wine looks for a shared Mono
# and runs it in place: every prefix uses it, so an upgraded package reaches
# prefixes made before it (only the support MSI's registry rows are per
# prefix; sg-shell's defaults carry those that matter).
#
# The version is Wine Mono's + our build + packaging revision; a different
# tarball or fixes script must come with a new version (the repository
# refuses changed contents under an unchanged version).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TARBALL=${1:?usage: build-deb.sh TARBALL OUT_DIR}
OUT=${2:?usage}
PKG=sg-wine-mono
MONO_VERSION=9.4.0
VERSION=$MONO_VERSION+sg8-1

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-mono-deb.XXXXXX")
trap 'rm -rf "$W"' EXIT
R="$W/root"
mkdir -p "$R/usr/share/wine/mono" "$R/DEBIAN" "$R/usr/share/doc/$PKG" "$OUT"
tar -C "$R/usr/share/wine/mono" -xJf "$TARBALL"
[[ -d "$R/usr/share/wine/mono/wine-mono-$MONO_VERSION" ]] || { echo "build-deb: no wine-mono-$MONO_VERSION in $TARBALL" >&2; exit 1; }
sh "$HERE/mono-fixes.sh" "$R/usr/share/wine/mono/wine-mono-$MONO_VERSION"
cp "$HERE/patches/README" "$R/usr/share/doc/$PKG/README.patches"
cat > "$R/usr/share/doc/$PKG/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Wine Mono
Source: https://gitlab.winehq.org/mono/wine-mono (tag wine-mono-9.4.0),
 with Stained Glass OS's patches (sg-image mono/patches)

Files: *
Copyright: The Mono project, the Wine project, Microsoft Corporation (the
 open-source reference source and runtime libraries Mono includes), and
 others; Stained Glass OS contributors (the patches)
License: MIT
 Wine Mono's components are under the MIT license or their own free
 licenses, as listed in its COPYING and the upstream repositories. The
 patches are MIT, as Mono's class libraries are.
EOF
chmod -R u=rwX,go=rX "$R/usr"
size=$(du -sk "$R/usr" | cut -f1)
cat > "$R/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: Stained Glass OS <ke7oxh@gmail.com>
Installed-Size: $size
Section: otherosfs
Priority: optional
Homepage: https://freesoft.page/
Description: Wine Mono for Stained Glass OS (.NET Framework programs)
 Wine Mono $MONO_VERSION, the .NET Framework implementation Wine runs .NET
 programs with, built with Stained Glass OS's fixes: event log reader types,
 writes to the certificate store, services that are not interactive, a
 .config's repeated <startup>, NDP v4 InstallPath -- what the athenaNet
 Device Manager and SQL Server Compact's installer need. Shared by every
 Wine prefix on the machine.
EOF
dpkg-deb --root-owner-group -Zxz --build "$R" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "[mono-deb] $OUT/${PKG}_${VERSION}_all.deb"
