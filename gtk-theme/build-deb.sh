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
# On top, the Windows side's look (sg-gtk3.css, sg-gtk4.css; David
# 2026-10-01: make Linux programs fit beside it): Orchis's Compact variant,
# small corners, white controls with thin grey edges, square menus with the
# purple highlight, square check boxes, always-shown scroll bars with arrows,
# flat 46 px window buttons with thin pictures (icon theme StainedGlass,
# Adwaita's otherwise).
#
# The system's GTK settings name it (GTK 3 and 4) with the Windows side's
# interface font, Inter 9 pt, and its text rendering; GNOME's own settings
# (libadwaita apps) get the purple accent and the font; fontconfig's
# system-ui is Inter; Linux Firefox gets the Windows build's scroll bars.
#
# SPDX-License-Identifier: AGPL-3.0-or-later  (this script; the theme: GPL-3.0)
set -euo pipefail
CACHE=${1:?usage: build-deb.sh CACHE_DIR OUT_DIR}
OUT=${2:?usage}
PKG=sg-gtk-theme
ORCHIS_VERSION=2024-11-03+ds-1
ORCHIS_SHA256=ca1f134366cdd14b954e74b2354b864b603300373467e6ded0b037fcb0504a59
VERSION=1.0+orchis20241103-3

mkdir -p "$CACHE" "$OUT"
deb="$CACHE/orchis-gtk-theme_${ORCHIS_VERSION}_all.deb"
# Debian has since dropped orchis-gtk-theme (2026-10): the pinned build is
# kept on the project server beside the Wine Mono tarballs; apt first.
ORCHIS_URL="https://freesoft.page/addons/orchis-gtk-theme_${ORCHIS_VERSION}_all.deb"
if [[ ! -f "$deb" ]]; then
    if ! (cd "$CACHE" && apt-get download "orchis-gtk-theme=$ORCHIS_VERSION" >/dev/null 2>&1); then
        curl -sSL --fail --retry 3 -o "$deb.part" "$ORCHIS_URL"
        mv "$deb.part" "$deb"
    fi
fi
echo "$ORCHIS_SHA256  $deb" | sha256sum -c - >/dev/null || { echo "build-deb: orchis-gtk-theme is not the pinned build" >&2; exit 1; }

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-gtk-theme.XXXXXX")
trap 'rm -rf "$W"' EXIT
dpkg-deb -x "$deb" "$W/orchis"
R="$W/root"
T="$R/usr/share/themes"
mkdir -p "$T" "$R/DEBIAN" "$R/usr/share/doc/$PKG"
# Orchis's Compact variants: closer to the Windows side's density (32 px
# controls, not 36)
for v in Light-Compact:StainedGlass Dark-Compact:StainedGlass-Dark; do
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
# The Windows side's look on top (sg-gtk3.css, sg-gtk4.css, appended to each
# stylesheet with the light or dark palette): Orchis's rounded Material
# controls become the small, square-cornered ones Wine draws next to them;
# its menus, tooltips, scroll bars and window buttons Windows-like; its green
# check boxes purple. Corner radii are clamped to 3 px first (pills and
# circles kept), so the whole stylesheet, not only what the overrides name,
# has the Windows side's small corners.
[ -n "${SG_GTK_NO_LOOK:-}" ] || python3 - "$T" "$(dirname "$0")" <<'PY'
import os, re, sys
root, here = sys.argv[1], sys.argv[2]
# light: sg-shell theme/50-sg-colors.reg (Menu 249, ButtonShadow 160, Hilight
# 112 48 192); dark: the Windows side's dark scheme (#202020, #2B2B2B)
LIGHT = dict(ACCENT="#7030C0", ACCENT_HOVER="#7F45C9", ACCENT_FG="#FFFFFF",
             FG="rgba(0, 0, 0, 0.87)", FG_DIM="rgba(0, 0, 0, 0.55)", FG_DISABLED="rgba(0, 0, 0, 0.38)",
             CAPTION="#FFFFFF", FRAME="rgba(0, 0, 0, 0.30)", SEPARATOR="rgba(0, 0, 0, 0.10)",
             CAPBTN_HOVER="rgba(0, 0, 0, 0.10)", CAPBTN_ACTIVE="rgba(0, 0, 0, 0.20)",
             BUTTON="#FDFDFD", BUTTON_HOVER="#F4EEFB", BUTTON_ACTIVE="#E8DCF6", BUTTON_DISABLED="#F4F4F4",
             BORDER="#ADADAD", BORDER_HOVER="#7A7A7A", BORDER_DISABLED="#D4D4D4",
             FIELD="#FFFFFF", FLAT_HOVER="rgba(112, 48, 192, 0.10)",
             MENU="#F9F9F9", MENU_BORDER="#A0A0A0", MENUBAR="#FFFFFF", MENUBAR_HOVER="#E8DCF6",
             TOOLTIP="#FFFFFF", TOOLTIP_BORDER="#767676",
             TROUGH="#F0F0F0", THUMB="#CDCDCD", THUMB_HOVER="#A6A6A6", THUMB_ACTIVE="#606060", ARROW="#606060")
