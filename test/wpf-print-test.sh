#!/bin/sh
# WPF printing under our Wine Mono (sg40, mono/patches/wpf-0009): every WPF
# program's Print threw NotImplementedException (PrintDialog.PrintVisual and
# PrintDocument -> PrintQueue.CreateXpsDocumentWriter, System.Printing's
# XpsDocumentWriter, the print ticket provider's SafeMemoryHandle). Now, as on
# the .NET Framework, a printer that is not an XPS device gets ReachFramework's
# NGC serialization manager, which flattens each page and prints it through the
# printer's GDI driver (CreateDC with the ticket's DEVMODE, StartDoc, a page per
# page). test/wpf-print-probe.cs, compiled with the packaged Mono's mcs and run
# on a private Xvfb, prints to a Wine PostScript printer whose port is a file,
# and the PostScript is rendered with Ghostscript:
#   - PrintDialog.PrintVisual: one page, a 2-inch blue square where it was put
#     (3 in, 3 in from the paper's corner), white elsewhere;
#   - XpsDocumentWriter.Write(Visual) asks the program for the document
#     sequence's, the document's and the page's tickets, in order;
#   - PrintDialog.PrintDocument of a FlowDocument: its pages (4);
#   - a FixedDocument (3 pages), a visuals collator (2 pages), WriteAsync with
#     progress and WritingCompleted carrying the program's state (2 pages);
#   - an XPS file is written (XpsDocument.CreateXpsDocumentWriter: fonts
#     embedded whole, PresentationCore had no subsetter), read back, and
#     printed (Write(path)) without the program dying in a finalizer.
#   - text is printed as text (sg41): PrintVisual's line and the FlowDocument's
#     paragraphs come out of the printer's font calls, so the PDF ghostscript
#     makes of the job can be searched (pdftotext reads them back); they were
#     part of a page-sized image.
#
#   test/wpf-print-test.sh [WINE]      (needs make mono-deb first; Xvfb, gs, mingw-w64)
# Mutation: sg39 fails every check (NotImplementedException); System.Printing
# built with -d:SG_MUTANT_GDI_NO_PAGE (pages sent blank) fails the square
# checks; PresentationCore with -d:SG_MUTANT_NO_WHOLE_FACE (no font for the XPS
# file) or -d:SG_MUTANT_PINNED_FREE_TWICE fails the XPS checks; System.Printing
# with -d:SG_MUTANT_GDI_TEXT_RASTER (text left in the image, sg40) fails the
# text checks.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE=${1:-/opt/wine-sg/bin/wine}
WINESERVER="$(dirname "$WINE")/wineserver"
[ -x "$WINESERVER" ] || WINESERVER="$(dirname "$WINE")/server/wineserver"   # a build tree
MONO=$(ls -d "${SG_MONO_DIR:-$HERE/build/mono-deb-root/usr/share/wine/mono}"/wine-mono-* 2>/dev/null | head -1)
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -n "$MONO" ] || { echo "SKIP: no packaged Wine Mono (make mono-deb)"; exit 77; }
command -v Xvfb >/dev/null || { echo "SKIP: Xvfb not installed"; exit 77; }
command -v gs >/dev/null || { echo "SKIP: ghostscript not installed"; exit 77; }
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "SKIP: mingw-w64 not installed"; exit 77; }
MONO=$(CDPATH='' cd -- "$MONO" && pwd)
unset WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS
T=$(mktemp -d /var/tmp/sg-wpfprint.XXXXXX)
export HOME="$T/home" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mshtml=;winemenubuilder.exe=d"
# never the person's live desktop: Wine's Wayland driver connects to $XDG_RUNTIME_DIR/wayland-0 (2026-11-16)
export XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=sg-no-wayland XDG_DATA_DIRS=/usr/local/share:/usr/share
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
n=180; while [ -e "/tmp/.X$n-lock" ] || [ -e "/tmp/.X11-unix/X$n" ]; do n=$((n + 1)); done
Xvfb ":$n" -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 & XP=$!
export DISPLAY=":$n"
cleanup() {
    "$WINESERVER" -k 2>/dev/null
    # and whatever of the prefix outlived its server (orphaned winedevice.exe)
    for p in /proc/[0-9]*; do
        [ -O "$p" ] || continue
        [ "$({ tr '\0' '\n' < "$p/environ"; } 2>/dev/null | sed -n 's/^WINEPREFIX=//p')" = "$WINEPREFIX" ] && kill -9 "${p#/proc/}" 2>/dev/null
    done
    kill "$XP" 2>/dev/null
    [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"
}
trap cleanup EXIT INT TERM
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

"$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
"$WINE" reg add 'HKCU\Software\Wine\Mono' /v RuntimePath /d "$("$WINE" winepath -w "$MONO" | tr -d '\r')" /f >/dev/null 2>&1
C="$WINEPREFIX/drive_c"
PS="$T/printed.ps"
# a printer on Wine's PostScript driver whose port is a file (localspl writes the job there)
cat > "$T/addprn.c" <<'C'
#include <windows.h>
#include <winspool.h>
int wmain(int argc, WCHAR **argv)
{
    DRIVER_INFO_3W di = {0};
    PRINTER_INFO_2W pi = {0};
    HANDLE h;
    if (argc < 3) return 2;
    di.cVersion = 3; di.pName = (WCHAR *)L"SG Letter PS";
    di.pDriverPath = di.pConfigFile = (WCHAR *)L"wineps.drv"; di.pDataFile = (WCHAR *)L"C:\\letter.ppd";
    di.pDefaultDataType = (WCHAR *)L"RAW";
    AddPrinterDriverExW(NULL, 3, (BYTE *)&di, APD_COPY_NEW_FILES | APD_COPY_FROM_DIRECTORY);
    pi.pPrinterName = argv[1]; pi.pDriverName = di.pName; pi.pPortName = argv[2];
    pi.pPrintProcessor = (WCHAR *)L"wineps"; pi.pDatatype = (WCHAR *)L"RAW";
    pi.pParameters = pi.pShareName = pi.pSepFile = (WCHAR *)L"";
    h = AddPrinterW(NULL, 2, (BYTE *)&pi);
    if (h) ClosePrinter(h);
    return !h;
}
C
cat > "$C/letter.ppd" <<'PPD'
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName: "SGLETTER.PPD"
*Manufacturer: "SG"
*ModelName: "SG Letter PS"
*NickName: "SG Letter PS"
*DefaultResolution: 300dpi
*OpenUI *PageSize: PickOne
*DefaultPageSize: Letter
*PageSize Letter/Letter: "<</PageSize[612 792]>>setpagedevice"
*CloseUI: *PageSize
*DefaultImageableArea: Letter
*ImageableArea Letter/Letter: "18 18 594 774"
*DefaultPaperDimension: Letter
*PaperDimension Letter/Letter: "612 792"
PPD
x86_64-w64-mingw32-gcc -municode -O1 -o "$C/addprn.exe" "$T/addprn.c" -lwinspool || { fail "the printer adder did not build"; exit 1; }
(cd "$C" && timeout 120 "$WINE" addprn.exe "WPF desk" "$PS" >/dev/null 2>&1) || { fail "the test printer was not added"; exit 1; }

cp "$HERE/test/wpf-print-probe.cs" "$C/probe.cs"
w() { "$WINE" winepath -w "$1" | tr -d '\r'; }
G="$MONO/lib/mono/gac"
refs="-r:System.Core.dll"
for a in PresentationFramework PresentationCore WindowsBase System.Xaml System.Printing ReachFramework; do
    f=$(ls "$G/$a"/*/"$a.dll" 2>/dev/null | head -1)
    [ -n "$f" ] || { fail "no $a in the packaged Mono"; exit 1; }
    refs="$refs -r:$(w "$f")"
done
mcs=$(w "$MONO/lib/mono/4.5/mcs.exe")
# shellcheck disable=SC2086
(cd "$C" && timeout 300 "$WINE" "$mcs" $refs -out:probe.exe probe.cs >"$T/mcs.out" 2>&1)
[ -f "$C/probe.exe" ] || { fail "the probe did not compile: $(cat "$T/mcs.out")"; exit 1; }

# check FILE.ps: its page count, and page 1 rendered at 20 dpi -- blue at (3 in, 3 in), white at (1 in, 4 in),
# the line of text at (2 in, 1 in)
cat > "$T/check.py" <<'PY'
import subprocess, sys, os
ps, ppm = sys.argv[1], sys.argv[2]
pages = open(ps, 'rb').read().count(b'\n%%Page:')
subprocess.run(['gs', '-q', '-dSAFER', '-dNOPAUSE', '-dBATCH', '-sDEVICE=ppmraw', '-r20', '-dFirstPage=1', '-dLastPage=1',
                '-sOutputFile=' + ppm, ps], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
res = 'unrendered'
try:
    b = open(ppm, 'rb').read()
    fields, pos = [], 0
    while len(fields) < 4:
        while b[pos:pos + 1].isspace(): pos += 1
        if b[pos:pos + 1] == b'#':
            pos = b.index(b'\n', pos) + 1
            continue
        end = pos
        while not b[end:end + 1].isspace(): end += 1
        fields.append(b[pos:end]); pos = end
    w = int(fields[1]); data = b[pos + 1:]
    px = lambda x, y: tuple(data[(y * w + x) * 3:(y * w + x) * 3 + 3])
    blue, white = px(60, 60), px(20, 80)
    # the line of text 1 in from the top, from 2 in: ink there, where it was put
    ink = sum(1 for y in range(19, 28) for x in range(40, 70) if max(px(x, y)) < 128)
    res = ('blue' if blue[2] > 200 and blue[0] < 60 and blue[1] < 60 else 'noblue%s' % (blue,)) + '+' + \
          ('white' if min(white) > 230 else 'nowhite%s' % (white,)) + '+' + ('text' if ink >= 5 else 'notext%d' % ink)
except Exception as e:
    res = 'error ' + str(e)
print('%d %s' % (pages, res))
PY
run() {
    rm -f "$PS"
    out=$(cd "$C" && timeout -s KILL 180 "$WINE" probe.exe "$1" "WPF desk" 'C:\printed.xps' 2>&1 | tr -d '\r')
    printed=$([ -s "$PS" ] && python3 "$T/check.py" "$PS" "$T/page.ppm" || echo "0 nothing")
}
v() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
# the job's text as a PDF reader sees it (ghostscript makes the PDF, as CUPS's Print to PDF does)
text() {
    rm -f "$T/printed.pdf"
    [ -s "$PS" ] && gs -q -dSAFER -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -sOutputFile="$T/printed.pdf" "$PS" >/dev/null 2>&1
    [ -s "$T/printed.pdf" ] && command -v pdftotext >/dev/null && pdftotext "$T/printed.pdf" - 2>/dev/null | tr -s ' \n' '  '
}

run visual
[ "$(v visual)" = ok ] && [ "$printed" = "1 blue+white+text" ] \
    && pass "PrintDialog.PrintVisual prints one page, the square where it was put" \
    || fail "PrintVisual: '$(v visual)', printed '$printed' (sg39: NotImplementedException)"
if command -v pdftotext >/dev/null; then
    words=$(text)
    case "$words" in *"Stained Glass WPF print"*) pass "PrintVisual's text is text (the PDF can be searched)" ;;
        *) fail "PrintVisual's text is not text: pdftotext read '$(printf '%.80s' "$words")'" ;; esac
fi
run writer
[ "$(v writer)" = "ok FixedDocumentSequence1 FixedDocument1 FixedPage1" ] && [ "$printed" = "1 blue+white+text" ] \
    && pass "XpsDocumentWriter.Write(Visual) asks for the sequence's, document's and page's tickets and prints" \
    || fail "Write(Visual): '$(v writer)', printed '$printed'"
run flow
[ "$(v flow)" = ok ] && [ "${printed%% *}" = 4 ] \
    && pass "PrintDialog.PrintDocument prints a FlowDocument's 4 pages" || fail "PrintDocument: '$(v flow)', printed '$printed'"
if command -v pdftotext >/dev/null; then
    words=$(text)
    case "$words" in *"Paragraph 1 of a FlowDocument."*"Paragraph 90 of a FlowDocument."*)
        pass "a FlowDocument's paragraphs are text, first to last" ;;
        *) fail "the FlowDocument's text is not text: pdftotext read '$(printf '%.80s' "$words")'" ;; esac
fi
run fixed
[ "$(v fixed)" = ok ] && [ "$printed" = "3 blue+white+text" ] \
    && pass "a FixedDocument's 3 pages" || fail "FixedDocument: '$(v fixed)', printed '$printed'"
run collator
[ "$(v collator)" = ok ] && [ "$printed" = "2 blue+white+text" ] \
    && pass "a visuals collator's 2 pages" || fail "collator: '$(v collator)', printed '$printed'"
run async
[ "$(v async)" = "ok state progress" ] && [ "$printed" = "2 blue+white+text" ] \
    && pass "WriteAsync: progress, WritingCompleted with the program's state, 2 pages" \
    || fail "WriteAsync: '$(v async)', printed '$printed'"
run xps
[ "$(v xpsfile)" = 2 ] && pass "an XPS file is written and read back (2 pages)" || fail "XPS file: '$(v xpsfile)' $(v xps)"
[ "$(v xps)" = ok ] && [ "$printed" = "2 blue+white+text" ] && ! printf '%s\n' "$out" | grep -q 'Unhandled Exception' \
    && pass "and printed (XpsDocumentWriter.Write(path)), the program ending cleanly" \
    || fail "XPS print: '$(v xps)', printed '$printed' $(printf '%s\n' "$out" | grep -m1 Exception)"
[ "$RC" = 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; printf '%s\n' "$out" | head -20; }
exit "$RC"
