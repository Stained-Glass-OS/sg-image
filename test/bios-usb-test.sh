#!/usr/bin/env bash
# The ISO written to a USB stick boots a legacy BIOS the way real PCs see a
# stick -- not only as QEMU's virtio disk (bios-test) -- and stays bootable
# under UEFI.
#
#   "grub rescue" / emergency mode on a legacy-BIOS ThinkPad (user report
#   2026-11-25): many legacy BIOSes (Lenovo's among them) pass over a disk
#   whose MBR has no active partition and start the next disk -- the internal
#   one, with its own boot loader. The ISO's MBR held only the GPT's
#   protective entry, not active. And a BIOS booting a stick as USB-FDD shows
#   it to GRUB as a floppy, which GRUB's early config did not search
#   (--no-floppy): no prefix, "grub rescue>".
#
#   1. The stick's MBR: an active entry (0x80), the protective 0xEE entry
#      unchanged (UEFI reads the GPT behind it). (GRUB's embedded config,
#      which now searches floppies too, is compressed in its core image and
#      not checked here: QEMU cannot show a stick as a USB floppy.)
#   2. SeaBIOS boots the ISO as a USB stick (usb-storage), on a 16 GB stick
#      (the ISO at its start, the rest empty): the live system comes up, no
#      UEFI.
#   3. OVMF boots the same stick (UEFI, USB): the active MBR entry does not
#      hide the GPT and its system partition.
#
#   SG_LIVE_ISO=build/sg-live.iso test/bios-usb-test.sh
#   SG_BIOSUSB_MUTANT=NO_ACTIVE: the stick's active flag cleared (step 1
#   must fail).
# shellcheck disable=SC2015,SC2317  # pass || fail; cleanup via trap
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
ISO="${SG_LIVE_ISO:-$BUILD/sg-live.iso}"
SSH_KEY="${SG_SSH_KEY:-$BUILD/ssh/id_ed25519}"
SSH_PORT="${SG_SSH_PORT:-2295}"
W="${SG_BIOSUSB_WORK:-$BUILD/bios-usb-test}"
QEMU_PID=""
RC=0
PATH="$PATH:/usr/sbin:/sbin"
log()  { echo "[bios-usb-test] $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[[ -f "$ISO" ]] || { echo "no ISO at $ISO -- make iso"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- make image"; exit 2; }
[[ -r /dev/kvm ]] || { echo "SKIP: needs KVM"; exit 77; }
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu"; exit 77; }
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { OVMF_CODE=$c; break; }; done
[[ -n "$OVMF_CODE" ]] || { echo "SKIP: no OVMF"; exit 77; }
rm -rf "$W"; mkdir -p "$W"
cleanup() { set +e; [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; wait 2>/dev/null; rm -f "$W/stick.img"; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM
ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi

# the ISO dd'ed to a 16 GB stick
cp --reflink=auto "$ISO" "$W/stick.img" && truncate -s 16G "$W/stick.img" || { fail "cannot make the stick"; exit 1; }
if [[ "${SG_BIOSUSB_MUTANT:-}" == NO_ACTIVE ]]; then
    python3 - "$W/stick.img" <<'EOF'
import sys
with open(sys.argv[1], "r+b") as f:
    for i in range(4):
        f.seek(446 + 16 * i)
        f.write(b"\0")
EOF
    log "MUTANT: no active MBR entry"
fi

# --- 1. the MBR ---------------------------------------------
mbr=$(python3 - "$W/stick.img" <<'EOF'
import struct, sys
with open(sys.argv[1], "rb") as f:
    s = f.read(512)
out = []
for i in range(4):
    e = s[446 + 16 * i: 462 + 16 * i]
    out.append("%02x:%02x:%d" % (e[0], e[4], struct.unpack("<I", e[8:12])[0]))
print(" ".join(out), "%02x%02x" % (s[510], s[511]))
EOF
)
log "MBR entries (status:type:start): $mbr"
if [[ "$mbr" == *"80:"* && "$mbr" == *"00:ee:1 "* && "$mbr" == *"55aa" ]]; then
    pass "the MBR has an active entry, and the GPT's protective entry is intact"
else fail "the MBR has no active entry (or no protective entry): $mbr -- a legacy BIOS may pass the stick over"; fi

# --- 2./3. the stick under SeaBIOS, then under OVMF ------------------------------------------
boot() { # NAME FIRMWARE-ARGS...
    local name=$1; shift
    # shellcheck disable=SC2054  # commas inside QEMU arguments
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 4 "$@" -device qemu-xhci \
        -drive "if=none,id=stick,format=raw,file=$W/stick.img" -device usb-storage,drive=stick,bootindex=0 \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0 \
        -device VGA -display none -serial "file:$W/$name-serial.log" \
        -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$SSH_KEY.pub")" &
    QEMU_PID=$!
    local deadline=$(( SECONDS + 400 ))
    until ssh_guest true 2>/dev/null; do
        kill -0 "$QEMU_PID" 2>/dev/null && (( SECONDS < deadline )) || return 1
        sleep 4
    done
}
stop() {
    ssh_guest "systemctl poweroff" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
    kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""
}
log "the stick under SeaBIOS (usb-storage)"
if boot bios && ssh_guest "[ ! -d /sys/firmware/efi ] && grep -qw sg.live=iso /proc/cmdline"; then
    pass "SeaBIOS boots the ISO from a USB stick (16 GB): the live system, no UEFI"
else fail "the stick did not boot under SeaBIOS"; tail -5 "$W/bios-serial.log"; fi
stop
cp "${OVMF_CODE/CODE/VARS}" "$W/vars.fd"
log "the same stick under OVMF (UEFI)"
if boot uefi -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,unit=1,file=$W/vars.fd" \
        && ssh_guest "[ -d /sys/firmware/efi ] && grep -qw sg.live=iso /proc/cmdline"; then
    pass "OVMF boots the same stick (UEFI): the active MBR entry leaves the GPT and its system partition usable"
else fail "the stick did not boot under UEFI"; tail -5 "$W/uefi-serial.log"; fi
stop

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL"; fi
exit $RC
