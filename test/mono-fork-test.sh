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
#     reflection (AmbirScan's GdPicture);
#   - (sg10) .NET 3.5 as a machine with the NetFx3 feature on has it: NDP\v3.5
#     InstallPath and CBS, NDP\v3.0\Setup WPF/WCF, AssemblyFolders\DX_1.0.2902.0
#     (Managed DirectX, which Mono has; MeediOS's setup ran DirectX's without
#     it), the 64-bit view's AssemblyFolders in Program Files (not x86), and
#     the files: Framework\v3.5\csc.exe (compiles a LINQ program for the 2.0
#     runtime), Program Files\Reference Assemblies\Microsoft\Framework\v3.0
#     and v3.5 with their reference assemblies (System.Core 3.5...);
#   - (sg11) a setting declared at run time reads the value user.config has
#     (DYMO Connect's second start); ManagementEventWatcher.Start does not
#     throw (DYMO Connect's launcher); System.Printing's LocalPrintServer
#     lists the spooler's queues with their drivers and ports, and a queue's
#     jobs (DYMO Connect's printer discovery).
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
REG=$(msiinfo export "$MONO/support/winemono-support.msi" Registry 2>/dev/null)
rows=$(printf '%s\n' "$REG" | grep -c -e 'NDP\\v3\.5	InstallPath	\[WindowsFolder\]Microsoft\.NET\\Framework\(64\)\?\\v3\.5\\' -e 'NDP\\v3\.5	CBS	#1')
[ "$rows" = 4 ] && pass "NDP v3.5 InstallPath and CBS (the feature's), both views" || fail "NDP v3.5 InstallPath/CBS rows: $rows"
rows=$(printf '%s\n' "$REG" | grep -c 'NDP\\v3\.0\\Setup\\Windows \(Presentation\|Communication\) Foundation	InstallSuccess	#1')
[ "$rows" = 4 ] && pass "NDP v3.0 Setup: WPF and WCF InstallSuccess, both views" || fail "v3.0 WPF/WCF rows: $rows"
rows=$(printf '%s\n' "$REG" | grep -c 'AssemblyFolders\\DX_1\.0\.2902\.0		\[WindowsFolder\]Microsoft\.NET\\DirectX for Managed Code\\1\.0\.2902\.0\\')
[ "$rows" = 2 ] && pass "AssemblyFolders DX_1.0.2902.0 (Managed DirectX), both views" || fail "DX rows: $rows"
rows=$(printf '%s\n' "$REG" | grep -c 'AssemblyFolders\\v3\.[05]		\[ProgramFiles64Folder\].*mono-registry64')
[ "$rows" = 2 ] && pass "the 64-bit view's AssemblyFolders v3.0/v3.5 in Program Files (64-bit)" || fail "64-bit AssemblyFolders rows: $rows"
FILES=$(msiinfo export "$MONO/support/winemono-support.msi" File 2>/dev/null)
rows=$(printf '%s\n' "$FILES" | grep -c -e '^Microsoft\.NET\\Framework\(64\)\?\\v3\.5\\csc\.exe	' -e '^ProgramFiles\(64\)\?Folder\\Reference Assemblies\\Microsoft\\Framework\\v3\.5\\System\.Core\.dll	')
[ "$rows" = 4 ] && pass "files: Framework(64) v3.5 csc.exe, Reference Assemblies v3.5 System.Core.dll (both Program Files)" || fail "v3.5 file rows: $rows"
msiinfo export "$MONO/support/winemono-support.msi" Property 2>/dev/null | grep -q '^ProductCode	{[0-9A-F-]\{36\}}' \
    && pass "and has a ProductCode (a build without uuidgen had {})" || fail "support MSI ProductCode"

"$WINE" wineboot -i >/dev/null 2>&1; "$WINESERVER" -w
"$WINE" reg add 'HKCU\Software\Wine\Mono' /v RuntimePath /d "$("$WINE" winepath -w "$MONO" | tr -d '\r')" /f >/dev/null 2>&1
C="$WINEPREFIX/drive_c"
# (sg10) the support MSI applied as sg-session applies it to a machine made
# before it: the 3.5 files land, and 3.5's csc.exe compiles for the 2.0 runtime
"$WINE" msiexec /i "$("$WINE" winepath -w "$MONO/support/winemono-support.msi" | tr -d '\r')" REINSTALL=ALL REINSTALLMODE=vomus /qn >/dev/null 2>&1
for f in "Program Files (x86)/Reference Assemblies/Microsoft/Framework/v3.5/System.Core.dll" \
         "Program Files/Reference Assemblies/Microsoft/Framework/v3.5/System.Xml.Linq.dll" \
         "Program Files (x86)/Reference Assemblies/Microsoft/Framework/v3.0/System.ServiceModel.dll" \
         "windows/Microsoft.NET/Framework/v3.5/csc.exe" "windows/Microsoft.NET/Framework64/v3.5/csc.exe"; do
    [ -s "$C/$f" ] && pass "installed: C:/$f" || fail "not installed: C:/$f"
