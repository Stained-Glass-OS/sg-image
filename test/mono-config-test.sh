#!/bin/sh
# Wine Mono with the image's fixes (mono/mono-fixes.sh) runs a WinForms
# program whose .config has <System.Windows.Forms.ApplicationConfigurationSection>
# (Greenshot's DPI awareness); unfixed Mono stops with "Unrecognized
# configuration section". The program is compiled here with Mono's own
# mcs.exe, under Wine; the image's addons tree is the Mono that runs it.
#
#   test/mono-config-test.sh [WINE]     (needs make addons first)
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE=${1:-/opt/wine-sg/bin/wine}
WINESERVER="$(dirname "$WINE")/wineserver"
MONO=$(ls -d "$HERE"/build/extra-tree/usr/share/wine/mono/wine-mono-* 2>/dev/null | head -1)
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -n "$MONO" ] || { echo "SKIP: no staged Wine Mono (make addons)"; exit 77; }
unset DISPLAY WAYLAND_DISPLAY
T=$(mktemp -d /var/tmp/sg-monocfg.XXXXXX)
export HOME="$T/home" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mshtml=;winemenubuilder.exe=d"
mkdir -p "$HOME"
trap '"$WINESERVER" -k 2>/dev/null; rm -rf "$T"' EXIT INT TERM
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
"$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
"$WINE" reg add 'HKCU\Software\Wine\Mono' /v RuntimePath /d "$("$WINE" winepath -w "$MONO" | tr -d '\r')" /f >/dev/null 2>&1
cat > "$WINEPREFIX/drive_c/cfg.cs" <<'CS'
using System;
using System.Configuration;
class P {
    static void Main() {
        var s = ConfigurationManager.GetSection("System.Windows.Forms.ApplicationConfigurationSection") as System.Collections.Specialized.NameValueCollection;
        Console.WriteLine("dpi=" + (s == null ? "none" : s["DpiAwareness"]));
        Console.WriteLine("setting=" + ConfigurationManager.AppSettings["gate"]);
    }
}
CS
cat > "$WINEPREFIX/drive_c/cfg.exe.config" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <System.Windows.Forms.ApplicationConfigurationSection>
    <add key="DpiAwareness" value="PerMonitorV2" />
  </System.Windows.Forms.ApplicationConfigurationSection>
  <appSettings><add key="gate" value="read" /></appSettings>
</configuration>
XML
mcs=$("$WINE" winepath -w "$MONO/lib/mono/4.5/mcs.exe" | tr -d '\r')
(cd "$WINEPREFIX/drive_c" && timeout 300 "$WINE" "$mcs" -r:System.Configuration.dll -out:cfg.exe cfg.cs >"$T/mcs.out" 2>&1)
[ -f "$WINEPREFIX/drive_c/cfg.exe" ] || { fail "the probe did not compile: $(cat "$T/mcs.out")"; exit 1; }
out=$(cd "$WINEPREFIX/drive_c" && timeout 120 "$WINE" cfg.exe 2>&1 | tr -d '\r')
case "$out" in *"dpi=PerMonitorV2"*"setting=read"*) pass "a WinForms program's DpiAwareness section is read, and its other settings with it" ;;
    *) fail "with the image's Mono: $(echo "$out" | head -3)" ;; esac
exit $RC
