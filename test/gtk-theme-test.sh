#!/bin/sh
# sg-gtk-theme (gtk-theme/build-deb.sh): Linux programs' GTK look in Stained
# Glass purple, light and dark (David 2026-10-01: GTK looked "quite a bit less
# pretty" than the Windows side). Built here from the pinned Orchis; then: no
# Orchis blue left in the CSS or its pictures, our purple there instead, and
# the system's GTK settings and GNOME's accent name it.
#   test/gtk-theme-test.sh [DEB]      (built into a scratch dir when not given)
# Mutation: SG_GTK_NO_RECOLOUR=1 build-deb.sh (Orchis as it is): the colour
# checks fail; SG_GTK_NO_LOOK=1: the Windows-side look's checks fail (below).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
command -v python3 >/dev/null && python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: python3-pil missing"; exit 77; }
T=$(mktemp -d /var/tmp/sg-gtktheme.XXXXXX); trap 'rm -rf "$T"' EXIT
DEB=${1:-}
if [ -z "$DEB" ]; then
    bash "$HERE/gtk-theme/build-deb.sh" "$HERE/build/gtk-theme-cache" "$T/out" >/dev/null || { fail "the package does not build"; exit 1; }
    DEB=$(ls "$T"/out/sg-gtk-theme_*_all.deb)
fi
dpkg-deb -x "$DEB" "$T/r"
TH="$T/r/usr/share/themes"
for v in StainedGlass StainedGlass-Dark; do
    [ -f "$TH/$v/gtk-3.0/gtk.css" ] && [ -f "$TH/$v/gtk-4.0/gtk.css" ] && [ -f "$TH/$v/index.theme" ] \
        && pass "$v: GTK 3 and 4" || fail "$v incomplete"
done
blue=$(grep -rhoi '#1A73E8\|#3281EA\|rgba\?(26, 115, 232\|rgba\?(50, 129, 234' "$TH" | wc -l)
[ "$blue" = 0 ] && pass "no Orchis blue left in the CSS" || fail "$blue Orchis blue colours left"
# (in Orchis's own part of the stylesheet: the look appended below names the purple too)
orchis() { awk '/sg-sentinel/ { exit } { print }' "$1"; }
orchis "$TH/StainedGlass/gtk-3.0/gtk.css" | grep -qi '#7030C0' && orchis "$TH/StainedGlass-Dark/gtk-3.0/gtk.css" | grep -qi '#9A66E8' \
    && pass "our purple instead (light #7030C0, dark #9A66E8)" || fail "our purple is not there"
python3 - "$TH" <<'PY' && pass "and in its pictures (the checked check box)" || fail "the pictures are still blue"
import sys, glob, colorsys
from PIL import Image
root = sys.argv[1]
blue = purple = 0
for p in glob.glob(root + "/StainedGlass/gtk-3.0/assets/*.png"):
    for r, g, b, a in Image.open(p).convert("RGBA").getdata():
        if a < 128: continue
        h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
        if s > 0.4 and 205 <= h * 360 <= 225: blue += 1
        if s > 0.4 and 255 <= h * 360 <= 275: purple += 1
sys.exit(0 if purple > 100 and blue < purple / 20 else 1)
PY
grep -qx 'gtk-theme-name=StainedGlass' "$T/r/etc/xdg/gtk-3.0/settings.ini" && grep -qx 'gtk-theme-name=StainedGlass' "$T/r/etc/xdg/gtk-4.0/settings.ini" \
    && pass "the system's GTK 3 and 4 settings name it" || fail "settings.ini"
O="$T/r/usr/share/glib-2.0/schemas/90_sg-gtk-theme.gschema.override"
grep -qx "accent-color='purple'" "$O" && grep -qx "gtk-theme='StainedGlass'" "$O" && pass "GNOME's settings: the theme and the purple accent" || fail "gschema override"
[ -f "$T/r/usr/share/doc/sg-gtk-theme/copyright.orchis" ] && pass "Orchis's copyright with it" || fail "no Orchis copyright"

# --- the Windows side's look on top (sg-gtk3.css / sg-gtk4.css) ---
# Mutation: SG_GTK_NO_LOOK=1 build-deb.sh: everything below about the look
# fails; removing a settings line, the fontconfig file, the icon theme or the
# Firefox prefs fails its own check.
look=0
for v in StainedGlass StainedGlass-Dark; do for g in 3 4; do for f in gtk.css gtk-dark.css; do
    grep -q "sg-sentinel: sg-gtk$g-overrides" "$TH/$v/gtk-$g.0/$f" || look=1
