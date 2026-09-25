#!/bin/bash
# Package voice typing's speech model as a .deb: sg-speech-model-parakeet.
#
#   speech-model/build-deb.sh SG_SESSION_DIR CACHE_DIR OUT_DIR
#
# Parakeet TDT 0.6B v3 (NVIDIA, int8 ONNX export by istupakov; CC BY 4.0) and
# Silero VAD v5 (MIT), 642 MB. The weights are never in git: they are fetched
# at build time from the pinned revisions in sg-session's sgspeech.FILES, each
# checked by size and SHA-256 by sg-dictate's own fetch_model, into CACHE_DIR
# (kept between builds), then packaged under
# /usr/share/stained-glass-speech/<model>/ with the stamp (.verified) that
# marks a complete model. sg-session looks there before the copy sg-speechd
# downloads into /var/lib/stained-glass-speech.
#
# The version is the model's: upstream revision date + our packaging revision.
# A different FILES list must come with a new version (the repository refuses
# changed contents under an unchanged version).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
SESSION=${1:?usage: build-deb.sh SG_SESSION_DIR CACHE_DIR OUT_DIR}
CACHE=${2:?usage}
OUT=${3:?usage}
PKG=sg-speech-model-parakeet
VERSION=0.6b.v3+20250801-1
log() { echo "[speech-model] $*"; }

mkdir -p "$CACHE" "$OUT"
CACHE=$(cd "$CACHE" && pwd)
log "fetching and verifying the model (cached in $CACHE)"
SG_SPEECH_DIR="$CACHE" SG_SPEECH_LIB="$SESSION/speech" python3 -c '
import runpy, sys
g = runpy.run_path(sys.argv[1], run_name="sg_image")
g["fetch_model"](lambda done, total: None)' "$SESSION/speech/sg-dictate"
MODEL_NAME=$(SG_SPEECH_LIB="$SESSION/speech" python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import sgspeech; print(sgspeech.MODEL_NAME)' "$SESSION/speech")
[[ -f "$CACHE/$MODEL_NAME/.verified" ]] || { echo "build-deb: the model did not verify" >&2; exit 1; }

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-speech-deb.XXXXXX")
trap 'rm -rf "$W"' EXIT
R="$W/root"
dest="$R/usr/share/stained-glass-speech/$MODEL_NAME"
mkdir -p "$dest" "$R/DEBIAN" "$R/usr/share/doc/$PKG"
cp -a "$CACHE/$MODEL_NAME/." "$dest/"
rm -f "$dest"/*.part
chmod -R u=rwX,go=rX "$R/usr"

cat > "$R/usr/share/doc/$PKG/copyright" <<'EOF'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: Parakeet TDT 0.6B v3 (int8 ONNX); Silero VAD
Source: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
 https://huggingface.co/istupakov/parakeet-tdt-0.6b-v3-onnx
 https://github.com/snakers4/silero-vad

Files: usr/share/stained-glass-speech/*/encoder-model.int8.onnx
 usr/share/stained-glass-speech/*/decoder_joint-model.int8.onnx
 usr/share/stained-glass-speech/*/vocab.txt
 usr/share/stained-glass-speech/*/config.json
Copyright: NVIDIA Corporation (model); ONNX export by istupakov
License: CC-BY-4.0
 Creative Commons Attribution 4.0 International.
 https://creativecommons.org/licenses/by/4.0/legalcode
 Changes: converted to ONNX and quantized to int8 by istupakov; not modified
 by Stained Glass OS.

Files: usr/share/stained-glass-speech/*/silero_vad.onnx
Copyright: Silero Team
License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
EOF

size=$(du -sk "$R/usr" | cut -f1)
cat > "$R/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: all
Section: sound
Priority: optional
Maintainer: Stained Glass OS <ke7oxh@gmail.com>
Installed-Size: $size
Enhances: sg-session
Description: speech recognition model for Stained Glass OS voice typing
 NVIDIA Parakeet TDT 0.6B v3 (int8 ONNX, CC BY 4.0) with Silero VAD (MIT):
 the model behind Win+H voice typing, installed so it works offline from the
 first boot instead of being downloaded on first use.
EOF

deb="$OUT/${PKG}_${VERSION}_all.deb"
rm -f "$OUT/${PKG}_"*.deb
# The weights are already dense: zstd at a low level costs little and saves
# a little; xz would take minutes for nothing.
dpkg-deb --root-owner-group -Zzstd -z3 --build "$R" "$deb" >/dev/null
log "built $deb ($(du -h "$deb" | cut -f1))"
