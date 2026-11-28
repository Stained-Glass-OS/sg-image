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
#   - (sg24) releasing the last reference to a wrapper of an object of another
#     apartment (a call into that apartment) does not hold Mono's COM lock:
#     with it held, the apartment's thread waiting for the lock deadlocked
#     with it (Visual Studio's Start window never answered; mono-0020);
#   - (sg26) Type.MetadataToken of an array, pointer or byref type is the nil
#     TypeDef token and a generic parameter's its GenericParam row, as the
#     CLR's (Visual Studio's MEF cache refused Mono's 0: no project
#     templates; mono-0021); WebRequest.Create works for a user without an
#     Internet Settings key (mono-0022); Marshal.CreateAggregatedObject
#     aggregates a managed object into a native COM object (Visual Studio's
#     DTE.Solution threw NotImplementedException; mono-0023);
#   - (sg34) late binding to COM objects: Type.InvokeMember on a COM object
#     through its IDispatch (methods, properties, named arguments, [DISPID=n],
#     the object's own errors), and C# "dynamic" on COM objects (Mesen's
#     WScript.Shell CreateShortcut; mono-0031, corefx-0004);
#   - (sg37) GetIPv4Properties with an adapter of several name servers
#     (mono-0035: GetPerAdapterInfo's buffer sized as it asks) is gated by
#     wine-sg's test/tcpipreg-gate.sh with SG_MONO_DIR (it needs adapters
#     whose servers the gate sets, in a network namespace of its own);
#   - (sg36) a configuration section may keep the reader DeserializeSection
#     gets and read it later (GetRuntimeObject), as on .NET Framework: Mono
#     closed it, and SyncTrayzor's settings section read as nothing
#     (NullReferenceException at start; mono-0034);
#   - (sg35) Windows Runtime classes named by the Windows SDK's contract
#     assemblies (Windows.Foundation.UniversalApiContract, FoundationContract,
#     Services.Store.StoreContract) resolve to the system's metadata, as the
#     CLR resolves them by namespace (Cyberduck died at start); the toast,
#     XML, package, application data, Store and ApiInformation classes are the
#     system's (Wine's) objects, events and IAsyncOperation included, and
#     System.Runtime.WindowsRuntime bridges them to tasks (mono-0032,
#     wine-mono-0005); the C++/CLI runtime's RegisterModuleUninitializer and
#     ThrowModuleLoadException are managed, as msvcm80/90's are (Apache
#     OpenOffice's cli_uno; mono-0033);
#   - (sg33) NetworkInterface.GetIPStatistics gives every interface's
#     counters (.NET Framework 4.6+; LibreHardwareMonitor died at start), and
#     MIB_IFROW's DWORD counters are read unsigned (mono-0030);
#   - (sg32) arrays into a managed COM method: an unsized LPArray is one
#     element, non-blittable struct arrays are converted both ways; a VT_RECORD
#     VARIANT becomes its managed value type or System.Guid (Visual Studio's
#     IVsFontAndColorDefaults.GetItem, IVsGuidParserPrivate.TryParseGuid;
#     mono-0029);
#   - (sg31) a SAFEARRAY from native code into a managed System.Array
#     parameter: an array of its SafeArrayUserDefinedSubType (Visual Studio's
#     IVCTask[]; the type name read from the marshal blob, also when it is
#     longer than 127 bytes), or of what the SAFEARRAY holds when no element
#     type is declared (mono-0028);
#   - (sg30) Visual Studio's C++ project system: an emitted type in a dynamic
#     assembly carrying [IgnoresAccessChecksTo] implements another assembly's
#     private nested interface (vs-mef metadata view proxies); [In, Out] on a
#     by-value IntPtr of a managed COM method does not abort Mono; a VARIANT
#     takes VT_UNKNOWN/VT_DISPATCH by QueryInterface; a collected object's
#     wrapper called from native code fails with an HRESULT (mono-0027);
#   - (sg29) a bool[] in a COM interface method is an array of VARIANT_BOOLs
#     (two bytes, -1 for true) unless its ArraySubType says otherwise (I1 one
#     byte, Bool four), both from managed to native code and into a managed
#     object's COM wrapper (Visual Studio's MEF host asked which component
#     assemblies may load; read as four-byte BOOLs only the first half came
#     back approved and the core editor's parts were never scanned;
#     mono-0026);
#   - (sg28) a SAFEARRAY a native caller passes by reference to a managed
#     COM method (ref object[]) reaches it as an array, and a ref (in/out)
#     one goes back to the caller as the array the method left (Visual
#     Studio calling a C++ project wizard's IDTWizard.Execute: Mono threw
#     "Byref input safearray marshaling not implemented", so Create made no
#     project; mono-0025);
#   - (sg27) a frame of code emitted at run time (Reflection.Emit) is
#     printed with an all-zero module id: its image has no #GUID heap, and
#     printing the stack of an exception through it (WINE_MONO_TRACE=E:all,
#     Mono's native frame printing) read through NULL -- Visual Studio
#     crashed 3 minutes after start whenever exceptions were traced
#     (mono-0024);
#   - (sg25) EndWaitForConnection on a named pipe server that was disposed
#     is ObjectDisposedException, as the .NET Framework's (also after a
#     client connected): Visual Studio's response-time channel went on to use
#     the closed pipe and the IDE died a minute after start (corefx-0003);
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
# (sg24) Mono released a wrapper's (RCW's) COM interfaces with its COM lock held. A release that
# waits -- a proxy's, calling into another apartment or process -- then kept every thread that needs
# the lock (Marshal.GetCCW, GetIUnknownForObject) waiting with it: Visual Studio's UI thread waited
# in GetCCW while its finalizer's release of a proxy waited, and the Start window never answered
# (mono-0020). A native object whose last release waits for the main thread's signal; the main
# thread takes the lock meanwhile, then signals.
cat > "$T/sg24.c" <<'C'
#include <windows.h>
/* a native object whose last Release waits for the program's main thread (an event it sets): what
 * a release that calls into a busy apartment or another process does */
