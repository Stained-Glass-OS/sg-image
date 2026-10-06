#!/bin/sh
# WPF programs at the display scale under our Wine Mono (mono/patches
# wpf-0006): as on the .NET Framework, a WPF program is aware of the system
# DPI unless its assembly says [DisableDpiAwareness]. Wine Mono's runtime
# left every one unaware -- Wine drew it at 100% and scaled the picture,
# soft at 175% (DYMO Connect, Sonos on a Surface Pro 7). Under Xvfb at
# 2736x1824 with the display scale at 175% (LogPixels 168), two probe
# windows, 400x300 DIPs:
#   - a plain WPF program: its window aware of the system DPI at 168, drawn
#     by WPF at 700x525 (crisp: not Wine's scaled picture)
#   - one with [assembly: DisableDpiAwareness]: unaware, as it asked (Wine
#     scales it to 700x525)
#
#   test/wpf-dpi-test.sh [WINE]        (needs make mono-deb first, or
#                                       SG_MONO_DIR=<a Wine Mono tree>)
# Mutant: WindowsBase built with -define:SG_MUTANT_WPF_DPI_UNAWARE (the
# plain program unaware again) fails the first check.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE=${1:-/opt/wine-sg/bin/wine}
WINESERVER="$(dirname "$WINE")/wineserver"
[ -x "$WINESERVER" ] || WINESERVER="$(dirname "$WINE")/server/wineserver"
MONO=$(ls -d "${SG_MONO_DIR:-$HERE/build/mono-deb-root/usr/share/wine/mono}"/wine-mono-* 2>/dev/null | head -1)
[ -n "$MONO" ] || MONO=${SG_MONO_DIR:-}
MINGW="${MINGW:-x86_64-w64-mingw32-gcc}"
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -n "$MONO" ] && [ -d "$MONO/lib/mono/gac" ] || { echo "SKIP: no packaged Wine Mono (make mono-deb)"; exit 77; }
for t in Xvfb "$MINGW"; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
T=$(mktemp -d /var/tmp/sg-wpfdpi.XXXXXX)
export HOME="$T/home" XDG_RUNTIME_DIR="$T/run" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mshtml=;winemenubuilder.exe=d" WINESERVER
unset WAYLAND_DISPLAY
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
n=170; while [ -e "/tmp/.X$n-lock" ]; do n=$((n + 1)); done
Xvfb ":$n" -screen 0 2736x1824x24 -nolisten tcp >/dev/null 2>&1 & XP=$!
export DISPLAY=":$n"
trap '"$WINESERVER" -k 2>/dev/null; kill $XP 2>/dev/null; rm -rf "$T"' EXIT INT TERM
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
"$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
w() { "$WINE" winepath -w "$1" | tr -d '\r'; }
"$WINE" reg add 'HKCU\Software\Wine\Mono' /v RuntimePath /d "$(w "$MONO")" /f >/dev/null 2>&1
"$WINE" reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d 168 /f >/dev/null 2>&1
"$WINESERVER" -w
C="$WINEPREFIX/drive_c"
cat > "$C/probe.cs" <<'EOF'
using System; using System.Windows; using System.Windows.Controls; using System.Windows.Media;
#if SG_DISABLED
[assembly: DisableDpiAwareness]
#endif
class P { [STAThread] static void Main(string[] a) {
  var app = new Application();
  var w = new Window { Title = a[0], Width = 400, Height = 300, Left = 100, Top = 100, WindowStyle = WindowStyle.None,
                       Background = Brushes.Green };
  app.Run(w);
} }
EOF
cat > "$T/look.c" <<'EOF'
#include <windows.h>
#include <stdio.h>
/* "AWARENESS DPI WxH" of the window titled argv[1], in the screen's pixels */
int main(int argc, char **argv)
{
    HWND h; RECT r; DPI_AWARENESS_CONTEXT c;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (argc < 2 || !(h = FindWindowA(NULL, argv[1]))) { printf("none\n"); return 1; }
    GetWindowRect(h, &r); c = GetWindowDpiAwarenessContext(h);
    printf("%d %u %ldx%ld\n", GetAwarenessFromDpiAwarenessContext(c), GetDpiForWindow(h), r.right - r.left, r.bottom - r.top);
    return 0;
}
EOF
"$MINGW" -O2 -o "$T/look.exe" "$T/look.c" || { fail "the probe did not build"; exit 1; }
G="$MONO/lib/mono/gac"; refs=""
for a in PresentationFramework PresentationCore WindowsBase System.Xaml; do
    f=$(ls "$G/$a"/*/"$a.dll" 2>/dev/null | head -1)
    [ -n "$f" ] || { fail "no $a in the packaged Mono"; exit 1; }
    refs="$refs -r:$(w "$f")"
done
mcs=$(w "$MONO/lib/mono/4.5/mcs.exe")
# shellcheck disable=SC2086
(cd "$C" && timeout 300 "$WINE" "$mcs" $refs -out:plain.exe probe.cs >"$T/mcs.out" 2>&1 \
          && timeout 300 "$WINE" "$mcs" $refs -define:SG_DISABLED -out:disabled.exe probe.cs >>"$T/mcs.out" 2>&1)
[ -f "$C/plain.exe" ] && [ -f "$C/disabled.exe" ] || { fail "the probes did not compile: $(cat "$T/mcs.out")"; exit 1; }
(cd "$C" && "$WINE" plain.exe sgwpfplain >/dev/null 2>&1 &)
(cd "$C" && "$WINE" disabled.exe sgwpfdisabled >/dev/null 2>&1 &)
i=0; while [ $i -lt 90 ] && { ! "$WINE" "$T/look.exe" sgwpfplain >/dev/null 2>&1 || ! "$WINE" "$T/look.exe" sgwpfdisabled >/dev/null 2>&1; }; do sleep 1; i=$((i + 1)); done
sleep 3
p=$("$WINE" "$T/look.exe" sgwpfplain 2>/dev/null | tr -d '\r')
d=$("$WINE" "$T/look.exe" sgwpfdisabled 2>/dev/null | tr -d '\r')
[ "$p" = "1 168 700x525" ] && pass "a WPF program is aware of the system DPI at 175%: drawn by WPF at 700x525 ($p)" \
    || fail "a plain WPF program at 175%: '$p' (want '1 168 700x525': aware of the system DPI)"
[ "$d" = "0 96 700x525" ] && pass "[DisableDpiAwareness] keeps it unaware, as it asks; Wine scales it ($d)" \
    || fail "a WPF program with [DisableDpiAwareness]: '$d' (want '0 96 700x525')"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
