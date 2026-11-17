#!/bin/sh
# A small FFmpeg for Windows, built here from its source (LGPL), that decodes H.264, HEVC, AV1 and VP9 through
# Direct3D 11 video decoders (D3D11VA) and DXVA2 (Direct3D 9) -- the test client of test/videodecode-test.sh: programs that
# decode video themselves (Chromium, Firefox, VLC, mpv) use the same interface. Not shipped.
#
#   test/ffmpeg-d3d11va-build.sh FFMPEG_TARBALL OUT_DIR     -> OUT_DIR/ffmpeg.exe
#
# Needs the mingw-w64 cross compiler.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
TARBALL=$1 OUT=$2
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "ffmpeg-d3d11va-build: mingw-w64 is missing" >&2; exit 1; }
W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-ffmpeg.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir "$W/src" "$W/build"
tar -xf "$TARBALL" -C "$W/src" --strip-components=1
cd "$W/build"
"$W/src/configure" --target-os=mingw32 --arch=x86_64 --cross-prefix=x86_64-w64-mingw32- \
    --enable-static --disable-shared --disable-everything --disable-doc --disable-network \
    --disable-autodetect --disable-x86asm --enable-d3d11va --enable-dxva2 \
    --enable-decoder=h264,hevc,av1,vp9,rawvideo \
    --enable-hwaccel=h264_d3d11va,h264_d3d11va2,hevc_d3d11va,hevc_d3d11va2,av1_d3d11va,av1_d3d11va2,vp9_d3d11va,vp9_d3d11va2,h264_dxva2,hevc_dxva2,av1_dxva2,vp9_dxva2 \
    --enable-demuxer=mov,h264,ivf,matroska --enable-parser=h264,hevc,av1,vp9 --enable-bsf=av1_frame_split,vp9_superframe_split --enable-protocol=file,pipe \
    --enable-muxer=framemd5,rawvideo --enable-filter=scale,format,hwdownload,null \
    --enable-encoder=rawvideo >/dev/null
nice make -j"${J:-3}" ffmpeg.exe >/dev/null
mkdir -p "$OUT"
cp ffmpeg.exe "$OUT/ffmpeg.exe"