typedef struct Obj Obj;
typedef struct { HRESULT (WINAPI *QI)(Obj*, REFIID, void**); ULONG (WINAPI *AddRef)(Obj*); ULONG (WINAPI *Release)(Obj*); } ObjVtbl;
struct Obj { const ObjVtbl *lpVtbl; LONG ref; };
static HANDLE gate;
static HRESULT WINAPI qi(Obj *o, REFIID iid, void **out)
{
    /* every interface asked for is this object (only IUnknown's methods are called) */
    *out = o; InterlockedIncrement(&o->ref); return S_OK;
}
static ULONG WINAPI addref(Obj *o) { return InterlockedIncrement(&o->ref); }
static ULONG WINAPI release(Obj *o)
{
    ULONG r = InterlockedDecrement(&o->ref);
    if (!r) WaitForSingleObject(gate, 60000);
    return r;
}
static const ObjVtbl vtbl = { qi, addref, release };
static Obj the = { &vtbl, 1 };
__declspec(dllexport) void * WINAPI make_slow_release(HANDLE event) { gate = event; return &the; }
C
x86_64-w64-mingw32-gcc -shared -O1 -o "$C/sgapt.dll" "$T/sg24.c" || { fail "sgapt.dll did not build"; exit 1; }
cat > "$C/sg24.cs" <<'CS'
using System; using System.Threading; using System.Runtime.InteropServices;
[ComImport, Guid("6B1D3C2E-0A4F-4E7B-9D5A-1C2B3A4D5E6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISgReleased { }
class P {
  [DllImport("sgapt.dll")] static extern IntPtr make_slow_release(IntPtr gate);
  static void Main() {
    ManualResetEvent gate = new ManualResetEvent(false), ready = new ManualResetEvent(false), done = new ManualResetEvent(false);
    IntPtr unk = make_slow_release(gate.SafeWaitHandle.DangerousGetHandle());
    object rcw = Marshal.GetObjectForIUnknown(unk);
    Marshal.Release(unk);
    ISgReleased itf = (ISgReleased)rcw;   /* an interface of the wrapper (it is released with it) */
    GC.KeepAlive(itf);
    Thread t = new Thread(() => {
      ready.Set();
      Marshal.FinalReleaseComObject(rcw);   /* the last release waits for the main thread */
      done.Set();
    });
    t.Start();
    ready.WaitOne();
    Thread.Sleep(500);
    /* the main thread takes Mono's COM lock while that release waits */
    DateTime end = DateTime.Now.AddSeconds(2);
    object mine = new object();   /* one object: the loop allocates nothing (no collection waits for the release) */
    while (DateTime.Now < end) Marshal.Release(Marshal.GetIUnknownForObject(mine));
    Console.WriteLine("lockfree=1");
    gate.Set();
    Console.WriteLine("released=" + (done.WaitOne(30000) ? 1 : 0));
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg24.exe sg24.cs >"$T/mcs24.out" 2>&1)
[ -f "$C/sg24.exe" ] || { fail "the sg24 probe did not compile: $(cat "$T/mcs24.out")"; exit 1; }
out=$(cd "$C" && timeout -s KILL 120 "$WINE" sg24.exe 2>&1 | tr -d '\r')
[ "$(v lockfree)" = 1 ] && pass "a COM object's last release that waits does not hold Mono's COM lock (Visual Studio's Start window)" \
    || fail "the main thread never got Mono's COM lock while a release waited: a deadlock (sg23 releases with the lock held)"
[ "$(v released)" = 1 ] && pass "and the release finishes once it may" || fail "the waiting release: '$(v released)'"
# (sg25) EndWaitForConnection on a server that was closed (disposed) is ObjectDisposedException,
# "Cannot access a closed pipe", as the .NET Framework's is -- also when the client's connection
# came in before the close. Mono's returned normally (or threw IOException 0x2a4 for a wait the
# close ended), and a callback written for the Framework went on to use the pipe that was gone:
# Visual Studio's response-time channel (ChannelReceiver.channelConnectedCallback) died with an
# unhandled ObjectDisposedException a minute after start (corefx-0003). Each case in a process of
# its own; the callback waits until the case says go.
cat > "$C/sg25.cs" <<'CS'
using System; using System.IO; using System.IO.Pipes; using System.Threading;
class P {
  static string Try(Action f) { try { f(); return "ok"; } catch (Exception e) { return e.GetType().Name; } }
  /* a server waiting with BeginWaitForConnection; "between" runs while the callback waits for "go" */
  static void Run(string key, Action<NamedPipeServerStream, string, ManualResetEvent> between) {
    string pn = "sg25-" + key + "-" + Environment.TickCount;
    var s = new NamedPipeServerStream(pn, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
    ManualResetEvent go = new ManualResetEvent(false), done = new ManualResetEvent(false);
    string end = "none", conn = "none";
    s.BeginWaitForConnection(ar => {
      go.WaitOne(10000);
      end = Try(() => s.EndWaitForConnection(ar));
      conn = s.IsConnected ? "1" : "0";
      done.Set();
    }, null);
    between(s, pn, go);
    done.WaitOne(10000);
    Console.WriteLine(key + "end=" + end);
    Console.WriteLine(key + "conn=" + conn);
    s.Dispose();
  }
  static void Main(string[] a) {
    string only = a.Length > 0 ? a[0] : "";
    /* a client connects; the server is disposed before the callback calls End (VS's response-time channel) */
    if (only == "" || only == "cd") Run("cd", (s, pn, go) => { var c = new NamedPipeClientStream(".", pn); c.Connect(5000); Thread.Sleep(300); s.Dispose(); go.Set(); Thread.Sleep(300); c.Dispose(); });
    /* the server is disposed while it waits, no client */
    if (only == "" || only == "d") Run("d", (s, pn, go) => { Thread.Sleep(200); s.Dispose(); go.Set(); });
    /* a client connects and the server talks to it: unchanged */
    if (only == "" || only == "c") Run("c", (s, pn, go) => {
      var c = new NamedPipeClientStream(".", pn, PipeDirection.InOut); c.Connect(5000); go.Set();
      int got = -1; var r = new Thread(() => got = c.ReadByte()); r.Start();
      s.WriteByte(42); r.Join(10000); Console.WriteLine("cbyte=" + got); c.Dispose(); });
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg25.exe sg25.cs >"$T/mcs25.out" 2>&1)
[ -f "$C/sg25.exe" ] || { fail "the sg25 probe did not compile: $(cat "$T/mcs25.out")"; exit 1; }
out=$(cd "$C" && for x in c cd d; do timeout -s KILL 60 "$WINE" sg25.exe $x 2>&1; done | tr -d '\r')
[ "$(v cdend)" = ObjectDisposedException ] && pass "a client connected, then the server was disposed: EndWaitForConnection says the pipe is closed (Visual Studio's response-time channel)" \
    || fail "connected, then disposed: EndWaitForConnection '$(v cdend)' (sg24: ok)"
[ "$(v cdconn)" = 0 ] && pass "and the disposed server is not connected" || fail "disposed server IsConnected: '$(v cdconn)'"
[ "$(v dend)" = ObjectDisposedException ] && pass "a server disposed while it waits: EndWaitForConnection says the pipe is closed" \
    || fail "disposed while waiting: EndWaitForConnection '$(v dend)' (sg24: IOException)"
[ "$(v cend)" = ok ] && [ "$(v cconn)" = 1 ] && [ "$(v cbyte)" = 42 ] && pass "a connection still completes and carries data" \
    || fail "plain connection: end '$(v cend)' connected '$(v cconn)' byte '$(v cbyte)'"
# (sg26) Type.MetadataToken as the CLR's RuntimeTypeHandle::GetToken: an array, a pointer or a
# byref type is the nil TypeDef token 0x02000000 (Mono said 0, or a byref's element's), and a
# generic parameter its GenericParam row 0x2Annnnnn (Mono said 0). Visual Studio's MEF cache
# writer (vs-mef WriteCompressedMetadataToken) refused a type token that is no TypeDef, "Wrong
# type": no MEF catalog, so no project templates and no SComponentModel (mono-0021). And
# WebRequest.Create for a user with no Internet Settings key threw NullReferenceException
# (Registry.GetValue is null for a missing key; Visual Studio's remote settings; mono-0022).
cat > "$C/sg26.cs" <<'CS'
using System; using System.Net;
class G<T> { }
class P {
  static string Tok(Type t) { return "0x" + t.MetadataToken.ToString("x8"); }
  static void Main(string[] a) {
    Console.WriteLine("arr=" + Tok(typeof(int[])));
    Console.WriteLine("arr2=" + Tok(typeof(string[,])));
    Console.WriteLine("ptr=" + Tok(typeof(int).MakePointerType()));
    Console.WriteLine("byref=" + Tok(typeof(int).MakeByRefType()));
    Console.WriteLine("gp=" + Tok(typeof(G<>).GetGenericArguments()[0]).Substring(0, 4));
    Console.WriteLine("gpm=" + Tok(typeof(Array).GetMethod("Empty").GetGenericArguments()[0]).Substring(0, 4));
    int t = typeof(G<int>).MetadataToken;
    Console.WriteLine("def=" + ((t & 0xff000000) == 0x02000000 && (t & 0xffffff) != 0 && t == typeof(G<>).MetadataToken ? 1 : 0));
    try { WebRequest.Create("http://127.0.0.1:9/"); Console.WriteLine("proxy=ok"); }
    catch (Exception e) { Console.WriteLine("proxy=" + e.GetType().Name); }
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg26.exe sg26.cs >"$T/mcs26.out" 2>&1)
[ -f "$C/sg26.exe" ] || { fail "the sg26 probe did not compile: $(cat "$T/mcs26.out")"; exit 1; }
"$WINE" reg delete 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings' /f >/dev/null 2>&1
out=$(cd "$C" && timeout -s KILL 60 "$WINE" sg26.exe 2>&1 | tr -d '\r')
for k in arr arr2 ptr byref; do
    [ "$(v $k)" = 0x02000000 ] && pass "$k type's MetadataToken is the nil TypeDef token, as the CLR's (Visual Studio's MEF cache)" \
        || fail "$k type's MetadataToken: '$(v $k)' (sg25: 0x00000000, byref the element's)"
done
[ "$(v gp)" = 0x2a ] && [ "$(v gpm)" = 0x2a ] && pass "a generic parameter's MetadataToken is its GenericParam row (type's and method's)" \
    || fail "generic parameter MetadataToken: '$(v gp)' '$(v gpm)' (sg25: 0x00)"
[ "$(v def)" = 1 ] && pass "a type's own token is its TypeDef row, the same for a generic instance" || fail "TypeDef tokens: '$(v def)'"
[ "$(v proxy)" = ok ] && pass "WebRequest.Create for a user with no Internet Settings key (Visual Studio's remote settings)" \
    || fail "WebRequest.Create with no Internet Settings key: '$(v proxy)' (sg25: NullReferenceException)"
# (sg26) Marshal.CreateAggregatedObject: a managed object aggregated by a native COM object, as
# .NET's -- the inner (non-delegating) IUnknown comes back, the managed interfaces answer as the
# outer object (QueryInterface, identity, reference counts). Mono threw NotImplementedException:
# Visual Studio's DTE.Solution (ComWrapperFactory.CreateAggregatedObject), so New Project
# stopped the IDE (mono-0023).
cat > "$T/sgagg.c" <<'C'
#include <windows.h>
/* an outer COM object that aggregates an inner object: it answers IUnknown and IID_OUTER itself
 * and passes every other interface to the inner (non-delegating) IUnknown */
static const GUID IID_OUTER = {0x5d0e0c41,0x7c1b,0x4e0a,{0x9b,0x51,0x3c,0x2a,0x11,0x6e,0x40,0x01}};
static const GUID IID_AGG   = {0x5d0e0c41,0x7c1b,0x4e0a,{0x9b,0x51,0x3c,0x2a,0x11,0x6e,0x40,0x02}};
typedef struct Outer Outer;
typedef struct { HRESULT (WINAPI *QI)(Outer*, REFIID, void**); ULONG (WINAPI *AddRef)(Outer*); ULONG (WINAPI *Release)(Outer*); } OuterVtbl;
struct Outer { const OuterVtbl *lpVtbl; LONG ref; IUnknown *inner; };
static HRESULT WINAPI o_qi(Outer *o, REFIID iid, void **out)
{
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_OUTER)) { *out = o; InterlockedIncrement(&o->ref); return S_OK; }
    if (o->inner) return o->inner->lpVtbl->QueryInterface(o->inner, iid, out);
    *out = NULL; return E_NOINTERFACE;
}
static ULONG WINAPI o_addref(Outer *o) { return InterlockedIncrement(&o->ref); }
static ULONG WINAPI o_release(Outer *o) { return InterlockedDecrement(&o->ref); }
static const OuterVtbl vt = { o_qi, o_addref, o_release };
static Outer the = { &vt, 1, NULL };
__declspec(dllexport) void * WINAPI agg_outer(void) { return &the; }
/* checks, as bits: 1 the outer gives the inner's interface; 2 its Value() answers; 4 that
 * interface's QueryInterface answers as the outer (IID_OUTER); 8 its IUnknown is the outer's;
 * 16 its AddRef/Release count the outer's references; 32 the inner's IUnknown is the inner;
 * 64 the inner's IMarshal (free-threaded marshaler) counts the outer's references */
typedef struct Agg Agg;
typedef struct { HRESULT (WINAPI *QI)(Agg*, REFIID, void**); ULONG (WINAPI *AddRef)(Agg*); ULONG (WINAPI *Release)(Agg*);
                 HRESULT (WINAPI *Value)(Agg*, int*); } AggVtbl;
struct Agg { const AggVtbl *lpVtbl; };
__declspec(dllexport) int WINAPI agg_check(IUnknown *inner)
{
    int r = 0, v = 0; Agg *a = NULL; void *p = NULL; LONG before;
    the.inner = inner;
    if (o_qi(&the, &IID_AGG, (void **)&a) == S_OK && a) r |= 1; else return r;
    if (a->lpVtbl->Value(a, &v) == S_OK && v == 42) r |= 2;
    if (a->lpVtbl->QI(a, &IID_OUTER, &p) == S_OK && p == &the) { r |= 4; o_release(&the); }
    p = NULL;
    if (a->lpVtbl->QI(a, &IID_IUnknown, &p) == S_OK && p == &the) { r |= 8; o_release(&the); }
    before = the.ref;
    a->lpVtbl->AddRef(a);
    if (the.ref == before + 1) r |= 16;
    a->lpVtbl->Release(a);
    p = NULL;
    if (inner->lpVtbl->QueryInterface(inner, &IID_IUnknown, &p) == S_OK && p == inner) { r |= 32; inner->lpVtbl->Release(inner); }
    before = the.ref; p = NULL;
    if (inner->lpVtbl->QueryInterface(inner, &IID_IMarshal, &p) == S_OK && p) {
        if (the.ref == before + 1) r |= 64;
        ((IUnknown *)p)->lpVtbl->Release((IUnknown *)p);
        if (the.ref != before) r &= ~64;
    }
    a->lpVtbl->Release(a);
    return r;
}
C
x86_64-w64-mingw32-gcc -shared -O1 -o "$C/sgagg.dll" "$T/sgagg.c" -luuid -lole32 || { fail "sgagg.dll did not build"; exit 1; }
cat > "$C/sgagg.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComVisible(true), Guid("5d0e0c41-7c1b-4e0a-9b51-3c2a116e4002"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ISgAgg { [PreserveSig] int Value(out int v); }
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Agg : ISgAgg { public int Value(out int v) { v = 42; return 0; } }
class P {
  [DllImport("sgagg.dll")] static extern IntPtr agg_outer();
  [DllImport("sgagg.dll")] static extern int agg_check(IntPtr inner);
  static void Main() {
    IntPtr inner;
    try { inner = Marshal.CreateAggregatedObject(agg_outer(), new Agg()); }
    catch (Exception e) { Console.WriteLine("aggregate=" + e.GetType().Name); return; }
    Console.WriteLine("aggregate=" + (inner != IntPtr.Zero ? "ok" : "null"));
    Console.WriteLine("checks=" + agg_check(inner));
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sgagg.exe sgagg.cs >"$T/mcsagg.out" 2>&1)
[ -f "$C/sgagg.exe" ] || { fail "the aggregation probe did not compile: $(cat "$T/mcsagg.out")"; exit 1; }
out=$(cd "$C" && timeout -s KILL 60 "$WINE" sgagg.exe 2>&1 | tr -d '\r')
[ "$(v aggregate)" = ok ] && pass "Marshal.CreateAggregatedObject gives the inner IUnknown (Visual Studio's DTE.Solution)" \
    || fail "CreateAggregatedObject: '$(v aggregate)' (sg25: NotImplementedException)"
[ "$(v checks)" = 127 ] && pass "and the aggregated object answers as the outer one: interface, call, QueryInterface, identity, references, inner IUnknown, free-threaded marshaler" \
    || fail "aggregation checks: '$(v checks)' of 127 (bits: 1 interface 2 call 4 QI as outer 8 identity 16 references 32 inner IUnknown 64 IMarshal counts the outer)"
# (sg27) an exception thrown by emitted code (AssemblyBuilder, no #GUID heap) while Mono traces
# exceptions (WINE_MONO_TRACE=E:all prints each one's frames, with each frame's module id): the
# frame is printed and the program goes on. Mono read the id through NULL and the process died
# (Visual Studio under an exception trace, 3 minutes after start; mono-0024).
cat > "$C/sg27.cs" <<'CS'
using System; using System.Reflection; using System.Reflection.Emit;
class P {
  static void Main() {
    var ab = AppDomain.CurrentDomain.DefineDynamicAssembly(new AssemblyName("SgDyn"), AssemblyBuilderAccess.Run);
    var tb = ab.DefineDynamicModule("SgDyn").DefineType("SgDynType", TypeAttributes.Public);
    var m = tb.DefineMethod("Throw", MethodAttributes.Public | MethodAttributes.Static, typeof(void), Type.EmptyTypes);
    var il = m.GetILGenerator();
    il.Emit(OpCodes.Nop); il.Emit(OpCodes.Nop);
    il.Emit(OpCodes.Ldstr, "from emitted code");
    il.Emit(OpCodes.Newobj, typeof(InvalidOperationException).GetConstructor(new[] { typeof(string) }));
    il.Emit(OpCodes.Throw);
    var t = tb.CreateType();
    int caught = 0;
    for (int i = 0; i < 3; i++) {
      try { t.GetMethod("Throw").Invoke(null, null); }
      catch (TargetInvocationException e) { if (e.InnerException is InvalidOperationException) caught++; }
    }
    Console.WriteLine("caught=" + caught);
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg27.exe sg27.cs >"$T/mcs27.out" 2>&1)
[ -f "$C/sg27.exe" ] || { fail "the sg27 probe did not compile: $(cat "$T/mcs27.out")"; exit 1; }
out=$(cd "$C" && WINE_MONO_TRACE=E:all timeout -s KILL 60 "$WINE" sg27.exe 2>"$T/sg27.err" | tr -d '\r')
[ "$(v caught)" = 3 ] && grep -q "SgDynType" "$T/sg27.err" \
    && pass "an exception through emitted code is traced (its frames printed) and caught, three times" \
    || fail "emitted code's exception under WINE_MONO_TRACE=E:all: caught '$(v caught)', frames printed: $(grep -c SgDynType "$T/sg27.err") (sg26: the process dies)"
# (sg28) a native caller (here the managed object's own COM wrapper called through its vtable, as
# native code calls it) passing SAFEARRAY** to a managed method: an [In] ref array arrives and is
# left to the caller, a plain ref array arrives and the method's new array goes back (the caller's
# destroyed), NULL arrives as null. Mono threw MarshalDirectiveException (0x80131535) before the
# method ran: Visual Studio's IDTWizard.Execute of the C++ wizards, so Create made no project
# (mono-0025).
cat > "$C/sg28.cs" <<'CS'
using System; using System.Runtime.InteropServices;
[ComVisible(true), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("5a1c0e8e-27b4-4d3a-9b9e-0c5f3a2d7e01")]
public interface IWiz {
  void Execute([In, MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_VARIANT)] ref object[] ctx,
               [MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_VARIANT)] ref object[] custom,
               out int result);
}
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Wiz : IWiz {
  public string seen = "none";
  public void Execute(ref object[] ctx, ref object[] custom, out int result) {
    seen = (ctx == null ? "null" : ctx.Length + ":" + ctx[0] + ":" + ctx[1]) + "/" + (custom == null ? "null" : custom.Length.ToString());
    ctx = new object[] { "ignored" };
    custom = new object[] { "back", 7, "three" };
    result = 1;
  }
}
class P {
  delegate int ExecFn(IntPtr self, ref IntPtr ctx, ref IntPtr custom, out int result);
  [DllImport("oleaut32.dll")] static extern IntPtr SafeArrayCreateVector(ushort vt, int lb, uint n);
  [DllImport("oleaut32.dll")] static extern int SafeArrayPutElement(IntPtr psa, int[] idx, IntPtr v);
  [DllImport("oleaut32.dll")] static extern int SafeArrayGetElement(IntPtr psa, int[] idx, IntPtr v);
  [DllImport("oleaut32.dll")] static extern int SafeArrayGetUBound(IntPtr psa, uint dim, out int ub);
  [DllImport("oleaut32.dll")] static extern int VariantClear(IntPtr v);
  static IntPtr Make(params object[] vals) {
    IntPtr psa = SafeArrayCreateVector(12 /* VT_VARIANT */, 0, (uint)vals.Length);
    IntPtr v = Marshal.AllocCoTaskMem(24);
    for (int i = 0; i < vals.Length; i++) {
      Marshal.GetNativeVariantForObject(vals[i], v);
      SafeArrayPutElement(psa, new[] { i }, v); VariantClear(v);
    }
    Marshal.FreeCoTaskMem(v); return psa;
  }
  static string Read(IntPtr psa) {
    if (psa == IntPtr.Zero) return "null";
    int ub; SafeArrayGetUBound(psa, 1, out ub);
    IntPtr v = Marshal.AllocCoTaskMem(24); string s = (ub + 1).ToString();
    for (int i = 0; i <= ub; i++) { SafeArrayGetElement(psa, new[] { i }, v); s += ":" + Marshal.GetObjectForNativeVariant(v); VariantClear(v); }
    Marshal.FreeCoTaskMem(v); return s;
  }
  static void Main() {
    var w = new Wiz();
    IntPtr itf = Marshal.GetComInterfaceForObject(w, typeof(IWiz));
    IntPtr fn = Marshal.ReadIntPtr(Marshal.ReadIntPtr(itf), 3 * IntPtr.Size);
    var exec = (ExecFn)Marshal.GetDelegateForFunctionPointer(fn, typeof(ExecFn));
    IntPtr ctx = Make("ctx", 42), custom = Make("x"); int r;
    int hr = exec(itf, ref ctx, ref custom, out r);
    Console.WriteLine("hr=0x" + hr.ToString("x8"));
    Console.WriteLine("seen=" + w.seen);
    Console.WriteLine("ctx=" + Read(ctx));
    Console.WriteLine("custom=" + Read(custom));
    IntPtr nul = IntPtr.Zero, nul2 = IntPtr.Zero;
    hr = exec(itf, ref nul, ref nul2, out r);
    Console.WriteLine("nullhr=0x" + hr.ToString("x8") + " nullseen=" + w.seen + " nullcustom=" + Read(nul2));
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg28.exe sg28.cs >"$T/mcs28.out" 2>&1)
[ -f "$C/sg28.exe" ] || { fail "the sg28 probe did not compile: $(cat "$T/mcs28.out")"; exit 1; }
out=$(cd "$C" && timeout -s KILL 60 "$WINE" sg28.exe 2>&1 | tr -d '\r')
[ "$(v hr)" = 0x00000000 ] && [ "$(v seen)" = "2:ctx:42/1" ] \
    && pass "a SAFEARRAY passed by reference from native code reaches the managed method (Visual Studio's IDTWizard.Execute)" \
    || fail "by-reference SAFEARRAY in: hr '$(v hr)' seen '$(v seen)' (sg27: 0x80131535, method not run)"
[ "$(v ctx)" = "2:ctx:42" ] && [ "$(v custom)" = "3:back:7:three" ] \
    && pass "an [In] one stays the caller's, a ref one comes back as the method's new array" \
    || fail "by-reference SAFEARRAY out: [In] '$(v ctx)', ref '$(v custom)'"
printf '%s\n' "$out" | grep -q "^nullhr=0x00000000 nullseen=null/null nullcustom=3:back:7:three$" \
    && pass "a NULL SAFEARRAY by reference arrives as null and a ref one still comes back" \
    || fail "NULL by-reference SAFEARRAY: '$(printf '%s\n' "$out" | grep nullhr)'"
# (sg29) bool[] in COM interface methods: VARIANT_BOOL elements by default, ArraySubType I1/Bool
# honoured; a native object (vtable made here) filling/reading through an RCW, and native code
# calling a managed object's wrapper. Mono used four-byte BOOLs always (sg28: 111000 for 101101)
# and its wrappers threw MarshalDirectiveException 0x80131535: Visual Studio's MEF host approved
# only half its component assemblies (IVsAppQueryLoad2.QueryLoadComponentAssemblies) and never
# scanned the core editor's parts (mono-0026).
cat > "$C/sg29.cs" <<'CS'
// sg29 probe (mono-0026): bool[] as LPArray in COM interface methods. COM's default element is
// VARIANT_BOOL (2 bytes, -1 = true); ArraySubType I1/Bool are 1/4 bytes. Both directions.
using System; using System.Runtime.InteropServices; using System.Text;
[ComImport, Guid("6b1d9a40-2f7e-4c55-9a51-3e0f7c2a9b11"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface INat {
  [PreserveSig] int Fill(uint n, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] bool[] a);
  [PreserveSig] int Read(uint n, [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] bool[] a);
  [PreserveSig] int FillI1(uint n, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.I1, SizeParamIndex = 0)] bool[] a);
  [PreserveSig] int FillBool(uint n, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.Bool, SizeParamIndex = 0)] bool[] a);
}
[ComVisible(true), Guid("6b1d9a40-2f7e-4c55-9a51-3e0f7c2a9b12"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMan {
  [PreserveSig] int Fill(uint n, [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] bool[] a);
  [PreserveSig] int Read(uint n, [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] bool[] a);
  [PreserveSig] int FillI1(uint n, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.I1, SizeParamIndex = 0)] bool[] a);
  [PreserveSig] int FillBool(uint n, [Out, MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.Bool, SizeParamIndex = 0)] bool[] a);
}
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Man : IMan {
  public static string seen = "none";
  static void Pat(bool[] a) { for (int i = 0; i < a.Length; i++) a[i] = P.Pattern[i]; }
  public int Fill(uint n, bool[] a) { Pat(a); return 0; }
  public int Read(uint n, bool[] a) { seen = P.Bits(a); return 0; }
  public int FillI1(uint n, bool[] a) { Pat(a); return 0; }
  public int FillBool(uint n, bool[] a) { Pat(a); return 0; }
}
class P {
  public static readonly bool[] Pattern = { true, false, true, true, false, true };
  public static string Bits(bool[] a) { var s = new StringBuilder(); foreach (var b in a) s.Append(b ? '1' : '0'); return s.ToString(); }
  delegate int QIFn(IntPtr self, ref Guid iid, out IntPtr ppv);
  delegate int RefFn(IntPtr self);
  delegate int ArrFn(IntPtr self, uint n, IntPtr arr);
  static string natSeen = "none";
  static void Put(IntPtr arr, int i, int size, bool v) {
    if (size == 1) Marshal.WriteByte(arr, i, (byte)(v ? 1 : 0));
    else if (size == 2) Marshal.WriteInt16(arr, i * 2, (short)(v ? -1 : 0));
    else Marshal.WriteInt32(arr, i * 4, v ? 1 : 0);
  }
  static string Dump(IntPtr arr, int n, int size) {
    var s = new StringBuilder();
    for (int i = 0; i < n; i++) {
      long v = size == 1 ? Marshal.ReadByte(arr, i) : size == 2 ? Marshal.ReadInt16(arr, i * 2) : Marshal.ReadInt32(arr, i * 4);
      s.Append(i > 0 ? "," : "").Append(v);
    }
    return s.ToString();
  }
  static Delegate[] keep;
  static IntPtr FakeNative() {
    QIFn qi = (IntPtr self, ref Guid iid, out IntPtr ppv) => { ppv = self; return 0; };
    RefFn ar = self => 2, rel = self => 1;
    ArrFn fill = (self, n, arr) => { for (int i = 0; i < n; i++) Put(arr, i, 2, Pattern[i]); return 0; };
    ArrFn read = (self, n, arr) => { natSeen = Dump(arr, (int)n, 2); return 0; };
    ArrFn fill1 = (self, n, arr) => { for (int i = 0; i < n; i++) Put(arr, i, 1, Pattern[i]); return 0; };
    ArrFn fill4 = (self, n, arr) => { for (int i = 0; i < n; i++) Put(arr, i, 4, Pattern[i]); return 0; };
    keep = new Delegate[] { qi, ar, rel, fill, read, fill1, fill4 };
    IntPtr vt = Marshal.AllocHGlobal(IntPtr.Size * keep.Length);
    for (int i = 0; i < keep.Length; i++) Marshal.WriteIntPtr(vt, i * IntPtr.Size, Marshal.GetFunctionPointerForDelegate(keep[i]));
    IntPtr obj = Marshal.AllocHGlobal(IntPtr.Size);
    Marshal.WriteIntPtr(obj, vt);
    return obj;
  }
  static void Main() {
    // managed -> native (RCW)
    try {
      var nat = (INat)Marshal.GetObjectForIUnknown(FakeNative());
      var a = new bool[6]; int hr = nat.Fill(6, a); Console.WriteLine("rcw fill hr=" + hr + " got=" + Bits(a));
      hr = nat.Read(6, (bool[])Pattern.Clone()); Console.WriteLine("rcw read hr=" + hr + " native=" + natSeen);
      a = new bool[6]; hr = nat.FillI1(6, a); Console.WriteLine("rcw filli1 hr=" + hr + " got=" + Bits(a));
      a = new bool[6]; hr = nat.FillBool(6, a); Console.WriteLine("rcw fillbool hr=" + hr + " got=" + Bits(a));
    } catch (Exception e) { Console.WriteLine("rcw EXC " + e.GetType().Name + ": " + e.Message); }
    // native -> managed (CCW)
    try {
      IntPtr itf = Marshal.GetComInterfaceForObject(new Man(), typeof(IMan));
      IntPtr vt = Marshal.ReadIntPtr(itf);
      Func<int, ArrFn> slot = k => (ArrFn)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt, k * IntPtr.Size), typeof(ArrFn));
      IntPtr buf = Marshal.AllocHGlobal(64);
      for (int i = 0; i < 64; i++) Marshal.WriteByte(buf, i, 0x55);
      int hr = slot(3)(itf, 6, buf); Console.WriteLine("ccw fill hr=0x" + hr.ToString("x") + " native=" + Dump(buf, 6, 2));
      for (int i = 0; i < 6; i++) Put(buf, i, 2, Pattern[i]);
      hr = slot(4)(itf, 6, buf); Console.WriteLine("ccw read hr=0x" + hr.ToString("x") + " got=" + Man.seen);
      for (int i = 0; i < 64; i++) Marshal.WriteByte(buf, i, 0x55);
      hr = slot(5)(itf, 6, buf); Console.WriteLine("ccw filli1 hr=0x" + hr.ToString("x") + " native=" + Dump(buf, 6, 1));
      for (int i = 0; i < 64; i++) Marshal.WriteByte(buf, i, 0x55);
      hr = slot(6)(itf, 6, buf); Console.WriteLine("ccw fillbool hr=0x" + hr.ToString("x") + " native=" + Dump(buf, 6, 4));
    } catch (Exception e) { Console.WriteLine("ccw EXC " + e.GetType().Name + ": " + e.Message); }
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg29.exe sg29.cs >"$T/mcs29.out" 2>&1)
[ -f "$C/sg29.exe" ] || { fail "the sg29 probe did not compile: $(cat "$T/mcs29.out")"; exit 1; }
out=$(cd "$C" && timeout -s KILL 60 "$WINE" sg29.exe 2>&1 | tr -d '\r')
l() { printf '%s\n' "$out" | grep "^$1 " | head -1; }
[ "$(l 'rcw fill')" = "rcw fill hr=0 got=101101" ] && [ "$(l 'rcw read')" = "rcw read hr=0 native=-1,0,-1,-1,0,-1" ] \
    && pass "a native COM method's bool[] is VARIANT_BOOLs both ways (Visual Studio's QueryLoadComponentAssemblies)" \
    || fail "bool[] through an RCW: '$(l 'rcw fill')' '$(l 'rcw read')' (sg28: got=111000, native=1,0,0,0,1,0)"
