#!/bin/sh
# A composition swap chain made through DXVK shows in its window
# (dxvk/patches/0001). Qt Quick windows (Audacity 4) and Chromium's
# swap-chain output were black under DXVK: CreateSwapChainForComposition
# made no swap chain. The probe binds one to a window with DirectComposition
# (wine-sg's dcomp), clears it red, presents, and reads the screen.
#
#   test/dcomp-test.sh [DXVK_X64_DIR]     (default: the staged payload)
#
# Host test: wine-sg (/opt/wine-sg or $WINE), Xvfb, mingw-w64 g++, and a
# Vulkan device for DXVK (no window system integration is needed).
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DXVK=${1:-$HERE/build/d3d-payload/dxvk/x64}
WINE=${WINE:-/opt/wine-sg/bin/wine}
WINESERVER=${WINESERVER:-$(dirname "$WINE")/wineserver}
for t in Xvfb x86_64-w64-mingw32-g++; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -f "$DXVK/dxgi.dll" ] && [ -f "$DXVK/d3d11.dll" ] || { echo "SKIP: no DXVK at $DXVK (make d3d)"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-dcomp.XXXXXX"); XP=
# a scratch HOME: a prefix links its Desktop, Documents... into HOME
export HOME="$T/home" WINEPREFIX="$T/prefix" WINEDEBUG=-all WINESERVER \
       WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d;dxgi,d3d11,d3d10core=n"
mkdir -p "$HOME"
trap '"$WINESERVER" -k 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
x86_64-w64-mingw32-g++ -O2 -static -o "$T/dcomp-probe.exe" "$HERE/test/dcomp-probe.cpp" \
    -ld3d11 -ldxgi -ldcomp -luuid -lgdi32 -luser32 || { echo "FAIL  probe did not build"; exit 1; }
Xvfb -displayfd 3 -screen 0 800x600x24 -nolisten tcp 3>"$T/display" >/dev/null 2>&1 & XP=$!
i=0; while [ ! -s "$T/display" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
export DISPLAY=":$(cat "$T/display")"
timeout -s KILL 300 "$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
cp "$DXVK"/*.dll "$WINEPREFIX/drive_c/windows/system32/"
cp "$T/dcomp-probe.exe" "$WINEPREFIX/drive_c/"
out=$(cd "$WINEPREFIX/drive_c" && DXVK_LOG_LEVEL=none timeout 120 "$WINE" 'C:\dcomp-probe.exe' 2>/dev/null | tr -d '\r')
printf '      %s\n' "$out"
case "$out" in
dcomp=ok*) echo "PASS  a composition swap chain through DXVK shows in its window"; echo "RESULT: PASS"; exit 0 ;;
*"FAIL device"*) echo "SKIP: DXVK made no Direct3D 11 device here (no Vulkan)"; exit 77 ;;
*"FAIL dcompdevice 0x80004001"*) echo "SKIP: this Wine has no DirectComposition (wine-sg 0191 and later; WINE=)"; exit 77 ;;
*) echo "FAIL  composition through DXVK: $out"; echo "RESULT: FAIL"; exit 1 ;;
esac
