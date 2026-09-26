#!/usr/bin/env bash
# The domain member gate (D1), with the image's own DC role (D2) as the domain.
#
# Two copies of the image on a private network segment (QEMU multicast
# socket), each also on its own user-mode network for ssh:
#
#   dc1  192.168.77.10  sg-dc-provision: SGTEST.LAN, users alice (a Domain
#                        User) and dave (a Domain Admin)
#   ws1  192.168.77.20  sg-domain-join, then signed in to at its console, by
#                        typing, as the domain user alice
#
# Checks: the join (trust, users and groups resolve), a wrong password is
# refused at the login screen, alice's session comes up with the Windows
# desktop, it holds the Windows system's group (Domain Users are local Users),
# her Windows identity is the domain's (her SID from dc1 in her token, files,
# HKCU and ProfileList; domain groups in ACLs),
# she got a Kerberos ticket at sign-in, and a Windows program in
# her session gets a Kerberos service ticket for the DC's file service through
# SSPI -- single sign-on, no password asked. dave is an administrator of ws1.
# Network drives: alice's home drive (homeDirectory \\dc1\home\alice as
# H:) is mapped at sign-in with her own ticket, her logon script runs from
# NETLOGON, maps S: with NET USE and writes to H:; dave does not get her H:.
# Machine Group Policy: the computer's registry policy on gpupdate, and --
# after dc1's GPO changes and ws1 reboots -- at boot with no gpupdate, with
# the computer's startup script run as SYSTEM.
#
# Passwords are generated per run and never committed. Needs what
# boot-test.sh needs.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
IMAGE="${SG_IMAGE:-$BUILD/sg-image.raw}"
SSH_KEY="$BUILD/ssh/id_ed25519"
ARTIFACTS="$BUILD/artifacts-domain"
MCAST="${SG_DOMAIN_MCAST:-230.0.0.1:$(( 20000 + RANDOM % 10000 ))}"
REALM=SGTEST.LAN
declare -A PORT=( [dc]=2231 [ws]=2232 ) ADDR=( [dc]=192.168.77.10 [ws]=192.168.77.20 ) MAC=( [dc]=52:54:00:77:00:10 [ws]=52:54:00:77:00:20 )
declare -A PID=()
RC=0

