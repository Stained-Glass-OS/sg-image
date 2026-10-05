#!/bin/bash
# Package Mozilla's official Thunderbird build as a .deb named thunderbird.
#
#   thunderbird/build-deb.sh TARBALL MOZ_VERSION OUT_DIR
#
# TARBALL is Mozilla's own Linux x86_64 release build
# (archive.mozilla.org/pub/thunderbird/releases/<v>/linux-x86_64/en-US/),
# already verified by thunderbird/update.sh against Mozilla's signed
# SHA512SUMS. It is installed UNMODIFIED in /usr/lib/thunderbird -- the same
# directory as Debian's package, so a person's Thunderbird profile (Mozilla
# keys profiles to the install directory) is the one they had. We add only
# what an installation is meant to be given beside the program:
#   distribution/policies.json   enterprise policies: no self-update (apt
#                                updates it), no telemetry (as Debian's);
#   dictionaries -> /usr/share/hunspell  the system's spelling dictionaries
#                                (as Debian's package links them);
# and outside it /usr/bin/thunderbird, a desktop entry and the icons.
#
# Why our own package (David 2026-10-05): SG Mail needs a newer Thunderbird
# than Debian's ESR (Microsoft 365 over Graph is in the Release channel only),
# and a source build (40 GB, hours) is not worth it when Mozilla's trademark
# policy lets anyone pass on its unmodified builds.
#
# The package is `thunderbird` at 1:<Mozilla version>-sg<REV>, above Debian's
# 1:<ESR version>esr-..., so apt (and PackageKit's offline update) upgrades
# Debian's package to ours in place: no removal, no Conflicts. Debian's layout
# had chrome/, defaults/ and isp/ as symlinks into /usr/share/thunderbird;
# ours are directories (dpkg-maintscript-helper symlink_to_dir). Debian's two
# conffiles go (rm_conffile): its pref file, and its AppArmor profile, which
# names /usr/lib/thunderbird/thunderbird and was written for Debian's layout
# (unloaded first, so it does not confine ours until the next boot).
#
# REV is the packaging revision: a change to this script (or policies.json)
# must bump it, or the repository refuses changed contents under an unchanged
# version.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TARBALL=${1:?usage: build-deb.sh TARBALL MOZ_VERSION OUT_DIR}
MOZ_VERSION=${2:?usage}
OUT=${3:?usage}
PKG=thunderbird
REV=$(sed -n 's/^REV=//p' "$HERE/REV")
EPOCH=1
VERSION=$EPOCH:$MOZ_VERSION-sg$REV
# the first version of ours (directories where Debian's had symlinks): any
# version below it is Debian's layout
FIRST=1:157.0.1-sg1~
[[ "$MOZ_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)*(esr)?$ ]] || { echo "build-deb: odd Mozilla version '$MOZ_VERSION'" >&2; exit 1; }
# test hook (test/thunderbird-deb-test.sh's mutants)
[[ "${SG_MUTANT_TB_NO_EPOCH:-0}" == 1 ]] && VERSION=$MOZ_VERSION-sg$REV

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-tb-deb.XXXXXX")
trap 'rm -rf "$W"' EXIT
R="$W/root"
L="$R/usr/lib/thunderbird"
mkdir -p "$R/usr/lib" "$R/DEBIAN" "$R/usr/bin" "$R/usr/share/doc/$PKG" "$R/usr/share/applications" "$OUT"
tar -C "$W" -xJf "$TARBALL"
[[ -x "$W/thunderbird/thunderbird" ]] || { echo "build-deb: no thunderbird/thunderbird in $TARBALL" >&2; exit 1; }
got=$(sed -n 's/^Version=//p' "$W/thunderbird/application.ini" | head -1)
[[ "$got" == "$MOZ_VERSION" || "$got" == "${MOZ_VERSION%esr}" ]] || { echo "build-deb: $TARBALL is Thunderbird $got, not $MOZ_VERSION" >&2; exit 1; }
mv "$W/thunderbird" "$L"

# what we add beside the program
mkdir -p "$L/distribution"
cp "$HERE/policies.json" "$L/distribution/policies.json"
ln -s /usr/share/hunspell "$L/dictionaries"
ln -s ../lib/thunderbird/thunderbird "$R/usr/bin/thunderbird"
cp "$HERE/thunderbird.desktop" "$R/usr/share/applications/thunderbird.desktop"
for s in 16 22 24 32 48 64 128 256; do
    mkdir -p "$R/usr/share/icons/hicolor/${s}x$s/apps"
    cp "$L/chrome/icons/default/default$s.png" "$R/usr/share/icons/hicolor/${s}x$s/apps/thunderbird.png"
done
cat > "$R/usr/share/doc/$PKG/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Mozilla Thunderbird
Source: https://archive.mozilla.org/pub/thunderbird/releases/$MOZ_VERSION/
 Mozilla's official Linux x86_64 build (en-US), unmodified, verified against
 Mozilla's signed SHA512SUMS (release key 14F26682D0916CDD81E37B6D61B7B526D98F0353).
 Source code: https://archive.mozilla.org/pub/thunderbird/releases/$MOZ_VERSION/source/
Comment: Packaged by Stained Glass OS (sg-image thunderbird/). Thunderbird and
 the Thunderbird logos are trademarks of the Mozilla Foundation; this is
 Mozilla's unmodified build. Stained Glass OS is not affiliated with Mozilla.

Files: usr/lib/thunderbird/*
Copyright: Mozilla Foundation and contributors
License: MPL-2.0
 Thunderbird is under the Mozilla Public License 2.0, with some components
 under their own free licenses (see about:license in Thunderbird).
 /usr/share/common-licenses/MPL-2.0

Files: usr/lib/thunderbird/distribution/* usr/share/applications/*
Copyright: Stained Glass OS contributors
License: AGPL-3.0-or-later
EOF

# Maintainer scripts: Debian's layout -> ours, Debian's conffiles gone.
mh() { # the dpkg-maintscript-helper calls, for one script
    [[ "${SG_MUTANT_TB_NO_SYMLINK_TO_DIR:-0}" == 1 ]] || for d in chrome defaults isp; do
        echo "dpkg-maintscript-helper symlink_to_dir /usr/lib/thunderbird/$d ../../share/thunderbird/$d $FIRST $PKG -- \"\$@\""
    done
    [[ "${SG_MUTANT_TB_KEEP_CONFFILES:-0}" == 1 ]] || for c in /etc/thunderbird/pref/thunderbird.js /etc/apparmor.d/usr.bin.thunderbird; do
        echo "dpkg-maintscript-helper rm_conffile $c $FIRST $PKG -- \"\$@\""
    done
}
{
    echo '#!/bin/sh'; echo 'set -e'
    cat <<'EOF'
# Debian's AppArmor profile confines /usr/lib/thunderbird/thunderbird{,-bin}
# for Debian's layout: unload it before it can confine Mozilla's build.
if [ "$1" = upgrade ] || [ "$1" = install ]; then
    if [ -f /etc/apparmor.d/usr.bin.thunderbird ] && command -v apparmor_parser >/dev/null 2>&1 \
       && [ -d /sys/kernel/security/apparmor ]; then
        apparmor_parser -R /etc/apparmor.d/usr.bin.thunderbird >/dev/null 2>&1 || true
    fi
fi
EOF
    mh
} > "$R/DEBIAN/preinst"
{ echo '#!/bin/sh'; echo 'set -e'; mh; } > "$R/DEBIAN/postinst"
{ echo '#!/bin/sh'; echo 'set -e'; mh; } > "$R/DEBIAN/postrm"
chmod 0755 "$R/DEBIAN/preinst" "$R/DEBIAN/postinst" "$R/DEBIAN/postrm"

chmod 0755 "$R"
chmod -R u+rwX,go+rX,go-w "$R/usr"
size=$(du -sk "$R/usr" | cut -f1)
cat > "$R/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: amd64
Maintainer: Stained Glass OS <ke7oxh@gmail.com>
Installed-Size: $size
Section: mail
Priority: optional
Homepage: https://www.thunderbird.net/
Depends: libc6, libgcc-s1, libstdc++6, libasound2t64, libatk1.0-0t64, libcairo-gobject2, libcairo2, libdbus-1-3, libfontconfig1, fontconfig, libfreetype6, libgdk-pixbuf-2.0-0, libglib2.0-0t64, libgtk-3-0t64, libpango-1.0-0, libpangocairo-1.0-0, libx11-6, libx11-xcb1, libxcb-shm0, libxcb1, libxcomposite1, libxcursor1, libxdamage1, libxext6, libxfixes3, libxi6, libxrandr2, libxrender1
Recommends: libgl1, libegl1, libpci3, hunspell-en-us | hunspell-dictionary
Provides: mail-reader
Description: Mozilla Thunderbird: mail, calendar and news (Mozilla's build)
 Thunderbird is Mozilla's mail, calendar, address book and news program.
 This is Mozilla's official, unmodified Linux build of Thunderbird
 $MOZ_VERSION, packaged for Stained Glass OS so that apt keeps it up to date
 (Thunderbird's own updater is turned off by policy). It replaces Debian's
 thunderbird package in place; profiles are kept. SG Mail runs on it.
EOF
dpkg-deb --root-owner-group -Zxz -z6 --build "$R" "$OUT/${PKG}_${VERSION#*:}_amd64.deb" >/dev/null
echo "[thunderbird-deb] $OUT/${PKG}_${VERSION#*:}_amd64.deb"
