#!/bin/sh
# WPF's flow layout under our Wine Mono (mono/patches/wpf-*.patch): rich text
# -- FlowDocument, RichTextBox, FlowDocumentScrollViewer/Reader -- needs PTS,
# which Wine Mono's PresentationNative does not have (Sonos Desktop
# Controller: EntryPointNotFoundException, CreateInstalledObjectsInfo, David
# 2026-10-02); wpf-0001 is our managed PTS engine, wpf-0002 what the managed
# TextFormatter lacked for it. test/wpf-flow-probe.cs, compiled with the
# packaged Mono's mcs and run on a private Xvfb:
#   - a RichTextBox's blocks (paragraphs, a list, a section, a
#     BlockUIContainer) are laid out in order, a paragraph wraps;
#   - the list's bullets are drawn;
#   - an edit (a paragraph inserted) moves what follows down;
#   - a FlowDocument paginated at 300 x 200 has several pages;
#   - an inline control (InlineUIContainer) sits in its line;
#   - centred text is centred (a paragraph and FormattedText);
#   - 500 paragraphs lay out in under 3 s (SG_WPF_LONG_MS);
#   - right-to-left text starts at the right (a TextBlock, a paragraph's
#     caret);
#   - a table: cells of a row side by side at one height, a cell spanning
#     two rows as high as they are, what follows below it; a long table
#     paginated breaks between rows over several pages;
#   - no exception anywhere.
#
#   test/wpf-flow-test.sh [WINE]      (needs make mono-deb first)
# Mutation: sg2 (no wpf patches) fails at once (EntryPointNotFoundException);
# PresentationFramework/PresentationCore built with -define:SG_MUTANT_PTS_NO_BREAK,
# SG_MUTANT_PTS_NO_TABLE, SG_MUTANT_NO_MARKER, SG_MUTANT_NO_EMBED_CACHE,
# SG_MUTANT_NO_ALIGN, SG_MUTANT_TF_RESHAPE or SG_MUTANT_TF_NO_RTL each fail
# their check (SG_MONO_DIR= a Mono tree with the mutant assemblies in its GAC).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE=${1:-/opt/wine-sg/bin/wine}
WINESERVER="$(dirname "$WINE")/wineserver"
MONO=$(ls -d "${SG_MONO_DIR:-$HERE/build/mono-deb-root/usr/share/wine/mono}"/wine-mono-* 2>/dev/null | head -1)
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -n "$MONO" ] || { echo "SKIP: no packaged Wine Mono (make mono-deb)"; exit 77; }
command -v Xvfb >/dev/null || { echo "SKIP: Xvfb not installed"; exit 77; }
unset WAYLAND_DISPLAY
T=$(mktemp -d /var/tmp/sg-wpfflow.XXXXXX)
export HOME="$T/home" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mshtml=;winemenubuilder.exe=d"
mkdir -p "$HOME"
n=170; while [ -e "/tmp/.X$n-lock" ]; do n=$((n + 1)); done
Xvfb ":$n" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 & XP=$!
export DISPLAY=":$n"
trap '"$WINESERVER" -k 2>/dev/null; kill $XP 2>/dev/null; rm -rf "$T"' EXIT INT TERM
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