[ "$(l 'rcw filli1')" = "rcw filli1 hr=0 got=101101" ] && [ "$(l 'rcw fillbool')" = "rcw fillbool hr=0 got=101101" ] \
    && pass "ArraySubType I1 and Bool bool[] elements are one and four bytes" \
    || fail "bool[] ArraySubType: '$(l 'rcw filli1')' '$(l 'rcw fillbool')'"
[ "$(l 'ccw fill')" = "ccw fill hr=0x0 native=-1,0,-1,-1,0,-1" ] && [ "$(l 'ccw read')" = "ccw read hr=0x0 got=101101" ] \
    && pass "native code calling a managed COM method with a bool[] gets and gives VARIANT_BOOLs" \
    || fail "bool[] into a managed object's wrapper: '$(l 'ccw fill')' '$(l 'ccw read')' (sg28: hr=0x80131535)"
[ "$(l 'ccw filli1')" = "ccw filli1 hr=0x0 native=1,0,1,1,0,1" ] && [ "$(l 'ccw fillbool')" = "ccw fillbool hr=0x0 native=1,0,1,1,0,1" ] \
    && pass "into a managed wrapper, I1 and Bool bool[] elements are one and four bytes" \
    || fail "bool[] ArraySubType into a wrapper: '$(l 'ccw filli1')' '$(l 'ccw fillbool')'"
