#!/bin/sh
# Our GTK 3 and GTK 4 (gtk-scale/build-debs.sh: Debian's, with the
# fractional-scale patch) at a fractional display scale, live, under Xvfb
# with an XSETTINGS manager as the session runs one (sg-session 0.1.0-126,
# xsettingsd), a 400x300 window of each (python3-gi):
#   1. at 100% (no Gdk/SgFractionalScale): 400x300, scale 1, 96 DPI -- as
#      Debian's GTK
#   2. the scale set to 175% while it runs (Xft/DPI 168,
#      Gdk/WindowScalingFactor 2, Gdk/SgFractionalScale 1792): its X window
#      700x525 -- 1.75 times, not 2 -- the text's DPI 96 (168 over 1.75)
#   3. 125% (1280): 500x375
#   4. a program that scales itself (named firefox): scale 1, the whole DPI
#      (168), its window its own size
#   5. Debian's GTK under the same settings: 800x600 at 175% (the check
#      tells the two apart)
#
#   sh test/gtk-scale-test.sh DIR-of-debs
# Needs Xvfb, xsettingsd, xwininfo, python3-gi with GTK 3 and GTK 4.
set -u
DEBS=${1:-build/gtk-scale-out}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
for t in Xvfb xsettingsd xwininfo dpkg-deb /usr/bin/python3; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
ls "$DEBS"/libgtk-3-0t64_*.deb "$DEBS"/libgtk-4-1_*.deb >/dev/null 2>&1 || { echo "SKIP: no built GTK in $DEBS (make gtk-scale-debs)"; exit 77; }
{ /usr/bin/python3 -c 'import gi; gi.require_version("Gtk", "3.0")' && /usr/bin/python3 -c 'import gi; gi.require_version("Gtk", "4.0")'; } 2>/dev/null || { echo "SKIP: python3-gi with GTK 3 and 4 missing"; exit 77; }
T=$(mktemp -d /var/tmp/sg-gtk-scale.XXXXXX); XP=; XS=
trap '[ -n "$XS" ] && kill "$XS" 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT INT TERM
for d in "$DEBS"/libgtk-3-0t64_*.deb "$DEBS"/libgtk-4-1_*.deb; do dpkg-deb -x "$d" "$T/root"; done
LIB="$T/root/usr/lib/x86_64-linux-gnu"
Xvfb -displayfd 3 -screen 0 1920x1200x24 -nolisten tcp 3>"$T/display" >/dev/null 2>&1 & XP=$!
i=0; while [ ! -s "$T/display" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
D=":$(cat "$T/display")"
conf() {   # PERCENT: the session's XSETTINGS at PERCENT (sg-session sg_xsettings_conf)
    g=$(( ($1 + 50) / 100 ))
    {
        printf 'Xft/DPI %d\nGdk/WindowScalingFactor %d\nGdk/UnscaledDPI %d\n' $(( 96 * $1 / 100 * 1024 )) "$g" $(( 96 * $1 / 100 * 1024 / g ))
        [ "$1" -gt 100 ] && printf 'Gdk/SgFractionalScale %d\n' $(( 1024 * $1 / 100 ))
    } > "$T/xs.conf"
    [ -n "$XS" ] && kill -HUP "$XS"
    sleep 1
}
conf 100
DISPLAY=$D xsettingsd -c "$T/xs.conf" >/dev/null 2>&1 & XS=$!
sleep 1
cat > "$T/probe.py" <<'EOS'
import sys, gi
ver, title, life = sys.argv[1], sys.argv[2], int(sys.argv[3])
gi.require_version('Gtk', ver + '.0')
from gi.repository import Gtk, GLib
if ver == '3':
    w = Gtk.Window(title=title); w.set_default_size(400, 300); w.add(Gtk.Label(label="Stained Glass")); w.show_all()
    def rep():
        print("scale=%d dpi=%d" % (w.get_scale_factor(), w.get_settings().get_property('gtk-xft-dpi') // 1024), flush=True)
        return True
    GLib.timeout_add(500, rep); GLib.timeout_add(life, Gtk.main_quit); Gtk.main()
else:
    app = Gtk.Application()
    def act(a):
        w = Gtk.ApplicationWindow(application=a, title=title); w.set_default_size(400, 300)
        w.set_child(Gtk.Label(label="Stained Glass")); w.present()
        def rep():
            s = w.get_surface()
            print("scale=%s dpi=%d" % (s.get_scale() if s else 0, w.get_settings().get_property('gtk-xft-dpi') // 1024), flush=True)
            return True
        GLib.timeout_add(500, rep); GLib.timeout_add(life, a.quit)
    app.connect('activate', act); app.run([])
EOS
size() { DISPLAY=$D xwininfo -name "$1" 2>/dev/null | awk '/Width:/ {w=$2} /Height:/ {h=$2} END {print w "x" h}'; }
# run VER TITLE LIBDIR [NAME]: the window's size at 100%, 175%, 125%, and its last report
run() {
    conf 100
    cp "$T/probe.py" "$T/${4:-probe}"
    env -i DISPLAY="$D" HOME="$T" XDG_RUNTIME_DIR="$T" GDK_BACKEND=x11 GSK_RENDERER=cairo ${3:+LD_LIBRARY_PATH="$3"} \
        /usr/bin/python3 "$T/${4:-probe}" "$1" "$2" 12000 > "$T/$2.log" 2>/dev/null &
    sleep 3; a=$(size "$2")
    conf 175; sleep 1; b=$(size "$2"); r175=$(tail -1 "$T/$2.log")
    conf 125; sleep 1; c=$(size "$2")
    wait
    echo "$a $b $c $r175"
}
for v in 3 4; do
    set -- $(run $v "sg-gtk$v" "$LIB")
    if [ "$1" = 400x300 ] && [ "$2" = 700x525 ] && [ "$3" = 500x375 ] && [ "$5" = dpi=96 ]; then
        pass "our GTK $v: 400x300 at 100%, while it runs 700x525 at 175% ($4, text $5) and 500x375 at 125%"
    else
        fail "our GTK $v: $1 at 100%, $2 at 175% (want 700x525), $3 at 125% (want 500x375); at 175% $4 $5 (want text dpi=96)"
    fi
done
set -- $(run 3 "sg-gtk3-firefox" "$LIB" firefox)
[ "$4" = scale=1 ] && [ "$5" = dpi=168 ] && pass "GTK 3, a program that scales itself (firefox): scale 1, the whole DPI (168)" \
    || fail "GTK 3 as firefox at 175%: $4 $5 (want scale=1 dpi=168)"
set -- $(run 3 "debian-gtk3" "")
[ "$2" = 800x600 ] && pass "Debian's GTK 3 under the same settings: $2 at 175% (whole steps) -- the check tells them apart" \
    || fail "Debian's GTK 3 at 175%: $2 (want 800x600; is the system's GTK ours?)"
[ "$RC" = 0 ] && echo "gtk-scale-test: PASS" || echo "gtk-scale-test: FAIL"
exit "$RC"
