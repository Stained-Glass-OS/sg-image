#!/bin/sh
# A Direct3D 11 texture shared between two processes under its keyed mutex, through DXVK, shows
# each process the other's drawing (dxvk/patches/0014, 0015). Chromium and Qt WebEngine (Sigil's
# preview) share every frame from their GPU process this way. test/keyedmutex-probe.cpp: the
# parent clears the texture red on the GPU and releases key 1, the child acquires key 1 and reads
# the pixel, releases key 0; the parent clears green; the child reads again.
#   - lavapipe (llvmpipe's Vulkan, as in most virtual machines), which cannot share a timeline
#     semaphore: before 0015 ReleaseSync failed, the device was lost and the child never opened
#     the texture; now the keyed mutex synchronizes on the CPU (0015) and both colours arrive;
#   - a hardware Vulkan driver, when there is one: the shared semaphore path, unchanged; before
#     0014 the child read the previous contents (a clear queued past the release).
#
#   test/keyedmutex-test.sh [DXVK_X64_DIR]     (default: the staged payload)
#   WINE=<a current wine-sg>; SG_KM_HW_ICD=<icd json> picks the hardware driver.
#
# Host test: wine-sg, Xvfb, mingw-w64 g++, Mesa's lavapipe.
# Mutants (DXVK source): SG_MUTANT_KEYEDMUTEX_NO_FALLBACK (src/dxvk/dxvk_image.cpp),
# SG_MUTANT_RELEASESYNC_NO_FLUSH (src/d3d11/d3d11_resource.cpp) and
# SG_MUTANT_SHARED_CLEAR_STAYS_DEFERRED (src/dxvk/dxvk_context.cpp) each fail it.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DXVK=${1:-$HERE/build/d3d-payload/dxvk/x64}
WINE=${WINE:-/opt/wine-sg/bin/wine}
WINESERVER=${WINESERVER:-$(dirname "$WINE")/wineserver}
ICDS=/usr/share/vulkan/icd.d
for t in Xvfb x86_64-w64-mingw32-g++; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -f "$DXVK/dxgi.dll" ] && [ -f "$DXVK/d3d11.dll" ] || { echo "SKIP: no DXVK at $DXVK (make d3d)"; exit 77; }
[ -f "$ICDS/lvp_icd.json" ] || { echo "SKIP: no lavapipe ($ICDS/lvp_icd.json; mesa-vulkan-drivers)"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-keyedmutex.XXXXXX"); XP=
export HOME="$T/home" WINEPREFIX="$T/prefix" WINEDEBUG=-all WINESERVER \
       WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d;dxgi,d3d11,d3d10core=n"
mkdir -p "$HOME"
trap '"$WINESERVER" -k 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
x86_64-w64-mingw32-g++ -O2 -static -o "$T/keyedmutex-probe.exe" "$HERE/test/keyedmutex-probe.cpp" \
    -ld3d11 -ldxgi -luuid || { echo "FAIL  probe did not build"; exit 1; }
Xvfb -displayfd 3 -screen 0 800x600x24 -nolisten tcp 3>"$T/display" >/dev/null 2>&1 & XP=$!
i=0; while [ ! -s "$T/display" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
export DISPLAY=":$(cat "$T/display")"
unset WAYLAND_DISPLAY
timeout -s KILL 300 "$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
cp "$DXVK"/*.dll "$WINEPREFIX/drive_c/windows/system32/"
cp "$T/keyedmutex-probe.exe" "$WINEPREFIX/drive_c/"

fail=0
run() {   # run NAME ICD_JSON
    out=$(cd "$WINEPREFIX/drive_c" && VK_DRIVER_FILES="$2" DXVK_LOG_LEVEL=none timeout -s KILL 120 \
          "$WINE" 'C:\keyedmutex-probe.exe' 2>/dev/null | tr -d '\r')
    "$WINESERVER" -k 2>/dev/null; "$WINESERVER" -w
    case "$out" in *"FAIL device"*) echo "SKIP  $1: DXVK made no Direct3D 11 device"; return 77 ;; esac
    printf '%s\n' "$out" | grep -E 'pixel|open|share' | sed "s/^/INFO  $1: /"
    for c in "share:the texture is shared by an NT handle" "child_open:the other process opens it" \
             "red:the other process sees the first drawing after acquiring the mutex" \
             "parent_turn:the mutex comes back" "green:it sees the second drawing too" \
             "parent_green:the drawing process still sees its own drawing"; do
        k=${c%%:*}
        if printf '%s\n' "$out" | grep -qx "$k=1"; then echo "PASS  $1: ${c#*:}"; else echo "FAIL  $1: ${c#*:}"; fail=1; fi
    done
}
run lavapipe "$ICDS/lvp_icd.json"
hw=${SG_KM_HW_ICD:-}
if [ -z "$hw" ]; then
    for j in nvidia_icd.json radeon_icd.json intel_icd.json; do [ -f "$ICDS/$j" ] && { hw=$ICDS/$j; break; }; done
fi
if [ -n "$hw" ]; then run "hardware ($(basename "$hw" .json))" "$hw"; else echo "INFO  no hardware Vulkan driver: lavapipe only"; fi
[ $fail = 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
