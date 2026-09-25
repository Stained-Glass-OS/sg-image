#!/usr/bin/env bash
# The network gate: connectivity managed the way Windows manages it.
#
# Boots the image with two wired adapters (QEMU user networking, each with its
# own DHCP server) and a simulated Wi-Fi pair (mac80211_hwsim), and checks:
#
#   - NetworkManager runs the network and systemd-networkd does not; every
#     wired adapter got a DHCP lease on its own
#   - a standard user may not give an adapter a static address -- neither
#     through sg-netd nor by driving NetworkManager directly -- and an
#     administrator may (polkit rules and sg-netd agree)
#   - a static address, gateway and DNS server take effect (ip, the route,
#     the resolver), survive a NetworkManager restart, and switching back to
#     DHCP brings a lease back
#   - Wi-Fi: an access point on one simulated radio (WPA2-PSK, SSID and key
#     generated here, never committed; DHCP from dnsmasq) in a network
#     namespace of its own; a standard user scans, is refused with a wrong key
#     (and the network is not remembered), joins with the right one, gets an
#     address from the access point, disconnects, rejoins with the saved key,
#     and forgets it
#   - the key appears in no command line, log or artifact
#
# Needs what boot-test.sh needs.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
IMAGE="${SG_IMAGE:-$BUILD/sg-image.raw}"
SSH_KEY="$BUILD/ssh/id_ed25519"
SSH_PORT="${SG_SSH_PORT:-2227}"
RUN_IMAGE="$BUILD/net-run.raw"
RUN_VARS="$BUILD/net-run-vars.fd"
ARTIFACTS="$BUILD/artifacts-net"
NIC2_MAC=52:54:00:5e:00:02
QEMU_PID=""
RC=0

log()  { echo "[net-test] $*"; }
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
    # SG_KEEP_VM=1 leaves the guest up (ssh -p $SSH_PORT) to look at a failure
    if [[ "${SG_KEEP_VM:-0}" == "1" && -n "$QEMU_PID" ]]; then echo "[net-test] keeping the guest (qemu pid $QEMU_PID)"; return 0; fi
    [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; rm -f "$RUN_IMAGE"; return 0
}
trap cleanup EXIT INT TERM

# The Wi-Fi network: a name with a space and a non-ASCII character, and a
# WPA2 key -- both made here, for this run only.
rand() { python3 -c 'import secrets, string, sys; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(int(sys.argv[1]))), end="")' "$1"; }
SSID="SG Lab $(rand 6) ✓"
PSK=$(rand 20)
WRONG=$(rand 20)

g() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
# As a user, through sg-netd: the uid the kernel reports is what decides.
as() { local u=$1; shift; g "runuser -u $u -- $*"; }

if g true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi
log "copying image for this run"
cp --reflink=auto "$IMAGE" "$RUN_IMAGE"
cp "${OVMF_CODE/CODE/VARS}" "$RUN_VARS"
# shellcheck disable=SC2054  # the commas are inside quoted QEMU arguments
args=(
    -machine "q35,accel=$ACCEL" -m 4096 -smp 4
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$RUN_VARS"
    -drive "if=virtio,format=raw,file=$RUN_IMAGE"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0
    -netdev "user,id=net1,net=10.0.3.0/24,dhcpstart=10.0.3.15" -device "virtio-net-pci,netdev=net1,mac=$NIC2_MAC"
    -device virtio-vga -display none -serial "file:$ARTIFACTS/serial.log" -no-reboot
)
[[ "$ACCEL" == kvm ]] && args+=(-cpu host)
qemu-system-x86_64 "${args[@]}" &
QEMU_PID=$!
deadline=$(( SECONDS + BOOT_TIMEOUT ))
until g true 2>/dev/null; do
    kill -0 "$QEMU_PID" 2>/dev/null || { echo "FAIL: QEMU exited"; exit 1; }
    (( SECONDS < deadline )) || { echo "FAIL: no ssh"; exit 1; }
    sleep 5
done
log "guest is up"

# --- the stack -------------------------------------------------------------------
if g "systemctl is-active -q NetworkManager && ! systemctl is-active -q systemd-networkd"; then
    pass "NetworkManager runs the network; systemd-networkd does not"