# (sg30) Visual Studio's C++ project system (mono-0027): a proxy type emitted into a dynamic
# assembly with [IgnoresAccessChecksTo("sg30")] implements sg30's private nested interface (vs-mef
# metadata views; TypeLoadException made CPS's IProjectService missing); without the attribute it
# still fails; a managed COM method with [In, Out] IntPtr gets a wrapper (Mono aborted: "should
# not be reached"); VARIANTs take VT_UNKNOWN (13) / VT_DISPATCH (9); a wrapper whose object was
# released and collected answers native code with an error HRESULT (Mono crashed reading NULL).
cat > "$C/sg30.cs" <<'CS'
// sg30 probe (mono-0027): a dynamic assembly carrying [IgnoresAccessChecksTo("sg30")] implements
// sg30's private nested interface (vs-mef's metadata view proxies); without it, TypeLoadException.
using System; using System.Reflection; using System.Reflection.Emit;
namespace System.Runtime.CompilerServices {
  [AttributeUsage(AttributeTargets.Assembly, AllowMultiple = true)]
  public class IgnoresAccessChecksToAttribute : Attribute {
    public IgnoresAccessChecksToAttribute(string assemblyName) { AssemblyName = assemblyName; }
    public string AssemblyName { get; private set; }
  }
}
[System.Runtime.InteropServices.ComVisible(true), System.Runtime.InteropServices.Guid("6b1d9a40-2f7e-4c55-9a51-3e0f7c2a9b13"),
 System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
public interface IOutPtr { [System.Runtime.InteropServices.PreserveSig] int Put([System.Runtime.InteropServices.In, System.Runtime.InteropServices.Out] IntPtr text, int n); }
[System.Runtime.InteropServices.ComVisible(true), System.Runtime.InteropServices.ClassInterface(System.Runtime.InteropServices.ClassInterfaceType.None)]
public class OutPtr : IOutPtr { public int Put(IntPtr text, int n) { System.Runtime.InteropServices.Marshal.WriteInt32(text, n * 2); return 7; } }
class Hidden { }  // not public: no IDispatch
[System.Runtime.InteropServices.ComVisible(true), System.Runtime.InteropServices.ClassInterface(System.Runtime.InteropServices.ClassInterfaceType.AutoDispatch)]
public class Disp { }
public class Outer {
  private interface IView { int Value { get; } }
  public static Type ViewType { get { return typeof(IView); } }
  public static int Read(object o) { return ((IView)o).Value; }
}
class P {
  [System.Runtime.InteropServices.DllImport("oleaut32.dll")] static extern int VariantClear(IntPtr v);
  delegate int PutFn(IntPtr self, IntPtr text, int n);
  static string Make(bool iact, string tag) {
    try {
      var ab = AppDomain.CurrentDomain.DefineDynamicAssembly(new AssemblyName("SgProxies" + tag), AssemblyBuilderAccess.Run);
      if (iact)
        ab.SetCustomAttribute(new CustomAttributeBuilder(typeof(System.Runtime.CompilerServices.IgnoresAccessChecksToAttribute).GetConstructor(new[] { typeof(string) }), new object[] { "sg30" }));
      var mb = ab.DefineDynamicModule("m");
      var tb = mb.DefineType("Proxy" + tag, TypeAttributes.Public | TypeAttributes.Class, typeof(object), new[] { Outer.ViewType });
      var get = tb.DefineMethod("get_Value", MethodAttributes.Public | MethodAttributes.Virtual | MethodAttributes.HideBySig | MethodAttributes.SpecialName | MethodAttributes.NewSlot | MethodAttributes.Final, typeof(int), Type.EmptyTypes);
      var il = get.GetILGenerator(); il.Emit(OpCodes.Ldc_I4, 42); il.Emit(OpCodes.Ret);
      tb.DefineMethodOverride(get, Outer.ViewType.GetProperty("Value").GetGetMethod(true));
      var t = tb.CreateType();
      return "ok:" + Outer.Read(Activator.CreateInstance(t));
    } catch (Exception e) { return e.GetType().Name; }
  }
  [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
  static IntPtr MakeDead() {
    IntPtr p = System.Runtime.InteropServices.Marshal.GetComInterfaceForObject(new OutPtr(), typeof(IOutPtr));
    System.Runtime.InteropServices.Marshal.Release(p);
    return p;
  }
  static void Main() {
    Console.WriteLine("iact=" + Make(true, "A"));
    Console.WriteLine("noiact=" + Make(false, "B"));
    // [In, Out] on a by-value IntPtr of a managed COM method (Visual Studio's IVCManagedInterop):
    // making the object's COM wrapper aborted Mono (marshal-ilgen.c "should not be reached")
    IntPtr itf = System.Runtime.InteropServices.Marshal.GetComInterfaceForObject(new OutPtr(), typeof(IOutPtr));
    var put = (PutFn)System.Runtime.InteropServices.Marshal.GetDelegateForFunctionPointer(
        System.Runtime.InteropServices.Marshal.ReadIntPtr(System.Runtime.InteropServices.Marshal.ReadIntPtr(itf), 3 * IntPtr.Size), typeof(PutFn));
    IntPtr buf = System.Runtime.InteropServices.Marshal.AllocHGlobal(8);
    int hr = put(itf, buf, 21);
    Console.WriteLine("outptr=" + hr + ":" + System.Runtime.InteropServices.Marshal.ReadInt32(buf));
    // an object without IDispatch goes into a VARIANT as VT_UNKNOWN without an exception thrown
    // (Visual Studio does this constantly); one with IDispatch as VT_DISPATCH
    int casts = 0;
    AppDomain.CurrentDomain.FirstChanceException += (s, e) => { if (e.Exception is InvalidCastException) casts++; };
    IntPtr v = System.Runtime.InteropServices.Marshal.AllocCoTaskMem(24);
    var hidden = new Hidden(); var disp = new Disp();
    for (int i = 0; i < 100; i++) {
      System.Runtime.InteropServices.Marshal.GetNativeVariantForObject(hidden, v);
      VariantClear(v);
    }
    System.Runtime.InteropServices.Marshal.GetNativeVariantForObject(hidden, v);
    short vtu = System.Runtime.InteropServices.Marshal.ReadInt16(v); VariantClear(v);
    System.Runtime.InteropServices.Marshal.GetNativeVariantForObject(disp, v);
    short vtd = System.Runtime.InteropServices.Marshal.ReadInt16(v); VariantClear(v);
    Console.WriteLine("variant=" + vtu + ":" + vtd);
    // a native caller using a wrapper after its last Release and a collection gets an error
    // HRESULT, not a crash in Mono (Visual Studio's IVsTask.get_IsCanceled)
    IntPtr dead = MakeDead();
    for (int i = 0; i < 3; i++) { GC.Collect(); GC.WaitForPendingFinalizers(); }
    var put2 = (PutFn)System.Runtime.InteropServices.Marshal.GetDelegateForFunctionPointer(
        System.Runtime.InteropServices.Marshal.ReadIntPtr(System.Runtime.InteropServices.Marshal.ReadIntPtr(dead), 3 * IntPtr.Size), typeof(PutFn));
    int hr2 = put2(dead, buf, 1);
    Console.WriteLine("deadccw=" + (hr2 != 0 ? "error" : "ok"));
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg30.exe sg30.cs >"$T/mcs30.out" 2>&1)
[ -f "$C/sg30.exe" ] || { fail "the sg30 probe did not compile: $(cat "$T/mcs30.out")"; exit 1; }
out=$(cd "$C" && timeout -s KILL 60 "$WINE" sg30.exe 2>&1 | tr -d '\r')
[ "$(v iact)" = "ok:42" ] && [ "$(v noiact)" = "TypeLoadException" ] \
    && pass "[IgnoresAccessChecksTo] lets an emitted proxy implement a private interface, and only with it (vs-mef metadata views)" \
    || fail "private interface in an emitted type: with '$(v iact)' without '$(v noiact)' (sg29: TypeLoadException both)"
[ "$(v outptr)" = "7:42" ] \
    && pass "a managed COM method with [In, Out] IntPtr gets its wrapper and runs (VS's IVCManagedInterop)" \
    || fail "[In, Out] IntPtr wrapper: '$(v outptr)' (sg29: Mono aborts)"
[ "$(v variant)" = "13:9" ] \
    && pass "VARIANTs: an object without IDispatch is VT_UNKNOWN, a dispatch one VT_DISPATCH" \
    || fail "VARIANT of objects: '$(v variant)'"
[ "$(v deadccw)" = "error" ] \
    && pass "a collected object's COM wrapper called from native code returns an error HRESULT" \
    || fail "collected object's wrapper: '$(v deadccw)' (sg29: crash in cominterop_set_ccw_domain)"
# (sg31) SAFEARRAYs from native code into a managed System.Array (mono-0028): declared
# SAFEARRAY(VT_UNKNOWN) of ITask (a type name past 127 bytes: a two-byte length in the blob) comes
# as ITask[] (Visual Studio's VCProjectEngine2.WaitForMultipleTasks casts to IVCTask[]; as object[]
# it threw for ever and "Creating project..." never ended); with no element type declared, as an
# array of what the SAFEARRAY holds (VT_UNKNOWN/VT_DISPATCH object[], VT_I4 int[], VT_I8 long[];
# Mono read it as VARIANT: SafeArrayTypeMismatchException 0x80131533).
cat > "$C/sg31.cs" <<'CS'
using System; using System.Runtime.InteropServices; using Sg.Probe.ALongNamespaceSoTheUserDefinedSubTypeNameIsLongerThanOneHundredAndTwentySevenBytesEvenWithoutAnAssemblyNameAfterIt;
[ComVisible(true), Guid("6b1d9a40-2f7e-4c55-9a51-3e0f7c2a9b21"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IWait { [PreserveSig] int Wait(uint t, [In, MarshalAs(UnmanagedType.SafeArray)] Array a);
  [PreserveSig] int WaitTasks(uint t, [In, MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_UNKNOWN, SafeArrayUserDefinedSubType = typeof(ITask))] Array a); }
namespace Sg.Probe.ALongNamespaceSoTheUserDefinedSubTypeNameIsLongerThanOneHundredAndTwentySevenBytesEvenWithoutAnAssemblyNameAfterIt {
// (a name past 127 bytes takes a two-byte length in the marshal blob, as Visual Studio's IVCTask does)
[ComVisible(true), Guid("6b1d9a40-2f7e-4c55-9a51-3e0f7c2a9b22"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITask { [PreserveSig] int Id(); }
}
namespace Sg.Probe { }
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Tsk : ITask { public int Id() { return 42; } }
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class W : IWait { public static string seen;
  public int WaitTasks(uint t, Array a) { var ts = a as ITask[]; seen = a == null ? "null" : a.GetType().Name + ":" + (ts != null ? ts[0].Id().ToString() : "notyped"); return 0; } public int Wait(uint t, Array a) { seen = a == null ? "null" : a.GetType() + ":" + a.Length + ":" + (a.Length > 0 ? (a.GetValue(0) == null ? "nullelem" : a.GetValue(0).GetType().ToString()) : ""); return 0; } }
public class Obj { }
class P {
  delegate int WaitFn(IntPtr self, uint t, IntPtr sa);
  [DllImport("oleaut32.dll")] static extern IntPtr SafeArrayCreateVector(ushort vt, int lb, uint n);
  [DllImport("oleaut32.dll")] static extern int SafeArrayPutElement(IntPtr psa, int[] idx, IntPtr v);
  static void Main() {
    IntPtr itf = Marshal.GetComInterfaceForObject(new W(), typeof(IWait));
    var f = (WaitFn)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(itf), 3 * IntPtr.Size), typeof(WaitFn));
    {
      var f2 = (WaitFn)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(itf), 4 * IntPtr.Size), typeof(WaitFn));
      IntPtr psa = SafeArrayCreateVector(13, 0, 1);
      SafeArrayPutElement(psa, new[] { 0 }, Marshal.GetComInterfaceForObject(new Tsk(), typeof(ITask)));
      W.seen = "notcalled"; int hr = f2(itf, 1, psa);
      Console.WriteLine("udt hr=0x" + hr.ToString("x") + " " + W.seen);
    }
    foreach (ushort vt in new ushort[] { 13, 9, 12, 3, 20 }) {
      IntPtr psa = SafeArrayCreateVector(vt, 0, 2);
      if (vt == 13 || vt == 9) { IntPtr u = vt == 13 ? Marshal.GetIUnknownForObject(new Obj()) : Marshal.GetIDispatchForObject(new W()); SafeArrayPutElement(psa, new[] { 0 }, u); }
      W.seen = "notcalled";
      int hr = f(itf, 1, psa);
      Console.WriteLine("vt" + vt + " hr=0x" + hr.ToString("x") + " " + W.seen);
    }
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg31.exe sg31.cs >"$T/mcs31.out" 2>&1)
[ -f "$C/sg31.exe" ] || { fail "the sg31 probe did not compile: $(cat "$T/mcs31.out")"; exit 1; }
out=$(cd "$C" && timeout -s KILL 60 "$WINE" sg31.exe 2>&1 | tr -d '\r')
l() { printf '%s\n' "$out" | grep "^$1 " | head -1; }
[ "$(l udt)" = "udt hr=0x0 ITask[]:42" ] \
    && pass "SAFEARRAY(VT_UNKNOWN) with a user-defined subtype reaches a managed System.Array as that type's array (VS's IVCTask[])" \
    || fail "user-defined SAFEARRAY subtype: '$(l udt)' (sg30: Object[]:notyped)"
[ "$(l vt13)" = "vt13 hr=0x0 System.Object[]:2:Obj" ] && [ "$(l vt9)" = "vt9 hr=0x0 System.Object[]:2:W" ] \
    && pass "an undeclared SAFEARRAY of VT_UNKNOWN/VT_DISPATCH comes as object[]" \
    || fail "undeclared SAFEARRAY of interfaces: '$(l vt13)' '$(l vt9)' (sg30: 0x80131533)"
[ "$(l vt3)" = "vt3 hr=0x0 System.Int32[]:2:System.Int32" ] && [ "$(l vt20)" = "vt20 hr=0x0 System.Int64[]:2:System.Int64" ] \
    && [ "$(l vt12)" = "vt12 hr=0x0 System.Object[]:2:nullelem" ] \
    && pass "an undeclared SAFEARRAY of VT_I4/VT_I8/VT_VARIANT comes as int[]/long[]/object[]" \
    || fail "undeclared SAFEARRAY of values: '$(l vt3)' '$(l vt20)' '$(l vt12)'"
# (sg32) arrays and records into a managed COM method (mono-0029): an LPArray with no size is one
# element (VS's IVsFontAndColorDefaults.GetItem(int, AllColorableItemInfo[] pInfo): Mono gave an
# empty array), arrays of structs with BSTRs are converted in and out (Mono threw
# MarshalDirectiveException 0x80131535), and a VT_RECORD VARIANT becomes the struct whose [Guid] is
# the record's, or System.Guid for a GUID record (IVsGuidParserPrivate.TryParseGuid: Mono threw
# NotImplementedException 0x80004001).
cat > "$C/sg32.cs" <<'CS'
// sg32 probe (mono-0029): arrays of structs with strings into a managed COM method (CCW), and an
// LPArray with no size taken as one element, as the CLR does (Visual Studio's
// IVsFontAndColorDefaults.GetItem(int, AllColorableItemInfo[] pInfo)).
using System; using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct Info { public int A; [MarshalAs(UnmanagedType.BStr)] public string Name; public uint C; }
[ComVisible(true), Guid("6b1d9a40-2f7e-4c55-9a51-3e0f7c2a9b31"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDefaults {
  [PreserveSig] int GetItem(int i, [Out, MarshalAs(UnmanagedType.LPArray)] Info[] p);
  [PreserveSig] int PutItems(int n, [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] Info[] p);
}
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Defaults : IDefaults {
  public static string seen = "none";
  public int GetItem(int i, Info[] p) { seen = "len" + p.Length; p[0].A = 7; p[0].Name = "seven" + i; p[0].C = 9; return 0; }
  public int PutItems(int n, Info[] p) { seen = p.Length + ":" + p[0].A + ":" + p[0].Name + ":" + p[1].Name + ":" + p[1].C; return 0; }
}
class P {
  delegate int ItemFn(IntPtr self, int i, IntPtr p);
  static void Main() {
    IntPtr itf = Marshal.GetComInterfaceForObject(new Defaults(), typeof(IDefaults));
    IntPtr vt = Marshal.ReadIntPtr(itf);
    var get = (ItemFn)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt, 3 * IntPtr.Size), typeof(ItemFn));
    var put = (ItemFn)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt, 4 * IntPtr.Size), typeof(ItemFn));
    int size = Marshal.SizeOf(typeof(Info));
    IntPtr buf = Marshal.AllocCoTaskMem(size * 2);
    for (int k = 0; k < size * 2; k++) Marshal.WriteByte(buf, k, 0);
    int hr = get(itf, 3, buf);
    var back = (Info)Marshal.PtrToStructure(buf, typeof(Info));
    Console.WriteLine("get=0x" + hr.ToString("x") + ":" + Defaults.seen + ":" + back.A + ":" + back.Name + ":" + back.C);
    var two = new[] { new Info { A = 5, Name = "five", C = 1 }, new Info { A = 6, Name = "six", C = 2 } };
    for (int k = 0; k < 2; k++) Marshal.StructureToPtr(two[k], buf + k * size, false);
    hr = put(itf, 2, buf);
    Console.WriteLine("put=0x" + hr.ToString("x") + ":" + Defaults.seen);
  }
}
CS
cat > "$C/sg32rec.cs" <<'CS'
// VT_RECORD VARIANTs into a managed COM method (mono-0029): a record whose GUID is a managed
// struct's [Guid] becomes that struct; oleaut32's GUID record becomes System.Guid.
using System; using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential), Guid("6b1d9a40-2f7e-4c55-9a51-3e0f7c2a9b41")]
public struct Pt { public int X; public int Y; }
[ComVisible(true), Guid("6b1d9a40-2f7e-4c55-9a51-3e0f7c2a9b42"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IParse { [PreserveSig] int Take([MarshalAs(UnmanagedType.Struct)] object v); }
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public class Parse : IParse { public static string seen = "none"; public int Take(object v) { seen = v == null ? "null" : v.GetType().Name + ":" + (v is Pt ? ((Pt)v).X + "," + ((Pt)v).Y : v.ToString()); return 0; } }
class P {
  delegate int TakeFn(IntPtr self, IntPtr vt_lo, IntPtr data, IntPtr recinfo);  // VARIANT by value: 24 bytes passed by reference on x64
  delegate int TakeRef(IntPtr self, IntPtr variant);
  delegate int QIFn(IntPtr self, ref Guid iid, out IntPtr ppv);
  delegate int RefFn(IntPtr self);
  delegate int GuidFn(IntPtr self, out Guid g);
  delegate int NameFn(IntPtr self, out IntPtr name);
  delegate int SizeFn(IntPtr self, out uint size);
  delegate int Dummy(IntPtr self);
  static Delegate[] keep = new Delegate[0];
  static IntPtr FakeRecInfo(Guid g, string name, uint size) {
    QIFn qi = (IntPtr s, ref Guid iid, out IntPtr ppv) => { ppv = s; return 0; };
    RefFn ar = s => 2, rel = s => 1; Dummy d = s => unchecked((int)0x80004001);
    GuidFn gg = (IntPtr s, out Guid o) => { o = g; return 0; };
    NameFn gn = (IntPtr s, out IntPtr n) => { n = Marshal.StringToBSTR(name); return 0; };
    SizeFn gs = (IntPtr s, out uint z) => { z = size; return 0; };
    var slots = new Delegate[] { qi, ar, rel, d, d, d, gg, gn, gs, d, d, d, d, d, d, d, d, d, d };
    var all = new Delegate[keep.Length + slots.Length]; keep.CopyTo(all, 0); slots.CopyTo(all, keep.Length); keep = all;
    IntPtr vt = Marshal.AllocHGlobal(IntPtr.Size * slots.Length);
    for (int i = 0; i < slots.Length; i++) Marshal.WriteIntPtr(vt, i * IntPtr.Size, Marshal.GetFunctionPointerForDelegate(slots[i]));
    IntPtr obj = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(obj, vt); return obj;
  }
  static void Main() {
    IntPtr itf = Marshal.GetComInterfaceForObject(new Parse(), typeof(IParse));
    var take = (TakeRef)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(itf), 3 * IntPtr.Size), typeof(TakeRef));
    IntPtr v = Marshal.AllocHGlobal(24);
    // a Pt record
    IntPtr data = Marshal.AllocHGlobal(8); Marshal.WriteInt32(data, 0, 3); Marshal.WriteInt32(data, 4, 4);
    Marshal.WriteInt64(v, 0, 0); Marshal.WriteInt16(v, 0, 36); Marshal.WriteIntPtr(v, 8, data);
    Marshal.WriteIntPtr(v, 8 + IntPtr.Size, FakeRecInfo(typeof(Pt).GUID, "Pt", 8));
    int hr = take(itf, v);
    Console.WriteLine("recpt=0x" + hr.ToString("x") + ":" + Parse.seen);
    // oleaut32's GUID record
    var g = new Guid("11112222-3333-4444-5555-666677778888");
    IntPtr gd = Marshal.AllocHGlobal(16); Marshal.Copy(g.ToByteArray(), 0, gd, 16);
    Marshal.WriteInt64(v, 0, 0); Marshal.WriteInt16(v, 0, 36); Marshal.WriteIntPtr(v, 8, gd);
    Marshal.WriteIntPtr(v, 8 + IntPtr.Size, FakeRecInfo(new Guid("00000000-0000-0000-0000-00000000aaaa"), "GUID", 16));
    Parse.seen = "none"; hr = take(itf, v);
    Console.WriteLine("recguid=0x" + hr.ToString("x") + ":" + Parse.seen);
  }
}
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg32.exe sg32.cs >"$T/mcs32.out" 2>&1; timeout 300 "$WINE" "$mcs" -out:sg32rec.exe sg32rec.cs >>"$T/mcs32.out" 2>&1)
[ -f "$C/sg32.exe" ] && [ -f "$C/sg32rec.exe" ] || { fail "the sg32 probes did not compile: $(cat "$T/mcs32.out")"; exit 1; }
out=$(cd "$C" && timeout -s KILL 60 "$WINE" sg32.exe 2>&1 | tr -d '\r'; cd "$C" && timeout -s KILL 60 "$WINE" sg32rec.exe 2>&1 | tr -d '\r')
[ "$(v get)" = "0x0:len1:7:seven3:9" ] \
    && pass "an unsized [Out] struct array into a managed method is one element and its BSTR comes back (VS's GetItem)" \
    || fail "unsized struct array: '$(v get)' (sg31: 0x80131535:len0)"
