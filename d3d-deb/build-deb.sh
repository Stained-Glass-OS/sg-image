#!/bin/bash
# Package the Direct3D translation layers as a .deb: sg-d3d.
#
#   d3d-deb/build-deb.sh PAYLOAD_DIR OUT_DIR
#
# PAYLOAD_DIR is what `make d3d` stages: DXVK (the pinned release, with our
# dxgi.dll -- dxvk/patches) and VKD3D-Proton, as PE DLLs, and a VERSION line.
# Packaged under /opt/sg-d3d, where sg-session's sg-install-d3d copies them
# into the machine's Wine prefix (at the next boot when the version changed).
# A package, so installed machines get a fixed DXVK with their updates, not
# only machines installed from a new image.
#
# The version carries the patches' hash: changed contents come with a new
# version (the repository refuses changed contents under an unchanged one).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
PAYLOAD=${1:?usage: build-deb.sh PAYLOAD_DIR OUT_DIR}
OUT=${2:?usage}
PKG=sg-d3d
[[ -f "$PAYLOAD/VERSION" ]] || { echo "build-deb: no $PAYLOAD/VERSION (make d3d)" >&2; exit 1; }
# "vkd3d-proton 3.0.1, dxvk 3.1.1+sg1234abcd" -> 3.1.1+sg1234abcd+vkd3d3.0.1-1
read -r _ vkd3d _ dxvk < <(tr -d ',' < "$PAYLOAD/VERSION")
VERSION="${dxvk}+vkd3d${vkd3d}-1"

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-d3d-deb.XXXXXX")
trap 'rm -rf "$W"' EXIT
R="$W/root"
mkdir -p "$R/opt/sg-d3d" "$R/DEBIAN" "$R/usr/share/doc/$PKG"
chmod 755 "$R"
cp -a "$PAYLOAD/." "$R/opt/sg-d3d/"
chmod -R u=rwX,go=rX "$R/opt" "$R/usr"

cat > "$R/usr/share/doc/$PKG/copyright" <<'COPY'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: DXVK; VKD3D-Proton
Source: https://github.com/doitsujin/dxvk
 https://github.com/HansKristian-Work/vkd3d-proton
Comment: DXVK's dxgi.dll is rebuilt with Stained Glass OS's patches, shipped
 beside it in /opt/sg-d3d/dxvk/patches.

Files: opt/sg-d3d/dxvk/*
Copyright: Philip Rebohle and DXVK contributors
License: Zlib (see /opt/sg-d3d/dxvk/LICENSE)

Files: opt/sg-d3d/vkd3d-proton/*
Copyright: Hans-Kristian Arntzen, Philip Rebohle, Joshua Ashton, and contributors
License: LGPL-2.1+ (see /opt/sg-d3d/vkd3d-proton/LICENSE)
COPY

size=$(du -sk "$R/opt" | cut -f1)
cat > "$R/DEBIAN/control" <<CTRL
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: Stained Glass OS <ke7oxh@gmail.com>
Installed-Size: $size
Section: misc
Priority: optional
Description: Direct3D for Stained Glass OS's Windows side (DXVK, VKD3D-Proton)
 DXVK (Direct3D 8-11) and VKD3D-Proton (Direct3D 12) as Windows DLLs, which
 sg-session installs into the machine's Wine prefix. DXVK's dxgi.dll is built
 with Stained Glass OS's patches (swap chains for composition).
CTRL

mkdir -p "$OUT"
dpkg-deb --root-owner-group -Zxz -b "$R" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "[sg-d3d] built ${PKG}_${VERSION}_all.deb"
