#!/bin/sh
# Build the elevated-display gate's fixtures on the host (ADR 0012, B56):
#   sg-test-setup.exe  a real NSIS installer (requireAdministrator): a first
#                      page whose text box takes a typed word, then installs
#                      sg-test-app.exe to Program Files with an all-users Start
#                      menu shortcut and an Add/Remove Programs entry.
#   sg-runas.exe       ShellExecute "runas" on its argument (Run as
#                      administrator), so the installer reaches the broker.
#   sg-xadversary      a session-side attacker: XTEST, XSendEvent and XGetImage
#                      against the elevated installer's window and display.
# Needs makensis, x86_64-w64-mingw32-gcc and cc with libX11/libXtst.
set -e
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
OUT="${1:-$HERE}"
mkdir -p "$OUT"
for t in makensis x86_64-w64-mingw32-gcc cc; do command -v "$t" >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
x86_64-w64-mingw32-gcc -O2 -municode -mwindows -o "$OUT/sg-test-app.exe" "$HERE/sg-test-app.c"
x86_64-w64-mingw32-gcc -O2 -municode -mwindows -o "$OUT/sg-runas.exe" "$HERE/sg-runas.c"
( cd "$OUT" && cp "$HERE/sg-test-setup.nsi" . && makensis -V2 sg-test-setup.nsi )
cc -O2 -o "$OUT/sg-xadversary" "$HERE/sg-xadversary.c" -lX11 -lXtst
echo "fixtures in $OUT"