else fail "network services: NM=$(g 'systemctl is-active NetworkManager') networkd=$(g 'systemctl is-active systemd-networkd')"; fi
g "systemctl is-active -q sg-netd.socket" && pass "sg-netd's socket is listening" || fail "sg-netd.socket is not active"
NIC2=$(g "ip -o link | awk -v m=$NIC2_MAC 'index(\$0, m) {sub(/:\$/, \"\", \$2); print \$2; exit}'")
[[ -n "$NIC2" ]] || { fail "no adapter with MAC $NIC2_MAC"; exit 1; }
t=0; until g "ip -4 -o addr show dev $NIC2 | grep -q 'inet 10.0.3.15/24.*dynamic'" || (( t > 60 )); do sleep 3; t=$(( t + 3 )); done
if g "ip -4 -o addr show dev $NIC2 | grep -q 'inet 10.0.3.15/24.*dynamic' && ip -4 -o addr show | grep -q 'inet 10.0.2.15/24.*dynamic'"; then
    pass "both wired adapters got a DHCP lease with no configuration"
else fail "DHCP: $(g 'ip -4 -o addr show')"; fi
out=$(as sguser sg-netctl adapters "$NIC2" || true)
if grep -qx 'IPV4-METHOD auto' <<<"$out" && grep -qx 'DHCP4-SERVER 10.0.3.2' <<<"$out" && grep -q '^DHCP4-EXPIRES [0-9]' <<<"$out"; then
    pass "sg-netctl reports the lease (DHCP server, expiry) as ipconfig /all would"
else fail "adapters: $out"; fi

# --- who may set an address -----------------------------------------------------------
# A standard desktop user: a Windows session (sgwine), not an administrator.
g "id stduser >/dev/null 2>&1 || useradd -m -s /bin/bash -G sgwine stduser"
g "id outsider >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin outsider"
g "id -nG stduser | grep -qw sg-admins" && fail "stduser is an administrator; the test needs a standard user"
status=0; as outsider sg-netctl wifi scan > "$ARTIFACTS/outsider.log" 2>&1 || status=$?
if [[ $status -eq 3 ]]; then pass "an account with no Windows session is refused even a scan"
else fail "outsider: status $status, $(cat "$ARTIFACTS/outsider.log")"; fi
g "id -nG sguser | grep -qw sg-admins" || fail "sguser is not an administrator"
status=0; as stduser sg-netctl ipv4 "$NIC2" static 10.0.3.50/24 --gateway 10.0.3.2 --dns 10.0.3.3 > "$ARTIFACTS/std-static.log" 2>&1 || status=$?
if [[ $status -eq 3 ]] && grep -q '^ERROR denied' "$ARTIFACTS/std-static.log" && ! g "ip -4 -o addr show dev $NIC2 | grep -q 10.0.3.50"; then
    pass "a standard user is refused a static address (and nothing changed)"
else fail "standard user static: status $status, $(cat "$ARTIFACTS/std-static.log")"; fi
UUID2=$(g "nmcli -t -g GENERAL.CON-UUID device show $NIC2")
if as stduser nmcli connection modify "$UUID2" ipv4.method manual ipv4.addresses 10.0.3.51/24 >/dev/null 2>&1; then
    fail "a standard user changed an adapter's profile through NetworkManager directly"
else pass "a standard user cannot go round sg-netd by driving NetworkManager (polkit)"; fi
if as stduser nmcli connection add type ethernet ifname "$NIC2" con-name mine ipv4.method manual ipv4.addresses 10.0.3.52/24 >/dev/null 2>&1; then
    fail "a standard user created a static profile of their own"
    g "nmcli connection delete mine" >/dev/null 2>&1 || true
else pass "nor create a static profile of their own"; fi
# An administrator from outside any seat session: the stock policy would ask
# for authentication (and fail with no agent); the rules let sg-admins through.
if as sguser nmcli connection modify "$UUID2" connection.autoconnect yes >/dev/null 2>&1; then
    pass "an administrator may drive NetworkManager directly (the rules are loaded)"
