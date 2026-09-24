#!/usr/bin/env bash
# The Remote Desktop gate (E1, ADR 0010): sign in to the image over RDP.
#
# Boots the image with the RDP port forwarded, turns Remote Desktop on (it is
# off by default, as on Windows), and connects a real FreeRDP client from this
# machine, on a private X server, as the lab user -- nobody signed in at the
# console. Then:
#
#   - a wrong password starts nothing
#   - the right one starts a remote session for that user, at the client's
#     size, with its own lock service; the Windows desktop comes up in it
#   - the client's window shows that desktop, taskbar included
#   - Win+L typed into the client locks the remote session and its lock
#     screen comes up; the password typed into the client unlocks it
#   - disconnecting keeps the session; logging in again reconnects to it
#
# Needs what boot-test.sh needs, plus xfreerdp3, Xvfb, xdotool and ImageMagick.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
IMAGE="${SG_IMAGE:-$BUILD/sg-image.raw}"
SSH_KEY="$BUILD/ssh/id_ed25519"
SSH_PORT="${SG_SSH_PORT:-2224}"
RDP_PORT="${SG_RDP_HOST_PORT:-33389}"
DPY_N="${SG_RDP_TEST_DISPLAY:-95}"
RUN_IMAGE="$BUILD/rdp-run.raw"
RUN_VARS="$BUILD/rdp-run-vars.fd"
LAB_USER=sguser
LAB_PASSWORD_FILE="$BUILD/lab-password"
ARTIFACTS="$BUILD/artifacts-rdp"
QEMU_PID=""; XPID=""; CPID=""
W=1280; H=800

log()  { echo "[rdp-test] $*"; }
fail() { echo "FAIL  $*"; RC=1; }
pass() { echo "PASS  $*"; }
RC=0

[[ -f "$IMAGE" ]] || { echo "no image at $IMAGE -- run 'make image'"; exit 2; }
[[ -f "$SSH_KEY" && -f "$LAB_PASSWORD_FILE" ]] || { echo "no ssh key or lab password -- run 'make image'"; exit 2; }
for t in xfreerdp3 Xvfb xdotool import convert; do
    command -v "$t" >/dev/null || { echo "SKIP: $t not installed"; exit 77; }
done
if [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm; BOOT_TIMEOUT=300; else ACCEL=tcg; BOOT_TIMEOUT=1800; fi
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { OVMF_CODE=$c; break; }; done
[[ -n "$OVMF_CODE" ]] || { echo "no OVMF"; exit 2; }

rm -rf "$ARTIFACTS"; mkdir -p "$ARTIFACTS"
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
    # Never abort half way (set -e): a VM left running holds the gate's ports,
    # and the next run would talk to it instead of its own.
    set +e
    [[ -n "$CPID" ]] && kill "$CPID" 2>/dev/null
    [[ -n "$XPID" ]] && kill "$XPID" 2>/dev/null
    [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null
    rm -f "/tmp/.X${DPY_N}-lock"
    return 0
}
trap cleanup EXIT INT TERM

ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}

if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi
log "copying image for this run"
cp --reflink=auto "$IMAGE" "$RUN_IMAGE"
cp "${OVMF_CODE/CODE/VARS}" "$RUN_VARS"
# shellcheck disable=SC2054  # the commas are inside quoted QEMU arguments
qemu_args=(
    -machine "q35,accel=$ACCEL" -m 4096 -smp 4
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$RUN_VARS"
    -drive "if=virtio,format=raw,file=$RUN_IMAGE"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$RDP_PORT-:3389"
    -device virtio-net-pci,netdev=net0
    -device virtio-vga -display none -serial "file:$ARTIFACTS/serial.log" -no-reboot
)
[[ "$ACCEL" == kvm ]] && qemu_args+=(-cpu host)
qemu-system-x86_64 "${qemu_args[@]}" &
QEMU_PID=$!
deadline=$(( SECONDS + BOOT_TIMEOUT ))
until ssh_guest true 2>/dev/null; do
    kill -0 "$QEMU_PID" 2>/dev/null || { echo "FAIL: QEMU exited"; exit 1; }
    (( SECONDS < deadline )) || { echo "FAIL: no ssh"; exit 1; }
    sleep 5
done
log "guest is up; waiting for the Windows system"
until ssh_guest "systemctl is-active -q sg-prefix-init && systemctl is-active -q sg-wineserver" 2>/dev/null; do
    (( SECONDS < deadline )) || { echo "FAIL: the Windows system did not start"; exit 1; }
    sleep 5