DARK = dict(ACCENT="#9A66E8", ACCENT_HOVER="#A77AEC", ACCENT_FG="#FFFFFF",
            FG="#FFFFFF", FG_DIM="rgba(255, 255, 255, 0.60)", FG_DISABLED="rgba(255, 255, 255, 0.38)",
            CAPTION="#202020", FRAME="rgba(255, 255, 255, 0.16)", SEPARATOR="rgba(255, 255, 255, 0.10)",
            CAPBTN_HOVER="rgba(255, 255, 255, 0.12)", CAPBTN_ACTIVE="rgba(255, 255, 255, 0.22)",
            BUTTON="#333333", BUTTON_HOVER="#3D3547", BUTTON_ACTIVE="#4A3D5C", BUTTON_DISABLED="#2A2A2A",
            BORDER="#5C5C5C", BORDER_HOVER="#8A8A8A", BORDER_DISABLED="#3C3C3C",
            FIELD="#1C1C1C", FLAT_HOVER="rgba(154, 102, 232, 0.16)",
            MENU="#2B2B2B", MENU_BORDER="#555555", MENUBAR="#202020", MENUBAR_HOVER="#3D3547",
            TOOLTIP="#2B2B2B", TOOLTIP_BORDER="#767676",
            TROUGH="#202020", THUMB="#4D4D4D", THUMB_HOVER="#6E6E6E", THUMB_ACTIVE="#9E9E9E", ARROW="#9E9E9E")

def clamp(m):
    def one(v):
        n = float(v.group(1))
        return v.group(0) if n >= 100 or n <= 3 else "3px"
    return m.group(1) + re.sub(r"([\d.]+)px", one, m.group(2))

def fill(text, pal):
    out = re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: pal[m.group(1)], text)
    assert "{{" not in out
    return out

# check boxes square, as the Windows side's are (Orchis's are circles): our
# own one-colour pictures, GTK colours them (-gtk-recolor); the tick and the
# dash are cut out of the filled box. Radio buttons: a ring, a dot inside.
def box(n, s):           # n: the picture's size, s: the box's
    o = (n - s) / 2
    return o, o + s
def rect(a, b, r):
    return ("M%g %gH%gA%g %g 0 0 1 %g %gV%gA%g %g 0 0 1 %g %gH%gA%g %g 0 0 1 %g %gV%gA%g %g 0 0 1 %g %gZ"
            % (a + r, a, b - r, r, r, b, a + r, b - r, r, r, b - r, b, a + r, r, r, a, b - r, a + r, r, r, a + r, a))
def circle(c, r):
    return "M%g %gA%g %g 0 1 0 %g %gA%g %g 0 1 0 %g %gZ" % (c - r, c, r, r, c + r, c, r, r, c - r, c)