else fail "sg-admins refused by NetworkManager: $(as sguser nmcli connection modify "$UUID2" connection.autoconnect yes 2>&1)"; fi

# --- static, and back to DHCP (as an administrator) ------------------------------------
if as sguser sg-netctl ipv4 "$NIC2" static 10.0.3.50/24 --gateway 10.0.3.2 --dns 10.0.3.3,9.9.9.9 > "$ARTIFACTS/static.log" 2>&1; then
    pass "an administrator sets a static address"
else fail "static: $(tail -3 "$ARTIFACTS/static.log")"; fi
check_static() {
    local when=$1
    if g "ip -4 -o addr show dev $NIC2 | grep 'inet 10.0.3.50/24' | grep -vq dynamic && ! ip -4 -o addr show dev $NIC2 | grep -q 10.0.3.15/"; then
        pass "$when: $NIC2 has 10.0.3.50/24, fixed, and the lease is gone"
    else fail "$when: address: $(g "ip -4 -o addr show dev $NIC2")"; fi
    if g "ip -4 route show default dev $NIC2 | grep 'via 10.0.3.2' | grep -q 'proto static'"; then
        pass "$when: the default gateway is 10.0.3.2 on $NIC2, configured (not from DHCP)"
    else fail "$when: route: $(g "ip -4 route show dev $NIC2")"; fi
    if g "resolvectl dns $NIC2 | grep -w 10.0.3.3 | grep -qw 9.9.9.9"; then pass "$when: the resolver uses 10.0.3.3 and 9.9.9.9 for $NIC2"
    else fail "$when: DNS: $(g "resolvectl dns $NIC2")"; fi
}
check_static "static"
out=$(as sguser sg-netctl adapters "$NIC2" || true)
grep -qx 'IPV4-METHOD manual' <<<"$out" && grep -qx 'IPV4-DNS-AUTO no' <<<"$out" \
    && pass "sg-netctl reports the adapter as manually configured" || fail "adapters after static: $out"
g "systemctl restart NetworkManager"; sleep 8
check_static "after NetworkManager restarts"
if as sguser sg-netctl ipv4 "$NIC2" dhcp > "$ARTIFACTS/dhcp.log" 2>&1; then pass "an administrator switches back to DHCP"
else fail "dhcp: $(tail -3 "$ARTIFACTS/dhcp.log")"; fi
t=0; until g "ip -4 -o addr show dev $NIC2 | grep -q 'inet 10.0.3.15/24.*dynamic'" || (( t > 45 )); do sleep 3; t=$(( t + 3 )); done
if g "ip -4 -o addr show dev $NIC2 | grep -q 'inet 10.0.3.15/24.*dynamic' && ! ip -4 -o addr show dev $NIC2 | grep -q 10.0.3.50"; then
    pass "a DHCP lease is back and the fixed address gone"
else fail "after dhcp: $(g "ip -4 -o addr show dev $NIC2")"; fi
g "resolvectl dns $NIC2 | grep -qw 10.0.3.3 && ! resolvectl dns $NIC2 | grep -qw 9.9.9.9 && ip -4 route show default dev $NIC2 | grep -q 'proto dhcp'" \
    && pass "DNS and the gateway come from the DHCP server again" || fail "after dhcp: $(g "resolvectl dns $NIC2; ip -4 route show dev $NIC2")"

# --- netsh and ipconfig (wine-sg 0079), on the real NetworkManager -----------------------
# As a Windows program runs them: a user's wine, the system prefix.
g "printf '%s\\n' '. /usr/lib/stained-glass/sg-common.sh' 'sg_wine_env' 'exec wine \"\$@\"' > /tmp/sg-wine.sh && chmod 0755 /tmp/sg-wine.sh"
# (a refused command exits 1: its output is what the checks judge)
W() { local u=$1; shift; { g "runuser -u $u -- sh /tmp/sg-wine.sh $*" 2>>"$ARTIFACTS/wine-stderr.log" || true; } | tr -d '\r'; }
out=$(W stduser netsh interface ip set address name=$NIC2 static 10.0.3.60 255.255.255.0 10.0.3.2)
if grep -q 'requires elevation' <<<"$out" && ! g "ip -4 -o addr show dev $NIC2 | grep -q 10.0.3.60"; then
    pass "netsh: a standard user is refused, in Windows' words, and nothing changed"
