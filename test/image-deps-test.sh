#!/bin/sh
# Every dependency of our packages staged for the image is in the image: the
# image installs them with dpkg, not apt, so a dependency that is neither one
# of ours nor in mkosi.conf's package list fails the image build at its end
# (2026-10-02: librsvg2-common for sg-gtk-theme, spice-vdagent for
# sg-session). Run before mkosi; also on its own: sh test/image-deps-test.sh
# [DIR-of-debs].
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DIR="${1:-$HERE/build/extra-tree/opt/sg-packages}"
RC=0
ls "$DIR"/*.deb >/dev/null 2>&1 || { echo "SKIP: no staged packages in $DIR"; exit 77; }
command -v apt-get >/dev/null || { echo "SKIP: no apt-get"; exit 77; }
# what the image has: what apt installs for mkosi.conf's packages (resolved
# from nothing installed, recommends left out, as mkosi does), and ours (and
# what ours provide)
have=$(mktemp); empty=$(mktemp); trap 'rm -f "$have" "$empty"' EXIT
apt-get -s -o Dir::State::Status="$empty" --no-install-recommends install \
    $(sed -n 's/^        \([a-z0-9][a-z0-9.+-]*\)$/\1/p' "$HERE/mkosi.conf") 2>/dev/null \
    | sed -n 's/^Inst \([^ :]*\).*/\1/p' > "$have"
[ -s "$have" ] || { echo "SKIP: apt could not resolve mkosi.conf's packages here"; exit 77; }
for d in "$DIR"/*.deb; do
    dpkg-deb -f "$d" Package >> "$have"
    dpkg-deb -f "$d" Provides | tr ',' '\n' | sed 's/(.*//; s/ //g' | grep . >> "$have"
done
for d in "$DIR"/*.deb; do
    pkg=$(dpkg-deb -f "$d" Package)
    dpkg-deb -f "$d" Depends | tr ',' '\n' | while IFS= read -r alt; do
        # one of "a | b" is enough; ${...} substitutions were resolved at build time
        ok=0
        for one in $(echo "$alt" | tr '|' '\n' | sed 's/(.*//; s/:any//; s/ //g'); do
            grep -qx "$one" "$have" && ok=1
        done
        [ "$ok" = 1 ] || [ -z "$(echo "$alt" | tr -d ' ')" ] || echo "FAIL  $pkg depends on '$(echo "$alt" | sed 's/^ *//')', which the image does not install"
    done
done > "$have.out"
if [ -s "$have.out" ]; then cat "$have.out"; RC=1; fi
rm -f "$have.out"
[ "$RC" = 0 ] && echo "image-deps-test: PASS (every dependency of our packages is in the image)" || echo "image-deps-test: FAIL"
exit "$RC"