done
[ -d "$C/windows/Microsoft.NET/DirectX for Managed Code/1.0.2902.0" ] && pass "installed: DirectX for Managed Code/1.0.2902.0" || fail "no DirectX for Managed Code/1.0.2902.0"
"$WINE" reg query 'HKLM\Software\Microsoft\.NETFramework\AssemblyFolders\v3.5' /reg:64 2>/dev/null | tr -d '\r' | grep -q 'C:\\Program Files\\Reference Assemblies' \
    && pass "64-bit view AssemblyFolders v3.5 is C:/Program Files/Reference Assemblies/..." || fail "64-bit AssemblyFolders v3.5 value"
cat > "$C/linq.cs" <<'CS'
using System; using System.Linq; using System.Xml.Linq;
class L { static void Main() { Console.WriteLine("linq=" + new XElement("a", Enumerable.Range(1, 3).Select(i => new XElement("b", i))).Elements().Count()); } }
CS
(cd "$C" && timeout 300 "$WINE" 'C:\windows\Microsoft.NET\Framework\v3.5\csc.exe' /r:System.Core.dll /r:System.Xml.Linq.dll /out:linq.exe linq.cs >"$T/csc35.out" 2>&1)
out=$(cd "$C" && timeout 120 "$WINE" linq.exe 2>&1 | tr -d '\r')
[ "$(printf '%s\n' "$out" | sed -n 's/^linq=//p')" = 3 ] && strings -a "$C/linq.exe" | grep -q '^v2\.0\.50727$' \
    && pass "Framework v3.5 csc.exe compiles a LINQ program for the 2.0 runtime, and it runs" \
    || fail "v3.5 csc: $(tail -2 "$T/csc35.out") / $out"
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
# (sg11) a printer for System.Printing to find: driver "SG Label 550", port USB001
cat > "$T/addprn.c" <<'EOF'
#include <windows.h>
#include <winspool.h>
int wmain(void)
{
    DRIVER_INFO_3W di = {0};
    PRINTER_INFO_2W pi = {0};
    HANDLE h;
    di.cVersion = 3; di.pName = (WCHAR *)L"SG Label 550"; di.pEnvironment = (WCHAR *)L"Windows x64";
    di.pDriverPath = di.pConfigFile = (WCHAR *)L"wineps.drv"; di.pDataFile = (WCHAR *)L"C:\\label.ppd";
    di.pDefaultDataType = (WCHAR *)L"RAW";
    AddPrinterDriverExW(NULL, 3, (BYTE *)&di, APD_COPY_NEW_FILES | APD_COPY_FROM_DIRECTORY);
    pi.pPrinterName = (WCHAR *)L"Label desk"; pi.pDriverName = di.pName; pi.pPortName = (WCHAR *)L"USB001";
    pi.pPrintProcessor = (WCHAR *)L"wineps"; pi.pDatatype = (WCHAR *)L"RAW";
    pi.pParameters = pi.pShareName = pi.pSepFile = (WCHAR *)L"";
    h = AddPrinterW(NULL, 2, (BYTE *)&pi);
    if (h) ClosePrinter(h);
    return !h;
}
EOF
cat > "$C/label.ppd" <<'EOF'
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName: "SGLABEL.PPD"
*Manufacturer: "SG"
*ModelName: "SG Label 550"
*NickName: "SG Label 550"
*OpenUI *PageSize: PickOne
*DefaultPageSize: w72h154
*PageSize w72h154/Address: "<</PageSize[72 154]>>setpagedevice"
*CloseUI: *PageSize
*DefaultImageableArea: w72h154
*ImageableArea w72h154/Address: "4 4 68 150"
*DefaultPaperDimension: w72h154
*PaperDimension w72h154/Address: "72 154"
EOF
x86_64-w64-mingw32-gcc -municode -O1 -o "$C/addprn.exe" "$T/addprn.c" -lwinspool || { fail "the printer adder did not build"; exit 1; }
(cd "$C" && timeout 120 "$WINE" addprn.exe >/dev/null 2>&1) || fail "the test printer was not added"
cat > "$C/sg11.cs" <<'CS'
using System;
using System.Configuration;
using System.Linq;
using System.Management;
using System.Printing;
class Gate : ApplicationSettingsBase {
    [UserScopedSetting, DefaultSettingValue("")] public string Other { get { return (string)this["Other"]; } }
    /* a setting declared at run time, as DYMO Connect's preferences are */
    public void Declare(string name) {
        var p = new SettingsProperty(name) { PropertyType = typeof(string), DefaultValue = "",
            Provider = Properties["Other"].Provider, SerializeAs = SettingsSerializeAs.String };
        p.Attributes.Add(typeof(UserScopedSettingAttribute), new UserScopedSettingAttribute());
        Properties.Add(p);
    }
}
class P {
    static void Main(string[] a) {
        if (a.Length > 0 && a[0] == "save") { var g = new Gate(); g.Declare("Late"); g["Late"] = "kept"; g.Save(); return; }
        if (a.Length > 0 && a[0] == "late") {
            var g = new Gate();
            Console.WriteLine("other=" + g.Other);          /* loads the file: Late is not declared yet */
            g.Declare("Late");
            Console.WriteLine("late=" + ((g["Late"] as string) ?? "<null>"));
            return;
        }
        try {
            var w = new ManagementEventWatcher(new WqlEventQuery("SELECT * FROM __InstanceCreationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_PnPEntity'"));
            w.Start(); w.Stop();
            Console.WriteLine("watcher=ok");
        } catch (Exception e) { Console.WriteLine("watcher=" + e.GetType().Name); }
        try {
            var server = new LocalPrintServer();
            var q = server.GetPrintQueues().FirstOrDefault(x => x.Name == "Label desk");
            Console.WriteLine("queue=" + (q == null ? "<none>" : q.Name + "|" + q.QueueDriver.Name + "|" + q.QueuePort.Name + "|" + q.IsOffline));
            q = server.GetPrintQueue("Label desk");
            q.Refresh();
            Console.WriteLine("jobs=" + q.GetPrintJobInfoCollection().Count() + "|" + q.FullName);
        } catch (Exception e) { Console.WriteLine("printing=" + e.GetType().Name + ": " + e.Message); }
    }
}
CS
# the WPF assemblies are only in the GAC
gac() { "$WINE" winepath -w "$(ls -d "$MONO"/lib/mono/gac/"$1"/*/"$1".dll | head -1)" | tr -d '\r'; }
(cd "$C" && timeout 300 "$WINE" "$mcs" -r:System.Configuration.dll -r:System.Core.dll -r:System.Management.dll \
    -r:"$(gac System.Printing)" -r:"$(gac ReachFramework)" -out:sg11.exe sg11.cs >"$T/mcs11.out" 2>&1)
[ -f "$C/sg11.exe" ] || { fail "the sg11 probe did not compile: $(cat "$T/mcs11.out")"; exit 1; }
(cd "$C" && timeout 120 "$WINE" sg11.exe save >/dev/null 2>&1)
out=$(cd "$C" && timeout 120 "$WINE" sg11.exe late 2>&1 | tr -d '\r')
[ "$(v late)" = kept ] && pass "a setting declared at run time reads the value user.config has (DYMO Connect's second start)" \
    || fail "late-declared setting: '$(v late)' $(echo "$out" | grep -m1 Exception)"
out=$(cd "$C" && timeout 120 "$WINE" sg11.exe 2>&1 | tr -d '\r')
[ "$(v watcher)" = ok ] && pass "ManagementEventWatcher starts and stops (DYMO Connect's launcher)" || fail "watcher: '$(v watcher)'"
[ "$(v queue)" = "Label desk|SG Label 550|USB001|False" ] && pass "LocalPrintServer lists the queue with its driver and port (DYMO Connect's discovery)" \
    || fail "print queue: '$(v queue)' $(v printing)"
[ "$(v jobs)" = "0|Label desk" ] && pass "a queue's jobs and full name" || fail "jobs: '$(v jobs)' $(v printing)"
exit $RC
