#!/bin/sh
# Wine Gecko as packaged (sg-wine-gecko, gecko/build-deb.sh): Wine's mshtml
# loads an HTML document with it, in a 64-bit and a 32-bit program -- each
# architecture's engine. The HTML in installers, help and sign-in windows.
#
#   test/gecko-test.sh [WINE]     (needs make gecko-deb-root first)
# Mutation: SG_GECKO_DIR at a package tree whose engine does not load (its
# xul.dll removed): both architectures fail rather than passing on another
# Gecko the machine has (Debian's /usr/share/wine/gecko).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE=${1:-/opt/wine-sg/bin/wine}
WINESERVER="$(dirname "$WINE")/wineserver"
G=${SG_GECKO_DIR:-$HERE/build/gecko-deb-root/usr/share/wine/gecko}
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -d "$G" ] || { echo "SKIP: no packaged Wine Gecko (make gecko-deb-root)"; exit 77; }
command -v x86_64-w64-mingw32-gcc >/dev/null && command -v i686-w64-mingw32-gcc >/dev/null || { echo "SKIP: mingw-w64 not installed"; exit 77; }
command -v Xvfb >/dev/null || { echo "SKIP: Xvfb not installed"; exit 77; }
unset WAYLAND_DISPLAY
T=$(mktemp -d /var/tmp/sg-gecko.XXXXXX)
export HOME="$T/home" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;winemenubuilder.exe=d"
mkdir -p "$HOME"
# Gecko makes a (hidden) window for its browser: a display of our own
for n in $(seq 140 199); do [ -e "/tmp/.X11-unix/X$n" ] || break; done
Xvfb ":$n" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 & XP=$!
export DISPLAY=":$n"
i=0; while [ ! -e "/tmp/.X11-unix/X$n" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
trap '"$WINESERVER" -k 2>/dev/null; kill $XP 2>/dev/null; rm -rf "$T"' EXIT INT TERM
RC=0
# printf, not echo: dash's echo eats the backslashes of Windows paths
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
x86_64-w64-mingw32-gcc -O1 -o "$T/g64.exe" "$HERE/test/gecko-probe.c" -lole32 -loleaut32 -luuid || { fail "probe (64-bit) did not build"; exit 1; }
i686-w64-mingw32-gcc -O1 -o "$T/g32.exe" "$HERE/test/gecko-probe.c" -lole32 -loleaut32 -luuid || { fail "probe (32-bit) did not build"; exit 1; }
"$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
ver=$(ls "$G" | sed -n 's/^wine-gecko-\(.*\)-x86_64$/\1/p' | head -1)
# each architecture's registry view: a 32-bit program reads the 32-bit one
for a in x86_64:g64:64 x86:g32:32; do
    arch=${a%%:*} exe=${a#*:} view=${a##*:}; exe=${exe%%:*}
    "$WINE" reg add "HKLM\\Software\\Wine\\MSHTML\\$ver" /v GeckoPath /d "$("$WINE" winepath -w "$G/wine-gecko-$ver-$arch" | tr -d '\r')" /reg:$view /f >/dev/null 2>&1
    "$WINESERVER" -w
    out=$(timeout 120 "$WINE" "$T/$exe.exe" 2>/dev/null | tr -d '\r')
    xul=$(printf '%s\n' "$out" | sed -n 's/^xul=//p')
    want=$("$WINE" winepath -w "$G/wine-gecko-$ver-$arch" | tr -d '\r')
    case "$out" in *"text=stained glass gecko"*) pass "$arch: mshtml renders an HTML document with Wine Gecko $ver" ;;
        *) fail "$arch: $(echo "$out" | tr '\n' ' ')" ;; esac
    case "$xul" in "$want"\\*) pass "$arch: with the packaged engine ($xul)" ;;
        *) fail "$arch: another engine: '$xul' (want $want)" ;; esac
done
exit $RC