done; done; done
[ "$look" = 0 ] && pass "the Windows-side overrides in every GTK 3 and 4 stylesheet" || fail "overrides missing from some stylesheet"
grep -rqF --include='*.css' '{{' "$TH" && fail "unfilled palette names left" || pass "every palette name filled in"
# light: the Windows side's menu (249 249 249, edge 160) and highlight; dark: its #2B2B2B
L="$TH/StainedGlass/gtk-3.0/gtk.css"; D="$TH/StainedGlass/gtk-3.0/gtk-dark.css"
awk '/sg-sentinel/ { f = 1 } f' "$L" > "$T/l.css"; awk '/sg-sentinel/ { f = 1 } f' "$D" > "$T/d.css"
grep -q 'background-color: #F9F9F9' "$T/l.css" && grep -q '#A0A0A0' "$T/l.css" \
    && grep -q 'background-color: #2B2B2B' "$T/d.css" && ! grep -q '#F9F9F9' "$T/d.css" \
    && pass "light palette in gtk.css, dark in gtk-dark.css (menus #F9F9F9 / #2B2B2B)" || fail "palettes"
big=$(grep -rhoE '(border(-[a-z]+)*-radius|-gtk-outline-radius)\s*:[^;}]*' "$TH" | grep -oE '[0-9.]+px' | tr -d px \
    | awk '$1 > 3 && $1 < 100' | wc -l)
[ "$big" = 0 ] && pass "corner radii at most 3 px (pills and circles kept)" || fail "$big corner radii above 3 px"
if [ -x /usr/bin/python3 ] && /usr/bin/python3 -c 'import gi; gi.require_version("Gtk", "3.0")' 2>/dev/null \
        && /usr/bin/python3 -c 'import gi; gi.require_version("Gtk", "4.0")' 2>/dev/null; then
    perr=0
    for g in 3.0 4.0; do
        out=$(env -u DISPLAY -u WAYLAND_DISPLAY /usr/bin/python3 - "$g" "$TH"/StainedGlass*/gtk-$g/gtk*.css 2>/dev/null <<'PY'
import sys, gi
gi.require_version("Gtk", sys.argv[1])
from gi.repository import Gtk
n = 0
for f in sys.argv[2:]:
    p = Gtk.CssProvider()
    def err(prov, sec, e, f=f):
        global n
        n += 1
        print("  %s: %s" % (f.split("/themes/")[-1], e.message))
    p.connect("parsing-error", err)
    try:
        p.load_from_path(f)
    except Exception as e:
        n += 1
        print("  %s" % e)
print("PARSE-ERRORS %d" % n)
PY
)
        echo "$out" | grep -q '^PARSE-ERRORS 0$' || { perr=1; echo "$out" | head -5; }
    done
    [ "$perr" = 0 ] && pass "GTK 3 and GTK 4 parse every stylesheet without an error" || fail "stylesheet parse errors"
else
    echo "SKIP  GTK's own CSS parser (no python3-gi with GTK 3 and 4)"
fi
python3 - "$TH" <<'PY' && pass "square check boxes, round radio buttons: our pictures" || fail "check box pictures are Orchis's circles"
import os, re, sys
root = sys.argv[1]
for v in ("StainedGlass", "StainedGlass-Dark"):
    for g in ("gtk-3.0", "gtk-4.0"):
        d = os.path.join(root, v, g, "assets", "scalable")
        for pre in ("", "small-"):
            for name in ("unchecked", "checkbox-checked", "mixed"):
                t = open(os.path.join(d, "%s%s-symbolic.svg" % (pre, name))).read()
                # a box: straight edges and corners of 2 px at most -- no curves, no big arcs
                assert not re.search(r"[cCsSqQ]", re.sub(r"<svg[^>]*>|xmlns=\"[^\"]*\"|</svg>|<path|fill-rule=\"evenodd\"|d=", "", t)), (v, g, pre, name)
                assert all(float(r) <= 2 for r in re.findall(r"A([\d.]+)", t)), (v, g, pre, name)
            t = open(os.path.join(d, "%sradio-unchecked-symbolic.svg" % pre)).read()
            assert re.search(r"A[5-9]", t), (v, g, pre, "radio")
        css = open(os.path.join(root, v, g, "gtk.css")).read()
        assert "radio-unchecked-symbolic.svg" in css, (v, g, "radio css")
