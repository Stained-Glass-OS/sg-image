#!/usr/bin/env bash
# The live boot that cannot find its medium says so on the screen and can
# save a report -- it ended in "emergency mode" with nothing on the screen
# to go on (user report 2026-11-25).
#
#   QEMU boots the ISO's own kernel and initrds (from its boot/efi.img, the
#   live entry's command line) with NO medium attached, and a USB stick (FAT)
#   plugged in; sg.live.timeout=20 shortens the search.
#   1. sg-live-iso gives up: the screen shows its text (the boot logo is
#      gone), it waits for S.
#   2. S: the report is on the stick -- what was looked for (label SGLIVE,
#      this build's id), the drives found, the kernel's storage messages.
#
#   SG_LIVE_ISO=build/sg-live.iso test/live-medium-test.sh
#   SG_LIVEMED_MUTANT=NO_SCREEN: sg-live-iso without its failure screen
#   (the initrd rebuilt from the ISO's, the call removed): must FAIL.
# shellcheck disable=SC2015,SC2317  # pass || fail; cleanup via trap
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
ISO="${SG_LIVE_ISO:-$BUILD/sg-live.iso}"
W="${SG_LIVEMED_WORK:-$BUILD/live-medium-test}"
QMP_SOCK="$W/qmp.sock"
QEMU_PID=""
RC=0
PATH="$PATH:/usr/sbin:/sbin"
export MTOOLS_SKIP_CHECK=1
log()  { echo "[live-medium-test] $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[[ -f "$ISO" ]] || { echo "no ISO at $ISO -- make iso"; exit 2; }
[[ -r /dev/kvm ]] || { echo "SKIP: needs KVM"; exit 77; }
for t in qemu-system-x86_64 xorriso mcopy mkfs.vfat cpio; do command -v "$t" >/dev/null || { echo "SKIP: needs $t"; exit 77; }; done
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: needs python3-pil"; exit 77; }
rm -rf "$W"; mkdir -p "$W"
cleanup() { set +e; [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; wait 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM
qmp() { python3 "$HERE/test/qmp.py" "$QMP_SOCK" "$@" >/dev/null 2>&1; }
colours() {
    qmp screendump "$W/$1.ppm" || { echo 0; return; }
    python3 -c 'import sys; from PIL import Image
im = Image.open(sys.argv[1]); im.save(sys.argv[2]); c = im.getcolors(1 << 22); print(len(c) if c else 1 << 22)' \
        "$W/$1.ppm" "$W/$1.png" 2>/dev/null || echo 0
}

# --- the ISO's kernel, initrds and live command line --------------------------------
xorriso -indev "$ISO" -osirrox on -extract /boot/efi.img "$W/efi.img" >/dev/null 2>&1 || { fail "no boot/efi.img in $ISO"; exit 1; }
entry=$(mdir -b -i "$W/efi.img" ::/loader/entries/ 2>/dev/null | grep -- '-live.conf$' | head -1)
[[ -n "$entry" ]] || { fail "no live entry in the ISO's system partition"; exit 1; }
mtype -i "$W/efi.img" "$entry" > "$W/entry.conf"
kernel=$(sed -n 's/^linux[[:space:]]*//p' "$W/entry.conf")
options=$(sed -n 's/^options[[:space:]]*//p' "$W/entry.conf")
mcopy -n -i "$W/efi.img" "::$kernel" "$W/vmlinuz"
: > "$W/initrd"
while read -r rd; do
    mtype -i "$W/efi.img" "::$rd" > "$W/part"
    if [[ "${SG_LIVEMED_MUTANT:-}" == NO_SCREEN && "$rd" == */sg-live.initrd ]]; then
        mkdir "$W/mut" && (cd "$W/mut" && cpio -id --quiet < "$W/part")
        sed -i '/failed "its live medium was not found."/d' "$W/mut/usr/libexec/sg-live-iso"
        (cd "$W/mut" && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc --quiet --owner=0:0) > "$W/part"
        log "MUTANT: sg-live-iso without its failure screen"
    fi
    cat "$W/part" >> "$W/initrd"
    # each archive padded to 512 bytes: the kernel skips the zeros between them
    head -c $(( (512 - $(stat -c %s "$W/part") % 512) % 512 )) /dev/zero >> "$W/initrd"
done < <(sed -n 's/^initrd[[:space:]]*//p' "$W/entry.conf")
rm -f "$W/part" "$W/efi.img"
truncate -s 64M "$W/stick.img" && mkfs.vfat -n SGREPORT "$W/stick.img" >/dev/null

log "booting the live kernel with no medium attached (and a FAT stick)"
# shellcheck disable=SC2054  # commas inside QEMU arguments
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 2048 -smp 2 \
    -kernel "$W/vmlinuz" -initrd "$W/initrd" -append "$options sg.live.timeout=20" \
    -device qemu-xhci -drive "if=none,id=stick,format=raw,file=$W/stick.img" -device usb-storage,drive=stick \
    -device VGA -display none -serial "file:$W/serial.log" -qmp "unix:$QMP_SOCK,server,nowait" -nic none &
QEMU_PID=$!

# --- 1. the failure screen -------------------------------------------------------------
shown=""
for _ in $(seq 1 50); do
    sleep 3
    grep -aq 'sg-live-iso: cannot start' "$W/serial.log" 2>/dev/null || continue
    sleep 3
    n=$(colours failed)
    (( n >= 2 && n <= 8 )) && { shown=1; break; }
done
if [[ -n "$shown" ]]; then pass "the medium is not found: the screen shows text (the boot logo is gone), not a silent wait"
else fail "no failure screen (serial: $(grep -a 'sg-live-iso' "$W/serial.log" | tail -2)) -- see $W/failed.png"; fi

# --- 2. S saves the report -----------------------------------------------------------------
qmp key s
sleep 15
kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""
report=$(mdir -b -i "$W/stick.img" ::/ 2>/dev/null | grep -m1 'sg-boot-report-initrd-.*\.txt')
if [[ -n "$report" ]] && mtype -i "$W/stick.img" "$report" > "$W/report.txt" \
        && grep -q 'looked for: an ISO 9660 file system labelled SGLIVE with live/build-id [0-9a-f-]\{36\}' "$W/report.txt" \
        && grep -q '== block devices' "$W/report.txt" && grep -q '== dmesg' "$W/report.txt"; then
    pass "S saves the report on the USB stick: what was looked for (this build), the drives, the kernel log"
else fail "no report on the stick ($report)"; fi

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL"; fi
exit $RC