def shapes(n, s):
    a, b = box(n, s)
    k = s / 14.0
    tick = [(a + 2.3 * k, a + 7.0 * k), (a + 3.6 * k, a + 5.7 * k), (a + 5.8 * k, a + 7.9 * k),
            (a + 10.4 * k, a + 3.3 * k), (a + 11.7 * k, a + 4.6 * k), (a + 5.8 * k, a + 10.5 * k)]
    tick = "M" + "L".join("%.2f %.2f" % p for p in tick) + "Z"
    dash = "M%g %gH%gV%gH%gZ" % (a + 3 * k, a + 6 * k, b - 3 * k, a + 8 * k, a + 3 * k)
    c = n / 2
    return {"unchecked": rect(a, b, 2) + rect(a + 1, b - 1, 1),
            "checkbox-checked": rect(a, b, 2) + tick,
            "mixed": rect(a, b, 2) + dash,
            "radio-unchecked": circle(c, s / 2) + circle(c, s / 2 - 1),
            "radio-checked": circle(c, s / 2) + circle(c, s / 2 - 1) + circle(c, s / 2 - 4),
            "radio-mixed": circle(c, s / 2) + dash}
def svg(n, scale, d):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">'
            '<path fill-rule="evenodd" d="%s"/></svg>\n' % (n * scale, n * scale, n, n, d))

for gtk in ("gtk-3.0", "gtk-4.0"):
    for theme in ("StainedGlass", "StainedGlass-Dark"):
        d = os.path.join(root, theme, gtk, "assets", "scalable")
        for prefix, n, s in (("", 24, 14), ("small-", 18, 13)):
            for name, path in shapes(n, s).items():
                for suffix, scale in (("", 1), ("@2", 2)):
                    open(os.path.join(d, "%s%s-symbolic%s.svg" % (prefix, name, suffix)), "w").write(svg(n, scale, path))

for gtk in ("gtk-3.0", "gtk-4.0"):
    extra = open(os.path.join(here, "sg-gtk%s.css" % gtk[4])).read()
    for theme in ("StainedGlass", "StainedGlass-Dark"):
        for name in ("gtk.css", "gtk-dark.css"):
            p = os.path.join(root, theme, gtk, name)
            css = open(p, encoding="utf-8").read()
            css = re.sub(r"((?:border(?:-[a-z]+)*-radius|-gtk-outline-radius)\s*:)([^;}]*)", clamp, css)
            pal = LIGHT if (theme, name) == ("StainedGlass", "gtk.css") else DARK
            open(p, "w", encoding="utf-8").write(css + fill(extra, pal))
PY
# window buttons' pictures: thin lines, as the Windows side's title bars draw
# them (Adwaita's are bold). A small icon theme of our own with only these,
# everything else from Adwaita; GTK colours them (symbolic icons).
I="$R/usr/share/icons/StainedGlass"
mkdir -p "$I/scalable/ui"
cat > "$I/index.theme" <<'EOF'
[Icon Theme]
Name=StainedGlass
Comment=Stained Glass OS: Adwaita, with thin window buttons
Inherits=Adwaita,hicolor
Directories=scalable/ui

[scalable/ui]
Size=16
MinSize=8
MaxSize=512
Type=Scalable
Context=UI
EOF
icon() { printf '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="%s"/></svg>\n' "$2" > "$I/scalable/ui/$1-symbolic.svg"; }
icon window-minimize 'M3 8h10v1H3z'
icon window-maximize 'M3 3h10v10H3zM4 4v8h8V4z'
icon window-restore 'M5 3h8v8h-2v2H3V5h2zM6 4v1h5v5h1V4zM4 6v6h6V6z'
icon window-close 'M3.7 3L8 7.3 12.3 3l.7.7L8.7 8l4.3 4.3-.7.7L8 8.7 3.7 13l-.7-.7L7.3 8 3 3.7z'
for v in StainedGlass StainedGlass-Dark; do
    cat > "$T/$v/index.theme" <<EOF