else fail "netsh as a standard user: $out"; fi
W sguser netsh interface ip set address name=$NIC2 static 10.0.3.60 255.255.255.0 10.0.3.2 > "$ARTIFACTS/netsh-static.log"
t=0; until g "ip -4 -o addr show dev $NIC2 | grep -q 'inet 10.0.3.60/24'" || (( t > 30 )); do sleep 2; t=$(( t + 2 )); done
if g "ip -4 -o addr show dev $NIC2 | grep 'inet 10.0.3.60/24' | grep -vq dynamic && ip -4 route show default dev $NIC2 | grep -q 'via 10.0.3.2'"; then
    pass "netsh interface ip set address ... static: the adapter has it, and the gateway"
else fail "netsh static: $(cat "$ARTIFACTS/netsh-static.log"); $(g "ip -4 -o addr show dev $NIC2")"; fi
out=$(W sguser netsh interface ip show config name=$NIC2)
grep -q 'DHCP enabled: *No' <<<"$out" && grep -q 'IP Address: *10.0.3.60' <<<"$out" \
    && pass "netsh interface ip show config reports it" || fail "netsh show config: $out"
W sguser netsh interface ip set address name=$NIC2 dhcp > "$ARTIFACTS/netsh-dhcp.log"
t=0; until g "ip -4 -o addr show dev $NIC2 | grep -q 'inet 10.0.3.15/24.*dynamic'" || (( t > 45 )); do sleep 3; t=$(( t + 3 )); done
g "ip -4 -o addr show dev $NIC2 | grep -q 'inet 10.0.3.15/24.*dynamic' && ! ip -4 -o addr show dev $NIC2 | grep -q 10.0.3.60" \
    && pass "netsh ... dhcp: back on a lease" || fail "netsh dhcp: $(g "ip -4 -o addr show dev $NIC2")"
g "runuser -u sguser -- sg-netctl adapters $NIC2" > "$ARTIFACTS/adapters-before-renew.log" 2>&1 || true
# name the test adapter: renewing every adapter would renew the one this ssh uses
out=$(g "runuser -u sguser -- env WINEDEBUG=err+all,+seh sh /tmp/sg-wine.sh ipconfig /renew $NIC2 2>>/tmp/ipconfig.err; echo \"rc=\$?\"" 2>/dev/null | tr -d '\r')
g "cat /tmp/ipconfig.err" > "$ARTIFACTS/ipconfig.err" 2>/dev/null || true
grep -q '10.0.3.15' <<<"$out" && pass "ipconfig /renew $NIC2 renews, and lists the lease" || fail "ipconfig /renew: $out"

# --- Wi-Fi --------------------------------------------------------------------------------
if ! g "modprobe mac80211_hwsim radios=2" 2>"$ARTIFACTS/hwsim.log"; then
    fail "mac80211_hwsim: $(cat "$ARTIFACTS/hwsim.log")"
else
    # The station is whichever radio NetworkManager sees; the other becomes the
    # access point, in a namespace of its own so its traffic really crosses
    # the simulated air.
    sleep 3
    radios=$(g "ls /sys/class/ieee80211/ | sort" | tr '\n' ' ')
    AP_PHY=$(awk '{print $2}' <<<"$radios")
    AP_DEV=$(g "ls /sys/class/ieee80211/$AP_PHY/device/net/ 2>/dev/null | head -1")
    [[ -n "$AP_PHY" && -n "$AP_DEV" ]] || fail "no second radio: $radios"
    # The access point's configuration carries the key: a root-only file in
    # /run, written through ssh's stdin (and the environment here) -- never a
    # command line.
    SG_AP_SSID="$SSID" SG_AP_PSK="$PSK" python3 -c '
