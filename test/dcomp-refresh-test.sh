#!/bin/sh
# Composition swap chains made through DXVK stay shown (dxvk/patches/0003).
# Paint.NET's canvas, colour wheel and History/Layers lists were black under
# DXVK (every installed machine's Direct3D): they are 16-bit float swap
# chains, which our DXVK's composition swap chain did not draw, and
# Windows.UI.Composition clears its window before it places them, which
# hid them until the next present. The probe checks a float swap chain,
# a Commit after the window was painted over, and the frame coming back by
# itself (see test/dcomp-refresh-probe.cpp).
#
#   test/dcomp-refresh-test.sh [DXVK_X64_DIR]     (default: the staged payload)
#
# Host test: wine-sg (/opt/wine-sg or $WINE), Xvfb, mingw-w64 g++, and a
# Vulkan device for DXVK (lavapipe does).
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DXVK=${1:-$HERE/build/d3d-payload/dxvk/x64}
WINE=${WINE:-/opt/wine-sg/bin/wine}
WINESERVER=${WINESERVER:-$(dirname "$WINE")/wineserver}
for t in Xvfb x86_64-w64-mingw32-g++; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
if [ ! -f "$DXVK/dxgi.dll" ] || [ ! -f "$DXVK/d3d11.dll" ]; then echo "SKIP: no DXVK at $DXVK (make d3d)"; exit 77; fi
T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-dcomp.XXXXXX"); XP=
# a scratch HOME: a prefix links its Desktop, Documents... into HOME
export HOME="$T/home" WINEPREFIX="$T/prefix" WINEDEBUG=-all WINESERVER \
       WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d;dxgi,d3d11,d3d10core=n"
mkdir -p "$HOME"
trap '"$WINESERVER" -k 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
x86_64-w64-mingw32-g++ -O2 -static -o "$T/dcomp-refresh-probe.exe" "$HERE/test/dcomp-refresh-probe.cpp" \
    -ld3d11 -ldxgi -ldcomp -luuid -lgdi32 -luser32 || { echo "FAIL  probe did not build"; exit 1; }
Xvfb -displayfd 3 -screen 0 800x600x24 -nolisten tcp 3>"$T/display" >/dev/null 2>&1 & XP=$!
i=0; while [ ! -s "$T/display" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
DISPLAY=":$(cat "$T/display")"; export DISPLAY
timeout -s KILL 300 "$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
cp "$DXVK"/*.dll "$WINEPREFIX/drive_c/windows/system32/"
cp "$T/dcomp-refresh-probe.exe" "$WINEPREFIX/drive_c/"
out=$(cd "$WINEPREFIX/drive_c" && DXVK_LOG_LEVEL=none timeout 120 "$WINE" 'C:\dcomp-refresh-probe.exe' 2>/dev/null | tr -d '\r')
printf '%s\n' "$out" | sed 's/^/      /'
if printf '%s\n' "$out" | grep -q '^device=FAIL'; then echo "SKIP: DXVK made no Direct3D 11 device here (no Vulkan)"; exit 77; fi
if printf '%s\n' "$out" | grep -q '^dcompdevice=FAIL 0x80004001'; then
    echo "SKIP: this Wine has no DirectComposition (wine-sg 0191 and later; WINE=)"; exit 77
fi
rc=0
for c in half commit refresh; do
    if printf '%s\n' "$out" | grep -q "^$c=ok"; then echo "PASS  $c"; else echo "FAIL  $c"; rc=1; fi
done
[ $rc = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $rc