[Desktop Entry]
Type=X-GNOME-Metatheme
Name=$v
Comment=Stained Glass OS's look for Linux programs (Orchis, in Stained Glass purple)
Encoding=UTF-8

[X-GNOME-Metatheme]
GtkTheme=$v
IconTheme=StainedGlass
EOF
done
# the system's GTK settings: every Linux program's default. Beside the theme,
# what the Windows side does: its interface font (Inter 9 pt, which Segoe UI
# is substituted with: sg-shell theme/52-sg-fonts.reg) with ClearType-like
# text (subpixel RGB, slight hinting); scroll bars always shown; window
# buttons on the right, the program's icon on the left; dialogs' buttons at
# the bottom, not in a header bar; a click in a scroll bar's trough pages.
# (Per-user files, sg-settingsctl's dark mode among them, override these.)
for g in gtk-3.0 gtk-4.0; do
    mkdir -p "$R/etc/xdg/$g"
    {
        echo '[Settings]'
        echo 'gtk-theme-name=StainedGlass'
        echo 'gtk-icon-theme-name=StainedGlass'
        echo 'gtk-font-name=Inter 9'
        echo 'gtk-xft-antialias=1'
        echo 'gtk-xft-hinting=1'
        echo 'gtk-xft-hintstyle=hintslight'
        echo 'gtk-xft-rgba=rgb'
        [ "$g" = gtk-3.0 ] || echo 'gtk-font-rendering=manual'
        echo 'gtk-overlay-scrolling=false'
        echo 'gtk-decoration-layout=icon:minimize,maximize,close'
        echo 'gtk-dialogs-use-header=false'
        echo 'gtk-primary-button-warps-slider=false'
    } > "$R/etc/xdg/$g/settings.ini"
done
# fontconfig: "system-ui" (what web pages and Firefox's own pages ask for the
# system's interface font with) is Inter, as on the Windows side; plain
# "sans-serif" is Liberation Sans -- Arial's metrics, what a Windows browser's
# sans-serif (Arial) comes out as here -- not Nimbus Sans, Helvetica's.
mkdir -p "$R/usr/share/fontconfig/conf.avail" "$R/etc/fonts/conf.d"
cat > "$R/usr/share/fontconfig/conf.avail/56-sg-fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <description>Stained Glass OS: the Windows side's fonts for Linux programs</description>
  <alias binding="same">
    <family>system-ui</family>
    <prefer><family>Inter</family></prefer>
  </alias>
  <alias binding="same">
    <family>sans-serif</family>
    <prefer><family>Liberation Sans</family></prefer>
  </alias>