[ "$(v put)" = "0x0:2:5:five:six:2" ] \
    && pass "a sized [In] array of structs with BSTRs reaches the managed method" \
    || fail "struct array in: '$(v put)' (sg31: 0x80131535)"
[ "$(v recpt)" = "0x0:Pt:3,4" ] && [ "$(v recguid)" = "0x0:Guid:11112222-3333-4444-5555-666677778888" ] \
    && pass "a VT_RECORD VARIANT becomes its [Guid] struct, a GUID record a System.Guid (VS's TryParseGuid)" \
    || fail "VT_RECORD VARIANT: '$(v recpt)' '$(v recguid)' (sg31: 0x80004001)"
# (sg33) NetworkInterface.GetIPStatistics (mono-0030): .NET Framework 4.6+ gives every
# interface's counters; Mono threw NotImplementedException (LibreHardwareMonitor died at start
# building its network sensors). The counters are MIB_IFROW's DWORDs, read unsigned (they were
# negative past 2 GB, in GetIPv4Statistics too). sg32: NotImplementedException.
# Mutant: -d:SG_MUTANT_IPSTATS_NOT_IMPLEMENTED (System.dll).
cat > "$C/sg33.cs" <<'CS'
using System; using System.Net.NetworkInformation;
class P { static void Main() {
  int n = 0, ok = 0, neg = 0; string err = "none";
  foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()) {
    n++;
    try {
      var s = ni.GetIPStatistics(); var s4 = ni.GetIPv4Statistics();
      if (s.BytesReceived < 0 || s.BytesSent < 0 || s4.BytesReceived < 0) neg++;
      else if (s.BytesReceived >= s4.BytesReceived && s.UnicastPacketsReceived >= 0) ok++;
    } catch (Exception e) { err = e.GetType().Name; }
  }
  Console.WriteLine("ifs=" + n + " ok=" + ok + " neg=" + neg + " err=" + err);
} }
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -out:sg33.exe sg33.cs >"$T/mcs33.out" 2>&1)
[ -f "$C/sg33.exe" ] || { fail "the sg33 probe did not compile: $(cat "$T/mcs33.out")"; exit 1; }
out=$(cd "$C" && timeout -s KILL 60 "$WINE" sg33.exe 2>&1 | tr -d '\r' | grep '^ifs=')
ifs=$(printf '%s' "$out" | sed -n 's/^ifs=\([0-9]*\).*/\1/p')
[ -n "$ifs" ] && [ "$ifs" -gt 0 ] && printf '%s' "$out" | grep -q " ok=$ifs neg=0 err=none" \
    && pass "every interface's GetIPStatistics, counters unsigned ($out)" \
    || fail "GetIPStatistics: '$out' (sg32: err=NotImplementedException)"
