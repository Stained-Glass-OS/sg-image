#!/bin/sh
# Direct3D 11 video decoders through DXVK on Vulkan Video (dxvk/patches/0006). Programs that decode
# video themselves -- Chromium and Electron programs, Firefox, VLC, mpv -- ask Direct3D 11 for a video
# decoder (D3D11VA); DXVK had none, so they all decoded on the CPU. The client here is an FFmpeg built
# from source for the purpose (test/ffmpeg-d3d11va-build.sh): it decodes short H.264 clips made by
# GStreamer's x264 -- High profile, B-frames, several references, a picture size that is cropped --
# and x265 -- HEVC Main with B-frames, Main 10 (P010 output), scaling lists and two slices a picture --
# through D3D11VA (frames kept on the GPU, so no quiet fall back to the CPU), and every frame must be
# bit for bit the frame its own software decoder gives (framemd5).
#
#   test/videodecode-test.sh [DXVK_X64_DIR]   (FFMPEG_D3D11VA=ffmpeg.exe; default DXVK: the staged payload)
#
# Host test: wine-sg (/opt/wine-sg or $WINE), Xvfb, python3 GStreamer bindings with x264enc, and a GPU
# whose Vulkan driver decodes H.264 (VK_KHR_video_decode_h264); skips (77) without them. The HEVC
# clips need x265enc and VK_KHR_video_decode_h265, and are skipped (said so) without them. Headless:
# its own Xvfb, a private runtime directory, nothing on anybody's screen.
# Then with d3d11.videoDecode = False (DXVK_CONFIG): no decoder offered. Auto (the default) offers them
# only on NVIDIA's driver, where they were proven; True on any driver, for testing.
# Mutant (dxvk/patches/0006, d3d11_video_decoder.cpp): SG_MUTANT_NO_VIDEO_DECODE.
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
HEVC=1
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

Xvfb -displayfd 3 -screen 0 640x480x24 -nolisten tcp 3>"$T/display" >/dev/null 2>&1 & XP=$!
i=0; while [ ! -s "$T/display" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -s "$T/display" ] || { echo "FAIL  Xvfb did not start"; exit 1; }
export DISPLAY=":$(cat "$T/display")"
timeout -s KILL 300 "$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
cp "$DXVK"/*.dll "$WINEPREFIX/drive_c/windows/system32/"
export WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d;dxgi,d3d11,d3d10core=n"
cp "$FF" "$WINEPREFIX/drive_c/ffmpeg.exe"
cp "$T"/*.mp4 "$WINEPREFIX/drive_c/"

CLIPS="bframes cropped${HEVC:+ hevc hevc10 hevcsl}"
for c in $CLIPS; do
    fmt=nv12; [ "$c" = hevc10 ] && fmt=p010le   # Main 10: P010 surfaces
    (cd "$WINEPREFIX/drive_c" && DXVK_LOG_LEVEL=none timeout -s KILL 300 "$WINE" ffmpeg.exe -hide_banner -loglevel error \
        -hwaccel d3d11va -hwaccel_output_format d3d11 -i "$c.mp4" -vf hwdownload,format=$fmt -f framemd5 - 2>"$T/$c.hw.err" </dev/null) \
        | tr -d '\r' | awk '/^0,/ {print $NF}' > "$T/$c.hw"
    (cd "$WINEPREFIX/drive_c" && timeout -s KILL 300 "$WINE" ffmpeg.exe -hide_banner -loglevel error \
        -i "$c.mp4" -pix_fmt $fmt -f framemd5 - 2>/dev/null </dev/null) | tr -d '\r' | awk '/^0,/ {print $NF}' > "$T/$c.sw"
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
