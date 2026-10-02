#!/bin/sh
# sg-gtk-theme (gtk-theme/build-deb.sh): Linux programs' GTK look in Stained
# Glass purple, light and dark (David 2026-10-01: GTK looked "quite a bit less
# pretty" than the Windows side). Built here from the pinned Orchis; then: no
# Orchis blue left in the CSS or its pictures, our purple there instead, and
# the system's GTK settings and GNOME's accent name it.
#   test/gtk-theme-test.sh [DEB]      (built into a scratch dir when not given)
# Mutation: SG_GTK_NO_RECOLOUR=1 build-deb.sh (Orchis as it is): the colour
# checks fail.
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
grep -qi '#7030C0' "$TH/StainedGlass/gtk-3.0/gtk.css" && grep -qi '#9A66E8' "$TH/StainedGlass-Dark/gtk-3.0/gtk.css" \
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
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
