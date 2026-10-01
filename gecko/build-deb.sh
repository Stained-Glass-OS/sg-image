#!/bin/bash
# Package Wine Gecko as a .deb: sg-wine-gecko.
#
#   gecko/build-deb.sh VERSION X86_TARBALL X86_64_TARBALL OUT_DIR
#
# Wine Gecko is the HTML engine behind Wine's mshtml: installers' pages, help,
# sign-in windows, anything that embeds a browser. Upstream's tarballs
# (dl.winehq.org, pinned by the Makefile), unmodified, both architectures
# (32-bit programs use the 32-bit engine), under /usr/share/wine/gecko, where
# Wine finds a shared Gecko and runs it in place -- every prefix uses it, so an
# upgraded package reaches every prefix. Packaged so updates carry it (David
# 2026-10-01: every Stained Glass OS update arrives through apt).
#
# A different upstream version, or a change here, must come with a new
# package version (the repository refuses changed contents under an
# unchanged version).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
GECKO_VERSION=${1:?usage: build-deb.sh VERSION X86_TARBALL X86_64_TARBALL OUT_DIR}
T32=${2:?usage}
T64=${3:?usage}
OUT=${4:?usage}
PKG=sg-wine-gecko
VERSION=$GECKO_VERSION-1

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-gecko-deb.XXXXXX")
trap 'rm -rf "$W"' EXIT
R="$W/root"
G="$R/usr/share/wine/gecko"
mkdir -p "$G" "$R/DEBIAN" "$R/usr/share/doc/$PKG" "$OUT"
tar -C "$G" -xJf "$T32"
tar -C "$G" -xJf "$T64"
for a in x86 x86_64; do
    [[ -d "$G/wine-gecko-$GECKO_VERSION-$a" ]] || { echo "build-deb: no wine-gecko-$GECKO_VERSION-$a" >&2; exit 1; }
done
cat > "$R/usr/share/doc/$PKG/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Wine Gecko
Source: https://dl.winehq.org/wine/wine-gecko/
 (built from https://gitlab.winehq.org/wine/wine-gecko; unmodified here)

Files: *
Copyright: The Mozilla Foundation and contributors; the Wine project
License: MPL-2.0
 This Source Code Form is subject to the terms of the Mozilla Public License,
 v. 2.0. If a copy of the MPL was not distributed with this file, You can
 obtain one at https://mozilla.org/MPL/2.0/. Its source is published by the
 Wine project at the address above.
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
Description: Wine Gecko for Stained Glass OS (HTML in Windows programs)
 Wine Gecko $GECKO_VERSION, the HTML engine Wine's mshtml uses: installers'
 pages, help, sign-in windows and other embedded web views in Windows
 programs. 32- and 64-bit, shared by every Wine prefix on the machine.
EOF
dpkg-deb --root-owner-group -Zxz --build "$R" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "[gecko-deb] $OUT/${PKG}_${VERSION}_all.deb"
