#!/bin/sh
# Guest side of sg-image's elevated-display gate (ADR 0012, B56). Run as the
# signed-in user: sh guest.sh launch|accounts|status|windows|adversary D W|verify
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
uid=$(id -u)
# the session's display, prefix and runtime directory
# shellcheck disable=SC1090
. "/run/user/$uid/sg-session.env"
export DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR WINEPREFIX
export PATH="/opt/wine-sg/bin:$PATH" WINEDEBUG=-all
CTL="/usr/libexec/stained-glass/sg-lockctl"
export SG_LOCK_CONTROL="/run/stained-glass-seat/seat0/$uid/control.sock"
APP='C:\Program Files\SG Test App'
case "$1" in
    launch)    # Run as administrator on the installer (ShellExecute runas)
        setsid wine "$(winepath -w "$HERE/sg-runas.exe")" "$(winepath -w "$HERE/sg-test-setup.exe")" \
            </dev/null >/dev/null 2>&1 & ;;
    accounts)  # "Add someone else to this PC": what the Control Panel runs, elevated
        setsid wine "$(winepath -w "$HERE/sg-runas.exe")" 'Z:\usr\libexec\stained-glass\shell\sg-control64.exe' \
            '/admin user-add' </dev/null >/dev/null 2>&1 & ;;
    status)    "$CTL" STATUS ;;
    windows)   "$CTL" WINDOWS ;;
    adversary) "$HERE/sg-xadversary" ":$2" "$3" ;;
    verify)
        printf 'TYPED %s\n' "$(wine cmd /c type "$APP\\typed.txt" 2>/dev/null | tr -d '\r')"
        wine cmd /c if exist "$APP\\sg-test-app.exe" echo INSTALLED 2>/dev/null | tr -d '\r'
        wine cmd /c if exist 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\SG Test App\SG Test App.lnk' echo SHORTCUT 2>/dev/null | tr -d '\r'
        wine reg query 'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\SGTestApp' /v DisplayName 2>/dev/null \
            | grep -q 'SG Test App' && echo ARP
        ;;
    *) echo "usage: guest.sh launch|accounts|status|windows|adversary D W|verify" >&2; exit 2 ;;
esac