PY
awk '/sg-sentinel/ { f = 1 } f' "$L" | grep -A4 '^check:checked, check:indeterminate' | grep -q 'color: #7030C0' \
    && pass "checked boxes in our purple (Orchis's are green)" || fail "checked boxes not purple"
S3="$T/r/etc/xdg/gtk-3.0/settings.ini"; S4="$T/r/etc/xdg/gtk-4.0/settings.ini"
ok=1
for k in 'gtk-font-name=Inter 9' 'gtk-xft-rgba=rgb' 'gtk-xft-hintstyle=hintslight' 'gtk-overlay-scrolling=false' \
         'gtk-decoration-layout=icon:minimize,maximize,close' 'gtk-dialogs-use-header=false' 'gtk-icon-theme-name=StainedGlass'; do
    grep -qx "$k" "$S3" && grep -qx "$k" "$S4" || { ok=0; echo "  missing: $k"; }
done
grep -qx 'gtk-font-rendering=manual' "$S4" || { ok=0; echo "  missing: gtk-font-rendering=manual (GTK 4)"; }
[ "$ok" = 1 ] && pass "GTK settings: the Windows side's font (Inter 9), text, scroll bars, window buttons" || fail "GTK settings"
grep -qx "font-name='Inter 9'" "$O" && grep -qx "icon-theme='StainedGlass'" "$O" && grep -qx "button-layout='appmenu:minimize,maximize,close'" "$O" \
    && pass "GNOME's settings: the font, the icon theme, the window buttons" || fail "gschema override: font / icons / buttons"
FC="$T/r/usr/share/fontconfig/conf.avail/56-sg-fonts.conf"
[ "$(readlink "$T/r/etc/fonts/conf.d/56-sg-fonts.conf")" = ../../../usr/share/fontconfig/conf.avail/56-sg-fonts.conf ] \
    && python3 - "$FC" <<'PY' && pass "fontconfig: system-ui is Inter, sans-serif Liberation Sans (enabled)" || fail "fontconfig"
import sys, xml.etree.ElementTree as ET
a = {e.findtext("family"): e.find("prefer").findtext("family") for e in ET.parse(sys.argv[1]).getroot().iter("alias")}
assert a == {"system-ui": "Inter", "sans-serif": "Liberation Sans"}, a
PY
IT="$T/r/usr/share/icons/StainedGlass"
icons=0; for i in close maximize minimize restore; do [ -s "$IT/scalable/ui/window-$i-symbolic.svg" ] && icons=$((icons + 1)); done
grep -qx 'Inherits=Adwaita,hicolor' "$IT/index.theme" && [ "$icons" = 4 ] \
    && grep -qx 'IconTheme=StainedGlass' "$TH/StainedGlass/index.theme" \
    && pass "icon theme StainedGlass: thin window buttons, the rest Adwaita's" || fail "icon theme"
grep -q '"widget.non-native-theme.scrollbar.style", 4' "$T/r/usr/lib/firefox/defaults/pref/sg-gtk-theme.js" \
    && grep -q '"widget.gtk.overlay-scrollbars.enabled", false' "$T/r/usr/lib/firefox/defaults/pref/sg-gtk-theme.js" \
    && pass "Linux Firefox: the Windows side's scroll bars (defaults/pref)" || fail "Firefox prefs"
dep=$(dpkg-deb -f "$DEB" Depends)
for d in librsvg2-common fonts-inter fonts-liberation; do echo "$dep" | grep -qw "$d" || { fail "does not depend on $d"; dep=; }; done
[ -n "$dep" ] && pass "depends on the SVG loader (check boxes are SVG), Inter, Liberation"
[ "$(cd "$T/r" && find etc -type f | sort | tr '\n' ' ')" = "etc/xdg/gtk-3.0/settings.ini etc/xdg/gtk-4.0/settings.ini " ] \
    && dpkg-deb --ctrl-tarfile "$DEB" | tar -xOf - ./conffiles | grep -qx /etc/xdg/gtk-4.0/settings.ini \
    && pass "conffiles: the settings files (the fontconfig link is not one)" || fail "conffiles"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