# (sg34) late binding to COM objects (mono-0031): Type.InvokeMember on a COM object goes through
# its IDispatch (methods, property get/put, named arguments, [DISPID=0]), and C# "dynamic" on a
# COM object binds through it, as the .NET Framework does: Mesen's WScript.Shell CreateShortcut
# threw RuntimeBinderException ("System.__ComObject does not contain a definition"), and
# InvokeMember threw NotImplementedException. sg33: both fail.
# Mutants: -d:SG_MUTANT_COM_INVOKEMEMBER_NOT_IMPLEMENTED (corlib), -d:SG_MUTANT_NO_COM_DYNAMIC
# (Microsoft.CSharp).
cat > "$C/sg34.cs" <<'CS'
using System; using System.IO; using System.Reflection;
class P { static void Main() {
  string r = "";
  try {
    object d = Activator.CreateInstance(Type.GetTypeFromProgID("Scripting.Dictionary"));
    Type t = d.GetType();
    t.InvokeMember("CompareMode", BindingFlags.SetProperty, null, d, new object[] { 1 });
    t.InvokeMember("Add", BindingFlags.InvokeMethod, null, d, new object[] { "a", 7 });
    t.InvokeMember("Add", BindingFlags.InvokeMethod, null, d, new object[] { "b", "two" });
    object n = t.InvokeMember("Count", BindingFlags.GetProperty, null, d, null);
    object v = t.InvokeMember("[DISPID=0]", BindingFlags.GetProperty, null, d, new object[] { "b" });
    r += "invoke=" + n + ":" + v + ":" + t.InvokeMember("CompareMode", BindingFlags.GetProperty, null, d, null);
    try { t.InvokeMember("NoSuchMember", BindingFlags.InvokeMethod, null, d, null); r += ":nomiss"; }
    catch (MissingMethodException) { r += ":missing"; }
    /* the object's own error (CompareMode of a dictionary that has items): TargetInvocationException */
    try { t.InvokeMember("CompareMode", BindingFlags.SetProperty, null, d, new object[] { 0 }); r += ":noerror"; }
    catch (TargetInvocationException e) { r += e.InnerException is System.Runtime.InteropServices.COMException ? ":tie" : ":tie?"; }
  } catch (Exception e) { r += "invoke=" + e.GetType().Name; }
  Console.WriteLine(r); r = "";
  try {
    dynamic d = Activator.CreateInstance(Type.GetTypeFromProgID("Scripting.Dictionary"));
    d.Add("x", 40); d["y"] = 2;
    int sum = (int)d.Item("x") + (int)d["y"];
    r += "dynamic=" + d.Count + ":" + sum + ":" + d.Exists("y");
    dynamic sh = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
    string lnk = Path.Combine(Path.GetTempPath(), "sg34.lnk");
    dynamic s = sh.CreateShortcut(lnk);
    s.TargetPath = @"C:\windows\notepad.exe";
    s.Save();
    r += ":lnk=" + File.Exists(lnk);
  } catch (Exception e) { r += "dynamic=" + e.GetType().Name; }
  Console.WriteLine(r);
} }
CS
(cd "$C" && timeout 300 "$WINE" "$mcs" -r:Microsoft.CSharp.dll -r:System.Core.dll -out:sg34.exe sg34.cs >"$T/mcs34.out" 2>&1)
[ -f "$C/sg34.exe" ] || { fail "the sg34 probe did not compile: $(cat "$T/mcs34.out")"; exit 1; }
out=$(cd "$C" && timeout -s KILL 120 "$WINE" sg34.exe 2>&1 | tr -d '\r')
[ "$(v invoke)" = "2:two:1:missing:tie" ] \
    && pass "Type.InvokeMember on a COM object: method, property get/put, [DISPID=0], a missing member, the object's own error" \
    || fail "InvokeMember on COM: '$(v invoke)' (sg33: NotImplementedException)"
[ "$(v dynamic)" = "2:42:True:lnk=True" ] \
    && pass "C# dynamic on COM objects: calls, indexer, properties, WScript.Shell CreateShortcut (Mesen)" \
    || fail "dynamic on COM: '$(v dynamic)' (sg33: RuntimeBinderException)"
