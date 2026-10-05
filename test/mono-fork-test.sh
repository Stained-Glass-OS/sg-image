#!/bin/sh
# Our Wine Mono build (mono/patches, mono/build-wine-mono.sh) does what the
# athenaNet Device Manager (and SQL Server Compact's installer) need of it:
#   - System.Diagnostics.Eventing.Reader's types load (Apollo's watcher field);
#   - X509Store.Add/Remove reach the system store, and a program may Remove
#     while it enumerates Certificates (Apollo's root certificate);
#   - an app .config may have <startup> twice (its tray program's);
#   - Environment.UserInteractive is false in a window station that is not
#     visible (a service's), so Apollo runs as a service, not a console program;
#   - the support MSI writes NDP\v4\{Client,Full} InstallPath, and
#     .NETFramework\AssemblyFolders\v3.0/v3.5 (installers take that for
#     .NET 3.5 SP1 being there);
#   - System.Drawing has .NET Framework's private names that programs reach by
#     reflection (AmbirScan's GdPicture).
# Programs are compiled here with Mono's own mcs.exe, under Wine; the image's
# addons tree is the Mono that runs them.
#
#   test/mono-fork-test.sh [WINE]     (needs make mono-deb first)
# Mutation: the official wine-mono 9.4.0 tarball staged instead fails every
# check but the ProductCode one (the probe does not load: no EventLogWatcher).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WINE=${1:-/opt/wine-sg/bin/wine}
WINESERVER="$(dirname "$WINE")/wineserver"
MONO=$(ls -d "${SG_MONO_DIR:-$HERE/build/mono-deb-root/usr/share/wine/mono}"/wine-mono-* 2>/dev/null | head -1)
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -n "$MONO" ] || { echo "SKIP: no packaged Wine Mono (make mono-deb)"; exit 77; }
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "SKIP: mingw-w64 not installed"; exit 77; }
command -v msiinfo >/dev/null || { echo "SKIP: msitools not installed"; exit 77; }
unset DISPLAY WAYLAND_DISPLAY
T=$(mktemp -d /var/tmp/sg-monofork.XXXXXX)
export HOME="$T/home" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mshtml=;winemenubuilder.exe=d"
mkdir -p "$HOME"
trap '"$WINESERVER" -k 2>/dev/null; rm -rf "$T"' EXIT INT TERM
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

# the support MSI's registry rows (static: wineboot installs the host's Mono)
rows=$(msiinfo export "$MONO/support/winemono-support.msi" Registry 2>/dev/null | grep -c 'NDP\\v4\\\(Client\|Full\).InstallPath')
[ "$rows" = 4 ] && pass "the support MSI writes NDP v4 Client/Full InstallPath, both views" || fail "InstallPath rows: $rows"
rows=$(msiinfo export "$MONO/support/winemono-support.msi" Registry 2>/dev/null | grep -c 'NETFramework.AssemblyFolders.v3\.[05]'"$(printf '\t')"'.*Reference Assemblies')
[ "$rows" = 4 ] && pass "and .NETFramework AssemblyFolders v3.0 and v3.5, both views (Meedio's setup ran .NET 3.5 SP1's, refused on Windows 10)" || fail "AssemblyFolders rows: $rows"
msiinfo export "$MONO/support/winemono-support.msi" Property 2>/dev/null | grep -q '^ProductCode	{[0-9A-F-]\{36\}}' \
    && pass "and has a ProductCode (a build without uuidgen had {})" || fail "support MSI ProductCode"