"$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
"$WINE" reg add 'HKCU\Software\Wine\Mono' /v RuntimePath /d "$("$WINE" winepath -w "$MONO" | tr -d '\r')" /f >/dev/null 2>&1
C="$WINEPREFIX/drive_c"
cp "$HERE/test/wpf-flow-probe.cs" "$C/probe.cs"
w() { "$WINE" winepath -w "$1" | tr -d '\r'; }
G="$MONO/lib/mono/gac"
refs=""
for a in PresentationFramework PresentationCore WindowsBase System.Xaml; do
    f=$(ls "$G/$a"/*/"$a.dll" 2>/dev/null | head -1)
    [ -n "$f" ] || { fail "no $a in the packaged Mono"; exit 1; }
    refs="$refs -r:$(w "$f")"
done
mcs=$(w "$MONO/lib/mono/4.5/mcs.exe")
# shellcheck disable=SC2086
(cd "$C" && timeout 300 "$WINE" "$mcs" $refs -out:probe.exe probe.cs >"$T/mcs.out" 2>&1)
[ -f "$C/probe.exe" ] || { fail "the probe did not compile: $(cat "$T/mcs.out")"; exit 1; }
(cd "$C" && timeout 300 "$WINE" probe.exe 'C:\' >"$T/out" 2>&1)

if grep -q "Exception" "$T/out"; then
    fail "an exception: $(grep -m1 "Exception" "$T/out" | cut -c1-200)"
fi
grep -q "^BOTTOMLESS ordered" "$T/out" && pass "a RichTextBox's paragraphs, list, section and BlockUIContainer are laid out in order" \
    || fail "layout: $(grep -m1 BOTTOMLESS "$T/out")"
h=$(sed -n 's/^BOTTOMLESS .* firstParaHeight \([0-9.]*\).*/\1/p' "$T/out"); [ "${h%.*}" -ge 30 ] 2>/dev/null && pass "a long paragraph wraps (first paragraph ${h} px high)" || fail "first paragraph ${h:-?} px"
b=$(sed -n 's/^BULLETS dark \([0-9]*\).*/\1/p' "$T/out"); [ "${b:-0}" -ge 4 ] && pass "the list's bullets are drawn ($b dark pixels)" || fail "no bullets (${b:-?})"
m=$(sed -n 's/^UPDATE moved \([0-9.-]*\).*/\1/p' "$T/out"); [ "${m%.*}" -ge 10 ] 2>/dev/null && pass "an edit moves what follows down (${m} px)" || fail "edit: ${m:-?}"
p=$(sed -n 's/^PAGES \([0-9]*\).*/\1/p' "$T/out"); [ "${p:-0}" -ge 3 ] && pass "a FlowDocument at 300 x 200 has $p pages" || fail "pages: ${p:-?}"
x=$(sed -n 's/^INLINE checkX \([0-9.-]*\).*/\1/p' "$T/out"); [ "${x%.*}" -ge 50 ] 2>/dev/null && pass "an inline control sits in its line (x ${x})" || fail "inline control: ${x:-?}"
c=$(sed -n 's/^FLOW centredX \([0-9.-]*\).*/\1/p' "$T/out"); [ "${c%.*}" -ge 100 ] 2>/dev/null && pass "a centred paragraph is centred (x ${c})" || fail "centred paragraph at x ${c:-?}"
f=$(sed -n 's/^FORMATTEDTEXT boundsX \([0-9.-]*\).*/\1/p' "$T/out"); [ "${f%.*}" -ge 100 ] 2>/dev/null && pass "and centred FormattedText (x ${f})" || fail "centred FormattedText at x ${f:-?}"
# shellcheck disable=SC2046  # six numbers, split on purpose
set -- $(sed -n 's/^TABLE r0c0 \([0-9.]*\) r0c1 \([0-9.]*\) r1c1 \([0-9.]*\) r2c0 \([0-9.]*\) c1x \([0-9.]*\) after \([0-9.]*\).*/\1 \2 \3 \4 \5 \6/p' "$T/out")
if [ $# = 6 ] && [ "${1%.*}" = "${2%.*}" ] && [ "${3%.*}" -gt "${2%.*}" ] && [ "${4%.*}" -ge $(( ${3%.*} + 25 )) ] \
   && [ "${5%.*}" -ge 100 ] && [ "${6%.*}" -gt "${4%.*}" ]; then
    pass "a table: a row's cells side by side (y $1, x $5), the next row below (y $3), a two-row cell pushes the third down (y $4), text after it below (y $6)"
else
    fail "table: $(grep -m1 "^TABLE " "$T/out")"
fi
tp=$(sed -n 's/^TABLEPAGES \([0-9]*\).*/\1/p' "$T/out"); [ "${tp:-0}" -ge 3 ] && pass "a 40-row table at 300 x 200 breaks between rows over $tp pages" || fail "table pages: ${tp:-?}"
r=$(sed -n 's/^RTLTEXTBLOCK left \([0-9]*\) right \([0-9]*\).*/\1 \2/p' "$T/out")
case "$r" in "0 "[1-9]*) pass "a right-to-left TextBlock's text is at its right (ink left/right: $r)";;
             *) fail "right-to-left TextBlock ink left/right: '${r:-?}' (drew at the left)";; esac
x=$(sed -n 's/^FLOW centredX [0-9.]* rtlX \([0-9.]*\).*/\1/p' "$T/out")
[ "${x%.*}" -ge 250 ] 2>/dev/null && pass "a right-to-left paragraph's caret is at its text, on the right (x $x)" || fail "right-to-left caret at x ${x:-?}"
# speed: the managed TextFormatter shaped each prefix of a line again while
# searching its break (4.6 s for these 500 paragraphs on the dev host);
# shaped once per run it takes about 1.3 s
l=$(sed -n 's/^LONG ms \([0-9]*\).*/\1/p' "$T/out")
[ -n "$l" ] && [ "$l" -lt "${SG_WPF_LONG_MS:-3000}" ] && pass "500 paragraphs laid out in $l ms" || fail "500 paragraphs took ${l:-?} ms (limit ${SG_WPF_LONG_MS:-3000})"
[ "$RC" = 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; sed -n 1,30p "$T/out" | cut -c1-200; }
exit "$RC"
