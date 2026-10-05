#!/bin/bash
# Package DYMO's CUPS driver for the LabelWriter 5xx printers as a .deb:
# sg-dymo-lw5xx.
#
#   dymo-deb/build-deb.sh CACHE_DIR OUT_DIR [FILTER-ONLY-DIR]
#
# Debian's printer-driver-dymo stops at the 450 series; the LabelWriter 550,
# 550 Turbo, 5XL (and their Pro/Twin models, and the LabelWriter Wireless)
# need DYMO's newer driver, which DYMO publishes under the GPL-2.0 at
# github.com/dymosoftware/Drivers (LW5xx_Linux). It is built here from that
# source, at a pinned commit whose tarball's hash is checked, with
# dymo-deb/patches applied (see each patch), without its autotools (whose
# shipped Makefile.in names a directory the tree does not have) and without
# boost (no longer used after patch 0002):
#   /usr/lib/cups/filter/raster2dymolw_v2   the filter the PPDs name
#   /usr/share/ppd/dymo-lw5xx/*.ppd         the LabelWriter 5xx PPDs, as DYMO's
# CUPS names the queue's make and model after the PPD ("DYMO LabelWriter
# 550"), which is what wine-sg names the printer's Windows driver (0871) and
# what DYMO Connect looks for. sg-session's sg-dymo-queue makes the queue when
# such a printer is plugged in.
#
# With a third argument, only the filter is built there (for the gate).
#
# SPDX-License-Identifier: AGPL-3.0-or-later  (this script; the driver: GPL-2.0)
set -euo pipefail
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CACHE=${1:?usage: build-deb.sh CACHE_DIR OUT_DIR [FILTER-ONLY-DIR]}
OUT=${2:?usage}
ONLY=${3:-}
PKG=sg-dymo-lw5xx
COMMIT=9f2f15b3f1c2dddf4dcdfb64f380748120d249ba
SHA256=d078100c36c57b34e64eb4d9545d0f08423f15f42026ce33c9abe06e082519d9
URL="https://codeload.github.com/dymosoftware/Drivers/tar.gz/$COMMIT"
# upstream's own version (configure.ac), the commit, and our revision: raise
# REV when the patches or this script change what is built
REV=1
VERSION="2.0.0.0+git20250918.${COMMIT:0:7}-$REV"
PPDS="lw550 lw550t lw550p lw550tp lw5xl lw5xlp lww"

mkdir -p "$CACHE"
tgz="$CACHE/dymo-drivers-$COMMIT.tar.gz"
if [[ ! -f "$tgz" ]]; then
    curl -sSL --fail --retry 3 -o "$tgz.part" "$URL"
    mv "$tgz.part" "$tgz"
fi
echo "$SHA256  $tgz" | sha256sum -c - >/dev/null || { echo "build-deb: the DYMO driver source is not the pinned one" >&2; exit 1; }

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-dymo-lw5xx.XXXXXX")
trap 'rm -rf "$W"' EXIT
tar -xzf "$tgz" -C "$W" --exclude='*/src/boost/*' "Drivers-$COMMIT/LW5xx_Linux"
S="$W/Drivers-$COMMIT/LW5xx_Linux"
for p in "$HERE"/patches/*.patch; do
    patch -d "$S" -p1 -s --no-backup-if-mismatch < "$p" || { echo "build-deb: $(basename "$p") does not apply" >&2; exit 1; }
done

bin="$W/raster2dymolw_v2"
( cd "$S/src" && ${CXX:-g++} -std=c++14 -O2 -g -w -Icommon \
    ${CPPFLAGS:-} ${CXXFLAGS:-} -D_FORTIFY_SOURCE=2 -fstack-protector-strong \
    lw/raster2dymolw.cpp lw/LabelWriterDriverV2.cpp lw/LabelWriterDriverInitializer.cpp \
    lw/LabelWriterLanguageMonitorV2.cpp common/CupsPrintEnvironment.cpp common/CupsUtils.cpp \
    common/NonLinearLaplacianHalftoning.cpp \
    -o "$bin" -Wl,-z,relro,-z,now ${LDFLAGS:-} -lcups )
strip --strip-unneeded "$bin"

if [[ -n "$ONLY" ]]; then
    mkdir -p "$ONLY"
    install -m 755 "$bin" "$ONLY/raster2dymolw_v2"
    for p in $PPDS; do install -m 644 "$S/ppd/$p.ppd" "$ONLY/$p.ppd"; done
    exit 0
fi

R="$W/root"
mkdir -p "$R/DEBIAN" "$R/usr/lib/cups/filter" "$R/usr/share/ppd/dymo-lw5xx" "$R/usr/share/doc/$PKG"
install -m 755 "$bin" "$R/usr/lib/cups/filter/raster2dymolw_v2"
for p in $PPDS; do install -m 644 "$S/ppd/$p.ppd" "$R/usr/share/ppd/dymo-lw5xx/$p.ppd"; done
cat > "$R/usr/share/doc/$PKG/copyright" <<COPY
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: DYMO LabelWriter 5xx CUPS drivers (dymo-cups-drivers)
Source: https://github.com/dymosoftware/Drivers/tree/$COMMIT/LW5xx_Linux

Files: *
Copyright: 2008-2025 Sanford L.P. (DYMO)
License: GPL-2.0-or-later
 Built by Stained Glass OS from the source above with sg-image dymo-deb/patches:
$(for p in "$HERE"/patches/*.patch; do printf ' %s\n' "$(basename "$p")"; done)
 .
 On Debian systems the GNU General Public License version 2 is in
 /usr/share/common-licenses/GPL-2.
COPY
cp "$HERE"/patches/*.patch "$R/usr/share/doc/$PKG/"
gzip -9n "$R"/usr/share/doc/$PKG/*.patch

size=$(du -sk "$R/usr" | cut -f1)
cat > "$R/DEBIAN/control" <<CTRL
Package: $PKG
Version: $VERSION
Architecture: amd64
Maintainer: Stained Glass OS <ke7oxh@gmail.com>
Installed-Size: $size
Depends: libc6, libstdc++6, libgcc-s1, libcups2t64 | libcups2, cups, cups-filters
Section: misc
Priority: optional
Homepage: https://github.com/dymosoftware/Drivers
Description: CUPS driver for DYMO LabelWriter 550, 550 Turbo, 5XL printers
 DYMO's own Linux driver for the LabelWriter 5xx series (550, 550 Turbo,
 550 Pro, 550 Twin Turbo Pro, 5XL, 5XL Pro) and the LabelWriter Wireless:
 the raster2dymolw_v2 CUPS filter and the printers' PPDs, built from DYMO's
 GPL source with Stained Glass OS's fixes. Debian's printer-driver-dymo
 covers the older LabelWriters only.
CTRL

mkdir -p "$OUT"
dpkg-deb --root-owner-group -Zxz -b "$R" "$OUT/${PKG}_${VERSION}_amd64.deb" >/dev/null
echo "[sg-dymo-lw5xx] built ${PKG}_${VERSION}_amd64.deb"