import os
ssid, psk = os.environ["SG_AP_SSID"], os.environ["SG_AP_PSK"]
print("ctrl_interface=/run/sg-ap-wpa\nap_scan=2\nnetwork={\n  ssid=%s\n  mode=2\n  frequency=2437\n"
      "  key_mgmt=WPA-PSK\n  proto=RSN\n  pairwise=CCMP\n  group=CCMP\n  psk=\"%s\"\n}" % (ssid.encode().hex(), psk))
'  | g "umask 077; cat > /run/sg-ap.conf"
    if g "set -e
        ip netns add sgap
        iw phy $AP_PHY set netns name sgap
        ip netns exec sgap ip link set lo up
        ip netns exec sgap ip link set $AP_DEV up
        ip netns exec sgap ip addr add 10.77.0.1/24 dev $AP_DEV
        ip netns exec sgap wpa_supplicant -B -D nl80211 -i $AP_DEV -c /run/sg-ap.conf -P /run/sg-ap-wpa.pid
        ip netns exec sgap dnsmasq --interface=$AP_DEV --bind-interfaces --port=0 --no-resolv \
            --dhcp-range=10.77.0.50,10.77.0.99,255.255.255.0,1h --dhcp-leasefile=/run/sg-ap.leases \
            --pid-file=/run/sg-ap-dnsmasq.pid
        mkdir -p /run/sg-ap-www; echo over-the-air > /run/sg-ap-www/probe.txt
        ip netns exec sgap setsid python3 -m http.server 8080 --bind 10.77.0.1 --directory /run/sg-ap-www \
            >/dev/null 2>&1 < /dev/null &" > "$ARTIFACTS/ap.log" 2>&1; then
        pass "an access point is up on the simulated air ($AP_DEV, WPA2-PSK)"
    else fail "access point: $(tail -5 "$ARTIFACTS/ap.log")"; fi
    STA=$(g "nmcli -t -f DEVICE,TYPE device status | awk -F: '\$2 == \"wifi\" {print \$1; exit}'")
    [[ -n "$STA" ]] && pass "NetworkManager has a Wi-Fi adapter ($STA)" || fail "no Wi-Fi adapter in NetworkManager"
    HEX=$(python3 -c 'import sys; print(sys.argv[1].encode().hex())' "$SSID")
    seen=""
    for _ in $(seq 1 12); do
        if as stduser sg-netctl wifi scan --rescan 2>/dev/null | grep -q "	$HEX	"; then seen=1; break; fi
        sleep 5
    done
    if [[ -n "$seen" ]]; then
        line=$(as stduser sg-netctl wifi scan | grep "	$HEX	")
        pass "a standard user sees the network: $(cut -f1-2 <<<"$line" | tr '\t' ' '), named '$(cut -f6 <<<"$line")'"
        [[ "$(cut -f6 <<<"$line")" == "$SSID" ]] && pass "its name comes back exactly, space and ✓ included" || fail "name mangled: $(cut -f6 <<<"$line")"
    else fail "the network never appeared in a scan: $(as stduser sg-netctl wifi scan 2>&1 | tail -3)"; fi

    status=0
    printf '%s\n' "$WRONG" | as stduser sg-netctl wifi connect --ssid-hex "$HEX" --password-stdin > "$ARTIFACTS/wrong.log" 2>&1 || status=$?
    if [[ $status -ne 0 ]] && grep -q '^ERROR auth' "$ARTIFACTS/wrong.log"; then pass "a wrong key is refused: $(grep ^ERROR "$ARTIFACTS/wrong.log")"
    else fail "wrong key: status $status, $(cat "$ARTIFACTS/wrong.log")"; fi
    if as stduser sg-netctl wifi saved | grep -q "	$HEX	"; then fail "a network that could not be joined was remembered"
    else pass "and the network is not remembered"; fi

    if printf '%s\n' "$PSK" | as stduser sg-netctl wifi connect --ssid-hex "$HEX" --password-stdin > "$ARTIFACTS/join.log" 2>&1; then
        pass "a standard user joins the network with its key"
    else fail "join: $(cat "$ARTIFACTS/join.log")"; fi
    t=0; until g "ip -4 -o addr show dev $STA | grep -q 'inet 10.77.0.'" || (( t > 30 )); do sleep 2; t=$(( t + 2 )); done
    if g "iw dev $STA link | grep -q 'Connected to' && ip -4 -o addr show dev $STA | grep -q 'inet 10.77.0.[5-9][0-9]/24'"; then
        pass "associated, with an address from the access point's DHCP ($(g "ip -4 -o addr show dev $STA | awk '{print \$4}'"))"
    else fail "after join: $(g "iw dev $STA link; ip -4 -o addr show dev $STA")"; fi
    g "ip netns exec sgap grep -q . /run/sg-ap.leases" && pass "the access point handed out the lease" || fail "no lease on the access point"
    if g "python3 -c \"import urllib.request; print(urllib.request.urlopen('http://10.77.0.1:8080/probe.txt', timeout=10).read().decode().strip())\"" | grep -qx over-the-air; then
        pass "traffic crosses the simulated air: a web page from the access point's side"
    else fail "no traffic to the access point: $(g "ip -4 route; ip neigh" 2>&1 | tail -5)"; fi
    out=$(as stduser sg-netctl adapters "$STA" || true)
    grep -qx "STATE connected" <<<"$out" && grep -qx "SSID-HEX $HEX" <<<"$out" \
        && pass "sg-netctl reports the Wi-Fi adapter connected to the network" || fail "adapters wlan: $out"
    if g "f=\$(grep -l '^psk=' /etc/NetworkManager/system-connections/sg-wifi-*.nmconnection | head -1); [ -n \"\$f\" ] && [ \"\$(stat -c %a:%U \"\$f\")\" = 600:root ]"; then
        pass "the saved profile is 0600 root"
    else fail "profile permissions: $(g 'ls -l /etc/NetworkManager/system-connections/')"; fi

    if as stduser sg-netctl wifi disconnect "$STA" >/dev/null && g "! iw dev $STA link | grep -q 'Connected to'"; then
        pass "a standard user disconnects"
    else fail "disconnect: $(g "iw dev $STA link")"; fi
    if as stduser sg-netctl wifi connect --ssid-hex "$HEX" > "$ARTIFACTS/rejoin.log" 2>&1 && \
       g "iw dev $STA link | grep -q 'Connected to'"; then
        pass "and rejoins with the saved key, not asked again"
    else fail "rejoin: $(cat "$ARTIFACTS/rejoin.log")"; fi
    if as stduser sg-netctl wifi forget --ssid-hex "$HEX" >/dev/null && ! as stduser sg-netctl wifi saved | grep -q "	$HEX	" && \
       g "! ls /etc/NetworkManager/system-connections/ | grep -q sg-wifi"; then
        pass "forget removes the network and its key"
    else fail "forget: $(as stduser sg-netctl wifi saved)"; fi
    if as stduser sg-netctl wifi radio off >/dev/null && as stduser sg-netctl wifi radio status | grep -qx 'RADIO disabled' && \
       as stduser sg-netctl wifi radio on >/dev/null; then
        pass "a standard user turns Wi-Fi off and on"
    else fail "radio: $(as stduser sg-netctl wifi radio status)"; fi
fi

# --- no key anywhere ------------------------------------------------------------------
g "journalctl -b --no-pager" > "$ARTIFACTS/journal.log" 2>/dev/null || true
g "rm -f /run/sg-ap.conf" || true
if grep -rqF -e "$PSK" -e "$WRONG" "$ARTIFACTS"; then fail "a Wi-Fi key appears in the journal or the artifacts"
else pass "no Wi-Fi key in the journal or the artifacts"; fi
grep -q 'sg-netd' "$ARTIFACTS/journal.log" && pass "sg-netd logs who changed what" || fail "sg-netd logged nothing"

[[ "${SG_KEEP_VM:-0}" == "1" ]] || g "systemctl poweroff" >/dev/null 2>&1 || true
for _ in $(seq 1 60); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
kill "$QEMU_PID" 2>/dev/null || true; wait "$QEMU_PID" 2>/dev/null || true; QEMU_PID=""

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL -- artifacts in $ARTIFACTS"; fi
exit $RC
