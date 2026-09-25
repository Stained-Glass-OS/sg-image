#!/usr/bin/env bash
# The first-run setup (OOBE) at the installed machine's first boot, walked
# through QEMU's keyboard as a person would: install-test.sh runs this through
# boot-test.sh's SG_PRE_LOGIN, between the boot and the sign-in.
#
#   region United Kingdom -> keyboard US -> a second layout, German -> the
#   network (the VM's wired one; "Skip for now" when offline) -> no account
#   page (Setup made the owner) -> privacy: Location on -> no browser -> "All
#   set" -> the login screen.
#
# Then, over ssh: the marker gone, the choices recorded, the keyboard file,
# the login screen's compositor started with both layouts, HKLM's privacy
# switches and no diagnostic data (read as SYSTEM), and sg-oobed refusing to
# run again. What the owner's own session gets is checked after sign-in
# (install-test.sh's post checks).
#
# Environment (from boot-test.sh): SG_QMP_SOCK, SG_SSH_PORT, SG_SSH_KEY,
# SG_ARTIFACTS, SG_WAIT (seconds to wait for the first-run setup).
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
QMP_SOCK=${SG_QMP_SOCK:?}
ART=${SG_ARTIFACTS:?}
WAIT=${SG_WAIT:-600}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
ssh_guest() {
    ssh -i "${SG_SSH_KEY:?}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "${SG_SSH_PORT:?}" root@127.0.0.1 "$@"
}
qmp()  { python3 "$HERE/test/qmp.py" "$QMP_SOCK" "$@" >/dev/null; }
shot() { python3 "$HERE/test/qmp.py" "$QMP_SOCK" screendump "$ART/oobe-$1.ppm" >/dev/null 2>&1 || true; }
journal() { ssh_guest "journalctl -b -t sg-oobe --no-pager -o cat" 2>/dev/null; }
seen() { journal | grep -c "$1"; }
# Wait until the first-run setup has logged $1 (a pattern) $2 times.
wait_for() {
    local t=0
    until [[ "$(seen "$1")" -ge "${2:-1}" ]]; do
        (( t < ${3:-120} )) || { fail "the first-run setup never logged '$1'"; shot "stuck"; return 1; }
        sleep 2; t=$(( t + 2 ))
    done
    sleep 1
}
# Press key $1 until the last selection logged is $2.
choose() {
    local _
    for _ in $(seq 1 30); do
        journal | grep 'sg-oobe: selected' | tail -1 | grep -q "selected $2\$" && return 0
        qmp key "$1"; sleep 1.5
    done
    fail "could not select $2"; return 1
}

t=0
until [[ "$(seen 'oobe ready')" -ge 1 ]]; do
    if (( t >= WAIT )); then
        fail "the first-run setup did not appear at the first boot"
        shot "none"
        ssh_guest "journalctl -b -t sg-login -t sg-oobe --no-pager -o cat | tail -20; ls -l /etc/stained-glass" 2>&1 | sed 's/^/    /'
        exit 1
    fi
    sleep 3; t=$(( t + 3 ))
done
pass "the first boot shows the first-run setup"
if ssh_guest "journalctl -b -t sg-login --no-pager -o cat | grep -q 'greeter ready'"; then
    fail "the login screen came up before the first-run setup was done"
else pass "and no login screen before it"; fi
if [[ "$(ssh_guest "stat -c '%U:%G %a' /run/stained-glass-oobe/oobed.sock" 2>/dev/null)" == "root:sgsetup 660" ]]; then
    pass "its service's socket is the login screen's alone (root:sgsetup 660)"
else fail "oobed socket: $(ssh_guest 'ls -l /run/stained-glass-oobe/' 2>&1)"; fi

wait_for 'sg-oobe: state' 1 60
sleep 3; qmp key shift; sleep 1; shot region
set +e
choose u 'United Kingdom'
qmp key ret
wait_for 'page keyboard$' && shot keyboard
qmp key ret                                   # Yes: US
wait_for 'page second-keyboard$' && shot second-keyboard
qmp key ret                                   # Add layout
wait_for 'page second-keyboard-pick$'
choose g German && shot second-pick
qmp key ret
wait_for 'page network$'
wait_for 'sg-oobe: networks' 1 90
sleep 2; shot network
if journal | grep 'sg-oobe: networks' | tail -1 | grep -q 'online=yes'; then
    ONLINE=yes
    qmp key ret                               # Next
else
    ONLINE=no
    qmp key tab; sleep 1; qmp key ret         # Skip for now
