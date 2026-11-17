#!/bin/sh
# Direct3D 11 video decoders through DXVK on Vulkan Video (dxvk/patches/0006). Programs that decode
# video themselves -- Chromium and Electron programs, Firefox, VLC, mpv -- ask Direct3D 11 for a video
# decoder (D3D11VA); DXVK had none, so they all decoded on the CPU. The client here is an FFmpeg built
# from source for the purpose (test/ffmpeg-d3d11va-build.sh): it decodes short H.264 clips made by
# GStreamer's x264 -- High profile, B-frames, several references, a picture size that is cropped --
# and x265 -- HEVC Main with B-frames, Main 10 (P010 output), scaling lists and two slices a picture --
# and AV1 Main from the host's FFmpeg (libaom: 8-bit, 10-bit, tiles, loop restoration; SVT-AV1: 10-bit
# with hidden frames shown later), its reference decoded by the host's dav1d -- and VP9 profile 0 and
# profile 2 (10-bit) from the host's libvpx (hidden alt-ref frames, two tile columns, segmentation) --
# through D3D11VA (frames kept on the GPU, so no quiet fall back to the CPU), and every frame must be
# bit for bit the frame its own software decoder gives (framemd5).
#
#   test/videodecode-test.sh [DXVK_X64_DIR]   (FFMPEG_D3D11VA=ffmpeg.exe; default DXVK: the staged payload)
#
# Host test: wine-sg (/opt/wine-sg or $WINE), Xvfb, python3 GStreamer bindings with x264enc, and a GPU
# whose Vulkan driver decodes H.264 (VK_KHR_video_decode_h264); skips (77) without them. The HEVC
# clips need x265enc and VK_KHR_video_decode_h265, the AV1 ones the host's ffmpeg with libaom-av1,
# libsvtav1 and libdav1d and VK_KHR_video_decode_av1, the VP9 ones libvpx-vp9, VK_KHR_video_decode_vp9
# and a Wine that offers it to programs (wine-sg 7848); skipped (said so) without them. Headless:
# its own Xvfb, a private runtime directory, nothing on anybody's screen.
# Then with d3d11.videoDecode = False (DXVK_CONFIG): no decoder offered. Auto (the default) offers them
# only on NVIDIA's driver, where they were proven; True on any driver, for testing.
# Mutants (d3d11_video_decoder.cpp): SG_MUTANT_NO_VIDEO_DECODE (dxvk/patches/0006: no decoder),
# SG_MUTANT_AV1_REF_NAMES_SWAPPED (0008: AV1's LAST and GOLDEN references swapped),
# SG_MUTANT_VP9_NO_COMPRESSED_HEADER_OFFSET (0009: the compressed header taken from the frame's start).
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DXVK=${1:-$HERE/build/d3d-payload/dxvk/x64}
WINE=${WINE:-/opt/wine-sg/bin/wine}
WINESERVER=${WINESERVER:-$(dirname "$WINE")/wineserver}
FF=${FFMPEG_D3D11VA:-}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
for t in Xvfb python3 vulkaninfo; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -f "$DXVK/dxgi.dll" ] && [ -f "$DXVK/d3d11.dll" ] || { echo "SKIP: no DXVK at $DXVK (make d3d)"; exit 77; }
[ -n "$FF" ] && [ -f "$FF" ] || { echo "SKIP: no D3D11VA FFmpeg (make videodecode-test builds one)"; exit 77; }
python3 -c "import gi; gi.require_version('Gst', '1.0'); from gi.repository import Gst; Gst.init(None); assert Gst.ElementFactory.find('x264enc') and Gst.ElementFactory.find('mp4mux')" 2>/dev/null \
    || { echo "SKIP: no GStreamer x264enc/mp4mux to make the clips"; exit 77; }

T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-videodecode.XXXXXX"); XP=
export HOME="$T/home" WINEPREFIX="$T/prefix" WINEDEBUG=-all WINESERVER \
       WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d"
