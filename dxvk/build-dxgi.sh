#!/bin/sh
# Build DXVK's dxgi.dll and d3d11.dll with Stained Glass OS's patches
# (dxvk/patches), for x64 and x32, from the pinned upstream source; the rest
# of DXVK stays the upstream release. Cached by the patches' hash.
#
#   build-dxgi.sh VERSION COMMIT CACHE_DIR OUT_DIR
#
# Needs meson, ninja, glslangValidator and the mingw-w64 posix compilers.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
VERSION=$1 COMMIT=$2 CACHE=$3 OUT=$4
HERE=$(cd "$(dirname "$0")" && pwd)
for t in meson ninja glslangValidator x86_64-w64-mingw32-g++-posix i686-w64-mingw32-g++-posix git; do
    command -v "$t" >/dev/null || { echo "build-dxgi: $t is missing (glslang-tools, meson, g++-mingw-w64)" >&2; exit 1; }
done
DLLS="dxgi d3d11"
KEY=$( { echo "$VERSION $COMMIT $DLLS"; cat "$HERE"/patches/*.patch; } | sha256sum | cut -c1-16)
BUILT="$CACHE/dxvk-dxgi-$KEY"
if [ ! -f "$BUILT/x64/d3d11.dll" ] || [ ! -f "$BUILT/x32/d3d11.dll" ]; then
    SRC="$CACHE/dxvk-src-$VERSION"
    if [ ! -d "$SRC/.git" ]; then
        rm -rf "$SRC"
        git clone -q --depth 1 --branch "v$VERSION" --recurse-submodules --shallow-submodules \
            https://github.com/doitsujin/dxvk.git "$SRC"
    fi
    [ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] \
        || { echo "build-dxgi: v$VERSION is not the pinned commit $COMMIT" >&2; exit 1; }
    W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-dxvk.XXXXXX")
    trap 'rm -rf "$W"' EXIT
    cp -a "$SRC" "$W/src"
    for p in "$HERE"/patches/*.patch; do git -C "$W/src" apply "$p"; done
    for arch in 64 32; do
        meson setup --cross-file "$W/src/build-win$arch.txt" --buildtype release \
            -Denable_d3d8=false -Denable_d3d9=false "$W/b$arch" "$W/src" >/dev/null
        nice ninja -j3 -C "$W/b$arch" $(for d in $DLLS; do printf 'src/%s/%s.dll ' "$d" "$d"; done) >/dev/null
    done
    rm -rf "$BUILT.tmp"
    mkdir -p "$BUILT.tmp/x64" "$BUILT.tmp/x32"
    for d in $DLLS; do
        cp "$W/b64/src/$d/$d.dll" "$BUILT.tmp/x64/"
        cp "$W/b32/src/$d/$d.dll" "$BUILT.tmp/x32/"
    done
    rm -rf "$BUILT"; mv "$BUILT.tmp" "$BUILT"
fi
mkdir -p "$OUT/x64" "$OUT/x32" "$OUT/patches"
for d in $DLLS; do
    cp "$BUILT/x64/$d.dll" "$OUT/x64/$d.dll"
    cp "$BUILT/x32/$d.dll" "$OUT/x32/$d.dll"
done
cp "$HERE"/patches/*.patch "$OUT/patches/"
echo "build-dxgi: $DLLS from DXVK $VERSION with $(ls "$HERE"/patches/*.patch | wc -l) patch(es) ($KEY)"
