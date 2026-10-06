#!/bin/bash
# GTK 3 and GTK 4 at a fractional display scale on X11 (Stained Glass OS):
# Debian's gtk+3.0 and gtk4, rebuilt with gtk-scale/gtk3-fractional-scale.patch
# or gtk4-fractional-scale.patch as their last patch. See
# docs/gtk-fractional-scale.md for why, and for what the patches do.
#
#   gtk-scale/build-debs.sh gtk3|gtk4 CACHE_DIR OUT_DIR
#
# The source is Debian's current one (apt-get source: the build host needs
# trixie's and trixie-security's deb-src, and the package's build
# dependencies, apt-get build-dep), so a Debian update (a security fix) is
# taken by the next release: its version is newer, and so is ours. Our
# version is Debian's with "+sg<date of Debian's changelog entry>.<REV>":
# 3.24.49-3 becomes 3.24.49-3+sg20250510.1 -- above Debian's (s sorts after
# d: also above 3.24.49-3+deb13u1), and a later Debian update gives a later
# date, above our earlier build. Raise REV when the patch or this script
# changes what is built.
#
# Built once per (Debian version, patch, script): the debs are kept in
# CACHE_DIR under that key and copied to OUT_DIR again by later releases.
# Every binary package of the source is shipped (but the udeb and the
# documentation): they depend on each other at the exact version, and an
# installed libgtk-3-dev or gir1.2-gtk-3.0 would otherwise hold the update
# back.
#
# SPDX-License-Identifier: AGPL-3.0-or-later  (this script; GTK: LGPL-2.1+)
set -euo pipefail
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WHICH=${1:?usage: build-debs.sh gtk3|gtk4 CACHE_DIR OUT_DIR}
CACHE=${2:?usage}
OUT=${3:?usage}
REV=1
case "$WHICH" in
    gtk3) SRC=gtk+3.0 PATCH="$HERE/gtk3-fractional-scale.patch" ;;
    gtk4) SRC=gtk4 PATCH="$HERE/gtk4-fractional-scale.patch" ;;
    *) echo "build-debs: gtk3 or gtk4" >&2; exit 2 ;;
esac

# Debian's newest source version (trixie and trixie-security, whichever is newer)
DEBVER=$(apt-cache showsrc "$SRC" 2>/dev/null | awk '/^Version:/ {print $2}' | sort -V | tail -1)
[[ -n "$DEBVER" ]] || { echo "build-debs: no deb-src for $SRC (add trixie's deb-src)" >&2; exit 1; }
KEY=$( { echo "$DEBVER"; cat "$PATCH" "$0"; } | sha256sum | cut -c1-16)
DIR="$CACHE/$SRC-$KEY"
mkdir -p "$OUT"
if compgen -G "$DIR/*.deb" >/dev/null; then
    cp "$DIR"/*.deb "$OUT"/
    echo "build-debs: $SRC $DEBVER, patched, from the cache ($DIR)"
    exit 0
fi

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-$WHICH.XXXXXX")
trap 'rm -rf "$W"' EXIT
( cd "$W" && apt-get source -q "$SRC=$DEBVER" >/dev/null )
S=$(find "$W" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -d "$S/debian" ]] || { echo "build-debs: $SRC $DEBVER did not unpack" >&2; exit 1; }
patch -d "$S" -p1 -s --dry-run < "$PATCH" >/dev/null || { echo "build-debs: $(basename "$PATCH") does not apply to $SRC $DEBVER: rebase it" >&2; exit 1; }
cp "$PATCH" "$S/debian/patches/sg-fractional-scale.patch"
echo sg-fractional-scale.patch >> "$S/debian/patches/series"   # dpkg-buildpackage applies it (3.0 quilt)

DATE=$(cd "$S" && date -u -d "$(dpkg-parsechangelog -S Date)" +%Y%m%d)
UP=${DEBVER%-*}
DREV=${DEBVER##*-}
VERSION="$UP-${DREV%%+*}+sg$DATE.$REV"
( cd "$S" && DEBFULLNAME="Stained Glass OS" DEBEMAIL="ke7oxh@gmail.com" \
    dch -v "$VERSION" -D trixie --force-distribution \
    "X11: fractional window scale from the XSETTINGS manager's Gdk/SgFractionalScale (Stained Glass OS; on $DEBVER)" )

( cd "$S" && DEB_BUILD_OPTIONS="nocheck nodoc parallel=${SG_JOBS:-4}" DEB_BUILD_PROFILES="noudeb nocheck nodoc" \
    nice dpkg-buildpackage -b -uc -us -j"${SG_JOBS:-4}" > "$W/build.log" 2>&1 ) || {
    tail -40 "$W/build.log" >&2; echo "build-debs: $SRC did not build" >&2; exit 1; }

mkdir -p "$DIR.part"
for d in "$W"/*.deb; do
    case "$(basename "$d")" in *-doc_*|*-udeb_*|*dbgsym*) continue ;; esac
    cp "$d" "$DIR.part"/
done
rm -rf "$DIR"; mv "$DIR.part" "$DIR"
cp "$DIR"/*.deb "$OUT"/
echo "build-debs: $SRC $VERSION built ($(ls "$DIR" | wc -l) packages)"