# (sg35) Windows Runtime classes by contract name, projected onto the system's classes
# (mono-0032, wine-mono-0005): a program built against the Windows SDK's contract
# assemblies (Microsoft.Windows.SDK.Contracts) references "Windows.Foundation.
# UniversalApiContract", "Windows.Foundation.FoundationContract", "Windows.Services.Store.
# StoreContract" (ContentType=WindowsRuntime), which the CLR resolves by namespace in the
# system's metadata whatever the name: Cyberduck 9.6 died at start with FileNotFoundException
# Windows.Foundation.UniversalApiContract 14.0. The probe is compiled against stand-ins of the
# three contracts (and of System.Runtime.WindowsRuntime 4.0.14.0, the NuGet reference version),
# which are then removed: only WinMetadata/Windows.winmd and the image's
# System.Runtime.WindowsRuntime can serve it. Its toast is the system's (Wine's
# Windows.UI.Notifications): it shows, a click raises Activated (registered through
# WindowsRuntimeMarshal.AddEventHandler, as compiled code does) with the launch arguments and the
# same toast object; Package.Current / ApplicationData.Current without package identity are
# InvalidOperationException 0x80073D54; the Store's app licence comes through IAsyncOperation:
# Completed, AsTask and await (System.Runtime.WindowsRuntime), and a Task back as IAsyncAction.
# sg34: FileNotFoundException. Mutants: -d:SG_MUTANT_WINRT_CONTRACTS_UNRESOLVED (assembly.c),
# -d:SG_MUTANT_WINRT_HRESULTS_AS_COMEXCEPTION, -d:SG_MUTANT_WINRT_PIID_NO_VERSION (Wine does not
# check the ids it is handed; the id check catches it),
# -d:SG_MUTANT_TOAST_SHOW_NOT_PROJECTED (Windows.winmd).
csc=$("$WINE" winepath -w "$MONO/lib/mono/4.5/csc.exe" | tr -d '\r')
W35="$C/sg35"; mkdir -p "$W35"
printf '\000\000\000\000\000\000\000\000\004\000\000\000\000\000\000\000' > "$W35/ecma.pub"
cat > "$W35/foundation.cs" <<'CS'
using System; using System.Reflection;
#pragma warning disable 618
[assembly: AssemblyVersion("4.0.0.0")] [assembly: AssemblyFlags(0x200)]
namespace Windows.Foundation {
  public enum AsyncStatus { Started = 0, Completed = 1, Canceled = 2, Error = 3 }
  public interface IAsyncInfo { Exception ErrorCode { get; } uint Id { get; } AsyncStatus Status { get; } void Cancel(); void Close(); }
  public delegate void AsyncOperationCompletedHandler<TResult>(IAsyncOperation<TResult> asyncInfo, AsyncStatus asyncStatus);
  public interface IAsyncOperation<TResult> : IAsyncInfo { AsyncOperationCompletedHandler<TResult> Completed { get; set; } TResult GetResults(); }
  public delegate void AsyncActionCompletedHandler(IAsyncAction asyncInfo, AsyncStatus asyncStatus);
  public interface IAsyncAction : IAsyncInfo { AsyncActionCompletedHandler Completed { get; set; } void GetResults(); }
  public delegate void TypedEventHandler<TSender, TResult>(TSender sender, TResult args);
}
namespace Windows.Foundation.Metadata {
  public static class ApiInformation { public static bool IsApiContractPresent(string contractName, ushort majorVersion) { throw null; } }
}
CS
cat > "$W35/universal.cs" <<'CS'
using System; using System.Collections.Generic; using System.Reflection;
using System.Runtime.InteropServices.WindowsRuntime; using Windows.Foundation;
#pragma warning disable 618
[assembly: AssemblyVersion("14.0.0.0")] [assembly: AssemblyFlags(0x200)]
namespace Windows.Data.Xml.Dom {
  public sealed class XmlDocument { public XmlDocument() { } public void LoadXml(string xml) { } public string GetXml() { throw null; } }
}
namespace Windows.UI.Notifications {
  using Windows.Data.Xml.Dom;
  public enum NotificationSetting { Enabled = 0, DisabledForApplication = 1, DisabledForUser = 2, DisabledByGroupPolicy = 3, DisabledByManifest = 4 }
  public sealed class ToastActivatedEventArgs { public string Arguments { get { throw null; } } }
  public sealed class ToastNotification {
    public ToastNotification(XmlDocument content) { }
    public string Tag { get { throw null; } } public void put_Tag(string value) { }
    public string Group { get { throw null; } } public void put_Group(string value) { }
    public EventRegistrationToken add_Activated(TypedEventHandler<ToastNotification, object> handler) { throw null; }
    public void remove_Activated(EventRegistrationToken token) { }
  }
  public sealed class ToastNotifier { public void Show(ToastNotification notification) { } public NotificationSetting Setting { get { throw null; } } }
  public sealed class ToastNotificationHistory { public void Clear(string applicationId) { } public IReadOnlyList<ToastNotification> GetHistory() { throw null; } }
  public static class ToastNotificationManager {
    public static ToastNotifier CreateToastNotifier(string applicationId) { throw null; }
    public static ToastNotificationHistory History { get { throw null; } }
  }
}
namespace Windows.ApplicationModel { public sealed class Package { public static Package Current { get { throw null; } } } }
namespace Windows.Storage { public sealed class ApplicationData { public static ApplicationData Current { get { throw null; } } } }
CS
cat > "$W35/store.cs" <<'CS'
using System.Reflection; using Windows.Foundation;
#pragma warning disable 618
[assembly: AssemblyVersion("4.0.0.0")] [assembly: AssemblyFlags(0x200)]
namespace Windows.Services.Store {
  public sealed class StoreAppLicense { public bool IsActive { get { throw null; } } public bool IsTrial { get { throw null; } } }
  public sealed class StoreContext {
    public static StoreContext GetDefault() { throw null; }
    public IAsyncOperation<StoreAppLicense> GetAppLicenseAsync() { throw null; }
  }
}
CS
cat > "$W35/srwr.cs" <<'CS'
using System.Reflection; using System.Runtime.CompilerServices; using System.Threading.Tasks; using Windows.Foundation;
[assembly: AssemblyVersion("4.0.14.0")] [assembly: AssemblyDelaySign(true)]
namespace System {
  public static class WindowsRuntimeSystemExtensions {
    public static Task<TResult> AsTask<TResult>(this IAsyncOperation<TResult> source) { throw null; }
    public static TaskAwaiter<TResult> GetAwaiter<TResult>(this IAsyncOperation<TResult> source) { throw null; }
    public static IAsyncAction AsAsyncAction(this Task source) { throw null; }
  }
}
CS
cat > "$W35/sg35.cs" <<'CS'
using System; using System.Runtime.InteropServices; using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading; using System.Threading.Tasks;
using Windows.Foundation; using Windows.UI.Notifications; using Windows.Data.Xml.Dom; using Windows.Services.Store;
class P {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string t);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, int m, IntPtr w, IntPtr l);
  static void Say(string k, Func<string> f) {
    string v; try { v = f(); } catch (Exception e) { v = (e is InvalidOperationException ? "InvalidOperationException" : e.GetType().Name) + ":" + e.HResult.ToString("X8"); }
    Console.WriteLine(k + "=" + v);
  }
  static IntPtr FindToast() {
    for (int t = 0; t < 10000; t += 50) {
      IntPtr h = IntPtr.Zero;
      while ((h = FindWindowExW(IntPtr.Zero, h, "WineToastNotification", null)) != IntPtr.Zero) if (IsWindowVisible(h)) return h;
      Thread.Sleep(50);
    }
    return IntPtr.Zero;
  }
  static string Xml() {
    var d = new XmlDocument();
    d.LoadXml("<toast launch=\"from-body\"><visual><binding template=\"ToastGeneric\"><text>sg35</text><text>From .NET</text></binding></visual></toast>");
    return d.GetXml();
  }
  static string Toast() {
    var d = new XmlDocument();
    d.LoadXml("<toast launch=\"from-body\"><visual><binding template=\"ToastGeneric\"><text>sg35</text><text>From .NET</text></binding></visual></toast>");
    var n = ToastNotificationManager.CreateToastNotifier("SG.MonoFork.Gate");
    var t = new ToastNotification(d);
    t.put_Tag("tag1"); t.put_Group("grp1");
    var fired = new ManualResetEvent(false); string args = null; object sender = null;
    WindowsRuntimeMarshal.AddEventHandler<TypedEventHandler<ToastNotification, object>>(t.add_Activated, t.remove_Activated,
      (s, a) => { sender = s; var e = a as ToastActivatedEventArgs; args = e == null ? "noargs" : e.Arguments; fired.Set(); });
    n.Show(t);
    IntPtr hw = FindToast();
    string r = n.Setting + ":" + t.Tag + "/" + t.Group + ":shown=" + (hw != IntPtr.Zero);
    if (hw != IntPtr.Zero) {
      PostMessageW(hw, 0x0202 /* WM_LBUTTONUP */, IntPtr.Zero, (IntPtr)((45 << 16) | 60));
      r += ":activated=" + fired.WaitOne(10000) + ":" + args + ":" + (ReferenceEquals(sender, t) ? "same" : "other");
    }
    return r;
  }
  static string History() {
    ToastNotificationManager.History.Clear("SG.MonoFork.Gate");
    return "" + ToastNotificationManager.History.GetHistory().Count;
  }
  static string Package() { return "" + Windows.ApplicationModel.Package.Current; }
  static string AppData() { return "" + Windows.Storage.ApplicationData.Current; }
  static string Contract() {
    return Windows.Foundation.Metadata.ApiInformation.IsApiContractPresent("Windows.Foundation.UniversalApiContract", 1)
      + ":" + Windows.Foundation.Metadata.ApiInformation.IsApiContractPresent("SG.Nonexistent.Contract", 1);
  }
  static string License() {
    var op = StoreContext.GetDefault().GetAppLicenseAsync();
    var done = new ManualResetEvent(false); AsyncStatus st = AsyncStatus.Started;
    op.Completed = (o, s) => { st = s; done.Set(); };
    done.WaitOne(10000);
    return st + ":" + op.GetResults().IsActive + ":" + op.GetResults().IsTrial;
  }
  // the interface ids the system's delegates and operations are asked for (QueryInterface), from
  // the Windows Runtime type signatures: TypedEventHandler<ToastNotification, Object> (as the
  // Windows SDK headers have it) and IAsyncOperation<StoreAppLicense> (as Wine's Store has it)
  static string Piid() {
    var m = typeof(XmlDocument).Assembly.GetType("Windows.Internal.Rt").GetMethod("ParameterizedIid",
      System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
    return m.Invoke(null, new object[] { "pinterface({9de1c534-6ae1-11e0-84e1-18a905bcc53f};rc(Windows.UI.Notifications.ToastNotification;{997e2675-059e-4e60-8b06-1760917c8b80});cinterface(IInspectable))" })
      + ":" + m.Invoke(null, new object[] { "pinterface({9fc2b0bb-e446-44e2-aa61-9cab8f636af2};rc(Windows.Services.Store.StoreAppLicense;{f389f9de-73c0-45ce-9bab-b2fe3e5eafd3}))" });
  }
  static string AsTask() { return "" + StoreContext.GetDefault().GetAppLicenseAsync().AsTask().Result.IsActive; }
  static async Task<string> Awaited() { var l = await StoreContext.GetDefault().GetAppLicenseAsync(); return "" + l.IsTrial; }
  static string AsAction() {
    IAsyncAction a = Task.Delay(20).AsAsyncAction();
    var done = new ManualResetEvent(false); AsyncStatus st = AsyncStatus.Started;
    a.Completed = (o, s) => { st = s; done.Set(); };
    done.WaitOne(10000);
    return st + ":" + typeof(WindowsRuntimeSystemExtensions).Assembly.GetName().Version;
  }
  static void Main() {
    Say("winrtxml", Xml);
    Say("toast", Toast);
    Say("history", History);
    Say("package", Package);
    Say("appdata", AppData);
    Say("contract", Contract);
    Say("license", License);
    Say("astask", AsTask);
    Say("await", () => Awaited().Result);
    Say("asaction", AsAction);
    Say("piid", Piid);
  }
}
CS
(cd "$W35" && timeout 300 "$WINE" "$csc" -nologo -t:library -out:Windows.Foundation.FoundationContract.dll foundation.cs \
  && timeout 300 "$WINE" "$csc" -nologo -t:library -r:Windows.Foundation.FoundationContract.dll -out:Windows.Foundation.UniversalApiContract.dll universal.cs \
  && timeout 300 "$WINE" "$csc" -nologo -t:library -r:Windows.Foundation.FoundationContract.dll -out:Windows.Services.Store.StoreContract.dll store.cs \
  && timeout 300 "$WINE" "$csc" -nologo -t:library -keyfile:ecma.pub -r:Windows.Foundation.FoundationContract.dll -out:System.Runtime.WindowsRuntime.dll srwr.cs \
  && timeout 300 "$WINE" "$csc" -nologo -r:Windows.Foundation.FoundationContract.dll -r:Windows.Foundation.UniversalApiContract.dll \
       -r:Windows.Services.Store.StoreContract.dll -r:System.Runtime.WindowsRuntime.dll -out:sg35.exe sg35.cs) >"$T/csc35.out" 2>&1
if [ ! -f "$W35/sg35.exe" ]; then
    fail "the sg35 probe did not compile: $(tail -5 "$T/csc35.out")"