"$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
"$WINE" reg add 'HKCU\Software\Wine\Mono' /v RuntimePath /d "$("$WINE" winepath -w "$MONO" | tr -d '\r')" /f >/dev/null 2>&1
C="$WINEPREFIX/drive_c"
cat > "$C/fork.cs" <<'CS'
using System;
using System.Configuration;
using System.Diagnostics.Eventing.Reader;
using System.Security.Cryptography.X509Certificates;
class P {
    static void Main(string[] a) {
        Console.WriteLine("interactive=" + Environment.UserInteractive);
        if (a.Length > 0) return;
        try {
            var w = new EventLogWatcher(new EventLogQuery("Application", PathType.LogName, "*"));
            w.Enabled = true; w.Enabled = false; w.Dispose();
            Console.WriteLine("eventlog=ok");
        } catch (Exception e) { Console.WriteLine("eventlog=" + e.GetType().Name); }
        Console.WriteLine("setting=" + ConfigurationManager.AppSettings["gate"]);
        {
            // System.Drawing's private names as .NET Framework's (GdPicture reflects on them)
            var bf = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
            var sf = System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic;
            var gfield = typeof(System.Drawing.Graphics).GetField("nativeGraphics", bf);
            bool names = gfield != null && typeof(System.Drawing.Pen).GetField("nativePen", bf) != null
                && typeof(System.Drawing.Brush).GetField("nativeBrush", bf) != null
                && typeof(System.Drawing.Drawing2D.GraphicsPath).GetConstructor(bf, null, new[] { typeof(IntPtr), typeof(int) }, null) != null
                && typeof(System.Drawing.Bitmap).GetMethod("FromGDIplus", sf) != null;
            bool handle = false;
            if (gfield != null)
                using (var b = new System.Drawing.Bitmap(4, 4))
                using (var g = System.Drawing.Graphics.FromImage(b))
                    handle = (IntPtr)gfield.GetValue(g) != IntPtr.Zero;
            Console.WriteLine("drawing=" + (names && handle ? "ok" : "names " + names + " handle " + handle));
        }
        try {
            var cert = new X509Certificate2(a.Length > 1 ? a[1] : "C:\\probe.crt");
            var s = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
            s.Open(OpenFlags.ReadWrite);
            s.Add(cert);
            Console.WriteLine("added=" + s.Certificates.Find(X509FindType.FindByThumbprint, cert.Thumbprint, false).Count);
            foreach (X509Certificate2 c in s.Certificates)       /* remove while enumerating */
                if (c.Thumbprint == cert.Thumbprint) s.Remove(c);
            s.Close();
            s = new X509Store(StoreName.Root, StoreLocation.CurrentUser);
            s.Open(OpenFlags.ReadOnly);
            Console.WriteLine("removed=" + (s.Certificates.Find(X509FindType.FindByThumbprint, cert.Thumbprint, false).Count == 0));
        } catch (Exception e) { Console.WriteLine("store=" + e.GetType().Name + ": " + e.Message); }
    }
}
CS
cat > "$C/fork.exe.config" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.5" /></startup>
  <appSettings><add key="gate" value="read" /></appSettings>
  <startup useLegacyV2RuntimeActivationPolicy="true"><supportedRuntime version="v4.0" /></startup>
</configuration>
XML
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$C/probe.crt" -days 2 -subj "/CN=sg-mono-fork-gate" 2>/dev/null
cat > "$T/hidden.c" <<'EOF'
/* runs a program in a window station that is not visible, as a service runs */
#include <windows.h>
int wmain(int argc, WCHAR **argv)
{
    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    if (argc < 2) return 2;
    si.lpDesktop = (WCHAR *)L"sg_gate_winstation\\Default";
    if (!CreateProcessW(NULL, argv[1], NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 3;
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    return (int)code;
}
EOF
x86_64-w64-mingw32-gcc -municode -O1 -o "$C/hidden.exe" "$T/hidden.c" || { fail "the launcher did not build"; exit 1; }
mcs=$("$WINE" winepath -w "$MONO/lib/mono/4.5/mcs.exe" | tr -d '\r')
(cd "$C" && timeout 300 "$WINE" "$mcs" -r:System.Configuration.dll -r:System.Core.dll -r:System.Drawing.dll -out:fork.exe fork.cs >"$T/mcs.out" 2>&1)
[ -f "$C/fork.exe" ] || { fail "the probe did not compile: $(cat "$T/mcs.out")"; exit 1; }
out=$(cd "$C" && timeout 120 "$WINE" fork.exe 2>&1 | tr -d '\r')
v() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
[ "$(v eventlog)" = ok ] && pass "EventLogWatcher loads and is enabled and disabled" || fail "eventlog: '$(v eventlog)' $(echo "$out" | head -2)"
[ "$(v setting)" = read ] && pass "a .config with <startup> twice is read" || fail "config: $(echo "$out" | grep -m1 -i 'configuration\|setting')"
[ "$(v drawing)" = ok ] && pass "System.Drawing has .NET Framework's private names (nativeGraphics, a live GDI+ handle; nativePen, nativeBrush, GraphicsPath(IntPtr,int), Bitmap.FromGDIplus)" \
    || fail "System.Drawing names: '$(v drawing)'"
[ "$(v added)" = 1 ] && pass "X509Store.Add puts a certificate in the Root store" || fail "add: $(v added) $(v store)"
[ "$(v removed)" = True ] && pass "and Remove, while enumerating Certificates, takes it out" || fail "remove: '$(v removed)' $(v store)"
[ "$(v interactive)" = True ] && pass "UserInteractive in the visible window station" || fail "interactive: '$(v interactive)'"
out=$(cd "$C" && timeout 120 "$WINE" hidden.exe "fork.exe service" 2>&1 | tr -d '\r')
[ "$(v interactive)" = False ] && pass "not UserInteractive in a window station that is not visible (a service's)" \
    || fail "hidden interactive: '$(v interactive)' $(echo "$out" | head -2)"
exit $RC