done
if ssh_guest "systemctl is-enabled -q sg-rdpd" 2>/dev/null; then fail "Remote Desktop is on by default"
else pass "Remote Desktop is off until turned on"; fi
ssh_guest "systemctl enable --now sg-rdpd" >/dev/null 2>&1
until ssh_guest "grep -q LISTENING /var/log/stained-glass/rdp.log" 2>/dev/null; do
    (( SECONDS < deadline )) || { fail "sg-rdpd did not start: $(ssh_guest 'journalctl -u sg-rdpd -o cat | tail -5')"; exit 1; }
    sleep 2
done
pass "Remote Desktop listens once turned on"
if [[ "$(ssh_guest "stat -c '%U %a' /etc/stained-glass/rdp/key.pem")" == "root 600" ]]; then
    pass "its certificate was made on first start, the key root's alone"
else fail "certificate key: $(ssh_guest 'ls -l /etc/stained-glass/rdp/' 2>&1)"; fi
UID_LAB=$(ssh_guest "id -u $LAB_USER")

rm -f "/tmp/.X${DPY_N}-lock"
Xvfb ":$DPY_N" -screen 0 "${W}x${H}x24" >/dev/null 2>&1 & XPID=$!
sleep 1
client() {
    DISPLAY=":$DPY_N" xfreerdp3 "/v:127.0.0.1:$RDP_PORT" "/u:$LAB_USER" "/p:$1" "/size:${W}x${H}" \
        /sec:tls /cert:ignore /log-level:OFF </dev/null >"$ARTIFACTS/client.log" 2>&1 &
    CPID=$!
}
rdplog() { ssh_guest "cat /var/log/stained-glass/rdp.log" 2>/dev/null; }
wait_rdplog() {   # wait_rdplog PATTERN SECONDS [COUNT]
    local t=0
    until [[ $(rdplog | grep -c -- "$1") -ge ${3:-1} ]]; do
        (( t < $2 )) || return 1
        sleep 2; t=$(( t + 2 ))
    done
}
shot() { DISPLAY=":$DPY_N" import -window root "$ARTIFACTS/$1.png" 2>/dev/null || true; }

# --- a wrong password ---------------------------------------------------------
client wrong-password
refused=0; wait_rdplog "LOGON FAIL user=$LAB_USER" 30 && refused=1
kill "$CPID" 2>/dev/null || true; wait "$CPID" 2>/dev/null || true; CPID=""
# It must have got as far as being refused -- a client that never reached the
# password check would otherwise "start nothing" too.
if [[ $refused == 0 ]]; then fail "the wrong password was never checked: $(rdplog | tail -3)"
elif ssh_guest "systemctl is-active -q sg-rdp-session-$UID_LAB" 2>/dev/null; then fail "a wrong password started a session"
else pass "a wrong password is refused and starts nothing"; fi

# --- the right one ------------------------------------------------------------
client "$(cat "$LAB_PASSWORD_FILE")"
if wait_rdplog "SESSION attached user=$LAB_USER" 120; then pass "the right password starts a remote session and attaches it"
else fail "no session: $(rdplog | tail -5)"; fi
if ssh_guest "systemctl is-active -q sg-rdp-session-$UID_LAB && systemctl is-active -q sg-rdp-lockd-$UID_LAB" 2>/dev/null; then
    pass "the session and its own lock service are running"
else fail "session units: $(ssh_guest "systemctl --no-pager status 'sg-rdp-*' 2>&1 | head -30")"; fi
t=0
until ssh_guest "pgrep -u $LAB_USER -f 'explorer.exe /desktop=shell,${W}x${H}' >/dev/null" 2>/dev/null; do
    (( t < 180 )) || break; sleep 3; t=$(( t + 3 ))
done
if ssh_guest "pgrep -u $LAB_USER -f 'explorer.exe /desktop=shell,${W}x${H}' >/dev/null" 2>/dev/null; then
    pass "the Windows desktop runs in it at the client's size (${W}x${H})"