</fontconfig>
EOF
ln -s ../../../usr/share/fontconfig/conf.avail/56-sg-fonts.conf "$R/etc/fonts/conf.d/56-sg-fonts.conf"
# Linux Firefox (Mozilla's package, /usr/lib/firefox): scroll bars like the
# Windows build's and the Windows side's -- always shown, with arrows --
# not GTK's overlay ones, which it keeps whatever GTK's settings say.
# Defaults only (pref, not lockPref): about:config still changes them.
mkdir -p "$R/usr/lib/firefox/defaults/pref"
cat > "$R/usr/lib/firefox/defaults/pref/sg-gtk-theme.js" <<'EOF'
// Stained Glass OS (sg-gtk-theme): scroll bars as on the Windows side
pref("widget.gtk.overlay-scrollbars.enabled", false);
pref("widget.non-native-theme.scrollbar.style", 4);
// Its window is in a Wine window of its own, title bar and all (wine-sg
// 0762): its own tabs-in-the-title-bar made two title bars (David 2026-10-02)
pref("browser.tabs.inTitlebar", 0);
// sg-firefox.cfg (beside firefox): what it says it runs on
pref("general.config.filename", "sg-firefox.cfg");
pref("general.config.obscure_value", 0);
EOF
# A Windows browser to the sites it visits, as the Windows build would say:
# web apps made for Windows PCs (athenaNet's device manager, downloads that
# offer the .exe) treat Stained Glass as one (David 2026-10-02). Defaults
# only: about:config still changes them. The version is the installed
# Firefox's (extensions.lastAppVersion, set once it has started).
cat > "$R/usr/lib/firefox/sg-firefox.cfg" <<'EOF'
// Stained Glass OS (sg-gtk-theme): Firefox says it runs on Windows
var sgv = "150.0";   // until Firefox has started once
try { var last = getPref("extensions.lastAppVersion"); if (last) sgv = last.split(".")[0] + ".0"; } catch (e) {}
defaultPref("general.useragent.override", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:" + sgv + ") Gecko/20100101 Firefox/" + sgv);
defaultPref("general.platform.override", "Win32");
defaultPref("general.oscpu.override", "Windows NT 10.0; Win64; x64");
defaultPref("general.appversion.override", "5.0 (Windows)");
EOF
# GNOME's settings (libadwaita programs, and what reads GSettings)
mkdir -p "$R/usr/share/glib-2.0/schemas"
cat > "$R/usr/share/glib-2.0/schemas/90_sg-gtk-theme.gschema.override" <<'EOF'
[org.gnome.desktop.interface]
gtk-theme='StainedGlass'
icon-theme='StainedGlass'
accent-color='purple'
font-name='Inter 9'
document-font-name='Inter 10'
monospace-font-name='Cascadia Mono 10'
font-antialiasing='rgba'
font-hinting='slight'
font-rgba-order='rgb'
overlay-scrolling=false

[org.gnome.desktop.wm.preferences]
button-layout='appmenu:minimize,maximize,close'
titlebar-font='Inter 9'
EOF
cp "$W/orchis/usr/share/doc/orchis-gtk-theme/copyright" "$R/usr/share/doc/$PKG/copyright.orchis"
cat > "$R/usr/share/doc/$PKG/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Orchis theme
Source: https://github.com/vinceliuice/Orchis-theme (Debian's orchis-gtk-theme)

Files: usr/share/themes/*
Copyright: Vince Liuice and contributors; recoloured by Stained Glass OS
License: GPL-3.0+
 Orchis's own copyright file is copyright.orchis, beside this one. Its
 colours were changed from its blue to Stained Glass OS's purple, its corner
 radii made small, and a stylesheet of our own appended to each of its own
 (the Windows side's controls, menus, scroll bars, window buttons); the
 check box and radio button pictures are our own.

Files: etc/* usr/share/glib-2.0/* usr/share/fontconfig/* usr/share/icons/*
 usr/lib/firefox/* usr/share/themes/*/gtk-*/assets/scalable/*checked*
 usr/share/themes/*/gtk-*/assets/scalable/*mixed*
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
Depends: gnome-themes-extra, gtk2-engines-murrine, librsvg2-common, fonts-inter, fonts-liberation
Section: x11
Priority: optional
Homepage: https://freesoft.page/
Description: Stained Glass OS's look for Linux programs
 The GTK theme Linux programs use in Stained Glass OS: Orchis, in Stained
 Glass purple, light and dark (StainedGlass, StainedGlass-Dark), made to
 look like the Windows side beside it -- small corners, square menus and
 check boxes, always-shown scroll bars, flat window buttons -- set as the
 system's GTK theme with its font (Inter 9 pt) and text rendering, with
 GNOME's purple accent for libadwaita programs.
EOF
( cd "$R" && find etc -type f | sed 's|^|/|' ) > "$R/DEBIAN/conffiles"
dpkg-deb --root-owner-group -Zxz --build "$R" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "[gtk-theme] $OUT/${PKG}_${VERSION}_all.deb"
