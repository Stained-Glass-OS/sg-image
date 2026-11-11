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
#     jobs (DYMO Connect's printer discovery);
#   - (sg12) a queue's print ticket (the printer's DEVMODE) and capabilities;
#     a font family's names (FamilyNames was always empty: DYMO Connect's
#     label editor crashed at the first letter typed).
#   - (sg15) X509Chain is built by crypt32, as .NET Framework's: its Handle is
#     a crypt32 chain context, a chain asked to check revocation is built (it
#     threw NotImplementedException from the store's CRLs: Visual Studio's
#     installer said "Certificate is invalid"), a self-signed certificate's is
#     UntrustedRoot, and a root of the system's store makes a valid chain.
#     SG_MONO_CHAIN=mono (Mono's managed chain) is the mutant. X509Certificate
#     .Import reinitializes a certificate (it threw "immutable on this
#     platform"), and a deflated part read from a package seeks (it threw
#     NotSupportedException) -- both in Visual Studio's installer -- and a
#     property implemented anew (newslot) over a base class's of the same name
#     does not inherit that one's attributes (VS Installer's GetCustomAttribute
#     threw AmbiguousMatchException); a CMS message whose certificate set
#     holds an attribute certificate ([1], as Microsoft's time-stamp tokens)
#     decodes (it threw "ASN1 corrupted data": VS's channel manifest); a
#     certificate is made from a CryptoAPI context (X509Certificate(IntPtr));
#     a reference marked WindowsRuntime ("Windows, Version=255.255.255.255")
#     loads our lib/mono/4.5/WinMetadata/Windows.winmd, and its
#     Windows.Networking.Connectivity answers (VS asks the connection's cost);
#     Marshal.ThrowExceptionForHR ignores a success code (the Windows SDK's
#     setup passes a Win32 error, 2, after a call that succeeded).
#   - (sg16) an omitted optional argument (Type.Missing) goes to COM as
#     VT_ERROR DISP_E_PARAMNOTFOUND and DBNull as VT_NULL, as .NET Framework
#     marshals them: Missing went out as a VT_DISPATCH, and Visual Studio's
#     installer, calling ITaskService.Connect() with no arguments, failed
#     "Failed to create scheduled task" 0x80070035.
#   - (sg17) an array of structures (Guid[]) goes to COM as a
#     SAFEARRAY(VT_RECORD) carrying an IRecordInfo, and comes back, as .NET
#     marshals it (Visual Studio's IVsUIContextManagerPrivate); a CCW's
#     GetIDsOfNames with a NULL name is DISP_E_UNKNOWNNAME, not a crash;
#     AppDomainSetup.TargetFrameworkName can be set (VsAppDomainManager).
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
# (sg12) a queue's print ticket and capabilities (DYMO Connect prints with
# them), and a font family's names (its text editor reads them as you type)
cat > "$C/sg12.cs" <<'CS'
using System;
using System.Linq;
using System.Printing;
class P {
    [STAThread] static void Main() {
        try {
            var q = new LocalPrintServer().GetPrintQueue("Label desk");
            var t = q.UserPrintTicket;
            Console.WriteLine("ticket=" + (t == null || t.PageMediaSize == null ? "<none>" :
                Math.Round(t.PageMediaSize.Width ?? 0) + "x" + Math.Round(t.PageMediaSize.Height ?? 0)));
            Console.WriteLine("defaultticket=" + (q.DefaultPrintTicket == null ? "<none>" : "ok"));
            Console.WriteLine("caps=" + (q.GetPrintCapabilitiesAsXml().Length > 0 ? "xml" : "empty"));
        } catch (Exception e) { Console.WriteLine("printing=" + e.GetType().Name + ": " + e.Message); }
        try {
            var f = new System.Windows.Media.FontFamily("Arial");
            Console.WriteLine("familynames=" + f.FamilyNames.Count + "|" + f.FamilyNames.Values.First());
        } catch (Exception e) { Console.WriteLine("familynames=" + e.GetType().Name + ": " + e.Message); }
    }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -r:System.Core.dll -r:"$(gac System.Printing)" -r:"$(gac ReachFramework)" \
    -r:"$(gac PresentationCore)" -r:"$(gac WindowsBase)" -out:sg12.exe sg12.cs >"$T/mcs12.out" 2>&1)
