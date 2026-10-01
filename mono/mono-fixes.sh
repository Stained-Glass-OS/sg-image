#!/bin/sh
# mono-fixes.sh MONO_DIR: Stained Glass OS's fixes to Wine Mono's own files,
# applied when the image unpacks it (Makefile: addons). Wine Mono is MIT; these
# are configuration only -- a fork with code patches would build Wine Mono
# from source instead.
#
# 1. machine.config (4.0, 4.5) declares <System.Windows.Forms.
#    ApplicationConfigurationSection>, as .NET Framework 4.7's does: a
#    WinForms program's own .config uses it for its DPI awareness
#    (Greenshot: <add key="DpiAwareness" value="PerMonitorV2"/>), and Mono's
#    configuration system refused the whole file -- "Unrecognized
#    configuration section", the program stopped before its first window.
set -eu
dir=$1
section='<section name="System.Windows.Forms.ApplicationConfigurationSection" type="System.Configuration.NameValueSectionHandler, System, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089" allowExeDefinition="MachineToApplication" requirePermission="false" />'
for v in 4.0 4.5; do
    f=$(find "$dir" -path "*/etc/mono/$v/machine.config" | head -1)
    [ -n "$f" ] || { echo "mono-fixes: no $v machine.config under $dir" >&2; exit 1; }
    grep -q 'System.Windows.Forms.ApplicationConfigurationSection' "$f" && continue
    sed -i "0,/<configSections>/s|<configSections>|<configSections>\n\t\t$section|" "$f"
    grep -q 'System.Windows.Forms.ApplicationConfigurationSection' "$f" || { echo "mono-fixes: $f not changed" >&2; exit 1; }
done
echo "mono-fixes: applied to $dir"