# never the person's live desktop: a runtime directory of its own, no Wayland display
export XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=sg-no-wayland XDG_DATA_DIRS=/usr/local/share:/usr/share
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
unset DISPLAY
trap '"$WINESERVER" -k 2>/dev/null; [ -n "$XP" ] && kill "$XP" 2>/dev/null; rm -rf "$T"' EXIT INT TERM

# a GPU that decodes H.264 with Vulkan; otherwise there is nothing to test here
vulkaninfo 2>/dev/null | grep -q VK_KHR_video_decode_h264 || { echo "SKIP: no Vulkan H.264 video decode on this host"; exit 77; }
HEVC=1 AV1=1
vulkaninfo 2>/dev/null | grep -q VK_KHR_video_decode_av1 || { AV1=; echo "      (no Vulkan AV1 video decode on this host: the AV1 clips are skipped)"; }
for e in libaom-av1 libsvtav1; do ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " $e " || AV1=; done
ffmpeg -hide_banner -decoders 2>/dev/null | grep -q " libdav1d " || AV1=
[ -n "$AV1" ] || echo "      (no host ffmpeg with libaom-av1, libsvtav1 and libdav1d, or no Vulkan AV1 decode: the AV1 clips are skipped)"
VP9=1
vulkaninfo 2>/dev/null | grep -q VK_KHR_video_decode_vp9 || VP9=
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " libvpx-vp9 " || VP9=
[ -n "$VP9" ] || echo "      (no Vulkan VP9 decode or no host libvpx-vp9: the VP9 clips are skipped)"
vulkaninfo 2>/dev/null | grep -q VK_KHR_video_decode_h265 || { HEVC=; echo "      (no Vulkan HEVC video decode on this host: the HEVC clips are skipped)"; }
python3 -c "import gi; gi.require_version('Gst', '1.0'); from gi.repository import Gst; Gst.init(None); assert Gst.ElementFactory.find('x265enc')" 2>/dev/null \
    || { HEVC=; echo "      (no GStreamer x265enc: the HEVC clips are skipped)"; }

# the clips: short, small
python3 - "$T" "${HEVC:-0}" <<'PY' || { echo "FAIL  the clips could not be made"; exit 1; }
import sys, gi
gi.require_version('Gst', '1.0')
from gi.repository import Gst
Gst.init(None)
t = sys.argv[1]
clips = {
    'bframes': 'videotestsrc pattern=ball num-buffers=90 ! video/x-raw,width=320,height=240,framerate=30/1 '
               '! x264enc bframes=3 ref=4 key-int-max=30 b-adapt=false ! video/x-h264,profile=high ! h264parse ! mp4mux',
    'cropped': 'videotestsrc pattern=smpte num-buffers=60 ! video/x-raw,width=640,height=360,framerate=30/1 ! timeoverlay '
               '! x264enc bframes=2 ref=3 key-int-max=25 speed-preset=fast ! video/x-h264,profile=high ! h264parse ! mp4mux',
}
if sys.argv[2] == '1':
    clips.update({
    'hevc': 'videotestsrc pattern=ball num-buffers=60 ! video/x-raw,width=320,height=240,framerate=30/1 '
            '! x265enc option-string="bframes=3:ref=4:keyint=30" ! video/x-h265,profile=main ! h265parse ! mp4mux',
    'hevc10': 'videotestsrc pattern=smpte num-buffers=40 ! video/x-raw,width=640,height=360,framerate=30/1 ! timeoverlay ! videoconvert '
              '! video/x-raw,format=I420_10LE ! x265enc option-string="bframes=4:ref=3:keyint=20" ! video/x-h265,profile=main-10 ! h265parse ! mp4mux',
    'hevcsl': 'videotestsrc pattern=ball num-buffers=40 ! video/x-raw,width=352,height=288,framerate=30/1 '
              '! x265enc option-string="bframes=2:scaling-list=default:slices=2" ! video/x-h265,profile=main ! h265parse ! mp4mux',
    })
