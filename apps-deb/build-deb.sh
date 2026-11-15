#!/bin/bash
# Package the bundled Windows applications as a .deb: sg-apps.
#
#   apps-deb/build-deb.sh PAYLOAD_DIR OUT_DIR
#
# PAYLOAD_DIR is what `make apps` stages: PowerShell 7 and CPython, upstream's
# own Windows builds (pinned versions and SHA-256s in the Makefile), and a
# VERSION line. Packaged under /opt/sg-apps, where sg-session's sg-install-apps
# copies them into the machine's Program Files, puts them on the machine PATH
# and in the Start menu (at the next boot when the version changed). A
# package, so machines get new versions with their updates and a Debian
# machine turned into a Stained Glass one gets them at all (everything is a
# package; they were a loose folder only images had).
#
# The version is the two upstream versions; a change here comes with a new
# package revision (the repository refuses changed contents under an
# unchanged version).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
PAYLOAD=${1:?usage: build-deb.sh PAYLOAD_DIR OUT_DIR}
OUT=${2:?usage}
PKG=sg-apps
REV=1
[[ -f "$PAYLOAD/VERSION" ]] || { echo "build-deb: no $PAYLOAD/VERSION (make apps)" >&2; exit 1; }
# "powershell 7.6.6, python 3.14.7" -> 7.6.6+python3.14.7-1
read -r _ pwsh _ py < <(tr -d ',' < "$PAYLOAD/VERSION")
VERSION="${pwsh}+python${py}-$REV"

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-apps-deb.XXXXXX")
trap 'rm -rf "$W"' EXIT
R="$W/root"
mkdir -p "$R/opt/sg-apps" "$R/DEBIAN" "$R/usr/share/doc/$PKG"
chmod 755 "$R"
cp -a "$PAYLOAD/." "$R/opt/sg-apps/"
chmod -R u=rwX,go=rX "$R/opt" "$R/usr"

cat > "$R/usr/share/doc/$PKG/copyright" <<'COPY'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: PowerShell; CPython
Source: https://github.com/PowerShell/PowerShell/releases
 https://www.nuget.org/packages/python (python.org's NuGet package)

Files: opt/sg-apps/powershell/*
Copyright: Microsoft Corporation and PowerShell contributors
License: MIT (see /opt/sg-apps/powershell/LICENSE.txt and ThirdPartyNotices.txt)

Files: opt/sg-apps/python/*
Copyright: Python Software Foundation
License: PSF-2.0 (see /opt/sg-apps/python/LICENSE.txt)
COPY

cat > "$R/DEBIAN/control" <<CTRL
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: Stained Glass OS <ke7oxh@gmail.com>
Installed-Size: $(du -sk "$R/opt" | cut -f1)
Section: misc
Priority: optional
Description: PowerShell 7 and Python for Stained Glass OS's Windows side
 Upstream's Windows builds of PowerShell $pwsh and CPython $py, which
 sg-session installs into the machine's Program Files, on the machine PATH
 and in the Start menu, as Windows programs.
CTRL
mkdir -p "$OUT"
dpkg-deb --root-owner-group -Zxz -b "$R" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "[$PKG] built ${PKG}_${VERSION}_all.deb"
