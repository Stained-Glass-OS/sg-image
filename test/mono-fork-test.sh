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
#   - (sg20) the debugger agent only over the user's own Unix socket (no TCP);
#   - (sg21) Visual Studio 2022's IDE: an [Out] array of interfaces filled by
#     managed code reaches native code; [ComEventInterface] events; a new COM
#     object handed to managed code stays alive (the RCW takes its reference
#     first); a CCW released once too often does not abort; NoPIA type
#     equivalence; RCW casts through a proxy made for an interface; Marshal.
#     CleanupUnusedObjectsInCurrentContext returns; a typed RCW for an
#     interface is the object's own RCW (mono-0010..0017; 0016, a blocking
#     thread whose preemptive suspend failed, is gated by wine-sg's
#     test-agentgone);
#   - (sg22) an interface pointer a native caller passes that is no object
#     (misaligned, unmapped, an unreadable vtable) reaches the managed method
#     as null, not a crash (Visual Studio's IPropertyBag.Read; mono-0018);
#   - (sg23) an [Out] or [In, Out] array of strings a native COM method fills
#     comes back with the strings it wrote, BSTR and LPWStr (Visual Studio's
#     IVsSettingsManager.GetCommonExtensionsSearchPaths: the array came back
#     empty, so no CommonExtensions and no C++ project system; mono-0019);
#   - (sg18) a thread that came into managed code from native code reports
#     the COM apartment it is in (GetApartmentState, ApartmentState), not
#     Unknown: Visual Studio's main thread is an STA, and WPF refused it
#     ("The calling thread must be STA"); a CCW asked for a [ComVisible(false)]
#     interface answers E_NOINTERFACE, as .NET does (Visual Studio's shell
#     asked for a service id marker interface and crashed in what came back).
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
# absolute: the probes are compiled from inside the prefix (cd), and make passes build/... relative
[ -n "$MONO" ] && MONO=$(CDPATH='' cd -- "$MONO" && pwd)
[ -x "$WINE" ] || { echo "SKIP: no wine at $WINE"; exit 77; }
[ -n "$MONO" ] || { echo "SKIP: no packaged Wine Mono (make mono-deb)"; exit 77; }
command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "SKIP: mingw-w64 not installed"; exit 77; }
command -v msiinfo >/dev/null || { echo "SKIP: msitools not installed"; exit 77; }
unset DISPLAY
T=$(mktemp -d /var/tmp/sg-monofork.XXXXXX)
export HOME="$T/home" WINEPREFIX="$T/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="mshtml=;winemenubuilder.exe=d"
# a runtime directory of its own: Wine's Wayland driver connects to
# $XDG_RUNTIME_DIR/wayland-0 by default -- on a Stained Glass machine the
# person's live desktop, where a display-less wineboot then waited for ever
# (2026-11-16). And the XDG spec's data dirs (a ~/.profile can drop /usr/share,
# and the Vulkan loader finds no driver).
export XDG_RUNTIME_DIR="$T/run" WAYLAND_DISPLAY=sg-no-wayland XDG_DATA_DIRS=/usr/local/share:/usr/share
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
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
# (sg18) native threads in an STA and in the MTA, calling into managed code
cat > "$C/sg18.cs" <<'CS'
using System; using System.Runtime.InteropServices; using System.Threading;
class A {
    delegate uint ThreadProc(IntPtr arg);
    [DllImport("kernel32.dll")] static extern IntPtr CreateThread(IntPtr a, UIntPtr s, ThreadProc p, IntPtr arg, uint f, out uint id);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr r, uint flags);
    static ApartmentState sta = ApartmentState.Unknown, mta = ApartmentState.Unknown, prop = ApartmentState.Unknown;
    static uint StaProc(IntPtr arg) { CoInitializeEx(IntPtr.Zero, 2); sta = Thread.CurrentThread.GetApartmentState(); prop = Thread.CurrentThread.ApartmentState; return 0; }
    static uint MtaProc(IntPtr arg) { CoInitializeEx(IntPtr.Zero, 0); mta = Thread.CurrentThread.GetApartmentState(); return 0; }
    static ThreadProc p1 = StaProc, p2 = MtaProc;
    static void Main() {
        uint id;
        WaitForSingleObject(CreateThread(IntPtr.Zero, UIntPtr.Zero, p1, IntPtr.Zero, 0, out id), 30000);
        WaitForSingleObject(CreateThread(IntPtr.Zero, UIntPtr.Zero, p2, IntPtr.Zero, 0, out id), 30000);
        Console.WriteLine("apartment=" + sta + "|" + prop + "|" + mta);
        IntPtr unk = Marshal.GetIUnknownForObject(new Service()), p;
        Guid marker = typeof(IMarker).GUID, visible = typeof(IVisible).GUID;
        int hm = Marshal.QueryInterface(unk, ref marker, out p);
        if (p != IntPtr.Zero) Marshal.Release(p);
        int hv = Marshal.QueryInterface(unk, ref visible, out p);
        if (p != IntPtr.Zero) Marshal.Release(p);
        Marshal.Release(unk);
        Console.WriteLine("comvisible=" + hm.ToString("x8") + "|" + hv.ToString("x8"));
    }
}
[ComVisible(false), Guid("6F1C1D6A-7A55-4F1E-9C2B-3D7E1C0A5B11")] public interface IMarker { }
[ComVisible(true), Guid("6F1C1D6A-7A55-4F1E-9C2B-3D7E1C0A5B12"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVisible { [PreserveSig] int Answer(); }
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Service : IMarker, IVisible { public int Answer() { return 42; } }
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg18.exe sg18.cs >"$T/mcs18.out" 2>&1)
[ -f "$C/sg18.exe" ] || { fail "the sg18 probe did not compile: $(cat "$T/mcs18.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg18.exe 2>&1 | tr -d '\r')
[ "$(v apartment)" = "STA|STA|MTA" ] && pass "a native thread's apartment is what it is in, STA or MTA, not Unknown (Visual Studio's main thread)" \
    || fail "native threads' apartment: '$(v apartment)'"
[ "$(v comvisible)" = "80004002|00000000" ] && pass "a CCW asked for a [ComVisible(false)] interface says E_NOINTERFACE; a visible one is given (Visual Studio's shell)" \
    || fail "QueryInterface of a COM-invisible interface: '$(v comvisible)'"
# (sg20) the debugger agent's one transport is the user's own Unix socket:
# libmono exports mono_sg_debugger_unix_transport (Wine's mscoree starts no
# agent without it). That no TCP transport is ever opened, wine-sg 7791's
# monoagent gate checks (it and cordbgsdb drive the agent itself)
for lib in "$MONO"/bin/libmono-2.0-x86.dll "$MONO"/bin/libmono-2.0-x86_64.dll; do
    n=$(basename "$lib")
    if [ ! -f "$lib" ]; then fail "no $n"; continue; fi
    grep -a -q mono_sg_debugger_unix_transport "$lib" && pass "$n has the dt_unix debugger transport (the user's own socket)" \
        || fail "$n has no mono_sg_debugger_unix_transport"
done
# (sg20) SAFEARRAYs as System.Array, two [Out] SAFEARRAYs, and a Reflection.Emit
# assembly's [IgnoresAccessChecksTo]: Visual Studio's brokered services
# (IVsSettingsStore2.GetSubCollectionNames came back empty, so nothing was
# registered and Proffer threw), its first-launch window
# (GetPropertyNamesAndValues: SafeArrayTypeMismatch) and ServiceHub's proxies
# (MethodAccessException, then a crash)
cat > "$T/sa2.c" <<'C'
#include <windows.h>
#include <oleauto.h>
__declspec(dllexport) HRESULT WINAPI two_out(SAFEARRAY **names, SAFEARRAY **values)
{
    LONG i;
    VARIANT v;
    *names = SafeArrayCreateVector(VT_BSTR, 0, 2);
    *values = SafeArrayCreateVector(VT_VARIANT, 0, 2);
    i = 0; SafeArrayPutElement(*names, &i, SysAllocString(L"Background"));
    i = 1; SafeArrayPutElement(*names, &i, SysAllocString(L"Foreground"));
    i = 0; V_VT(&v) = VT_I4; V_I4(&v) = 42; SafeArrayPutElement(*values, &i, &v);
    i = 1; V_VT(&v) = VT_BSTR; V_BSTR(&v) = SysAllocString(L"blue"); SafeArrayPutElement(*values, &i, &v); VariantClear(&v);
    return S_OK;
}
C
x86_64-w64-mingw32-gcc -shared -O1 -o "$C/sa2.dll" "$T/sa2.c" -loleaut32 || { fail "sa2.dll did not build"; exit 1; }
cat > "$C/sg20.cs" <<'CS'
using System;
using System.Runtime.InteropServices;
using System.Reflection;
using System.Reflection.Emit;
class P {
    [DllImport("oleaut32.dll")] static extern IntPtr SafeArrayCreateVector(ushort vt, int lb, uint n);
    [DllImport("oleaut32.dll")] static extern int SafeArrayPutElement(IntPtr psa, ref int idx, [MarshalAs(UnmanagedType.BStr)] string v);
    [DllImport("oleaut32.dll", EntryPoint = "SafeArrayCopy")]
    static extern int CopyArray(IntPtr psa, [MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_BSTR)] out Array copy);
    [DllImport("sa2.dll")]
    static extern int two_out([MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_BSTR)] out Array names,
                              [MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_VARIANT)] out Array values);
    static string J(Array a) { if (a == null) return "null"; var s = new string[a.Length]; int i = 0; foreach (object o in a) s[i++] = o == null ? "null" : o.ToString(); return a.GetType() + ":" + string.Join(",", s); }
    static int Secret(int x) { return x * 7; }
    // a Reflection.Emit assembly that names this one in [IgnoresAccessChecksTo],
    // as StreamJsonRpc's/ServiceHub's proxies do, calls a private method
    static string Ignores() {
        var ab = AppDomain.CurrentDomain.DefineDynamicAssembly(new AssemblyName("proxies"), AssemblyBuilderAccess.Run);
        var mb = ab.DefineDynamicModule("proxies");
        var at = mb.DefineType("System.Runtime.CompilerServices.IgnoresAccessChecksToAttribute", TypeAttributes.NotPublic, typeof(Attribute));
        var ac = at.DefineConstructor(MethodAttributes.Public | MethodAttributes.HideBySig | MethodAttributes.SpecialName | MethodAttributes.RTSpecialName, CallingConventions.Standard, new[] { typeof(string) });
        var il = ac.GetILGenerator(); il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Call, typeof(Attribute).GetConstructor(BindingFlags.NonPublic | BindingFlags.Instance, null, Type.EmptyTypes, null)); il.Emit(OpCodes.Ret);
        var attr = at.CreateTypeInfo();
        ab.SetCustomAttribute(new CustomAttributeBuilder(attr.GetConstructor(new[] { typeof(string) }), new object[] { typeof(P).Assembly.GetName().Name }));
        var tb = mb.DefineType("Caller", TypeAttributes.Public);
        var m = tb.DefineMethod("Call", MethodAttributes.Public | MethodAttributes.Static, typeof(int), new[] { typeof(int) });
        il = m.GetILGenerator(); il.Emit(OpCodes.Ldarg_0); il.Emit(OpCodes.Call, typeof(P).GetMethod("Secret", BindingFlags.NonPublic | BindingFlags.Static)); il.Emit(OpCodes.Ret);
        var t = tb.CreateTypeInfo();
        try { return t.GetMethod("Call").Invoke(null, new object[] { 6 }).ToString(); }
        catch (TargetInvocationException e) { return "EXC " + e.InnerException.GetType().Name; }
    }
    static void Main() {
        try { Console.WriteLine("ignores=" + Ignores()); } catch (Exception e) { Console.WriteLine("ignores=EXC " + e.GetType().Name + " " + e.Message); }
        IntPtr psa = SafeArrayCreateVector(8 /* VT_BSTR */, 0, 3);
        string[] want = { "Alpha", "Beta", "Gamma" };
        for (int i = 0; i < 3; i++) SafeArrayPutElement(psa, ref i, want[i]);
        try { Array a; int hr = CopyArray(psa, out a); Console.WriteLine("array=" + hr + "|" + J(a)); }
        catch (Exception e) { Console.WriteLine("array=EXC " + e.GetType().Name); }
        try { Array n, v; int hr = two_out(out n, out v); Console.WriteLine("twoout=" + hr + "|" + J(n) + "|" + J(v)); }
        catch (Exception e) { Console.WriteLine("twoout=EXC " + e.GetType().Name); }
    }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg20.exe sg20.cs >"$T/mcs20.out" 2>&1)