for name, desc in clips.items():
    p = Gst.parse_launch(desc + ' ! filesink location=%s/%s.mp4' % (t, name))
    p.set_state(Gst.State.PLAYING)
    m = p.get_bus().timed_pop_filtered(60 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
    p.set_state(Gst.State.NULL)
    if not m or m.type != Gst.MessageType.EOS:
        sys.exit(1)
PY

# the VP9 clips (the test FFmpeg decodes VP9 in software too: the references are made there)
if [ -n "$VP9" ]; then
    vf() { timeout 300 ffmpeg -hide_banner -loglevel error -y "$@" </dev/null; }
    vf -f lavfi -i testsrc2=size=320x240:rate=30 -frames:v 40 -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -g 20 -auto-alt-ref 1 -lag-in-frames 10 -pix_fmt yuv420p "$T/vp9.webm" &&
    vf -f lavfi -i testsrc2=size=352x288:rate=30 -frames:v 30 -c:v libvpx-vp9 -deadline good -cpu-used 5 -profile:v 2 -g 15 -auto-alt-ref 1 -lag-in-frames 8 -pix_fmt yuv420p10le "$T/vp9x10.webm" &&
    vf -f lavfi -i "testsrc2=size=640x360:rate=30,noise=alls=15:allf=t" -frames:v 30 -c:v libvpx-vp9 -deadline good -cpu-used 5 -tile-columns 1 -aq-mode 1 -g 30 -pix_fmt yuv420p "$T/vp9tiles.webm" \
        || { echo "FAIL  the VP9 clips could not be made"; exit 1; }
fi

# the AV1 clips, and their frames as dav1d decodes them (the test FFmpeg has no software AV1 decoder)
if [ -n "$AV1" ]; then
    hf() { timeout 300 ffmpeg -hide_banner -loglevel error -y "$@" </dev/null; }
    hf -f lavfi -i testsrc2=size=320x240:rate=30 -frames:v 40 -c:v libaom-av1 -cpu-used 8 -g 20 -lag-in-frames 10 -pix_fmt yuv420p "$T/av1.mp4" &&
    hf -f lavfi -i testsrc2=size=352x288:rate=30 -frames:v 30 -c:v libaom-av1 -cpu-used 8 -g 15 -lag-in-frames 8 -pix_fmt yuv420p10le "$T/av1x10.mp4" &&
    hf -f lavfi -i testsrc2=size=640x360:rate=30 -frames:v 30 -c:v libaom-av1 -cpu-used 8 -tile-columns 1 -tile-rows 1 -g 30 -pix_fmt yuv420p "$T/av1tiles.mp4" &&
    hf -f lavfi -i "testsrc2=size=320x240:rate=30,noise=alls=20:allf=t" -frames:v 30 -c:v libaom-av1 -cpu-used 6 -enable-restoration 1 -g 10 -pix_fmt yuv420p "$T/av1lr.mp4" &&
    hf -f lavfi -i testsrc2=size=480x272:rate=30 -frames:v 48 -c:v libsvtav1 -preset 8 -g 24 -pix_fmt yuv420p10le "$T/av1svt.mp4" 2>/dev/null \
        || { echo "FAIL  the AV1 clips could not be made"; exit 1; }
    for c in av1 av1x10 av1tiles av1lr av1svt; do
        fmt=nv12; case $c in *10|av1svt) fmt=p010le ;; esac
        hf -c:v libdav1d -i "$T/$c.mp4" -pix_fmt $fmt -f framemd5 - 2>/dev/null | awk '/^0,/ {print $NF}' > "$T/$c.sw"
    done
fi