log()  { echo "[domain-test] $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

[[ -f "$IMAGE" ]] || { echo "no image at $IMAGE -- run 'make image'"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- run 'make image'"; exit 2; }
if [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm; BOOT_TIMEOUT=300; else ACCEL=tcg; BOOT_TIMEOUT=1800; fi
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { OVMF_CODE=$c; break; }; done
[[ -n "$OVMF_CODE" ]] || { echo "no OVMF"; exit 2; }
rm -rf "$ARTIFACTS"; mkdir -p "$ARTIFACTS"
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    set +e
    # SG_DOMAIN_HOLD=1 leaves both machines running for a look afterwards
    # (ssh -p 2231 / 2232 root@127.0.0.1 with the image's key).
    if [[ -n "${SG_DOMAIN_HOLD:-}" ]]; then echo "[domain-test] holding dc1 (:${PORT[dc]}) and ws1 (:${PORT[ws]})"; return 0; fi
    local p; for p in "${PID[@]}"; do kill "$p" 2>/dev/null; done; return 0
}
trap cleanup EXIT INT TERM

genpw() {   # AD's default policy: upper, lower and digits
    python3 -c 'import secrets, string
a = string.ascii_letters + string.digits
while True:
    p = "".join(secrets.choice(a) for _ in range(14))
    if any(c.islower() for c in p) and any(c.isupper() for c in p) and any(c.isdigit() for c in p): break
print(p, end="")'
}
ADMIN_PW=$(genpw); ALICE_PW=$(genpw); DAVE_PW=$(genpw)
# Typed through QEMU's keyboard: qmp.py types letters (either case) and digits.

on() {   # on dc|ws COMMAND...
    local vm=$1; shift
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "${PORT[$vm]}" root@127.0.0.1 "$@"
}
qmp() { python3 "$HERE/test/qmp.py" "$BUILD/domain-ws-qmp.sock" "$@" >/dev/null; }

boot() {   # boot dc|ws [again]: a fresh copy of the image, or (again) the same disk
    local vm=$1
    if [[ "${2:-}" != again ]]; then
        cp --reflink=auto "$IMAGE" "$BUILD/domain-$vm.raw"
        cp "${OVMF_CODE/CODE/VARS}" "$BUILD/domain-$vm-vars.fd"
    fi
    # shellcheck disable=SC2054  # the commas are inside quoted QEMU arguments
    local args=(
        -machine "q35,accel=$ACCEL" -m 4096 -smp 4
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,unit=1,file=$BUILD/domain-$vm-vars.fd"
        -drive "if=virtio,format=raw,file=$BUILD/domain-$vm.raw"
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${PORT[$vm]}-:22" -device virtio-net-pci,netdev=net0
        -netdev "socket,id=net1,mcast=$MCAST" -device "virtio-net-pci,netdev=net1,mac=${MAC[$vm]}"
        -device virtio-vga -display none -serial "file:$ARTIFACTS/serial-$vm.log" -no-reboot
        -qmp "unix:$BUILD/domain-$vm-qmp.sock,server,nowait"
    )
    [[ "$ACCEL" == kvm ]] && args+=(-cpu host)
    qemu-system-x86_64 "${args[@]}" &
    PID[$vm]=$!
}
wait_up() {
    local vm=$1 deadline=$(( SECONDS + BOOT_TIMEOUT ))
    until on "$vm" true 2>/dev/null; do
        kill -0 "${PID[$vm]}" 2>/dev/null || { echo "FAIL: $vm's QEMU exited"; exit 1; }
        (( SECONDS < deadline )) || { echo "FAIL: $vm has no ssh"; exit 1; }
        sleep 5
    done
    # The private segment: a fixed address on the NIC with the known MAC, set
    # the way an administrator sets one (NetworkManager, through sg-netctl).
    on "$vm" "dev=\$(ip -o link | awk -v m='${MAC[$vm]}' 'index(\$0, m) {sub(/:\$/, \"\", \$2); print \$2; exit}')
[ -n \"\$dev\" ] && sg-netctl ipv4 \"\$dev\" static ${ADDR[$vm]}/24 >/dev/null &&
ip -4 -o addr show | grep -q 'inet ${ADDR[$vm]}/'"
}

for vm in dc ws; do
    if on "$vm" true 2>/dev/null; then echo "FAIL: something already answers on port ${PORT[$vm]} -- a VM left over?"; exit 1; fi
done
log "booting dc1 and ws1 on segment $MCAST"
boot dc; boot ws
wait_up dc; wait_up ws
pass "both machines are up on the private segment"

# --- the domain -----------------------------------------------------------------
if printf '%s' "$ADMIN_PW" | on dc "sg-dc-provision --realm $REALM --address ${ADDR[dc]} --admin-password-stdin" \
        > "$ARTIFACTS/provision.log" 2>&1; then
    pass "dc1 is the domain controller for $REALM"
else fail "provisioning: $(tail -3 "$ARTIFACTS/provision.log")"; exit 1; fi
if on dc "samba-tool user create alice '$ALICE_PW' --given-name=Alice --surname=User \
           --home-drive=H: --home-directory='\\\\dc1\\home\\alice' --script-path=logon.bat >/dev/null &&
       samba-tool user create dave '$DAVE_PW' --given-name=Dave --surname=Admin >/dev/null &&
       samba-tool group addmembers 'Domain Admins' dave >/dev/null"; then
    pass "users alice (Domain Users) and dave (Domain Admins) exist"
else fail "creating users"; fi
# File shares on dc1 for the network-drive checks: alice's home folder, a
# shared folder, and her logon script in NETLOGON. The script writes to H:
# (mapped before it runs) and maps S: itself, as logon scripts do.
if on dc "set -e
    mkdir -p /srv/home/alice /srv/shared
    chmod 1777 /srv/home /srv/shared; chmod 0777 /srv/home/alice
    echo marker > /srv/shared/marker.txt
    printf '\n[home]\n\tpath = /srv/home\n\tread only = no\n\n[shared]\n\tpath = /srv/shared\n\tread only = no\n' >> /etc/samba/smb.conf
    printf '%s\\r\\n' '@echo off' 'echo %USERNAME% ran the logon script> H:\\logon-ran.txt' \\
        'net use S: \\\\dc1\\shared' 'if exist S:\\marker.txt echo S-ok>> H:\\logon-ran.txt' \\
        > /var/lib/samba/sysvol/sgtest.lan/scripts/logon.bat
    smbcontrol all reload-config >/dev/null 2>&1 || true"; then
    pass "dc1 shares alice's home folder, a shared folder and a logon script"
else fail "file shares on dc1"; fi
# A Group Policy Object linked to the domain, for alice's sign-in: a
# Preferences drive map (T: -> \\dc1\shared), a GPO logon script, and a
# user registry policy value.
GPO=$(on dc "samba-tool gpo create 'SG Test Policy' -U administrator --password='$ADMIN_PW' 2>/dev/null" \
      | grep -o '{[0-9A-Fa-f-]*}' | head -1 || true)
if [[ -n "$GPO" ]] && on dc "set -e
    g=/var/lib/samba/sysvol/sgtest.lan/Policies/$GPO/User
    mkdir -p \$g/Preferences/Drives \$g/Scripts/Logon \$g/../Machine/Scripts/Startup
    cat > \$g/Preferences/Drives/Drives.xml <<'XML'
<?xml version=\"1.0\" encoding=\"utf-8\"?>
<Drives clsid=\"{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}\"><Drive clsid=\"{935D1B74-9CB8-4e3c-9914-7DD559B7A417}\" name=\"T:\" status=\"T:\" image=\"2\" changed=\"2026-09-24 00:00:00\" uid=\"{6A2C4D1E-0000-4000-8000-000000000001}\"><Properties action=\"U\" thisDrive=\"NOCHANGE\" allDrives=\"NOCHANGE\" userName=\"\" path=\"\\\\dc1\\shared\" label=\"Shared\" persistent=\"0\" useLetter=\"1\" letter=\"T\"/></Drive></Drives>
XML
    printf '%s\\r\\n' 'echo GPO script ran> H:\\gpo-ran.txt' 'if exist T:\\marker.txt echo T-ok>> H:\\gpo-ran.txt' > \$g/Scripts/Logon/gpo-logon.cmd
    printf '%s\\r\\n' '@echo off' 'echo startup script ran as %USERNAME%> C:\\ProgramData\\sg-gpo-startup.txt' > \$g/../Machine/Scripts/Startup/gpo-startup.cmd
    python3 -c \"import sys
open(sys.argv[1], 'wb').write('\\ufeff[Logon]\\r\\n0CmdLine=gpo-logon.cmd\\r\\n0Parameters=\\r\\n'.encode('utf-16-le'))
def w(s): return s.encode('utf-16-le')
e = w('[') + w('Software\\\\Policies\\\\StainedGlassTest\\0') + w(';') + w('GpoValue\\0') + w(';') + (4).to_bytes(4, 'little') + w(';') + (4).to_bytes(4, 'little') + w(';') + (42).to_bytes(4, 'little') + w(']')
open(sys.argv[2], 'wb').write(b'PReg' + (1).to_bytes(4, 'little') + e)
m = w('[') + w('Software\\\\Policies\\\\StainedGlassTest\\0') + w(';') + w('MachineValue\\0') + w(';') + (4).to_bytes(4, 'little') + w(';') + (4).to_bytes(4, 'little') + w(';') + (7).to_bytes(4, 'little') + w(']')
open(sys.argv[3], 'wb').write(b'PReg' + (1).to_bytes(4, 'little') + m)
open(sys.argv[4], 'wb').write('\\ufeff[Startup]\\r\\n0CmdLine=gpo-startup.cmd\\r\\n0Parameters=\\r\\n'.encode('utf-16-le'))\" \$g/Scripts/scripts.ini \$g/Registry.pol \$g/../Machine/Registry.pol \$g/../Machine/Scripts/scripts.ini
    samba-tool gpo setlink DC=sgtest,DC=lan $GPO -U administrator --password='$ADMIN_PW' >/dev/null
    samba-tool ntacl sysvolreset >/dev/null 2>&1 || true"; then
    pass "a GPO ($GPO) with a drive map, a logon script, a startup script and registry policy is linked to the domain"
else fail "creating the test GPO"; fi

# --- the join -------------------------------------------------------------------
on ws "hostnamectl set-hostname ws1"
if printf '%s' "$ADMIN_PW" | on ws "sg-domain-join --domain $REALM --dc ${ADDR[dc]} --user administrator --password-stdin" \
        > "$ARTIFACTS/join.log" 2>&1; then
    pass "ws1 joined $REALM"
else fail "join: $(tail -5 "$ARTIFACTS/join.log")"; exit 1; fi
if on ws "wbinfo -t" >/dev/null 2>&1; then pass "the machine account's trust holds (wbinfo -t)"
else fail "trust: $(on ws 'wbinfo -t' 2>&1)"; fi
if on ws "getent passwd alice | grep -q '/home/SGTEST/alice' && id alice | grep -qi '(domain users)'"; then
    pass "domain users resolve by plain name (alice, in Domain Users)"
else fail "alice: $(on ws 'getent passwd alice; id alice' 2>&1)"; fi
if on ws "id dave | grep -qi '(domain admins)'"; then pass "dave is in Domain Admins"
else fail "dave: $(on ws 'id dave' 2>&1)"; fi


# --- signing in at ws1's console as alice -----------------------------------------
log "signing in to ws1 as alice"
t=0
until on ws "journalctl -b -t sg-login --no-pager -o cat | grep -q 'greeter ready'" 2>/dev/null; do
    (( t < 300 )) || { fail "no login screen on ws1"; break; }; sleep 3; t=$(( t + 3 ))
done
sleep 3
type_login() {   # type_login USER PASSWORD
    # After a refused sign-in the greeter keeps the user name, as Windows does:
    # select what is there, so typing replaces it.
    qmp type x; qmp key backspace; sleep 1
    qmp key home; qmp key shift+end
    qmp type "$1"; qmp key ret; sleep 4
    qmp type "$2"; qmp key ret
}
type_login alice "Wrong$ALICE_PW"
sleep 8
if on ws "journalctl -b -t greetd --no-pager -o cat | grep -q 'authentication error'" 2>/dev/null \
   && ! on ws "pgrep -u alice -f explorer.exe >/dev/null" 2>/dev/null; then
    pass "a wrong domain password is refused at the login screen"
else fail "wrong password: $(on ws 'journalctl -b -t greetd -o cat | tail -3' 2>&1)"; fi
sleep 3
type_login alice "$ALICE_PW"
t=0
until on ws "pgrep -u alice -x explorer.exe >/dev/null" 2>/dev/null; do
    (( t < 240 )) || break; sleep 3; t=$(( t + 3 ))
done
python3 "$HERE/test/qmp.py" "$BUILD/domain-ws-qmp.sock" screendump "$ARTIFACTS/ws1-alice.ppm" >/dev/null 2>&1 || true
if on ws "pgrep -u alice -x explorer.exe >/dev/null" 2>/dev/null; then
    pass "alice's session came up with the Windows desktop"
else fail "no session for alice: $(on ws 'journalctl -b -t greetd -t sg-session -o cat | tail -8' 2>&1)"; fi

ALICE_UID=$(on ws "id -u alice")
SHELL_PID=$(on ws "pgrep -u alice -x explorer.exe | head -1" || true)
if [[ -n "$SHELL_PID" ]] && on ws "grep '^Groups:' /proc/$SHELL_PID/status | tr ' \\t' '\\n\\n' | grep -qx \$(getent group sgwine | cut -d: -f3)"; then
    pass "her session holds the Windows system's group from sign-in (Domain Users are local Users)"
else fail "session groups: $(on ws "grep Groups /proc/${SHELL_PID:-1}/status" 2>&1)"; fi
if on ws "ls /tmp/krb5cc_$ALICE_UID >/dev/null && runuser -u alice -- klist -s -c /tmp/krb5cc_$ALICE_UID"; then
    pass "she got a Kerberos ticket at sign-in"
else fail "no ticket cache for alice: $(on ws 'ls -l /tmp/krb5cc_* 2>&1')"; fi

# A Windows program in her session: SSPI, no password.
probe=$(on ws "runuser -u alice -- env KRB5CCNAME=FILE:/tmp/krb5cc_$ALICE_UID sh -c '
    . /usr/lib/stained-glass/sg-common.sh; sg_wine_env
    timeout 120 wine /usr/libexec/stained-glass/sg-sspi-probe.exe cifs/dc1.sgtest.lan 2>/dev/null'" | tr -d '\r' || true)
printf '%s\n' "$probe" > "$ARTIFACTS/sspi-probe.txt"
if printf '%s\n' "$probe" | grep -qx 'AcquireKerberos=0x00000000'; then
    pass "a Windows program gets alice's Kerberos credentials through SSPI, without a password"
else fail "SSPI credentials: $(printf '%s ' "$probe")"; fi
if printf '%s\n' "$probe" | grep -Eq '^InitKerberos=0x0009031[12]$' && printf '%s\n' "$probe" | grep -qx 'MechKerberos=kerberos'; then
    pass "and a service ticket for dc1's file service -- single sign-on"
else fail "SSPI context: $(printf '%s ' "$probe")"; fi
if printf '%s\n' "$probe" | grep -Eq '^InitNegotiate=0x0009031[12]$' && printf '%s\n' "$probe" | grep -qx 'MechNegotiate=kerberos'; then
    pass "Negotiate chooses Kerberos too, not NTLM"
else fail "Negotiate: $(printf '%s ' "$probe")"; fi

# --- network drives and the logon script -------------------------------------------
if on ws "readlink /run/stained-glass-net/drives/$ALICE_UID/h: | grep -q '/unc/dc1/home/alice\$' &&
          grep -q ' /run/stained-glass-net/unc/dc1/home cifs ' /proc/mounts"; then
    pass "alice's home drive H: is \\\\dc1\\home\\alice, mounted with her ticket at sign-in"
else fail "home drive: $(on ws "ls -l /run/stained-glass-net/drives/$ALICE_UID/ 2>&1; grep cifs /proc/mounts; journalctl -b -t sg-domain-logon -o cat | tail -3" 2>&1)"; fi
t=0
until on dc "grep -q 'S-ok' /srv/home/alice/logon-ran.txt" 2>/dev/null; do
    (( t < 120 )) || break; sleep 3; t=$(( t + 3 ))
done
if on dc "grep -qi '^alice ran the logon script' /srv/home/alice/logon-ran.txt"; then
    pass "her logon script ran from NETLOGON and wrote to H: on the file server"
else fail "logon script: $(on ws "journalctl -b -t sg-session -t sg-domain-logon -o cat | grep -i logon | tail -4" 2>&1)"; fi
if on dc "grep -q 'S-ok' /srv/home/alice/logon-ran.txt"; then
    pass "and mapped S: with NET USE (the Windows network provider), which her programs then read"
else fail "NET USE S: in the logon script: $(on dc 'cat /srv/home/alice/logon-ran.txt' 2>&1)"; fi
drive_probe=$(on ws "runuser -u alice -- env KRB5CCNAME=FILE:/tmp/krb5cc_$ALICE_UID sh -c '
    . /usr/lib/stained-glass/sg-common.sh; sg_wine_env
    timeout 120 wine cmd /c \"type H:\\logon-ran.txt & type \\\\\\\\dc1\\\\shared\\\\marker.txt\" 2>/dev/null'" | tr -d '\r' || true)
printf '%s\n' "$drive_probe" > "$ARTIFACTS/drive-probe.txt"
if printf '%s\n' "$drive_probe" | grep -qi 'ran the logon script' && printf '%s\n' "$drive_probe" | grep -qx marker; then
    pass "a Windows program reads H: and \\\\dc1\\shared directly (UNC)"
else fail "Windows program on H: / UNC: $(printf '%s ' "$drive_probe")"; fi
dir_probe=$(on ws "runuser -u alice -- env KRB5CCNAME=FILE:/tmp/krb5cc_$ALICE_UID sh -c '
    . /usr/lib/stained-glass/sg-common.sh; sg_wine_env
    timeout 120 wine cmd /c \"dir \\\\\\\\dc1\\\\shared\" 2>/dev/null'" | tr -d '\r' || true)
printf '%s\n' "$dir_probe" > "$ARTIFACTS/dir-probe.txt"
if printf '%s\n' "$dir_probe" | grep -qF 'Directory of \\dc1\shared' && printf '%s\n' "$dir_probe" | grep -q ' marker.txt$'; then
    pass "cmd's dir \\\\dc1\\shared lists the share (not Z:\\dc1)"
else fail "dir of a UNC path: $(printf '%s ' "$dir_probe" | head -c 400)"; fi

t=0
until on dc "grep -q 'T-ok' /srv/home/alice/gpo-ran.txt" 2>/dev/null; do
    (( t < 90 )) || break; sleep 3; t=$(( t + 3 ))
done
if on dc "grep -q '^GPO script ran' /srv/home/alice/gpo-ran.txt && grep -q 'T-ok' /srv/home/alice/gpo-ran.txt"; then
    pass "Group Policy: the GPO's logon script ran and its drive map T: works"
else fail "GPO drive map / logon script: $(on ws "journalctl -b -t sg-gpo-user -o cat | tail -5" 2>&1)"; fi
gpo_reg=$(on ws "runuser -u alice -- sh -c '. /usr/lib/stained-glass/sg-common.sh; sg_wine_env
    timeout 120 wine reg query \"HKCU\\\\Software\\\\Policies\\\\StainedGlassTest\" /v GpoValue 2>/dev/null'" | tr -d '\r' || true)
if printf '%s\n' "$gpo_reg" | grep -Eq 'GpoValue.*REG_DWORD.*0x2a'; then
    pass "Group Policy: the user's registry policy is in her HKCU"
else fail "GPO user registry policy: $(printf '%s ' "$gpo_reg")"; fi

# --- alice's Windows identity is the domain's -------------------------------------
ALICE_SID=$(on dc "samba-tool user show alice --attributes=objectSid 2>/dev/null" | sed -n 's/^objectSid: //p' | tr -d '\r')
DOMAIN_SID=${ALICE_SID%-*}
sid_probe() {   # sid_probe USER ARGS...: sg-sid-probe in the user's session
    local u=$1; shift
    on ws "runuser -u $u -- sh -c '. /usr/lib/stained-glass/sg-common.sh; sg_wine_env
        timeout 120 wine /usr/libexec/stained-glass/sg-sid-probe.exe $*' 2>/dev/null" | tr -d '\r' || true
}
sid_out=$(sid_probe alice '"C:\\users\\alice"' '"SGTEST\\alice"' '"SGTEST\\Domain Admins"')
printf '%s\n' "$sid_out" > "$ARTIFACTS/sid-probe-alice.txt"
has() { printf '%s\n' "$sid_out" | grep -qxF -- "$1"; }
if [[ "$ALICE_SID" == S-1-5-21-* ]] && has "UserSid=$ALICE_SID"; then
    pass "a Windows program's token has alice's domain SID ($ALICE_SID, from dc1)"
else fail "token SID: wanted '$ALICE_SID': $(printf '%s ' "$sid_out" | head -c 600)"; fi
if has 'UserName=SGTEST\alice use=1' && has 'SamCompatible=SGTEST\alice'; then
    pass "LookupAccountSid and GetUserNameEx name her SGTEST\\alice"
else fail "names: $(printf '%s\n' "$sid_out" | grep -E '^(UserName|SamCompatible)=' | tr '\n' ' ')"; fi
if has "PrimaryGroup=$DOMAIN_SID-513" && has "Group=$DOMAIN_SID-513"; then
    pass "her primary group is the domain's Domain Users"
else fail "groups: $(printf '%s\n' "$sid_out" | grep -E '^(PrimaryGroup|Group)=' | tr '\n' ' ')"; fi
if has "FileOwner=$ALICE_SID"; then pass "a file she creates is owned by her domain SID"
else fail "file owner: $(printf '%s\n' "$sid_out" | grep '^File')"; fi
if has 'HkcuIsHkuSid=1'; then pass "her HKCU is HKEY_USERS\\<her domain SID>"
else fail "HKCU: $(printf '%s\n' "$sid_out" | grep '^Hkcu')"; fi
if has 'ProfileImagePath=%SystemDrive%\users\alice'; then pass "ProfileList\\<her SID> names her profile"
else fail "ProfileList: $(printf '%s\n' "$sid_out" | grep '^Profile')"; fi
if has "Name[SGTEST\\alice]=$ALICE_SID SGTEST use=1" && has "Name[SGTEST\\Domain Admins]=$DOMAIN_SID-512 SGTEST use=2"; then
    pass "LookupAccountName maps SGTEST\\alice and SGTEST\\Domain Admins to the domain's SIDs"
else fail "LookupAccountName: $(printf '%s\n' "$sid_out" | grep '^Name')"; fi
acl_held=$(sid_probe alice acl held '"SGTEST\\Domain Users"')
acl_not=$(sid_probe alice acl notheld '"SGTEST\\Domain Admins"')
printf '%s\n' "$acl_held" "$acl_not" > "$ARTIFACTS/sid-probe-acl.txt"
if printf '%s\n' "$acl_held" | grep -qx "Ace=$DOMAIN_SID-513" && printf '%s\n' "$acl_held" | grep -qx 'Opened=0' &&
   printf '%s\n' "$acl_not" | grep -qx "Ace=$DOMAIN_SID-512" && printf '%s\n' "$acl_not" | grep -qx 'Opened=5'; then
    pass "ACLs name domain groups and are enforced by them (Domain Users may open, Domain Admins only: denied)"
else fail "ACLs: $(printf '%s ' "$acl_held" "$acl_not")"; fi

# Machine Group Policy: the computer's GPOs' registry policy, fetched with the
# machine account and applied to HKLM as SYSTEM. gpupdate is eventually
# consistent (it needs the machine wineserver up, and the 90-minute timer
# retries), so poll a little, as Windows' own gpupdate does.
on ws "sg-gpupdate" >/dev/null 2>&1
if on ws "ls /etc/stained-glass/policy.d/60-domain-*.pol >/dev/null 2>&1"; then
    pass "sg-gpupdate fetches the computer's GPO registry policy"
else fail "machine GPO: $(on ws 'journalctl -b -t sg-gpo-machine -o cat | tail -4; ls /etc/stained-glass/policy.d' 2>&1)"; fi
mreg=""; t=0
while [ $t -lt 40 ]; do
    on ws "sg-gpupdate" >/dev/null 2>&1
    mreg=$(on ws "runuser -u sgsystem -- sh -c '. /usr/lib/stained-glass/sg-common.sh; sg_wine_env
        timeout 120 wine reg query \"HKLM\\\\Software\\\\Policies\\\\StainedGlassTest\" /v MachineValue 2>/dev/null'" | tr -d '\r' || true)
    printf '%s\n' "$mreg" | grep -Eq 'MachineValue.*REG_DWORD.*0x7' && break
    sleep 4; t=$(( t + 4 ))
done
if printf '%s\n' "$mreg" | grep -Eq 'MachineValue.*REG_DWORD.*0x7'; then
    pass "and it is in HKLM of the machine's Windows system"
else fail "machine GPO value: $(printf '%s ' "$mreg")"; fi

# --- administrators: Domain Admins are, Domain Users are not ---------------------
session_groups() {   # session_groups USER: group names the user's shell process holds
    on ws "p=\$(pgrep -u $1 -x explorer.exe | head -1); [ -n \"\$p\" ] &&
        for g in \$(sed -n 's/^Groups:\t*//p' /proc/\$p/status); do getent group \$g | cut -d: -f1; done" 2>/dev/null
}
alice_groups=$(session_groups alice || true)
if [[ -z "$alice_groups" ]]; then fail "could not read alice's session groups"
elif printf '%s\n' "$alice_groups" | grep -qx sg-admins; then fail "alice, a Domain User, is an administrator of ws1"
else pass "alice, a Domain User, is not an administrator of ws1"; fi
log "signing alice out, dave in"
on ws "loginctl terminate-user alice" >/dev/null 2>&1 || true
t=0
until [[ $(on ws "journalctl -b -t sg-login --no-pager -o cat | grep -c 'greeter ready'" 2>/dev/null || echo 0) -ge 2 ]]; do
    (( t < 180 )) || break; sleep 3; t=$(( t + 3 ))
done
sleep 3
type_login dave "$DAVE_PW"
t=0
until on ws "pgrep -u dave -x explorer.exe >/dev/null" 2>/dev/null; do
    (( t < 240 )) || break; sleep 3; t=$(( t + 3 ))
done
dave_groups=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    dave_groups=$(session_groups dave || true)
    [[ -n "$dave_groups" ]] && break
    sleep 3
done
if printf '%s\n' "$dave_groups" | grep -qx sg-admins; then pass "dave, a Domain Admin, is an administrator of ws1 (sg-admins from sign-in)"
else fail "dave's session groups: $(printf '%s' "$dave_groups" | tr '\n' ' ')"; fi
dave_sid=$(sid_probe dave)
printf '%s\n' "$dave_sid" > "$ARTIFACTS/sid-probe-dave.txt"
if [[ -n "${DOMAIN_SID:-}" ]] && printf '%s\n' "$dave_sid" | grep -qx "Group=$DOMAIN_SID-512" &&
   ! printf '%s\n' "$dave_sid" | grep -qx 'Group=S-1-5-32-544'; then
    pass "dave's Windows token holds Domain Admins, not Administrators (elevation is the broker's)"
else fail "dave's token: $(printf '%s\n' "$dave_sid" | grep -E '^(UserSid|Group)=' | tr '\n' ' ')"; fi
DAVE_UID=$(on ws "id -u dave")
if on ws "test ! -e /run/stained-glass-net/drives/$DAVE_UID/h: && test ! -e /run/stained-glass-net/drives/$ALICE_UID"; then
    pass "alice's drive letters went with her session; dave has none of them"
else fail "drive letters after sign-out: $(on ws 'ls -lR /run/stained-glass-net/drives' 2>&1)"; fi

# --- machine Group Policy at boot ---------------------------------------------------
# dc1's GPO changes (MachineValue 7 -> 9); ws1 restarts. With no gpupdate run
# by hand, the computer's policy is fetched and applied at boot and its
# startup script runs, as SYSTEM, once.
on ws "journalctl -b --no-pager" > "$ARTIFACTS/journal-ws-before-reboot.log" 2>/dev/null || true
if on dc "set -e
    m=/var/lib/samba/sysvol/sgtest.lan/Policies/$GPO/Machine/Registry.pol
    python3 -c \"import sys
def w(s): return s.encode('utf-16-le')
m = w('[') + w('Software\\\\Policies\\\\StainedGlassTest\\0') + w(';') + w('MachineValue\\0') + w(';') + (4).to_bytes(4, 'little') + w(';') + (4).to_bytes(4, 'little') + w(';') + (9).to_bytes(4, 'little') + w(']')
open(sys.argv[1], 'wb').write(b'PReg' + (1).to_bytes(4, 'little') + m)\" \$m" &&
   on ws "rm -f /var/lib/stained-glass/prefix/drive_c/ProgramData/sg-gpo-startup.txt"; then
    log "restarting ws1"
    on ws "systemctl reboot" >/dev/null 2>&1 || true
    t=0; while kill -0 "${PID[ws]}" 2>/dev/null && (( t < 120 )); do sleep 2; t=$(( t + 2 )); done
    boot ws again
    wait_up ws
    mreg=""; t=0
    while (( t < 240 )); do
        mreg=$(on ws "runuser -u sgsystem -- sh -c '. /usr/lib/stained-glass/sg-common.sh; sg_wine_env
            timeout 120 wine reg query \"HKLM\\\\Software\\\\Policies\\\\StainedGlassTest\" /v MachineValue 2>/dev/null'" | tr -d '\r' || true)
        printf '%s\n' "$mreg" | grep -Eq 'MachineValue.*REG_DWORD.*0x9' && break
        sleep 5; t=$(( t + 5 ))
    done
    if printf '%s\n' "$mreg" | grep -Eq 'MachineValue.*REG_DWORD.*0x9'; then
        pass "at boot, with no gpupdate by hand, ws1 applies the computer's changed GPO (MachineValue 9)"
    else fail "machine policy at boot: $(printf '%s ' "$mreg") $(on ws 'journalctl -b -u sg-gpupdate -t sg-gpo-machine -o cat | tail -5' 2>&1)"; fi
    t=0
    until on ws "grep -qi 'startup script ran' /var/lib/stained-glass/prefix/drive_c/ProgramData/sg-gpo-startup.txt" 2>/dev/null; do
        (( t < 180 )) || break; sleep 5; t=$(( t + 5 ))
    done
    startup=$(on ws "cat /var/lib/stained-glass/prefix/drive_c/ProgramData/sg-gpo-startup.txt" 2>/dev/null | tr -d '\r' || true)
    owner=$(on ws "stat -c %U /var/lib/stained-glass/prefix/drive_c/ProgramData/sg-gpo-startup.txt" 2>/dev/null || true)
    if printf '%s\n' "$startup" | grep -qi 'startup script ran as' && [[ "$owner" == sgsystem ]]; then
        pass "and runs the computer's GPO startup script at boot, as SYSTEM"
    else fail "startup script: '$startup' (owner '$owner') $(on ws 'journalctl -b -t sg-gpupdate -t sg-gpo-machine -o cat | tail -5' 2>&1)"; fi
else fail "changing the GPO / restarting ws1"; fi

on dc "journalctl -b --no-pager" > "$ARTIFACTS/journal-dc.log" 2>/dev/null || true
on ws "journalctl -b --no-pager" > "$ARTIFACTS/journal-ws.log" 2>/dev/null || true
for pw in "$ADMIN_PW" "$ALICE_PW" "$DAVE_PW"; do
    if grep -rq "$pw" "$ARTIFACTS"; then fail "a password appears in the artifacts"; fi
done

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL -- artifacts in $ARTIFACTS"; fi
exit $RC