[ -f "$C/sg20.exe" ] || { fail "the sg20 probe did not compile: $(cat "$T/mcs20.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg20.exe 2>&1 | tr -d '\r')
[ "$(v array)" = "0|System.String[]:Alpha,Beta,Gamma" ] && pass "a SAFEARRAY(VT_BSTR) declared as System.Array comes back as its strings (Visual Studio's brokered services)" \
    || fail "SAFEARRAY as System.Array: '$(v array)'"
[ "$(v twoout)" = "0|System.String[]:Background,Foreground|System.Object[]:42,blue" ] && pass "two [Out] SAFEARRAYs each come back as their own (Visual Studio's colour themes)" \
    || fail "two out SAFEARRAYs: '$(v twoout)'"
[ "$(v ignores)" = 42 ] && pass "a Reflection.Emit assembly with [IgnoresAccessChecksTo] calls the named assembly's private method (ServiceHub's proxies)" \
    || fail "IgnoresAccessChecksTo: '$(v ignores)'"
# (sg21) a managed enumerator's Next(celt, [Out] IItem[] (LPArray of
# interfaces), out fetched), called from native code through its CCW, hands
# back interface pointers: Visual Studio's msenv enumerates window frames this
# way and crashed on the NULL it got (the array was never marshaled back)
cat > "$T/outarr.c" <<'C'
#include <windows.h>
#include <stdio.h>
/* calls a managed enumerator's Next(1, IItem*[1], &fetched) as Visual Studio's msenv does with IEnumWindowFrames */
typedef struct IItem IItem;
typedef struct { HRESULT (WINAPI *QI)(IItem*, REFIID, void**); ULONG (WINAPI *AddRef)(IItem*); ULONG (WINAPI *Release)(IItem*); int (WINAPI *Answer)(IItem*); } IItemVtbl;
struct IItem { const IItemVtbl *lpVtbl; };
typedef struct IEnumItems IEnumItems;
typedef struct { HRESULT (WINAPI *QI)(IEnumItems*, REFIID, void**); ULONG (WINAPI *AddRef)(IEnumItems*); ULONG (WINAPI *Release)(IEnumItems*);
                 HRESULT (WINAPI *Next)(IEnumItems*, ULONG, IItem**, ULONG*); } IEnumItemsVtbl;