fi
echo "      the VM is online: $ONLINE"
wait_for 'page privacy$' && shot privacy
qmp key spc                                   # Location on
sleep 1; shot privacy-location
qmp key ret                                   # Accept
wait_for 'page browser$'
if [[ "$ONLINE" == yes ]]; then choose end "Don't install a browser now"; fi
shot browser
qmp key ret
wait_for 'page done$' 1 180 && shot "done"
if [[ "$(seen 'page account$')" -eq 0 ]]; then pass "no account page: Setup made the owner"
else fail "the account page appeared although Setup made the owner"; fi

# The login screen follows, with the layouts just chosen.
t=0
until ssh_guest "journalctl -b -t sg-login --no-pager -o cat | grep -q 'greeter ready'" 2>/dev/null; do
    (( t < 240 )) || { fail "no login screen after the first-run setup"; shot "no-greeter"; break; }
    sleep 3; t=$(( t + 3 ))
done
sleep 2; shot login
ssh_guest "journalctl -b -t sg-oobe -u 'sg-oobed@*' --no-pager -o cat" > "$ART/oobe.log" 2>&1

check=$(ssh_guest 'set +e
c=/etc/stained-glass/oobe.conf
[ ! -e /etc/stained-glass/oobe.pending ] && echo marker-gone
g() { sed -n "s/^$1=//p" $c; }
[ "$(g REGION_LOCALE) $(g REGION_GEO) $(g KEYBOARDS) $(g KEYBOARD_IDS)" = "en-GB 242 us,de 00000409,00000407" ] && echo recorded
[ "$(g LOCATION)$(g MICROPHONE)$(g TAILORED)$(g ADVERTISING) $(g DIAGNOSTICS) $(g BROWSER)" = "1100 none none" ] && echo privacy
grep -qx "XKBLAYOUT=\"us,de\"" /etc/default/keyboard && grep -qx "XKBOPTIONS=\"grp:win_space_toggle\"" /etc/default/keyboard && echo keyboard
for p in $(pgrep -u sggreet -x sg-compositor); do tr "\0" "\n" < /proc/$p/environ | grep -qx "XKB_DEFAULT_LAYOUT=us,de" && echo greeter-xkb; done
. /usr/lib/stained-glass/sg-common.sh
q() { runuser -u "$SG_SYSTEM_USER" -- env -u DISPLAY -u WAYLAND_DISPLAY SG_WINSTATION="__wineservice_winstation\\Default" \
      SG_LIB=/usr/lib/stained-glass K="$1" V="$2" sh -c ". \$SG_LIB/sg-common.sh; sg_wine_env; wine reg query \"\$K\" /v \"\$V\"" 2>/dev/null | tr -d "\r"; }
q "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location" Value | grep -q "REG_SZ *Allow" && echo hklm-location
q "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\microphone" Value | grep -q "REG_SZ *Allow" && echo hklm-microphone
q "HKLM\\Software\\Policies\\Microsoft\\Windows\\DataCollection" AllowTelemetry | grep -q "0x0" && echo hklm-telemetry
[ ! -e /run/stained-glass-oobe/oobed.sock ] || { runuser -u sggreet -- python3 -c "import socket; s = socket.socket(socket.AF_UNIX); s.connect(\"/run/stained-glass-oobe/oobed.sock\"); s.sendall(b\"STATE\\n\"); print(s.recv(200).decode())" 2>/dev/null | head -1 | grep -q "already done" && echo refuses-again; }
[ ! -e /run/stained-glass-oobe/oobed.sock ] && echo refuses-again
' 2>&1)
echo "$check" > "$ART/oobe-checks.txt"
has() { grep -qx "$1" <<< "$check"; }
has marker-gone && pass "done: the first-run setup's marker is gone" || fail "the marker is still there"
has recorded && pass "the region (en-GB, 242) and the layouts (us,de) are recorded for every user's first sign-in" || fail "oobe.conf: $(ssh_guest 'cat /etc/stained-glass/oobe.conf' 2>&1 | paste -sd' ')"
has privacy && pass "privacy as chosen: location on, microphone on, tailored and advertising off, no diagnostics, no browser" || fail "privacy record"
has keyboard && pass "the keyboard file has US and German, switched with Windows logo key + Space" || fail "/etc/default/keyboard: $(ssh_guest 'cat /etc/default/keyboard' 2>&1 | paste -sd' ')"
has greeter-xkb && pass "the login screen's compositor runs with both layouts" || fail "the login screen's compositor has no XKB_DEFAULT_LAYOUT=us,de"
has hklm-location && has hklm-microphone && pass "HKLM: the device's location and microphone switches are Allow (as SYSTEM)" || fail "HKLM ConsentStore: $check"
has hklm-telemetry && pass "HKLM: AllowTelemetry is 0" || fail "HKLM AllowTelemetry"
has refuses-again && pass "the first-run setup's service is gone or refuses once done" || fail "sg-oobed still answers after the first-run setup"
exit $RC
