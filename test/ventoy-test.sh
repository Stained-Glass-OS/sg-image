#!/bin/bash
# The ISO from a multiboot stick (Ventoy): Ventoy starts the ISO's own kernel
# and initrds, then the running system sees no ISO device at all -- only the
# stick, with the .iso as a file on its exFAT partition. The live initrd
# (iso/sg-live-iso) must find that file, pass by another release's ISO on the
# same stick, and boot the live system from it.
#
# Here: the kernel, initrds and options of the ISO's live entry, booted
# directly (-kernel), with one disk: exFAT, holding ventoy/sg-live.iso and a
# decoy Stained Glass ISO from another build. Passes when the initrd picks the
# real file and the live system comes up.
#
#   ISO=build/sg-live.iso test/ventoy-test.sh
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
ISO=${ISO:-build/sg-live.iso}
[[ -f "$ISO" ]] || { echo "ventoy-test: no $ISO (make iso)" >&2; exit 1; }
ISO=$(realpath "$ISO")
OUT=$(realpath build)/artifacts-ventoy
mkdir -p "$OUT"
W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-ventoy.XXXXXX")
QPID=""
cleanup() {
    [[ -n "$QPID" ]] && kill "$QPID" 2>/dev/null
    mountpoint -q "$W/mnt" 2>/dev/null && sudo umount "$W/mnt"
    rm -rf "$W"
}
trap cleanup EXIT
log() { echo "[ventoy-test] $*"; }
export MTOOLS_SKIP_CHECK=1

# --- what Ventoy boots: the live entry of the ISO's boot loader ----------------
xorriso -osirrox on -indev "$ISO" -extract /boot/efi.img "$W/efi.img" >/dev/null 2>&1
entry=$(mdir -b -i "$W/efi.img" ::/loader/entries/ | grep -- '-live\.conf$' | head -1)
mtype -i "$W/efi.img" "$entry" > "$W/entry"
linux=$(awk '$1 == "linux" { print $2 }' "$W/entry")
options=$(sed -n 's/^options //p' "$W/entry")
mcopy -i "$W/efi.img" "::$linux" "$W/vmlinuz"
: > "$W/initrd"
for i in $(awk '$1 == "initrd" { print $2 }' "$W/entry"); do
    mcopy -i "$W/efi.img" "::$i" "$W/part"; cat "$W/part" >> "$W/initrd"
    # as a boot loader loads several: each starts on a 4-byte boundary
    pad=$(( (4 - $(stat -c %s "$W/initrd") % 4) % 4 ))
    head -c "$pad" /dev/zero >> "$W/initrd"
done

# --- the stick: exFAT, the ISO and another release's -------------------------
mkdir -p "$W/decoy/live" "$W/mnt"
echo "another-build" > "$W/decoy/live/build-id"
head -c 110M /dev/zero > "$W/decoy/live/root.erofs"
xorriso -as mkisofs -quiet -volid SGLIVE -o "$W/decoy.iso" "$W/decoy" 2>/dev/null
truncate -s $(( $(stat -c %s "$ISO") + 512 * 1024 * 1024 )) "$W/stick.img"
mkfs.exfat -L Ventoy "$W/stick.img" >/dev/null
sudo mount -o loop,uid="$(id -u)" "$W/stick.img" "$W/mnt"
mkdir -p "$W/mnt/ventoy/old"
cp "$W/decoy.iso" "$W/mnt/ventoy/old/sg-live-old.iso"
cp "$ISO" "$W/mnt/ventoy/sg-live.iso"
sudo umount "$W/mnt"
rm -f "$W/decoy.iso" "$W/efi.img" "$W/part"

# --- boot ---------------------------------------------------------------------
accel=tcg; [[ -w /dev/kvm ]] && accel=kvm
log "booting the live entry with only the stick attached (accel=$accel)"
qemu-system-x86_64 -machine q35,accel=$accel -m 4096 -smp 4 -nographic -nic none \
    -kernel "$W/vmlinuz" -initrd "$W/initrd" \
    -append "$options systemd.show_status=yes loglevel=6" \
    -drive file="$W/stick.img",format=raw,if=virtio \
    -serial file:"$OUT/serial.log" -monitor none -display none >/dev/null 2>&1 &
QPID=$!
rc=1
for _ in $(seq 1 180); do
    sleep 2
    # The live system's own setup (sg-live.service, in the root file system
    # the initrd attached) makes its "live" account: the ISO file is the
    # root. Reaching the login screen is boot-test's and iso-test's job.
    if grep -q 'acct="live"' "$OUT/serial.log" 2>/dev/null; then rc=0; break; fi
    if grep -q "Reached target emergency.target\|You are in emergency mode" "$OUT/serial.log" 2>/dev/null; then break; fi
    kill -0 "$QPID" 2>/dev/null || break
done
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null || :; QPID=""

s=$(sed 's/\x1b\[[0-9;]*m//g' "$OUT/serial.log")
fail=0
if grep -q "sg-live-iso: found /ventoy/sg-live.iso on /dev/vda" <<<"$s"; then log "PASS  the initrd found the .iso file on the stick's exFAT partition"
else log "FAIL  the .iso file was not found: $(grep 'sg-live-iso' <<<"$s" | tr '\n' ';')"; fail=1; fi
if grep -q "sg-live-iso: found /ventoy/old" <<<"$s"; then log "FAIL  it booted another release's ISO"; fail=1
else log "PASS  another release's ISO on the stick was passed by"; fi
if [[ $rc = 0 ]]; then log "PASS  the live system runs from it (its live account was made)"
else log "FAIL  the live system did not come up (serial log: $OUT/serial.log)"; fail=1; fi
[[ $fail = 0 ]] && log "RESULT: PASS" || log "RESULT: FAIL"
exit $fail