Xvfb -displayfd 3 -screen 0 640x480x24 -nolisten tcp 3>"$T/display" >/dev/null 2>&1 & XP=$!
i=0; while [ ! -s "$T/display" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$T/display" ] || { echo "FAIL  Xvfb did not start"; exit 1; }
export DISPLAY=":$(cat "$T/display")"
timeout -s KILL 300 "$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
cp "$DXVK"/*.dll "$WINEPREFIX/drive_c/windows/system32/"
export WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d;dxgi,d3d11,d3d10core=n"
cp "$FF" "$WINEPREFIX/drive_c/ffmpeg.exe"
cp "$T"/*.mp4 "$WINEPREFIX/drive_c/"
[ -n "$VP9" ] && cp "$T"/*.webm "$WINEPREFIX/drive_c/"
# a Wine that does not offer programs VK_KHR_video_decode_vp9 (before wine-sg 7848) gets no VP9 decoder
if [ -n "$VP9" ]; then
    (cd "$WINEPREFIX/drive_c" && DXVK_LOG_LEVEL=info DXVK_LOG_PATH=none timeout -s KILL 300 "$WINE" ffmpeg.exe -hide_banner -loglevel error \
        -hwaccel d3d11va -i vp9.webm -frames:v 1 -f framemd5 - </dev/null 2>&1) | grep -q "video decode VP9 profile 0" \
        || { VP9=; echo "      (this Wine does not offer VK_KHR_video_decode_vp9 to programs -- wine-sg 7848: the VP9 clips are skipped)"; }
fi

CLIPS="bframes cropped${HEVC:+ hevc hevc10 hevcsl}${AV1:+ av1 av1x10 av1tiles av1lr av1svt}${VP9:+ vp9 vp9x10 vp9tiles}"
for c in $CLIPS; do
    fmt=nv12; case $c in hevc10|av1x10|av1svt|vp9x10) fmt=p010le ;; esac   # 10-bit: P010 surfaces
    f=$c.mp4; case $c in vp9*) f=$c.webm ;; esac
    (cd "$WINEPREFIX/drive_c" && DXVK_LOG_LEVEL=none timeout -s KILL 300 "$WINE" ffmpeg.exe -hide_banner -loglevel error \
        -hwaccel d3d11va -hwaccel_output_format d3d11 -i "$f" -vf hwdownload,format=$fmt -f framemd5 - 2>"$T/$c.hw.err" </dev/null) \
        | tr -d '\r' | awk '/^0,/ {print $NF}' > "$T/$c.hw"
    case $c in av1*) ;; *)   # the AV1 references are dav1d's (above)
    (cd "$WINEPREFIX/drive_c" && timeout -s KILL 300 "$WINE" ffmpeg.exe -hide_banner -loglevel error \
        -i "$f" -pix_fmt $fmt -f framemd5 - 2>/dev/null </dev/null) | tr -d '\r' | awk '/^0,/ {print $NF}' > "$T/$c.sw" ;;
    esac
    hw=$(wc -l < "$T/$c.hw"); sw=$(wc -l < "$T/$c.sw")
    diff=$(paste "$T/$c.hw" "$T/$c.sw" | awk '$1 != $2' | wc -l)
    if [ "$sw" -gt 0 ] && [ "$hw" = "$sw" ] && [ "$diff" = 0 ]; then
        pass "$c: $hw frames decoded by the GPU through D3D11VA, each the same as the software decoder's"
    else
        fail "$c: D3D11VA gave $hw frames ($diff different) of $sw; $(tr -d '\r' < "$T/$c.hw.err" | grep -v '^$' | sort -u | head -2 | tr '\n' ' ')"
    fi
done

# d3d11.videoDecode = False (dxvk.conf; Auto offers decoders only on drivers they were proven on):
# no decoder is offered, the program decodes on the CPU
(cd "$WINEPREFIX/drive_c" && DXVK_LOG_LEVEL=none DXVK_CONFIG="d3d11.videoDecode = False" timeout -s KILL 300 "$WINE" ffmpeg.exe -hide_banner \
    -loglevel error -hwaccel d3d11va -hwaccel_output_format d3d11 -i bframes.mp4 -vf hwdownload,format=nv12 -f framemd5 - 2>"$T/off.err" </dev/null) \
    | tr -d '\r' | awk '/^0,/ {print $NF}' > "$T/off.hw"
if [ ! -s "$T/off.hw" ] && grep -q "hwaccel initialisation returned error\|Failed to get the decoder" "$T/off.err"; then
    pass "d3d11.videoDecode = False: no decoder is offered (the program would decode on the CPU)"
else
    fail "d3d11.videoDecode = False: $(wc -l < "$T/off.hw") frames came from a decoder"
fi

[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
