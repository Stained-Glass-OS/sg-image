#!/bin/sh
# A texture made and drawn by Direct3D 11 (DXVK) in one process is read by Direct3D 12
# (vkd3d-proton) in another, as Qt's Direct3D 12 renderer takes Chromium's frames (Sigil's preview).
# test/d3d12share-probe.cpp: the parent clears an NT-shared texture red on the GPU and waits for
# it (an event query), the child opens it with ID3D12Device::OpenSharedHandle and reads the pixel
# through a readback buffer; then green. With and without SHARED_KEYEDMUTEX.
# Before dxvk/patches/0014 the child read zeros on every driver: a clear on a shared image still
# in its default layout stayed deferred past the submission the parent waited on.
#
#   test/d3d12share-test.sh [DXVK_X64_DIR [VKD3D_X64_DIR]]     (default: the staged payload)
#   WINE=<a current wine-sg>; SG_KM_HW_ICD=<icd json> picks the hardware driver.
#
# Host test: wine-sg, Xvfb, mingw-w64 g++, Mesa's lavapipe (and a hardware driver if any).
# Mutant (DXVK source): SG_MUTANT_SHARED_CLEAR_STAYS_DEFERRED (src/dxvk/dxvk_context.cpp) fails it.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DXVK=${1:-$HERE/build/d3d-payload/dxvk/x64}
VKD3D=${2:-$HERE/build/d3d-payload/vkd3d-proton/x64}
WINE=${WINE:-/opt/wine-sg/bin/wine}
WINESERVER=${WINESERVER:-$(dirname "$WINE")/wineserver}
ICDS=/usr/share/vulkan/icd.d
for t in Xvfb x86_64-w64-mingw32-g++; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -f "$DXVK/dxgi.dll" ] && [ -f "$DXVK/d3d11.dll" ] || { echo "SKIP: no DXVK at $DXVK (make d3d)"; exit 77; }
[ -f "$VKD3D/d3d12.dll" ] && [ -f "$VKD3D/d3d12core.dll" ] || { echo "SKIP: no vkd3d-proton at $VKD3D (make d3d)"; exit 77; }
[ -f "$ICDS/lvp_icd.json" ] || { echo "SKIP: no lavapipe ($ICDS/lvp_icd.json; mesa-vulkan-drivers)"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-d3d12share.XXXXXX"); XP=
export HOME="$T/home" WINEPREFIX="$T/prefix" WINEDEBUG=-all WINESERVER \
       WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d;dxgi,d3d11,d3d10core,d3d12,d3d12core=n"
mkdir -p "$HOME"
trap '"$WINESERVER" -k 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
x86_64-w64-mingw32-g++ -O2 -static -o "$T/d3d12share-probe.exe" "$HERE/test/d3d12share-probe.cpp" \
    -ld3d11 -ld3d12 -ldxgi -luuid || { echo "FAIL  probe did not build"; exit 1; }
Xvfb -displayfd 3 -screen 0 800x600x24 -nolisten tcp 3>"$T/display" >/dev/null 2>&1 & XP=$!
i=0; while [ ! -s "$T/display" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
export DISPLAY=":$(cat "$T/display")"
unset WAYLAND_DISPLAY
timeout -s KILL 300 "$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
cp "$DXVK"/*.dll "$VKD3D"/d3d12.dll "$VKD3D"/d3d12core.dll "$WINEPREFIX/drive_c/windows/system32/"
cp "$T/d3d12share-probe.exe" "$WINEPREFIX/drive_c/"

fail=0
run() {   # run NAME ICD_JSON [km]
    out=$(cd "$WINEPREFIX/drive_c" && VK_DRIVER_FILES="$2" DXVK_LOG_LEVEL=none VKD3D_DEBUG=none timeout -s KILL 120 \
          "$WINE" 'C:\d3d12share-probe.exe' ${3:-} 2>/dev/null | tr -d '\r')
    "$WINESERVER" -k 2>/dev/null; "$WINESERVER" -w
    case "$out" in *"FAIL device"*|*"FAIL d3d12 device"*) echo "SKIP  $1: no Direct3D device"; return 77 ;; esac
    printf '%s\n' "$out" | grep -E 'pixel|OpenSharedHandle|desc' | sed "s/^/INFO  $1: /"
    for c in "share:the D3D11 texture is shared by an NT handle" "open:Direct3D 12 opens it in the other process" \
             "red:Direct3D 12 reads the first drawing" "green:and the second"; do
        k=${c%%:*}
        if printf '%s\n' "$out" | grep -qx "$k=1"; then echo "PASS  $1: ${c#*:}"; else echo "FAIL  $1: ${c#*:}"; fail=1; fi
    done
}
hw=${SG_KM_HW_ICD:-}
if [ -z "$hw" ]; then
    for j in nvidia_icd.json radeon_icd.json intel_icd.json; do [ -f "$ICDS/$j" ] && { hw=$ICDS/$j; break; }; done
fi
for mode in "" km; do
    run "lavapipe${mode:+, keyed mutex}" "$ICDS/lvp_icd.json" $mode
    [ -n "$hw" ] && run "hardware ($(basename "$hw" .json))${mode:+, keyed mutex}" "$hw" $mode
done
[ -n "$hw" ] || echo "INFO  no hardware Vulkan driver: lavapipe only"
[ $fail = 0 ] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