else
    rm -f "$W35"/*.dll   # the stand-ins go: the image must serve the references
    # the compilers ran without a display: let that wineserver (and its desktop, which has no
    # display driver) go, so the probe's desktop has the display
    "$WINESERVER" -w
    D35=${SG_MONOFORK_DISPLAY:-}; XP35=
    if [ -z "$D35" ] && command -v Xvfb >/dev/null; then
        n=780; while [ $n -lt 810 ] && { [ -e "/tmp/.X$n-lock" ] || [ -e "/tmp/.X11-unix/X$n" ]; }; do n=$((n + 1)); done
        Xvfb ":$n" -screen 0 1280x1024x24 -nolisten tcp >/dev/null 2>&1 & XP35=$!; D35=":$n"
        i=0; while [ $i -lt 50 ] && [ ! -e "/tmp/.X11-unix/X$n" ]; do python3 -c "import time; time.sleep(0.1)"; i=$((i + 1)); done
    fi
    out=$(cd "$W35" && DISPLAY=$D35 timeout -s KILL 180 "$WINE" sg35.exe 2>&1 | tr -d '\r')
    [ -n "$XP35" ] && kill "$XP35" 2>/dev/null
    [ "$(v winrtxml)" = '<toast launch="from-body"><visual><binding template="ToastGeneric"><text>sg35</text><text>From .NET</text></binding></visual></toast>' ] \
        && pass "references to the Windows SDK's contract assemblies resolve to the system's metadata; XmlDocument is the system's" \
        || fail "WinRT by contract name: '$(v winrtxml)' $(printf '%s' "$out" | grep -m1 -i 'could not load\|exception') (sg34: FileNotFoundException)"
    [ "$(v toast)" = "Enabled:tag1/grp1:shown=True:activated=True:from-body:same" ] \
        && pass "a toast through the system's ToastNotifier shows; a click raises Activated (WindowsRuntimeMarshal) with its launch arguments" \
        || fail "toast: '$(v toast)'"
    [ "$(v history)" = 0 ] && pass "ToastNotificationManager.History clears and lists" || fail "toast history: '$(v history)'"
    [ "$(v package)" = "InvalidOperationException:80073D54" ] && [ "$(v appdata)" = "InvalidOperationException:80073D54" ] \
        && pass "Package.Current and ApplicationData.Current without package identity: InvalidOperationException 0x80073D54, as on Windows" \
        || fail "no package identity: '$(v package)' / '$(v appdata)'"
    [ "$(v contract)" = "True:False" ] && pass "ApiInformation.IsApiContractPresent is the system's answer" || fail "ApiInformation: '$(v contract)'"
    [ "$(v license)" = "Completed:False:False" ] && [ "$(v astask)" = False ] && [ "$(v await)" = False ] \
        && pass "the Store's app licence through IAsyncOperation: Completed, AsTask and await (System.Runtime.WindowsRuntime)" \
        || fail "IAsyncOperation: '$(v license)' / '$(v astask)' / '$(v await)'"
    [ "$(v piid)" = "ab54de2d-97d9-5528-b6ad-105afe156530:3866370b-afc6-5d01-84c2-4574628de539" ] \
        && pass "parameterized interface ids from the type signatures (the system asks delegates and operations by them)" \
        || fail "parameterized interface ids: '$(v piid)'"
    [ "$(v asaction)" = "Completed:4.0.0.0" ] \
        && pass "a Task as IAsyncAction; System.Runtime.WindowsRuntime 4.0.14.0 binds to the framework's 4.0.0.0" \
        || fail "AsAsyncAction / System.Runtime.WindowsRuntime: '$(v asaction)'"
fi
# (sg35) the C++/CLI runtime's managed helpers (mono-0033): a mixed-mode assembly built by Visual
# C++ 2005/2008 (/clr: Apache OpenOffice's cli_uno.dll, cli_cppuhelper.dll) imports
# <CrtImplementationDetails>.RegisterModuleUninitializer(EventHandler), ThrowModuleLoadException
# (string[, Exception]) and ThrowNestedModuleLoadException(Exception, Exception) from msvcm80/90
# as native methods of its <Module>; on Windows they are msvcm's managed functions. The runtime
# calls corlib's own: the uninitializers (C++ static destructors) run once at process exit, the
# module registered last first, and a failed module initialization raises ModuleLoadException.
# Wine's native msvcm only printed "stub" (the destructors never ran) and returned. The probe
# declares the imports as cli_uno.dll does (pinvokeimpl msvcm90.dll; ilasm writes no native code, so they are plain imports).
# sg34: MissingMethodException / EntryPointNotFoundException. Mutant:
# -d:SG_MUTANT_MSVCM_HELPERS_NATIVE (marshal.c).
cat > "$C/crtimpl.il" <<'IL'
.assembly extern mscorlib { .publickeytoken = (B7 7A 5C 56 19 34 E0 89) .ver 4:0:0:0 }
.assembly crtimpl { .ver 1:0:0:0 }
.module crtimpl.dll
.method public static pinvokeimpl("msvcm90.dll" lasterr cdecl) void '<CrtImplementationDetails>.RegisterModuleUninitializer'(class [mscorlib]System.EventHandler A_0) cil managed preservesig { }
.method public static pinvokeimpl("msvcm90.dll" lasterr cdecl) void '<CrtImplementationDetails>.ThrowModuleLoadException'(string A_0) cil managed preservesig { }
.method public static pinvokeimpl("msvcm90.dll" lasterr cdecl) void '<CrtImplementationDetails>.ThrowModuleLoadException'(string A_0, class [mscorlib]System.Exception A_1) cil managed preservesig { }
.method public static pinvokeimpl("msvcm90.dll" lasterr cdecl) void '<CrtImplementationDetails>.ThrowNestedModuleLoadException'(class [mscorlib]System.Exception A_0, class [mscorlib]System.Exception A_1) cil managed preservesig { }
.class public auto ansi abstract sealed Crt extends [mscorlib]System.Object {
  .method public static void Register(class [mscorlib]System.EventHandler h) cil managed {
    ldarg.0
    call void '<CrtImplementationDetails>.RegisterModuleUninitializer'(class [mscorlib]System.EventHandler)
    ret
  }
  .method public static void Throw(string m) cil managed {
    ldarg.0
    call void '<CrtImplementationDetails>.ThrowModuleLoadException'(string)
    ret
  }
  .method public static void Throw(string m, class [mscorlib]System.Exception e) cil managed {
    ldarg.0
    ldarg.1
    call void '<CrtImplementationDetails>.ThrowModuleLoadException'(string, class [mscorlib]System.Exception)
    ret
  }
  .method public static void ThrowNested(class [mscorlib]System.Exception a, class [mscorlib]System.Exception b) cil managed {
    ldarg.0
    ldarg.1
    call void '<CrtImplementationDetails>.ThrowNestedModuleLoadException'(class [mscorlib]System.Exception, class [mscorlib]System.Exception)
    ret
  }
}
IL
cat > "$C/crtprobe.cs" <<'CS'
using System;
class P {
  static string Try(Action a) {
    try { a(); return "returned"; }
    catch (Exception e) { return e.GetType().Name + ":" + e.Message.Trim() + (e.InnerException != null ? "<" + e.InnerException.Message : ""); }
  }
  static void Main() {
    Console.WriteLine("register=" + Try(() => {
      Crt.Register((s, e) => Console.WriteLine("uninit=first"));
      Crt.Register((s, e) => Console.WriteLine("uninit=second"));
    }));
    Console.WriteLine("load1=" + Try(() => Crt.Throw("The C++ module failed to load.")));
    Console.WriteLine("load2=" + Try(() => Crt.Throw("The C++ module failed to load during native initialization.", new InvalidOperationException("cause"))));
    Console.WriteLine("nested=" + Try(() => Crt.ThrowNested(new InvalidOperationException("primary"), new ArgumentException("handler"))));
    Console.WriteLine("main=done");
  }
}
CS
ilasm=$("$WINE" winepath -w "$MONO/lib/mono/4.5/ilasm.exe" | tr -d '\r')
(cd "$C" && timeout 300 "$WINE" "$ilasm" /dll /out:crtimpl.dll crtimpl.il && timeout 300 "$WINE" "$mcs" -r:crtimpl.dll -out:crtprobe.exe crtprobe.cs) >"$T/crt.out" 2>&1
if [ ! -f "$C/crtprobe.exe" ]; then
    fail "the C++/CLI probe did not build: $(tail -5 "$T/crt.out")"
else
    out=$(cd "$C" && timeout -s KILL 120 "$WINE" crtprobe.exe 2>&1 | tr -d '\r')
    [ "$(v register)" = returned ] && [ "$(printf '%s\n' "$out" | grep '^uninit=' | tr '\n' ' ')" = "uninit=second uninit=first " ] \
        && printf '%s\n' "$out" | grep -A2 '^main=done' | grep -q '^uninit=second' \
        && pass "C++/CLI RegisterModuleUninitializer: the uninitializers run once at exit, the last registered first" \
        || fail "RegisterModuleUninitializer: '$(v register)' / $(printf '%s\n' "$out" | grep '^uninit=' | tr '\n' ' ') (sg34: EntryPointNotFoundException)"
    [ "$(v load1)" = "ModuleLoadException:The C++ module failed to load." ] \
        && [ "$(v load2)" = "ModuleLoadException:The C++ module failed to load during native initialization.<cause" ] \
        && pass "C++/CLI ThrowModuleLoadException raises ModuleLoadException (with its cause)" \
        || fail "ThrowModuleLoadException: '$(v load1)' / '$(v load2)'"
    case "$(v nested)" in "ModuleLoadExceptionHandlerException:A nested exception occurred after the primary exception that caused the C++ module to fail to load.<primary")
        pass "C++/CLI ThrowNestedModuleLoadException raises ModuleLoadExceptionHandlerException" ;;
    *)  fail "ThrowNestedModuleLoadException: '$(v nested)'" ;; esac
fi
# (sg36) a configuration section keeps the reader it was given (mono-0034): .NET Framework leaves
# the XmlReader it hands ConfigurationSection.DeserializeSection open, and a section may return it
# from GetRuntimeObject for the program to read -- SyncTrayzor's XmlConfigurationSection does, and
# deserializes its <settings> with XmlSerializer. Mono closed the reader after DeserializeSection:
# the settings read as nothing (null) and SyncTrayzor stopped at start with a
# NullReferenceException. sg35: reader=Closed, settings=null.
# Mutant: -d:SG_MUTANT_SECTION_READER_CLOSED (System.Configuration).
cat > "$C/sg36.cs" <<'CS'
using System; using System.Configuration; using System.Xml; using System.Xml.Serialization;
public class XmlSection : ConfigurationSection {
  XmlReader reader;
  protected override void DeserializeSection(XmlReader r) { reader = r; }
  protected override object GetRuntimeObject() { return reader; }
}
public class Settings { public string Url { get; set; } public int Port { get; set; } }
class P { static void Main() {
  var r = ConfigurationManager.GetSection("settings") as XmlReader;
  Console.WriteLine("reader=" + (r == null ? "null" : r.ReadState.ToString()));
  try {
    var s = (Settings)new XmlSerializer(typeof(Settings), new XmlRootAttribute("settings")).Deserialize(r);
    Console.WriteLine("settings=" + (s == null ? "null" : s.Url + ":" + s.Port));
  } catch (Exception e) { Console.WriteLine("settings=" + e.GetType().Name); }
} }
CS
cat > "$C/sg36.exe.config" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <configSections><section name="settings" type="XmlSection, sg36" /></configSections>
  <settings><Url>https://example.invalid/check</Url><Port>2004</Port></settings>
</configuration>
XML
(cd "$C" && timeout 300 "$WINE" "$mcs" -r:System.Configuration.dll -r:System.Xml.dll -out:sg36.exe sg36.cs >"$T/mcs36.out" 2>&1)
if [ ! -f "$C/sg36.exe" ]; then
    fail "the sg36 probe did not compile: $(cat "$T/mcs36.out")"
else
    out=$(cd "$C" && timeout -s KILL 120 "$WINE" sg36.exe 2>&1 | tr -d '\r')
    [ "$(v reader)" = Initial ] && [ "$(v settings)" = "https://example.invalid/check:2004" ] \
        && pass "a configuration section keeps the reader it was given and reads it later (SyncTrayzor's settings)" \
        || fail "section reader: '$(v reader)' settings '$(v settings)' (sg35: Closed, null)"
fi
exit $RC