struct IEnumItems { const IEnumItemsVtbl *lpVtbl; };
__declspec(dllexport) int WINAPI call_next(IEnumItems *e)
{
    IItem *items[2] = { NULL, (IItem *)0x1 };
    ULONG fetched = 99;
    HRESULT hr = e->lpVtbl->Next(e, 1, items, &fetched);
    int answer = items[0] ? items[0]->lpVtbl->Answer(items[0]) : -1;
    printf("next=%08lx fetched=%lu item=%s answer=%d\n", hr, fetched, items[0] ? "set" : "null", answer);
    fflush(stdout);
    return answer;
}
C
x86_64-w64-mingw32-gcc -shared -O1 -o "$C/outarr.dll" "$T/outarr.c" || { fail "outarr.dll did not build"; exit 1; }
cat > "$C/sg21.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComVisible(true), Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A001"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IItem { [PreserveSig] int Answer(); }
[ComVisible(true), Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A002"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IEnumItems {
  [PreserveSig] int Next(uint celt, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.Interface, SizeParamIndex = 0)] IItem[] rgelt, out uint fetched);
}
[ComVisible(true), ClassInterface(ClassInterfaceType.None)] public class Item : IItem { public int Answer() { return 42; } }
[ComVisible(true), ClassInterface(ClassInterfaceType.None)] public class Items : IEnumItems {
  public int Next(uint celt, IItem[] rgelt, out uint fetched) { rgelt[0] = new Item(); fetched = 1; return 0; }
}
class P {
  [DllImport("outarr.dll")] static extern int call_next(IntPtr e);
  static void Main() {
    IntPtr p = Marshal.GetComInterfaceForObject(new Items(), typeof(IEnumItems));
    try { Console.WriteLine("outarr=" + call_next(p)); } catch (Exception e) { Console.WriteLine("outarr=EXC " + e.GetType().Name + " " + e.Message); }
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg21.exe sg21.cs >"$T/mcs21.out" 2>&1)
[ -f "$C/sg21.exe" ] || { fail "the sg21 probe did not compile: $(cat "$T/mcs21.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg21.exe 2>&1 | tr -d '\r')
[ "$(v outarr)" = 42 ] && pass "an [Out] array of interfaces filled by managed code reaches native code as interface pointers (Visual Studio's window frames)" \
    || fail "[Out] interface array from a CCW: '$(v outarr)' ($(printf '%s' "$out" | grep '^next=' | head -1))"
# (sg21) a COM object's events through its [ComEventInterface]: the
# interface's event provider is made once, with the object, and takes the
# add and remove calls, as .NET does (Visual Studio's packages subscribe to
# DTE CommandEvents this way; Mono threw InvalidCastException)
cat > "$T/comev.c" <<'C'
#include <windows.h>
/* a COM object that answers IUnknown and ISrc (an event source, as DTE's CommandEvents) */
static const GUID IID_ISrc = {0x2a9c4e11,0x7b2d,0x4c1e,{0x9f,0x00,0x11,0x22,0x33,0x44,0xa0,0x11}};
typedef struct { const void *vtbl; LONG ref; } Obj;
static HRESULT WINAPI qi(Obj *o, REFIID iid, void **out)
{
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_ISrc)) { *out = o; o->ref++; return S_OK; }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG WINAPI addref(Obj *o) { return ++o->ref; }
static ULONG WINAPI release(Obj *o) { return --o->ref; }
static const void *vtbl[] = { qi, addref, release };
static Obj obj = { vtbl, 1 };
__declspec(dllexport) void * WINAPI create_src(void) { return &obj; }
C
x86_64-w64-mingw32-gcc -shared -O1 -o "$C/comev.dll" "$T/comev.c" -luuid || { fail "comev.dll did not build"; exit 1; }
cat > "$C/sg21b.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A011"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ISrc { }
[ComEventInterface(typeof(ISrc), typeof(SrcEventProvider)), ComVisible(false)]
public interface ISrc_Event { event EventHandler Fired; }
[ComImport, Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A011")]
public interface Src : ISrc, ISrc_Event { }
sealed class SrcEventProvider : ISrc_Event {
  public static string log = "";
  public SrcEventProvider(object source) { log += source != null ? "ctor;" : "ctor-null;"; }
  public event EventHandler Fired { add { log += "add;"; } remove { log += "remove;"; } }
}
class P {
  [DllImport("comev.dll")] static extern IntPtr create_src();
  static void H(object s, EventArgs e) { }
  static void Main() {
    try {
      Src s = (Src)Marshal.GetObjectForIUnknown(create_src());
      s.Fired += H; s.Fired -= H; s.Fired += H;
      Console.WriteLine("comevent=" + SrcEventProvider.log);
    } catch (Exception e) { Console.WriteLine("comevent=EXC " + e.GetType().Name); }
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg21b.exe sg21b.cs >"$T/mcs21b.out" 2>&1)
[ -f "$C/sg21b.exe" ] || { fail "the sg21b probe did not compile: $(cat "$T/mcs21b.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg21b.exe 2>&1 | tr -d '\r')
[ "$(v comevent)" = "ctor;add;remove;add;" ] && pass "a [ComEventInterface] add/remove on a COM object goes to its event provider, made once with the object (Visual Studio's DTE events)" \
    || fail "COM event interface: '$(v comevent)'"

# (sg21) System.Core's System.Diagnostics.Eventing.EventProvider and
# EventDescriptor (no ETW session listening: not enabled, writes succeed);
# Visual Studio's source control package holds one (TypeLoadException)
cat > "$C/sg21c.cs" <<'CS'
using System; using System.Reflection;
class P {
  static void Main() {
    // by reflection, so the probe also builds where System.Core has no EventProvider
    Type t = Type.GetType("System.Diagnostics.Eventing.EventProvider, System.Core, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089");
    Type d = Type.GetType("System.Diagnostics.Eventing.EventDescriptor, System.Core, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089");
    if (t == null || d == null) { Console.WriteLine("eventprovider=missing"); return; }
    object p = Activator.CreateInstance(t, new object[] { Guid.NewGuid() });
    bool enabled = (bool)t.GetMethod("IsEnabled", Type.EmptyTypes).Invoke(p, null);
    bool wrote = (bool)t.GetMethod("WriteMessageEvent", new[] { typeof(string) }).Invoke(p, new object[] { "hello" });
    object ed = Activator.CreateInstance(d, new object[] { 7, (byte)1, (byte)0, (byte)4, (byte)0, 3, 0x10L });
    int id = (int)d.GetProperty("EventId").GetValue(ed, null);
    ((IDisposable)p).Dispose();
    Console.WriteLine("eventprovider=" + enabled + "|" + wrote + "|" + id + "|" + System.Runtime.InteropServices.Marshal.SizeOf(d));
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg21c.exe sg21c.cs >"$T/mcs21c.out" 2>&1)
[ -f "$C/sg21c.exe" ] || { fail "the sg21c probe did not compile: $(cat "$T/mcs21c.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg21c.exe 2>&1 | tr -d '\r')
[ "$(v eventprovider)" = "False|True|7|16" ] && pass "System.Diagnostics.Eventing.EventProvider and EventDescriptor exist: not enabled, a write succeeds, a 16-byte descriptor (Visual Studio's TFS tracing)" \
    || fail "EventProvider: '$(v eventprovider)'"
# (sg21) a COM object handed to managed code that nobody holds yet
# (reference count 0) stays alive: the wrapper takes its reference before
# GetProxy drops its own (Visual Studio's msenv advises a new solution events
# sink this way; the sink deleted itself and Mono crashed in QueryInterface)
cat > "$T/rcwref.c" <<'C'
#include <windows.h>
#include <stdio.h>
/* native code hands a managed method a new object that nobody holds yet (reference count 0),
 * as Visual Studio's msenv does with its solution events sink; the object deletes itself
 * (here: poisons its vtable) when its count drops back to 0 */
static const GUID IID_IItem2 = {0x2a9c4e11,0x7b2d,0x4c1e,{0x9f,0x00,0x11,0x22,0x33,0x44,0xa0,0x21}};
typedef struct Obj { const void *vtbl; LONG ref; } Obj;
static const void *dead_vtbl = (void *)-1;
static HRESULT WINAPI qi(Obj *o, REFIID iid, void **out)
{
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IItem2)) { *out = o; o->ref++; return S_OK; }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG WINAPI addref(Obj *o) { return ++o->ref; }
static ULONG WINAPI release(Obj *o) { ULONG r = --o->ref; if (!r) o->vtbl = dead_vtbl; return r; }
static int WINAPI answer(Obj *o) { return 7; }
static const void *vtbl[] = { qi, addref, release, answer };
typedef struct ITaker ITaker;
typedef struct { HRESULT (WINAPI *QI)(ITaker*, REFIID, void**); ULONG (WINAPI *AddRef)(ITaker*); ULONG (WINAPI *Release)(ITaker*);
                 int (WINAPI *Take)(ITaker*, Obj*); } ITakerVtbl;
struct ITaker { const ITakerVtbl *lpVtbl; };
__declspec(dllexport) int WINAPI give_new_object(ITaker *t)
{
    static Obj o;
    o.vtbl = vtbl; o.ref = 0;
    return t->lpVtbl->Take(t, &o);
}
C
x86_64-w64-mingw32-gcc -shared -O1 -o "$C/rcwref.dll" "$T/rcwref.c" -luuid || { fail "rcwref.dll did not build"; exit 1; }
cat > "$C/sg21d.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A021"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IItem2 { [PreserveSig] int Answer(); }
[ComVisible(true), Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A022"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITaker { [PreserveSig] int Take([MarshalAs(UnmanagedType.Interface)] object item); }
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Taker : ITaker { public int Take(object item) { IItem2 i = item as IItem2; return i == null ? -2 : i.Answer(); } }
class P {
  [DllImport("rcwref.dll")] static extern int give_new_object(IntPtr taker);
  static void Main() {
    IntPtr p = Marshal.GetComInterfaceForObject(new Taker(), typeof(ITaker));
    try { Console.WriteLine("rcwref=" + give_new_object(p)); } catch (Exception e) { Console.WriteLine("rcwref=EXC " + e.GetType().Name); }
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg21d.exe sg21d.cs >"$T/mcs21d.out" 2>&1)
[ -f "$C/sg21d.exe" ] || { fail "the sg21d probe did not compile: $(cat "$T/mcs21d.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg21d.exe 2>&1 | tr -d '\r')
[ "$(v rcwref)" = 7 ] && pass "an object handed over with no reference yet stays alive in its runtime callable wrapper (Visual Studio's solution events sink)" \
    || fail "count-0 object to managed code: '$(v rcwref)' (sg20 crashes)"
# (sg21) a COM callable wrapper released once too often: the process goes on
# (sg20 asserted "ccw->ref_count > 0" and aborted; Visual Studio 2022 ended at
# startup on its VSTelemetrySession wrapper)
cat > "$C/sg21e.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComVisible(true), Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A031"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IThing { [PreserveSig] int Answer(); }
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Thing : IThing { public int Answer() { return 7; } }
class P {
  static void Main() {
    Thing t = new Thing();
    IntPtr p = Marshal.GetComInterfaceForObject(t, typeof(IThing));
    int first = Marshal.Release(p);
    int extra = Marshal.Release(p);
    IntPtr q = Marshal.GetComInterfaceForObject(t, typeof(IThing));
    int again = Marshal.Release(q);
    Console.WriteLine("ccwover=" + first + "," + extra + "," + again);
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg21e.exe sg21e.cs >"$T/mcs21e.out" 2>&1)
[ -f "$C/sg21e.exe" ] || { fail "the sg21e probe did not compile: $(cat "$T/mcs21e.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg21e.exe 2>&1 | tr -d '\r')
[ "$(v ccwover)" = "0,0,0" ] && pass "an extra Release of a COM callable wrapper is let pass, and the wrapper still works after (Visual Studio's VSTelemetrySession)" \
    || fail "extra CCW Release: '$(v ccwover)' (sg20 aborts)"
# (sg21) type equivalence (NoPIA): a method whose signature names an embedded
# interop interface ([TypeIdentifier], own copy in each assembly) is found from
# another assembly that embeds its own copy (Visual Studio 2022's extension
# manager: SetupEngineHelpers.GetApplicationName(ISetupInstance2, ...) was a
# MissingMethodException, and with it the editor's component model)
cat > "$C/sg21f_lib.cs" <<'CS'
using System; using System.Runtime.InteropServices;
namespace Setup.Interop {
  [ComImport, Guid("B41463C3-8866-43B5-BC33-2B0676F7F42E"), TypeIdentifier, InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface ISetupThing { }
}
public static class Helpers {
  public static string Name(Setup.Interop.ISetupThing t, int lcid) { return "name" + lcid; }
}
CS
cat > "$C/sg21f.il" <<'IL'
.assembly extern mscorlib { .publickeytoken = (B7 7A 5C 56 19 34 E0 89) .ver 4:0:0:0 }
.assembly extern sg21f_lib { }
.assembly sg21f { }
.module sg21f.exe
.class interface public abstract auto ansi import Setup.Interop.ISetupThing
{
  .custom instance void [mscorlib]System.Runtime.InteropServices.TypeIdentifierAttribute::.ctor() = ( 01 00 00 00 )
  .custom instance void [mscorlib]System.Runtime.InteropServices.GuidAttribute::.ctor(string) = ( 01 00 24 42 34 31 34 36 33 43 33 2D 38 38 36 36 2D 34 33 42 35 2D 42 43 33 33 2D 32 42 30 36 37 36 46 37 46 34 32 45 00 00 )
}
.class public auto ansi P extends [mscorlib]System.Object
{
  .method public static string Call() cil managed noinlining
  {
    ldnull
    ldc.i4.7
    call string [sg21f_lib]Helpers::Name(class Setup.Interop.ISetupThing, int32)
    ret
  }
  .method public static void Main() cil managed
  {
    .entrypoint
    .locals init (string V_0)
    .try {
      ldstr "nopia="
      call string P::Call()
      call string [mscorlib]System.String::Concat(string, string)
      call void [mscorlib]System.Console::WriteLine(string)
      leave.s done
    } catch [mscorlib]System.Exception {
      callvirt instance class [mscorlib]System.Type [mscorlib]System.Object::GetType()
      callvirt instance string [mscorlib]System.Reflection.MemberInfo::get_Name()
      stloc.0
      ldstr "nopia=EXC "
      ldloc.0
      call string [mscorlib]System.String::Concat(string, string)
      call void [mscorlib]System.Console::WriteLine(string)
      leave.s done
    }
    done: ret
  }
}
IL
(cd "$C" && timeout 300 "$WINE" "$mcs" -t:library -out:sg21f_lib.dll sg21f_lib.cs >"$T/mcs21f.out" 2>&1)
[ -f "$C/sg21f_lib.dll" ] || { fail "the sg21f library did not compile: $(cat "$T/mcs21f.out")"; exit 1; }
ilasm=$("$WINE" winepath -w "$MONO/lib/mono/4.5/ilasm.exe" | tr -d '\r')
(cd "$C" && timeout 300 "$WINE" "$ilasm" /exe /out:sg21f.exe sg21f.il >"$T/ilasm21f.out" 2>&1)
[ -f "$C/sg21f.exe" ] || { fail "the sg21f probe did not assemble: $(cat "$T/ilasm21f.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg21f.exe 2>&1 | tr -d '\r')
[ "$(v nopia)" = name7 ] && pass "an embedded interop interface ([TypeIdentifier]) in two assemblies is one type in a call between them (Visual Studio's extension manager)" \
    || fail "type equivalence: '$(v nopia)' (sg20: EXC MissingMethodException)"
# (sg21) RCW casts through a proxy made for an interface (no stack overflow;
# Visual Studio 2022's UI thread), and Marshal.CleanupUnusedObjectsInCurrentContext
# returns (Visual Studio's idle loop)
cat > "$T/sg21g_obj.c" <<'C'
#include <windows.h>
/* a COM object with IUnknown and one interface; QI for anything else fails */
static const GUID IID_IItem3 = {0x2a9c4e11,0x7b2d,0x4c1e,{0x9f,0x00,0x11,0x22,0x33,0x44,0xa0,0x41}};
typedef struct Obj { const void *vtbl; LONG ref; } Obj;
static HRESULT WINAPI qi(Obj *o, REFIID iid, void **out)
{
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IItem3)) { *out = o; o->ref++; return S_OK; }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG WINAPI addref(Obj *o) { return ++o->ref; }
static ULONG WINAPI release(Obj *o) { return --o->ref; }
static int WINAPI answer(Obj *o) { return 9; }
static const void *vtbl[] = { qi, addref, release, answer };
__declspec(dllexport) void * WINAPI new_object(void) { static Obj o; o.vtbl = vtbl; o.ref = 1; return &o; }
C
x86_64-w64-mingw32-gcc -shared -O1 -o "$C/cancast.dll" "$T/sg21g_obj.c" -luuid || { fail "cancast.dll did not build"; exit 1; }
cat > "$C/sg21g.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A041"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IItem3 { [PreserveSig] int Answer(); }
[ComImport, Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A042"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface INotThere { [PreserveSig] int Nothing(); }
[ComImport, Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A043")]
public class ThingClass { }
class P {
  [DllImport("cancast.dll")] static extern IntPtr new_object();
  static string Try(Func<string> f) { try { return f(); } catch (Exception e) { return "EXC " + e.GetType().Name; } }
  static void Main() {
    Console.WriteLine("rcwclass=" + Try(() => { object o = Marshal.GetTypedObjectForIUnknown(new_object(), typeof(ThingClass)); return (o is IItem3) + "," + (o is INotThere) + "," + ((IItem3)o).Answer(); }));
    Console.WriteLine("rcwitf=" + Try(() => { object o = Marshal.GetTypedObjectForIUnknown(new_object(), typeof(IItem3)); return (o is IItem3) + "," + (o is INotThere); }));
    Console.WriteLine("cleanup=" + Try(() => { Marshal.CleanupUnusedObjectsInCurrentContext(); return "ok"; }));
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg21g.exe sg21g.cs >"$T/mcs21g.out" 2>&1)
[ -f "$C/sg21g.exe" ] || { fail "the sg21g probe did not compile: $(cat "$T/mcs21g.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg21g.exe 2>&1 | tr -d '\r')
[ "$(v rcwclass)" = "True,False,9" ] && pass "an RCW made for a COM class casts and calls as before" || fail "RCW for a class: '$(v rcwclass)'"
[ "$(v rcwitf)" = "True,False" ] && pass "an RCW made for an interface casts without overflowing the stack (Visual Studio's UI thread)" \
    || fail "RCW for an interface: '$(v rcwitf)' (sg20: EXC StackOverflowException)"
[ "$(v cleanup)" = ok ] && pass "Marshal.CleanupUnusedObjectsInCurrentContext returns (Visual Studio's idle loop)" \
    || fail "CleanupUnusedObjectsInCurrentContext: '$(v cleanup)' (sg20: EXC PlatformNotSupportedException)"
# (sg22) Marshal.GetTypedObjectForIUnknown for an interface gives the object's own
# RCW: its methods are called through COM, not remoting (Visual Studio 2022's
# licensing state; the IDE shut down after two minutes). Uses cancast.dll from sg21g.
cat > "$C/sg21h.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A041"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IItem3 { [PreserveSig] int Answer(); }
[ComImport, Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A042"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface INotThere { [PreserveSig] int Nothing(); }
class P {
  [DllImport("cancast.dll")] static extern IntPtr new_object();
  static string Try(Func<string> f) { try { return f(); } catch (Exception e) { return "EXC " + e.GetType().Name; } }
  static void Main() {
    Console.WriteLine("itfcall=" + Try(() => { object o = Marshal.GetTypedObjectForIUnknown(new_object(), typeof(IItem3)); return ((IItem3)o).Answer().ToString(); }));
    Console.WriteLine("itfsame=" + Try(() => { IntPtr p = new_object(); return (Marshal.GetTypedObjectForIUnknown(p, typeof(IItem3)) == Marshal.GetObjectForIUnknown(p)).ToString(); }));
    Console.WriteLine("itfnot=" + Try(() => { object o = Marshal.GetTypedObjectForIUnknown(new_object(), typeof(IItem3)); return (o is INotThere).ToString(); }));
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg21h.exe sg21h.cs >"$T/mcs21h.out" 2>&1)
[ -f "$C/sg21h.exe" ] || { fail "the sg21h probe did not compile: $(cat "$T/mcs21h.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg21h.exe 2>&1 | tr -d '\r')
[ "$(v itfcall)" = 9 ] && pass "a method called through a typed RCW for an interface goes through COM (Visual Studio's licensing state)" \
    || fail "call through a typed RCW for an interface: '$(v itfcall)' (sg21: EXC Exception, not implemented)"
[ "$(v itfsame)" = True ] && pass "the typed RCW for an interface is the object's own wrapper" || fail "typed RCW identity: '$(v itfsame)'"
[ "$(v itfnot)" = False ] && pass "and does not cast to an interface the object lacks" || fail "typed RCW cast to a missing interface: '$(v itfnot)'"
# (sg22) a native caller that passes something that is no object for an interface parameter
# of a managed method -- misaligned, unmapped, or with an unreadable vtable -- gets null there,
# not a crash (Visual Studio's managed IPropertyBag.Read declares RemoteRead's 5 parameters;
# native callers pass the 3-argument Read, so pUnkObj is stack junk: devenv crashed opening a
# solution). A defensive guard against bad callers; .NET Framework's own handling is unproven.
cat > "$T/sg21i.c" <<'C'
#include <windows.h>
/* native code calls a managed object's interface method with a value that is no object in its
 * interface parameter -- what a caller that passes fewer arguments than the managed declaration
 * has leaves there (Visual Studio's IPropertyBag.Read): it must arrive as null, not crash */
typedef struct ITaker2 ITaker2;
typedef struct { HRESULT (WINAPI *QI)(ITaker2*, REFIID, void**); ULONG (WINAPI *AddRef)(ITaker2*); ULONG (WINAPI *Release)(ITaker2*);
                 int (WINAPI *Take)(ITaker2*, void *item); } ITaker2Vtbl;
struct ITaker2 { const ITaker2Vtbl *lpVtbl; };
static char junk[64];
__declspec(dllexport) int WINAPI give_misaligned(ITaker2 *t) { return t->lpVtbl->Take(t, junk + 3); }
__declspec(dllexport) int WINAPI give_unmapped(ITaker2 *t)
{
    /* an aligned address with nothing mapped: reserve a page, then release it */
    void *p = VirtualAlloc(NULL, 4096, MEM_RESERVE, PAGE_NOACCESS);
    VirtualFree(p, 0, MEM_RELEASE);
    return t->lpVtbl->Take(t, p);
}
__declspec(dllexport) int WINAPI give_badvtable(ITaker2 *t)
{
    /* a readable, aligned object whose vtable pointer leads nowhere */
    static void *obj[2];
    void *p = VirtualAlloc(NULL, 4096, MEM_RESERVE, PAGE_NOACCESS);
    VirtualFree(p, 0, MEM_RELEASE);
    obj[0] = p;
    return t->lpVtbl->Take(t, obj);
}
C
x86_64-w64-mingw32-gcc -shared -O1 -o "$C/misalign.dll" "$T/sg21i.c" || { fail "misalign.dll did not build"; exit 1; }
cat > "$C/sg21i.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A051"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IItem4 { [PreserveSig] int Answer(); }
[ComVisible(true), Guid("2A9C4E11-7B2D-4C1E-9F00-11223344A052"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITaker2 { [PreserveSig] int Take([MarshalAs(UnmanagedType.Interface)] IItem4 item); }
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Taker2 : ITaker2 { public int Take(IItem4 item) { return item == null ? 1 : 2; } }
class P {
  [DllImport("misalign.dll")] static extern int give_misaligned(IntPtr taker);
  [DllImport("misalign.dll")] static extern int give_unmapped(IntPtr taker);
  [DllImport("misalign.dll")] static extern int give_badvtable(IntPtr taker);
  static string Try(Func<int> f) { try { return f().ToString(); } catch (Exception e) { return "EXC " + e.GetType().Name; } }
  static void Main() {
    IntPtr p = Marshal.GetComInterfaceForObject(new Taker2(), typeof(ITaker2));
    Console.WriteLine("misaligned=" + Try(() => give_misaligned(p)));
    Console.WriteLine("unmapped=" + Try(() => give_unmapped(p)));
    Console.WriteLine("badvtable=" + Try(() => give_badvtable(p)));
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg21i.exe sg21i.cs >"$T/mcs21i.out" 2>&1)
[ -f "$C/sg21i.exe" ] || { fail "the sg21i probe did not compile: $(cat "$T/mcs21i.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg21i.exe 2>&1 | tr -d '\r')
for k in misaligned unmapped badvtable; do
    [ "$(v $k)" = 1 ] && pass "a native caller's $k interface pointer reaches the managed method as null (Visual Studio's IPropertyBag.Read)" \
        || fail "$k interface pointer from a native caller: '$(v $k)' (sg21 crashes)"
done
# (sg23) a native COM method that fills a caller-allocated array of strings (count, array,
# actual) -- Visual Studio's IVsSettingsManager.GetCommonExtensionsSearchPaths, declared
# [In] uint, [Out, MarshalAs(LPArray, ArraySubType=BStr, SizeParamIndex=0)] string[], out uint --
# gives the managed array the strings it wrote. Mono freed them and left the array as it went in
# (nulls): VS found no CommonExtensions, so no CPS parts and no C++ project system (mono-0019).
cat > "$T/sg23.c" <<'C'
#include <windows.h>
#include <oleauto.h>
typedef struct Obj Obj;
typedef struct { HRESULT (WINAPI *QI)(Obj*, REFIID, void**); ULONG (WINAPI *AddRef)(Obj*); ULONG (WINAPI *Release)(Obj*);
                 HRESULT (WINAPI *GetBstr)(Obj*, UINT, BSTR*, UINT*); HRESULT (WINAPI *GetWstr)(Obj*, UINT, WCHAR**, UINT*); } ObjVtbl;
struct Obj { const ObjVtbl *lpVtbl; LONG ref; };
static const WCHAR *names[] = { L"C:\\SG\\CommonExtensions", L"C:\\SG\\Extensions\\Second" };
static HRESULT WINAPI qi(Obj *o, REFIID iid, void **out) { *out = o; InterlockedIncrement(&o->ref); return S_OK; }
static ULONG WINAPI addref(Obj *o) { return InterlockedIncrement(&o->ref); }
static ULONG WINAPI release(Obj *o) { return InterlockedDecrement(&o->ref); }
static HRESULT WINAPI get_bstr(Obj *o, UINT count, BSTR *paths, UINT *actual)
{
    UINT i;
    *actual = 2;
    for (i = 0; i < count && i < 2; i++) paths[i] = SysAllocString(names[i]);
    return S_OK;
}
static HRESULT WINAPI get_wstr(Obj *o, UINT count, WCHAR **paths, UINT *actual)
{
    UINT i;
    *actual = 2;
    for (i = 0; i < count && i < 2; i++)
    {
        paths[i] = CoTaskMemAlloc((lstrlenW(names[i]) + 1) * sizeof(WCHAR));
        lstrcpyW(paths[i], names[i]);
    }
    return S_OK;
}
static const ObjVtbl vtbl = { qi, addref, release, get_bstr, get_wstr };
static Obj the = { &vtbl, 1 };
__declspec(dllexport) HRESULT WINAPI get_paths_object(IUnknown **out) { *out = (IUnknown *)&the; return S_OK; }
C
x86_64-w64-mingw32-gcc -shared -O1 -o "$C/sgpaths.dll" "$T/sg23.c" -loleaut32 -lole32 || { fail "sgpaths.dll did not build"; exit 1; }
cat > "$C/sg23.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("4F3A6C2E-5B1D-4E8A-9C7F-2D6B8E1A9F30"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPaths {
  [PreserveSig] int GetBstr([In] uint paths, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.BStr, SizeParamIndex = 0)] string[] p, out uint actual);
  [PreserveSig] int GetWstr([In] uint paths, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr, SizeParamIndex = 0)] string[] p, out uint actual);
}
[ComImport, Guid("4F3A6C2E-5B1D-4E8A-9C7F-2D6B8E1A9F30"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPathsInOut {
  [PreserveSig] int GetBstr([In] uint paths, [In, Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.BStr, SizeParamIndex = 0)] string[] p, out uint actual);
}
class P {
  [DllImport("sgpaths.dll")] static extern int get_paths_object([MarshalAs(UnmanagedType.IUnknown)] out object o);
  static string Show(string[] a) { return string.Join("|", Array.ConvertAll(a, s => s ?? "null")); }
  static void Main() {
    object o; uint n;
    get_paths_object(out o);
    IPaths p = (IPaths)o;
    p.GetBstr(0, new string[0], out n);
    Console.WriteLine("pathcount=" + n);
    string[] a = new string[n]; p.GetBstr(n, a, out n);
    Console.WriteLine("bstrout=" + Show(a));
    string[] w = new string[2]; p.GetWstr(2, w, out n);
    Console.WriteLine("wstrout=" + Show(w));
    string[] io = new string[2]; ((IPathsInOut)o).GetBstr(2, io, out n);
    Console.WriteLine("bstrinout=" + Show(io));
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg23.exe sg23.cs >"$T/mcs23.out" 2>&1)
[ -f "$C/sg23.exe" ] || { fail "the sg23 probe did not compile: $(cat "$T/mcs23.out")"; exit 1; }
out=$(cd "$C" && timeout 180 "$WINE" sg23.exe 2>&1 | tr -d '\r')
want='C:\SG\CommonExtensions|C:\SG\Extensions\Second'
[ "$(v pathcount)" = 2 ] && pass "a native COM method's count comes back through an out uint" || fail "count: '$(v pathcount)'"
for k in bstrout wstrout bstrinout; do
    [ "$(v $k)" = "$want" ] && pass "$k: the strings a native COM method wrote into the caller's array come back (Visual Studio's CommonExtensions search paths)" \
        || fail "$k: '$(v $k)' (sg22: null|null)"
done
exit $RC
