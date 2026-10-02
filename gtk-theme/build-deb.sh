#!/bin/bash
# Package the Linux apps' look as a .deb: sg-gtk-theme.
#
#   gtk-theme/build-deb.sh CACHE_DIR OUT_DIR
#
# Linux programs (GTK: Firefox's Linux build, GIMP, Linux apps from SG Store)
# came up in GTK's plain default next to our Windows side (David 2026-10-01:
# "quite a bit less pretty"). This is Orchis (vinceliuice, GPL-3.0, Debian's
# orchis-gtk-theme at a pinned version, unmodified otherwise) recoloured from
# its blue to Stained Glass OS's purple (the Windows side's selection colour,
# 112 48 192), light and dark: StainedGlass and StainedGlass-Dark. The colour
# moves by hue, so Orchis's shades of its accent keep their relations; its
# other colours (warnings, errors, the Material palette) stay.
#
# The system's GTK settings name it (GTK 3 and 4), and GNOME's own settings
# (libadwaita apps) get the purple accent.
#
# SPDX-License-Identifier: AGPL-3.0-or-later  (this script; the theme: GPL-3.0)
set -euo pipefail
CACHE=${1:?usage: build-deb.sh CACHE_DIR OUT_DIR}
OUT=${2:?usage}
PKG=sg-gtk-theme
ORCHIS_VERSION=2024-11-03+ds-1
ORCHIS_SHA256=ca1f134366cdd14b954e74b2354b864b603300373467e6ded0b037fcb0504a59
VERSION=1.0+orchis20241103-1

mkdir -p "$CACHE" "$OUT"
deb="$CACHE/orchis-gtk-theme_${ORCHIS_VERSION}_all.deb"
if [[ ! -f "$deb" ]]; then
    (cd "$CACHE" && apt-get download "orchis-gtk-theme=$ORCHIS_VERSION" >/dev/null)
fi
echo "$ORCHIS_SHA256  $deb" | sha256sum -c - >/dev/null || { echo "build-deb: orchis-gtk-theme is not the pinned build" >&2; exit 1; }

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-gtk-theme.XXXXXX")
trap 'rm -rf "$W"' EXIT
dpkg-deb -x "$deb" "$W/orchis"
R="$W/root"
T="$R/usr/share/themes"
mkdir -p "$T" "$R/DEBIAN" "$R/usr/share/doc/$PKG"
for v in Light:StainedGlass Dark:StainedGlass-Dark; do
    src="$W/orchis/usr/share/themes/Orchis-${v%%:*}"
    dst="$T/${v#*:}"
    mkdir -p "$dst"
    cp -a "$src/gtk-2.0" "$src/gtk-3.0" "$src/gtk-4.0" "$dst/"
done
[ -n "${SG_GTK_NO_RECOLOUR:-}" ] || python3 - "$T" <<'PY'
import colorsys, os, re, sys
from PIL import Image

root = sys.argv[1]
# the accent of each variant, and ours for it: the Windows side's selection
# purple (112 48 192), and a lighter one on dark surfaces
ACCENT = {"StainedGlass": ((0x1A, 0x73, 0xE8), (112, 48, 192)),
          "StainedGlass-Dark": ((0x32, 0x81, 0xEA), (154, 102, 232))}

def hsv(rgb):
    return colorsys.rgb_to_hsv(*[c / 255 for c in rgb])

def mapper(src, dst):
    (h0, s0, v0), (h1, s1, v1) = hsv(src), hsv(dst)
    def move(rgb):
        h, s, v = hsv(rgb)
        if s < 0.25 or abs(h - h0) * 360 > 9:
            return None   # not the accent's family: left alone
        s = min(1, s * s1 / s0)
        v = min(1, v * v1 / v0)
        return tuple(round(c * 255) for c in colorsys.hsv_to_rgb(h1, s, v))
    return move

