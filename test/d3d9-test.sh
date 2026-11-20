#!/bin/sh
# Direct3D 9 through the DXVK built here: sg-d3d now builds d3d9.dll from the pinned source with
# Stained Glass OS's patches (dxvk/patches/0010: DXVA2 video decoders) instead of shipping the
# release's. The probe (64- and 32-bit) makes a D3D9Ex device, clears red, draws a green triangle,
# stretches a blue NV12 surface onto the target, and a blue P010 one (0013) -- each read back -- and presents.
#
#   test/d3d9-test.sh [DXVK_DIR]     (the payload's dxvk directory: x64 and x32 in it)
#
# Host test: wine-sg (/opt/wine-sg or $WINE), Xvfb, mingw-w64 g++, a Vulkan device for DXVK.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DXVK=${1:-$HERE/build/d3d-payload/dxvk}
WINE=${WINE:-/opt/wine-sg/bin/wine}
WINESERVER=${WINESERVER:-$(dirname "$WINE")/wineserver}
[ -x "$WINESERVER" ] || WINESERVER="$(dirname "$WINE")/server/wineserver"
for t in Xvfb x86_64-w64-mingw32-g++ i686-w64-mingw32-g++; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -f "$DXVK/x64/d3d9.dll" ] && [ -f "$DXVK/x32/d3d9.dll" ] || { echo "SKIP: no DXVK at $DXVK (make d3d)"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-d3d9.XXXXXX"); XP=; RC=0
export HOME="$T/home" WINEPREFIX="$T/prefix" WINEDEBUG=-all WINESERVER \
       WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d"
# never the person's live desktop (Wine's Wayland driver, $XDG_RUNTIME_DIR/wayland-0)
export XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=sg-no-wayland XDG_DATA_DIRS=/usr/local/share:/usr/share
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
trap '"$WINESERVER" -k 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
x86_64-w64-mingw32-g++ -O2 -static -o "$T/p64.exe" "$HERE/test/d3d9-probe.cpp" -ld3d9 -luser32 -lgdi32 \
    && i686-w64-mingw32-g++ -O2 -static -o "$T/p32.exe" "$HERE/test/d3d9-probe.cpp" -ld3d9 -luser32 -lgdi32 \
    || { echo "FAIL  probe did not build"; exit 1; }
Xvfb -displayfd 3 -screen 0 800x600x24 -nolisten tcp 3>"$T/display" >/dev/null 2>&1 & XP=$!
i=0; while [ ! -s "$T/display" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
export DISPLAY=":$(cat "$T/display")"
timeout -s KILL 300 "$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
cp "$DXVK"/x64/*.dll "$WINEPREFIX/drive_c/windows/system32/"
cp "$DXVK"/x32/*.dll "$WINEPREFIX/drive_c/windows/syswow64/"
export WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d;dxgi,d3d11,d3d10core,d3d9=n"
cp "$T/p64.exe" "$T/p32.exe" "$WINEPREFIX/drive_c/"
for a in 64 32; do
    out=$(cd "$WINEPREFIX/drive_c" && DXVK_LOG_LEVEL=none timeout 120 "$WINE" "C:\\p$a.exe" 2>/dev/null | tr -d '\r')
    echo "      $a-bit: $out"
    set -- $out
    case "$out" in
    "d3d9=ok clear=ff0000 draw=00ff00 nv12="*)
        # blue in BT.601: about 0,0,255 (the converter's rounding aside)
        rgb=${4#nv12=}
        r=$((0x$(echo "$rgb" | cut -c1-2))); g=$((0x$(echo "$rgb" | cut -c3-4))); b=$((0x$(echo "$rgb" | cut -c5-6)))
        if [ $r -lt 40 ] && [ $g -lt 40 ] && [ $b -gt 200 ]; then
            echo "PASS  $a-bit: a D3D9 device clears, draws, shows an NV12 surface and presents"
        else
            echo "FAIL  $a-bit: the NV12 surface came out $rgb (wanted blue)"; RC=1
        fi
        # the same blue from a P010 surface (dxvk/patches/0013: DXVA2's 10-bit decoders)
        rgb=${5#p010=}
        r=$((0x$(echo "$rgb" | cut -c1-2))); g=$((0x$(echo "$rgb" | cut -c3-4))); b=$((0x$(echo "$rgb" | cut -c5-6)))
        if [ $r -lt 40 ] && [ $g -lt 40 ] && [ $b -gt 200 ]; then
            echo "PASS  $a-bit: a P010 surface shows (made, written with LockRect, stretched)"
        else
            echo "FAIL  $a-bit: the P010 surface came out $rgb (wanted blue)"; RC=1
        fi ;;
    *"FAIL device"*) echo "SKIP: DXVK made no Direct3D 9 device here (no Vulkan)"; exit 77 ;;
    *) echo "FAIL  $a-bit: $out"; RC=1 ;;
    esac
done
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