else fail "no desktop: $(ssh_guest "pgrep -a -u $LAB_USER" 2>&1 | head)"; fi
sleep 15
shot session
# The taskbar: the bottom 40 rows are its colour across the width, and differ
# from the desktop above -- a blank or black client window has neither.
bar=$(convert "$ARTIFACTS/session.png" -crop "${W}x1+0+$((H - 20))" -depth 8 -format '%k' info: 2>/dev/null || echo 0)
top=$(convert "$ARTIFACTS/session.png" -crop "1x1+$((W / 2))+$((H / 2))" -depth 8 txt:- 2>/dev/null | sed -n 's/.*#\([0-9A-F]\{6\}\).*/\1/p' | head -1)
barpx=$(convert "$ARTIFACTS/session.png" -crop "1x1+$((W - 300))+$((H - 20))" -depth 8 txt:- 2>/dev/null | sed -n 's/.*#\([0-9A-F]\{6\}\).*/\1/p' | head -1)
if [[ -n "$barpx" && "$barpx" != "000000" && "$barpx" != "$top" ]]; then
    pass "the client shows the desktop and its taskbar (bar #$barpx, desktop #$top, $bar colours in the bar row)"
else fail "the client's window: bar #$barpx, desktop #$top"; fi

# --- Win+L, typed into the client --------------------------------------------
lock_status() {
    ssh_guest "SG_LOCK_CONTROL=/run/stained-glass-seat/rdp-$UID_LAB/$UID_LAB/control.sock /usr/libexec/stained-glass/sg-lockctl STATUS" \
        2>/dev/null | tr -d '\r'
}
WIN=$(DISPLAY=":$DPY_N" xdotool search --class freerdp 2>/dev/null | head -1 || true)
if [[ -n "$WIN" ]]; then DISPLAY=":$DPY_N" xdotool windowfocus "$WIN" 2>/dev/null || true; fi
DISPLAY=":$DPY_N" xdotool mousemove $((W / 2)) $((H / 3)) 2>/dev/null || true
for _ in 1 2 3; do
    DISPLAY=":$DPY_N" xdotool key super+l 2>/dev/null || true
    sleep 3
    [[ "$(lock_status)" == "OK locked" ]] && break
done
if [[ "$(lock_status)" == "OK locked" ]]; then pass "Win+L typed into the client locks the remote session"
else fail "not locked: $(lock_status)"; fi
t=0
until ssh_guest "grep -q 'locked: starting the lock screen' /var/log/stained-glass/lockd-rdp-$UID_LAB.log && pgrep -u sgsystem -f 'sg-greeter64.exe /lock' >/dev/null" 2>/dev/null; do
    (( t < 90 )) || break; sleep 3; t=$(( t + 3 ))
done
if ssh_guest "pgrep -u sgsystem -f 'sg-greeter64.exe /lock' >/dev/null" 2>/dev/null; then
    pass "the remote session's own lock screen comes up"
else fail "no lock screen: $(ssh_guest "tail -5 /var/log/stained-glass/lockd-rdp-$UID_LAB.log" 2>&1)"; fi
sleep 8
shot locked
for _ in 1 2 3; do
    DISPLAY=":$DPY_N" xdotool type --delay 80 "x" 2>/dev/null; DISPLAY=":$DPY_N" xdotool key BackSpace 2>/dev/null
    sleep 1
    DISPLAY=":$DPY_N" xdotool type --delay 80 "$(cat "$LAB_PASSWORD_FILE")" 2>/dev/null
    DISPLAY=":$DPY_N" xdotool key Return 2>/dev/null
    sleep 6
    [[ "$(lock_status)" == "OK unlocked" ]] && break
done
if [[ "$(lock_status)" == "OK unlocked" ]]; then pass "the password typed into the client unlocks it"
else fail "still locked: $(lock_status)"; fi

# --- disconnect, reconnect ----------------------------------------------------
kill "$CPID" 2>/dev/null || true; wait "$CPID" 2>/dev/null || true; CPID=""
wait_rdplog "SESSION detached" 30 || true
if ssh_guest "systemctl is-active -q sg-rdp-session-$UID_LAB" 2>/dev/null; then pass "disconnecting keeps the session"
else fail "the session ended with the connection"; fi
client "$(cat "$LAB_PASSWORD_FILE")"
if wait_rdplog "SESSION reconnect user=$LAB_USER" 60; then pass "logging in again reconnects to it"
else fail "no reconnect: $(rdplog | tail -4)"; fi
sleep 8
shot reconnected

rdplog > "$ARTIFACTS/rdp.log"
ssh_guest "journalctl -b --no-pager" > "$ARTIFACTS/journal.log" 2>/dev/null || true
if grep -q "$(cat "$LAB_PASSWORD_FILE")" "$ARTIFACTS/rdp.log"; then fail "the password appears in the RDP log"
else pass "no password in the RDP log"; fi

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL -- artifacts in $ARTIFACTS"; fi
exit $RC