[ -f "$C/sg12.exe" ] || { fail "the sg12 probe did not compile: $(cat "$T/mcs12.out")"; exit 1; }
out=$(cd "$C" && timeout 120 "$WINE" sg12.exe 2>&1 | tr -d '\r')
# 1 x 2.14 in (the PPD's w72h154) in WPF's 1/96 in
[ "$(v ticket)" = "96x205" ] && pass "a queue's print ticket is its printer's DEVMODE: the label's size" || fail "ticket: '$(v ticket)' $(v printing)"
[ "$(v defaultticket)" = ok ] && [ "$(v caps)" = xml ] && pass "and its default ticket and capabilities (PrintCapabilities XML)" \
    || fail "default ticket '$(v defaultticket)', capabilities '$(v caps)' $(v printing)"
case "$(v familynames)" in 1\|*) pass "a font family's names: $(v familynames)" ;;
    *) fail "font family names: '$(v familynames)' (DYMO Connect's editor stops at the first letter typed)" ;; esac
# (sg15) X509Chain by crypt32
cat > "$C/sg15.cs" <<'CS'
using System;
using System.Security.Cryptography.X509Certificates;
using System.IO;
using System.IO.Packaging;
using System.Reflection;
[AttributeUsage(AttributeTargets.Property, Inherited = true, AllowMultiple = true)]
sealed class MX : Attribute { public MX(params string[] o) {} }
interface I1 { bool Quiet { get; } }
interface I2 { bool Quiet { get; } }
class A2 : I1 { [MX("Passive")] public bool Quiet { get { return false; } } }
abstract class B2 : A2, I2 { [MX("Passive")] public new bool Quiet { get { return true; } } }
class C2 : B2 { }
class P {
    [System.Runtime.InteropServices.DllImport("crypt32.dll")]
    static extern IntPtr CertCreateCertificateContext(int type, byte[] data, int len);
    static void Main() {
        try {
            System.Runtime.InteropServices.Marshal.ThrowExceptionForHR(2);
            Console.WriteLine("hrsuccess=" + (System.Runtime.InteropServices.Marshal.GetExceptionForHR(2) == null ? "none" : "exception"));
        } catch (Exception e) { Console.WriteLine("hrsuccess=" + e.GetType().Name + ": " + e.Message); }
        try {
            var raw = File.ReadAllBytes("C:\\probe.der");
            IntPtr ctx = CertCreateCertificateContext(0x10001, raw, raw.Length);
            Console.WriteLine("handlecert=" + new X509Certificate2(ctx).Subject);
        } catch (Exception e) { Console.WriteLine("handlecert=" + e.GetType().Name + ": " + e.Message); }
        try {
            var cms = new System.Security.Cryptography.Pkcs.SignedCms();
            cms.Decode(File.ReadAllBytes("C:\\cms.der"));
            Console.WriteLine("cms=" + cms.Certificates.Count + "|" + cms.SignerInfos.Count);
        } catch (Exception e) { Console.WriteLine("cms=" + e.GetType().Name + ": " + e.Message); }
        try {
            typeof(C2).GetProperty("Quiet").GetCustomAttribute<MX>(true);
            Console.WriteLine("newslotattr=one");
        } catch (Exception e) { Console.WriteLine("newslotattr=" + e.GetType().Name); }
        try {
            var c2 = new X509Certificate2();
            c2.Import(File.ReadAllBytes("C:\\probe.crt"));
            Console.WriteLine("import=" + c2.Subject);
        } catch (Exception e) { Console.WriteLine("import=" + e.GetType().Name + ": " + e.Message); }
        try {
            var data = new byte[200000];
            for (int i = 0; i < data.Length; i++) data[i] = (byte)(i % 251);
            using (var pkg = Package.Open("C:\\gate.opc", FileMode.Create)) {
                var part = pkg.CreatePart(new Uri("/a.bin", UriKind.Relative), "application/octet-stream", CompressionOption.Maximum);
                using (var w = part.GetStream()) w.Write(data, 0, data.Length);
            }
            using (var pkg = Package.Open("C:\\gate.opc", FileMode.Open, FileAccess.Read)) {
                var st = pkg.GetPart(new Uri("/a.bin", UriKind.Relative)).GetStream();
                var buf = new byte[1000];
                st.Read(buf, 0, buf.Length);
                st.Seek(0, SeekOrigin.Begin);
                var all = new MemoryStream();
                st.CopyTo(all);
                var b = all.ToArray();
                bool same = b.Length == data.Length;
                for (int i = 0; same && i < b.Length; i++) same = b[i] == data[i];
                st.Position = 150000;
                int x = st.ReadByte();
                Console.WriteLine("zipseek=" + st.CanSeek + "|" + same + "|" + (x == 150000 % 251));
            }
        } catch (Exception e) { Console.WriteLine("zipseek=" + e.GetType().Name + ": " + e.Message); }
        try {
            var c = new X509Certificate2("C:\\probe.crt");
            var ch = new X509Chain();
            ch.ChainPolicy.RevocationMode = X509RevocationMode.Online;
            ch.ChainPolicy.RevocationFlag = X509RevocationFlag.ExcludeRoot;
            bool ok = ch.Build(c);
            X509ChainStatusFlags f = 0;
            foreach (var st in ch.ChainStatus) f |= st.Status;
            Console.WriteLine("handle=" + (ch.ChainContext != IntPtr.Zero ? "context" : "none"));
            Console.WriteLine("selfsigned=" + ok + "|" + ((f & X509ChainStatusFlags.UntrustedRoot) != 0 ? "UntrustedRoot" : f.ToString()) + "|" + ch.ChainElements.Count);
        } catch (Exception e) { Console.WriteLine("selfsigned=" + e.GetType().Name + ": " + e.Message); }
        try {
            var st = new X509Store(StoreName.Root, StoreLocation.LocalMachine);
            st.Open(OpenFlags.ReadOnly);
            X509Certificate2 root = null;
            foreach (var r in st.Certificates)
                if (r.Subject == r.Issuer && r.NotBefore < DateTime.Now && r.NotAfter > DateTime.Now.AddYears(1)) { root = r; break; }
            if (root == null) { Console.WriteLine("root=none in the store"); return; }
            var ch = new X509Chain();
            ch.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
            Console.WriteLine("root=" + ch.Build(root) + "|" + ch.ChainElements.Count);
        } catch (Exception e) { Console.WriteLine("root=" + e.GetType().Name + ": " + e.Message); }
    }
}
CS
# a SignedData whose certificate set is the probe's certificate and an
# attribute certificate ([1] IMPLICIT: here an empty one), no signers
openssl x509 -in "$C/probe.crt" -outform DER -out "$T/probe.der"
cp "$T/probe.der" "$C/probe.der"
python3 - "$T/probe.der" "$C/cms.der" <<'PY'
import sys
def tlv(tag, body):
    n = len(body)
    if n < 0x80: l = bytes([n])
    else:
        b = n.to_bytes((n.bit_length() + 7) // 8, 'big'); l = bytes([0x80 | len(b)]) + b
    return bytes([tag]) + l + body
oid_signed = bytes.fromhex('06092a864886f70d010702')
oid_data = bytes.fromhex('06092a864886f70d010701')
cert = open(sys.argv[1], 'rb').read()
certs = tlv(0xa0, cert + tlv(0xa1, b''))
sd = tlv(0x30, bytes.fromhex('020101') + tlv(0x31, b'') + tlv(0x30, oid_data) + certs + tlv(0x31, b''))
open(sys.argv[2], 'wb').write(tlv(0x30, oid_signed + tlv(0xa0, sd)))
PY
(cd "$C" && timeout 300 "$WINE" "$mcs" -r:"$(gac WindowsBase)" -r:System.Security.dll -out:sg15.exe sg15.cs >"$T/mcs15.out" 2>&1)
[ -f "$C/sg15.exe" ] || { fail "the sg15 probe did not compile: $(cat "$T/mcs15.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg15.exe 2>&1 | tr -d '\r')
[ "$(v handle)" = context ] && pass "X509Chain is crypt32's: its handle is a chain context" || fail "chain handle: '$(v handle)' (Mono's managed chain)"
[ "$(v selfsigned)" = "False|UntrustedRoot|1" ] && pass "a chain asked to check revocation is built; a self-signed certificate's is UntrustedRoot (Visual Studio's installer)" \
    || fail "revocation-checked chain: '$(v selfsigned)'"
case "$(v root)" in True\|1) pass "a root of the system's store is a valid chain of one" ;; *) fail "system root chain: '$(v root)'" ;; esac
[ "$(v import)" = "CN=sg-mono-fork-gate" ] && pass "X509Certificate2.Import reads a certificate into an empty one" || fail "Import: '$(v import)'"
[ "$(v hrsuccess)" = none ] && pass "ThrowExceptionForHR and GetExceptionForHR ignore a success code" || fail "success HRESULT: '$(v hrsuccess)'"
[ "$(v handlecert)" = "CN=sg-mono-fork-gate" ] && pass "a certificate is made from a CryptoAPI certificate context" || fail "X509Certificate(IntPtr): '$(v handlecert)'"
[ "$(v cms)" = "1|0" ] && pass "a CMS message with an attribute certificate in its set decodes (Microsoft's time stamps)" || fail "CMS decode: '$(v cms)'"
[ "$(v newslotattr)" = one ] && pass "a property implemented anew over a base class's has its own attribute only" || fail "newslot attributes: '$(v newslotattr)'"
[ "$(v zipseek)" = "True|True|True" ] && pass "a deflated package part seeks: back to the start, and to a place ahead" || fail "package part seek: '$(v zipseek)'"
# (sg15) a Windows Runtime reference: the probe is assembled, then its
# reference to "Windows" (the only one at 255.255.255.255) is marked
# ContentType=WindowsRuntime (AssemblyRef flags 0x200), which ilasm here
# cannot write; Windows.winmd is not beside it, so only WinMetadata can serve it
cat > "$C/winrt.il" <<'IL'
.assembly extern mscorlib { .publickeytoken = (B7 7A 5C 56 19 34 E0 89) .ver 4:0:0:0 }
.assembly extern Windows { .ver 255:255:255:255 }
.assembly winrtprobe { .ver 1:0:0:0 }
.class public auto ansi P extends [mscorlib]System.Object {
  .method public static void Main() cil managed {
    .entrypoint
    .maxstack 2
    .locals init (class [Windows]Windows.Networking.Connectivity.ConnectionProfile p)
    call class [Windows]Windows.Networking.Connectivity.ConnectionProfile [Windows]Windows.Networking.Connectivity.NetworkInformation::GetInternetConnectionProfile()
    stloc.0
    ldstr "winrt="
    ldloc.0
    brtrue.s HAVE
    ldstr "noprofile"
    br.s DONE
  HAVE:
    ldloc.0
    callvirt instance class [Windows]Windows.Networking.Connectivity.ConnectionCost [Windows]Windows.Networking.Connectivity.ConnectionProfile::GetConnectionCost()
    callvirt instance valuetype [Windows]Windows.Networking.Connectivity.NetworkCostType [Windows]Windows.Networking.Connectivity.ConnectionCost::get_NetworkCostType()
    box [Windows]Windows.Networking.Connectivity.NetworkCostType
    callvirt instance string [mscorlib]System.Object::ToString()
  DONE:
    call string [mscorlib]System.String::Concat(string, string)
    call void [mscorlib]System.Console::WriteLine(string)
    ret
  }
}
IL
ilasm=$("$WINE" winepath -w "$MONO/lib/mono/4.5/ilasm.exe" | tr -d '\r')
(cd "$C" && timeout 300 "$WINE" "$ilasm" /exe /out:winrt.exe winrt.il >"$T/ilasm.out" 2>&1)
python3 - "$C/winrt.exe" <<'PY'
import sys
p = sys.argv[1]; b = bytearray(open(p, 'rb').read())
pat = bytes.fromhex('ff00ff00ff00ff0000000000')
i = b.find(pat)
assert i >= 0 and b.find(pat, i + 1) < 0, "Windows reference not found once"
b[i + 8:i + 12] = (0x200).to_bytes(4, 'little')
open(p, 'wb').write(b)
PY
[ -f "$C/winrt.exe" ] || fail "the Windows Runtime probe did not assemble: $(cat "$T/ilasm.out")"
out=$(cd "$C" && timeout 120 "$WINE" winrt.exe 2>&1 | tr -d '\r')
case "$(v winrt)" in Unrestricted|noprofile) pass "a WindowsRuntime reference loads WinMetadata/Windows.winmd: the connection's cost is '$(v winrt)'" ;;
    *) fail "Windows Runtime reference: '$(v winrt)' $(printf '%s' "$out" | grep -m1 -i 'could not load\|exception')" ;; esac
