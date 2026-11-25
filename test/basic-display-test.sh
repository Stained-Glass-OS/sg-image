#!/usr/bin/env bash
# No GPU driver, and still a screen: the live ISO's Setup screen draws on the
# Basic Display Adapter (sg-compositor's software rendering on the firmware
# framebuffer, through sg-basic-displayd), and Ctrl+Alt+F2 reaches a text
# console from it -- as Windows always reaches its screens on the Basic
# Display Adapter. Before: a black screen after the boot logo (user report
# 2026-11-25), and no console either.
#
#   QEMU with OVMF, -vga none -device ramfb: the firmware's framebuffer (efifb)
#   and no DRM driver for it -- a PC whose GPU has no working driver
#   (nomodeset, NVIDIA without its driver or firmware, a GPU newer than the
#   kernel). The ISO is booted unmodified, as a CD.
#   1. The live system comes up (ssh), with no /dev/dri.
#   2. The screen is not black: Setup draws (many colours in a screendump),
#      and the compositor says it draws on the basic display.
#   3. Ctrl+Alt+F2: tty2 is shown, a text console (a login prompt); then
#      Ctrl+Alt+F1: Setup is drawn again, whole.
#   4. No display even in software (sg-basic-displayd masked): the login
#      screen fails at each start, and tty1 shows sg-boot-report's screen --
#      what failed, how to reach a console, S to save a boot report; S saves
#      it on a USB stick (FAT) and says where.
#
#   SG_LIVE_ISO=build/sg-live.iso test/basic-display-test.sh
#   SG_BASIC_DEBS=DIR: install DIR/*.deb into the live system first and start
#   the login screen again (packages not yet in an ISO).
#   SG_BASIC_MUTANT=NO_DAEMON: sg-basic-display.socket masked, the login
#   screen started again: step 2 must fail.
#   SG_BASIC_MUTANT=NO_REPORT: sg-boot-report.service masked: step 4 must fail.
# shellcheck disable=SC2015,SC2317  # pass || fail; cleanup via trap
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
ISO="${SG_LIVE_ISO:-$BUILD/sg-live.iso}"
SSH_KEY="${SG_SSH_KEY:-$BUILD/ssh/id_ed25519}"
SSH_PORT="${SG_SSH_PORT:-2293}"
W="${SG_BASIC_WORK:-$BUILD/basic-display-test}"
QMP_SOCK="$W/qmp.sock"
QEMU_PID=""
RC=0
PATH="$PATH:/usr/sbin:/sbin"
log()  { echo "[basic-display-test] $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[[ -f "$ISO" ]] || { echo "no ISO at $ISO -- make iso"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- make image"; exit 2; }
[[ -r /dev/kvm ]] || { echo "SKIP: needs KVM"; exit 77; }
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu"; exit 77; }
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: needs python3-pil"; exit 77; }
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { OVMF_CODE=$c; break; }; done
[[ -n "$OVMF_CODE" ]] || { echo "SKIP: no OVMF"; exit 77; }
rm -rf "$W"; mkdir -p "$W"
cleanup() { set +e; [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; wait 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM

ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
qmp() { python3 "$HERE/test/qmp.py" "$QMP_SOCK" "$@" >/dev/null 2>&1; }
# colours NAME: the number of distinct colours on the screen now (screendump)
colours() {
    qmp screendump "$W/$1.ppm" || { echo 0; return; }
    python3 -c 'import sys; from PIL import Image
im = Image.open(sys.argv[1]); im.save(sys.argv[2]); c = im.getcolors(1 << 22); print(len(c) if c else 1 << 22)' \
        "$W/$1.ppm" "$W/$1.png" 2>/dev/null || echo 0
}
active_vt() { ssh_guest "cat /sys/class/tty/tty0/active" 2>/dev/null; }
if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi

cp "${OVMF_CODE/CODE/VARS}" "$W/vars.fd"
# a USB stick (FAT) for the boot report
truncate -s 64M "$W/stick.img" && mkfs.vfat -n SGREPORT "$W/stick.img" >/dev/null || { echo "SKIP: needs mkfs.vfat"; exit 77; }
log "booting the ISO with a firmware framebuffer and no GPU driver (OVMF, ramfb)"
# shellcheck disable=SC2054  # commas inside QEMU arguments
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$W/vars.fd" \
    -vga none -device ramfb \
    -drive "if=none,id=cd,format=raw,readonly=on,file=$ISO" -device ide-cd,drive=cd,bus=ide.0 \
    -device qemu-xhci -drive "if=none,id=stick,format=raw,file=$W/stick.img" -device usb-storage,drive=stick \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0 \
    -display none -serial "file:$W/serial.log" -qmp "unix:$QMP_SOCK,server,nowait" \
    -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$SSH_KEY.pub")" &
QEMU_PID=$!

# --- 1. the live system ---------------------------------------------------------
deadline=$(( SECONDS + 400 ))
until ssh_guest true 2>/dev/null; do
    kill -0 "$QEMU_PID" 2>/dev/null && (( SECONDS < deadline )) || { fail "the live system did not come up"; tail -20 "$W/serial.log"; exit 1; }
    sleep 4
done
pass "the live system is up"
ssh_guest "[ ! -e /dev/dri ] && [ -e /dev/fb0 ]" && pass "a firmware framebuffer and no DRM device (no GPU driver)" \
    || fail "the VM has a DRM device or no framebuffer: $(ssh_guest 'ls /dev/dri; cat /proc/fb' 2>&1 | tr '\n' ' ')"

restart_login=0
if [[ -n "${SG_BASIC_DEBS:-}" ]]; then
    ssh_guest "mkdir -p /root/debs" && scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -P "$SSH_PORT" "$SG_BASIC_DEBS"/*.deb root@127.0.0.1:/root/debs/ \
        && ssh_guest "dpkg -i --force-depends /root/debs/*.deb && systemctl daemon-reload && { ! systemctl is-enabled -q sg-boot-report.service || systemctl start sg-boot-report.service; }" > "$W/debs.log" 2>&1 \
        && log "installed $(cd "$SG_BASIC_DEBS" && echo ./*.deb)" || { fail "installing $SG_BASIC_DEBS: $(tail -3 "$W/debs.log")"; exit 1; }
    restart_login=1
fi
if [[ "${SG_BASIC_MUTANT:-}" == NO_DAEMON ]]; then
    ssh_guest "systemctl mask --now sg-basic-display.socket sg-basic-display.service" && log "MUTANT: no sg-basic-displayd"
    restart_login=1
fi
if (( restart_login )); then
    ssh_guest "systemctl restart greetd"
fi

# --- 2. the screen draws ------------------------------------------------------------
n=0
for _ in $(seq 1 45); do
    n=$(colours setup)
    (( n > 300 )) && break
    sleep 4
done
if (( n > 300 )); then pass "the screen draws with no GPU driver ($n colours)"
else fail "the screen stays black or blank ($n colours) -- see $W/setup.png"; fi
ssh_guest "journalctl -b --no-pager | grep -q -e 'trying the Basic Display Adapter' -e 'the Basic Display Adapter at once' && journalctl -b -u sg-basic-display --no-pager | grep -q 'draws'" \
    && pass "the compositor draws in software on the firmware framebuffer (Basic Display Adapter)" \
    || fail "no basic display in the journal: $(ssh_guest 'journalctl -b -t sg-setup --no-pager | tail -4' 2>&1)"

# --- 3. a text console and back -------------------------------------------------------
qmp key ctrl+alt+f2; sleep 3
vt=$(active_vt); n2=$(colours console)
if [[ "$vt" == tty2 ]] && (( n2 >= 2 && n2 < 16 )); then pass "Ctrl+Alt+F2 shows a text console (tty2)"
else fail "Ctrl+Alt+F2: active $vt, $n2 colours -- see $W/console.png"; fi
qmp key ctrl+alt+f1; sleep 4
vt=$(active_vt); n3=$(colours back)
if [[ "$vt" == tty1 ]] && (( n3 > 300 )); then pass "Ctrl+Alt+F1 comes back to the graphical screen, drawn whole ($n3 colours)"
else fail "Ctrl+Alt+F1: active $vt, $n3 colours -- see $W/back.png"; fi

# --- 4. no display at all: the boot report screen ------------------------------------------
# The compositor cannot draw even in software (sg-basic-displayd masked): the
# login screen fails at each start, and sg-boot-report shows what failed on
# tty1, with a one-key save to the USB stick.
if [[ "${SG_BASIC_MUTANT:-}" == NO_REPORT ]]; then
    ssh_guest "systemctl mask --now sg-boot-report.service" && log "MUTANT: no sg-boot-report"
fi
ssh_guest "systemctl mask --now sg-basic-display.socket sg-basic-display.service; systemctl restart greetd"
shown=""
for _ in $(seq 1 40); do
    ssh_guest "[ \"\$(cat /sys/class/tty/tty0/active)\" = tty1 ] && tr -s ' ' < /dev/vcs1 | grep -q 'could not start its graphical login screen'" 2>/dev/null && { shown=1; break; }
    sleep 4
done
colours report >/dev/null
if [[ -n "$shown" ]] && ssh_guest "tr -s ' ' < /dev/vcs1 | grep -q 'Ctrl+Alt+F2' && tr -s ' ' < /dev/vcs1 | grep -q 'save a boot report'"; then
    pass "the login screen cannot start: tty1 says what failed, how to reach a console, and offers the report"
else fail "no boot report screen on tty1 -- see $W/report.png"; fi
qmp key s
saved=""
for _ in $(seq 1 30); do
    ssh_guest "tr -s ' ' < /dev/vcs1 | grep -q 'Saved:'" 2>/dev/null && { saved=1; break; }
    sleep 2
done
colours saved >/dev/null
ssh_guest "sync; systemctl poweroff" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""
report=$(MTOOLS_SKIP_CHECK=1 mdir -b -i "$W/stick.img" ::/ 2>/dev/null | grep -m1 'sg-boot-report-.*\.tar\.gz')
files=""
[[ -n "$report" ]] && MTOOLS_SKIP_CHECK=1 mcopy -n -i "$W/stick.img" "$report" "$W/report.tar.gz" && files=$(tar -tzf "$W/report.tar.gz" | tr '\n' ' ')
if [[ -n "$saved" && "$files" == *journal.txt* && "$files" == *lspci.txt* && "$files" == *dmesg.txt* && "$files" == *compositor.txt* ]]; then
    pass "S saves the boot report on the USB stick, and the screen says where"
else fail "the report was not saved (screen: $saved; on the stick: $files) -- see $W/saved.png"; fi
echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL"; fi
exit $RC