def css(path, move):
    text = open(path, encoding="utf-8").read()
    def hex_sub(m):
        rgb = tuple(int(m.group(1)[i:i + 2], 16) for i in (0, 2, 4))
        new = move(rgb)
        return m.group(0) if new is None else "#%02X%02X%02X" % new
    def rgb_sub(m):
        rgb = tuple(int(m.group(i)) for i in (2, 3, 4))
        new = move(rgb)
        return m.group(0) if new is None else "%s(%d, %d, %d" % ((m.group(1),) + new)
    text = re.sub(r"#([0-9a-fA-F]{6})\b", hex_sub, text)
    text = re.sub(r"(rgba?)\(\s*(\d+),\s*(\d+),\s*(\d+)", rgb_sub, text)
    open(path, "w", encoding="utf-8").write(text)

def png(path, move):
    im = Image.open(path).convert("RGBA")
    px = im.load()
    changed = False
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if not a:
                continue
            new = move((r, g, b))
            if new:
                px[x, y] = new + (a,)
                changed = True
    if changed:
        im.save(path)

for theme, (src, dst) in ACCENT.items():
    move = mapper(src, dst)
    for base, _, files in os.walk(os.path.join(root, theme)):
        for f in files:
            p = os.path.join(base, f)
            if f.endswith((".css", "gtkrc", ".svg")):
                css(p, move)
            elif f.endswith(".png"):
                png(p, move)
PY
for v in StainedGlass StainedGlass-Dark; do
    cat > "$T/$v/index.theme" <<EOF
[Desktop Entry]
Type=X-GNOME-Metatheme
Name=$v
Comment=Stained Glass OS's look for Linux programs (Orchis, in Stained Glass purple)
Encoding=UTF-8

[X-GNOME-Metatheme]
GtkTheme=$v
IconTheme=Adwaita
EOF
done
# the system's GTK settings: every Linux program's default
for g in gtk-3.0 gtk-4.0; do
    mkdir -p "$R/etc/xdg/$g"
    printf '[Settings]\ngtk-theme-name=StainedGlass\n' > "$R/etc/xdg/$g/settings.ini"
done
# GNOME's settings (libadwaita programs, and what reads GSettings)
mkdir -p "$R/usr/share/glib-2.0/schemas"
cat > "$R/usr/share/glib-2.0/schemas/90_sg-gtk-theme.gschema.override" <<'EOF'
[org.gnome.desktop.interface]
gtk-theme='StainedGlass'
accent-color='purple'
EOF
cp "$W/orchis/usr/share/doc/orchis-gtk-theme/copyright" "$R/usr/share/doc/$PKG/copyright.orchis"
cat > "$R/usr/share/doc/$PKG/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Orchis theme
Source: https://github.com/vinceliuice/Orchis-theme (Debian's orchis-gtk-theme)

Files: usr/share/themes/*
Copyright: Vince Liuice and contributors; recoloured by Stained Glass OS
License: GPL-3.0+
 Orchis's own copyright file is copyright.orchis, beside this one. The
 colours were changed from its blue to Stained Glass OS's purple; nothing
 else.

Files: etc/* usr/share/glib-2.0/*
Copyright: Stained Glass OS contributors
License: GPL-3.0+
EOF
chmod -R u=rwX,go=rX "$R/usr" "$R/etc"
size=$(du -sk "$R" | cut -f1)
cat > "$R/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: Stained Glass OS <ke7oxh@gmail.com>
Installed-Size: $size
Depends: gnome-themes-extra, gtk2-engines-murrine
Section: x11
Priority: optional
Homepage: https://freesoft.page/
Description: Stained Glass OS's look for Linux programs
 The GTK theme Linux programs use in Stained Glass OS: Orchis, in Stained
 Glass purple, light and dark (StainedGlass, StainedGlass-Dark), set as the
 system's GTK theme, with GNOME's purple accent for libadwaita programs.
EOF
( cd "$R" && find etc -type f | sed 's|^|/|' ) > "$R/DEBIAN/conffiles"
dpkg-deb --root-owner-group -Zxz --build "$R" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "[gtk-theme] $OUT/${PKG}_${VERSION}_all.deb"