# (sg16) Type.Missing and DBNull as VARIANTs, and an early-bound COM call
# with the optional arguments left out (Wine's Task Scheduler)
cat > "$C/sg16.cs" <<'CS'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("2FABA4C7-4DA9-4013-9697-20CC3FD40F85"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
interface ITaskService {
    [DispId(1)] object GetFolder([MarshalAs(UnmanagedType.BStr)] string path);
    [DispId(2)] object GetRunningTasks(int flags);
    [DispId(3)] object NewTask(uint flags);
    [DispId(4)] void Connect([Optional] object serverName, [Optional] object user, [Optional] object domain, [Optional] object password);
    [DispId(5)] bool Connected { get; }
}
[ComImport, Guid("0F87369F-A4E5-4CFC-BD3E-73E6154572DD")]
class TaskScheduler { }
class P {
    static void Main() {
        IntPtr v = Marshal.AllocHGlobal(24);
        Marshal.GetNativeVariantForObject(Type.Missing, v);
        Console.WriteLine("missing=" + Marshal.ReadInt16(v) + "|" + Marshal.ReadInt32(v, 8).ToString("x8"));
        Marshal.GetNativeVariantForObject(DBNull.Value, v);
        Console.WriteLine("dbnull=" + Marshal.ReadInt16(v));
        try {
            var ts = (ITaskService)new TaskScheduler();
            ts.Connect();
            Console.WriteLine("connect=" + ts.Connected);
        } catch (Exception e) { Console.WriteLine("connect=" + e.GetType().Name + ": " + e.Message); }
    }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg16.exe sg16.cs >"$T/mcs16.out" 2>&1)
[ -f "$C/sg16.exe" ] || { fail "the sg16 probe did not compile: $(cat "$T/mcs16.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg16.exe 2>&1 | tr -d '\r')
[ "$(v missing)" = "10|80020004" ] && pass "Type.Missing is VT_ERROR DISP_E_PARAMNOTFOUND" || fail "Missing as a VARIANT: '$(v missing)'"
[ "$(v dbnull)" = 1 ] && pass "DBNull is VT_NULL" || fail "DBNull as a VARIANT: '$(v dbnull)'"
[ "$(v connect)" = True ] && pass "ITaskService.Connect() with its optional arguments left out connects (Visual Studio's installer)" \
    || fail "Connect with omitted arguments: '$(v connect)'"
# (sg17) Guid[] as SAFEARRAY(VT_RECORD) both ways, a CCW asked for a NULL
# name, and a settable AppDomainSetup.TargetFrameworkName (Visual Studio's IDE)
cat > "$C/sg17.cs" <<'CS'
using System;
using System.Runtime.InteropServices;
[ComVisible(true), ClassInterface(ClassInterfaceType.AutoDispatch)]
public class Disp { public void Hello() { } }
public class P {
    [DllImport("oleaut32.dll")] static extern int SafeArrayGetVartype(IntPtr psa, out ushort vt);
    [DllImport("oleaut32.dll")] static extern int SafeArrayGetRecordInfo(IntPtr psa, out IntPtr info);
    [DllImport("oleaut32.dll")] static extern int SafeArrayAccessData(IntPtr psa, out IntPtr data);
    [DllImport("oleaut32.dll")] static extern int SafeArrayUnaccessData(IntPtr psa);
    [DllImport("oleaut32.dll")] static extern int VariantClear(IntPtr v);
    [DllImport("oleaut32.dll")]
    static extern int SafeArrayCopy(IntPtr psa, [MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_RECORD)] out Guid[] copy);
    delegate int GetIDsOfNamesFn(IntPtr self, ref Guid riid, IntPtr[] names, int count, int lcid, int[] ids);
    public static void Main() {
        var a = new Guid[] { new Guid("01234567-89ab-cdef-0123-456789abcdef"), Guid.Empty };
        IntPtr v = Marshal.AllocHGlobal(32);
        try {
            Marshal.GetNativeVariantForObject(a, v);
            IntPtr psa = Marshal.ReadIntPtr(v, 8), info, data;
            ushort evt; SafeArrayGetVartype(psa, out evt);
            bool hasinfo = SafeArrayGetRecordInfo(psa, out info) == 0 && info != IntPtr.Zero;
            if (hasinfo) Marshal.Release(info);
            SafeArrayAccessData(psa, out data);
            bool same = (Guid)Marshal.PtrToStructure(data, typeof(Guid)) == a[0];
            SafeArrayUnaccessData(psa);
            Guid[] back; int hr = SafeArrayCopy(psa, out back);
            bool round = hr == 0 && back != null && back.Length == 2 && back[0] == a[0];
            Console.WriteLine("record=" + Marshal.ReadInt16(v).ToString("x") + "|" + evt + "|" + hasinfo + "|" + same + "|" + round);
            VariantClear(v);
        } catch (Exception e) { Console.WriteLine("record=" + e.GetType().Name + ": " + e.Message); }
        try {
            IntPtr disp = Marshal.GetIDispatchForObject(new Disp());
            IntPtr fn = Marshal.ReadIntPtr(Marshal.ReadIntPtr(disp), 5 * IntPtr.Size);
            var gin = (GetIDsOfNamesFn)Marshal.GetDelegateForFunctionPointer(fn, typeof(GetIDsOfNamesFn));
            Guid none = Guid.Empty; int[] ids = new int[1];
            Console.WriteLine("nullname=" + gin(disp, ref none, new IntPtr[] { IntPtr.Zero }, 1, 0, ids).ToString("x8"));
        } catch (Exception e) { Console.WriteLine("nullname=" + e.GetType().Name); }
        try {
            var s = new AppDomainSetup();
            typeof(AppDomainSetup).GetProperty("TargetFrameworkName").SetValue(s, ".NETFramework,Version=v4.7.2");
            Console.WriteLine("tfm=" + s.TargetFrameworkName + "|" + (new AppDomainSetup().TargetFrameworkName == s.TargetFrameworkName));
        } catch (Exception e) { Console.WriteLine("tfm=" + e.GetType().Name); }
    }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg17.exe sg17.cs >"$T/mcs17.out" 2>&1)
[ -f "$C/sg17.exe" ] || { fail "the sg17 probe did not compile: $(cat "$T/mcs17.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg17.exe 2>&1 | tr -d '\r')
[ "$(v record)" = "2024|36|True|True|True" ] && pass "Guid[] goes to COM as SAFEARRAY(VT_RECORD) with an IRecordInfo and comes back (Visual Studio's IDE)" \
    || fail "Guid[] as a SAFEARRAY: '$(v record)'"
[ "$(v nullname)" = 80020006 ] && pass "a CCW's GetIDsOfNames with a NULL name is DISP_E_UNKNOWNNAME" || fail "GetIDsOfNames(NULL): '$(v nullname)'"
[ "$(v tfm)" = ".NETFramework,Version=v4.7.2|False" ] && pass "AppDomainSetup.TargetFrameworkName can be set (VsAppDomainManager)" || fail "TargetFrameworkName: '$(v tfm)'"
exit $RC
