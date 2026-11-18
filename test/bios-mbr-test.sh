#!/usr/bin/env bash
# Beside Windows on an MBR disk, on a legacy BIOS PC (SeaBIOS): Setup's
# installer goes into the unallocated space and leaves Windows as it was;
# GRUB starts Stained Glass OS and, from its menu, Windows.
#
#   The disk: an MBR partition table as Windows leaves it -- "System
#   Reserved" (100 MB NTFS, active; its boot sector, here, writes
#   SG-FAKE-WINDOWS-BOOT to the serial port instead of starting bootmgr), C:
#   (NTFS) -- Windows' MBR boot code, and unallocated space.
#   1. The ISO under SeaBIOS: sg-install --layout offers the disk ("mbr") and
#      its free space; sg-install --free installs there.
#   2. Windows' partitions, their table entries and the disk signature are
#      byte-identical; ours are an 0xEF boot partition and a Linux root (no
#      conversion to GPT); GRUB is in the MBR, and Windows' MBR code is kept
#      (sg-original-mbr.bin, 446 bytes) in our boot partition.
#   3. The installed disk alone: it starts from its own GRUB; the menu has
#      Windows, and waits 5 seconds.
#   4. Windows from the menu (grub-reboot's next_entry): GRUB chainloads its
#      boot partition's boot sector (the marker on the serial port); the next
#      start is Stained Glass OS again.
#   5. sg-grub-bios --restore-mbr puts Windows' MBR code back (code only).
#
#   SG_LIVE_ISO=build/sg-live.iso test/bios-mbr-test.sh
#   SG_MBR_MUTANT=NO_CHAIN: the Windows entry left out of grub.cfg (step 4
#   must fail).
# shellcheck disable=SC2015,SC2317  # pass || fail; cleanup via trap
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
ISO="${SG_LIVE_ISO:-$BUILD/sg-live.iso}"
SSH_KEY="$BUILD/ssh/id_ed25519"
SSH_PORT="${SG_SSH_PORT:-2229}"
W="$BUILD/bios-mbr-test"
ART="$BUILD/artifacts-bios-mbr"
QMP_SOCK="$W/qmp.sock"
QEMU_PID=""
PATH="$PATH:/usr/sbin:/sbin"
RC=0
log()  { echo "[bios-mbr-test] $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[[ -f "$ISO" ]] || { echo "no ISO at $ISO -- make iso"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- make image"; exit 2; }
[[ -r /dev/kvm ]] || { echo "SKIP: needs KVM"; exit 77; }
command -v mkntfs >/dev/null || { echo "SKIP: needs mkntfs (ntfs-3g)"; exit 77; }
for t in sfdisk mtype qemu-system-x86_64; do command -v "$t" >/dev/null || { echo "SKIP: needs $t"; exit 77; }; done
rm -rf "$W" "$ART"; mkdir -p "$W" "$ART"
cleanup() { set +e; [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; wait 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM

ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
reset_vm() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from qmp import QMP; q = QMP(sys.argv[2]); q.command("system_reset"); q.close()' "$HERE/test" "$QMP_SOCK"; }
if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi
start_vm() {   # NAME DRIVES...: SeaBIOS
    local name=$1; shift
    # shellcheck disable=SC2054  # commas inside QEMU arguments
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 4 "$@" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0 \
        -device virtio-vga -display none -serial "file:$ART/$name-serial.log" \
        -qmp "unix:$QMP_SOCK,server,nowait" \
        -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$SSH_KEY.pub")" &
    QEMU_PID=$!
}
wait_up() {
    local deadline=$(( SECONDS + $1 ))
    until ssh_guest true 2>/dev/null; do
        kill -0 "$QEMU_PID" 2>/dev/null || return 1
        (( SECONDS < deadline )) || return 1
        sleep 4
    done
}
stop_vm() {
    ssh_guest "systemctl poweroff" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
    kill "$QEMU_PID" 2>/dev/null || true; wait "$QEMU_PID" 2>/dev/null || true; QEMU_PID=""
}

# --- the disk Windows left ----------------------------------------------------------
T="$W/target.raw"
truncate -s 40G "$T"
P1=2048 N1=204800 P2=206848 N2=16777216          # System Reserved 100 MB, C: 8 GB
printf 'label: dos\nlabel-id: 0x5ca1ab1e\nstart=%s, size=%s, type=7, bootable\nstart=%s, size=%s, type=7\n' "$P1" "$N1" "$P2" "$N2" | sfdisk -q "$T"
truncate -s $((N1 * 512)) "$W/p1.img"; mkntfs -q -F -Q -L "System Reserved" -s 512 -p "$P1" -H 255 -S 63 "$W/p1.img" >/dev/null 2>&1 || { echo "mkntfs failed"; exit 2; }
truncate -s $((N2 * 512)) "$W/p2.img"; mkntfs -q -F -Q -L Windows -s 512 -p "$P2" -H 255 -S 63 "$W/p2.img" >/dev/null 2>&1 || { echo "mkntfs failed"; exit 2; }
# mkntfs seeds the volume serial (the file system UUID) from the clock: two
# made in the same second share it, which two Windows volumes never do -- C:
# gets its own (boot sector and its backup, the volume's last sector)
for off in $((0x48)) $(( (N2 - 1) * 512 + 0x48 )); do
    printf '\xef\xcd\xab\x89\x67\x45\x23\x01' | dd of="$W/p2.img" bs=1 seek="$off" conv=notrunc status=none
done
# System Reserved's boot sector: NTFS's own jump (EB 52 90) goes to 0x54;
# there, instead of bootmgr's loader, a few bytes that write the marker to
# COM1 and halt -- proof GRUB chainloaded Windows' boot partition
printf '\xfa\x31\xc0\x8e\xd8\xbe\x6a\x7c\xba\xf8\x03\xac\x84\xc0\x74\x03\xee\xeb\xf8\xf4\xeb\xfdSG-FAKE-WINDOWS-BOOT\r\n\x00' \
    | dd of="$W/p1.img" bs=1 seek=$((0x54)) conv=notrunc status=none
dd if="$W/p1.img" of="$T" bs=512 seek="$P1" conv=notrunc,sparse status=none
dd if="$W/p2.img" of="$T" bs=1M oflag=seek_bytes seek=$((P2 * 512)) conv=notrunc,sparse status=none
# Windows' MBR boot code: a recognisable pattern (never run here)
head -c 440 /dev/urandom > "$W/winmbr.bin"
dd if="$W/winmbr.bin" of="$T" bs=440 count=1 conv=notrunc status=none
rm -f "$W/p1.img" "$W/p2.img"
part_sum() { dd if="$T" bs=512 skip="$1" count="$2" status=none | sha256sum | cut -d' ' -f1; }
S1=$(part_sum "$P1" "$N1"); S2=$(part_sum "$P2" "$N2")
ENTRIES=$(sfdisk -d "$T" | grep -E 'target.raw[12] :')
SIG=$(dd if="$T" bs=1 skip=440 count=6 status=none | od -An -tx1 | tr -d ' \n')
MBR446=$(dd if="$T" bs=446 count=1 status=none | sha256sum | cut -d' ' -f1)
WIN_UUID=$(blkid -p -o value -s UUID -O $((P1 * 512)) "$T" 2>/dev/null || true)
log "Windows' disk: MBR, System Reserved (active, NTFS $WIN_UUID), C: (NTFS), 31 GB unallocated"

# --- 1. the ISO under SeaBIOS, the installer --------------------------------------------
cp --reflink=auto "$ISO" "$W/stick.img"
start_vm live -drive "if=virtio,format=raw,file=$W/stick.img" -drive "if=virtio,format=raw,file=$T"
wait_up 300 && pass "the ISO boots the live system under SeaBIOS" || { fail "no live system"; tail -20 "$ART/live-serial.log"; exit 1; }
ssh_guest "sg-install --layout" > "$ART/layout.txt" 2>&1
grep -qP '^DISK /dev/vdb\t.*\tmbr$' "$ART/layout.txt" && pass "--layout: the MBR disk with Windows is offered (\"mbr\")" || fail "layout: $(head -5 "$ART/layout.txt")"
free=$(awk -F'\t' '$1 == "FREE /dev/vdb" { print $2 ":" $3; exit }' "$ART/layout.txt")
[[ -n "$free" ]] && pass "...with its unallocated space ($free)" || { fail "no FREE row for vdb"; exit 1; }
# no other way onto it: Windows' partitions are not install targets
ssh_guest "echo x | sg-install --target /dev/vdb2 --user bob --password-stdin --yes" >/dev/null 2>&1 \
    && fail "it installed over a Windows partition" || pass "Windows' partitions are never install targets on it"
pw=$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_lowercase) for _ in range(12)))')
if printf '%s\n' "$pw" | ssh_guest "sg-install --free /dev/vdb:$free --user alice --password-stdin --hostname sg-mbr --yes" > "$ART/install.log" 2>&1; then
    pass "sg-install installed into the unallocated space beside Windows"
else fail "sg-install: $(tail -5 "$ART/install.log")"; exit 1; fi
if [[ "${SG_MBR_MUTANT:-}" == NO_CHAIN ]]; then
    log "MUTANT: no Windows entry"
    ssh_guest "m=\$(mktemp -d); mount /dev/vdb3 \$m && rm -f \$m/grub/sg-chain && sed -i '/menuentry .Windows./,/^}/d' \$m/grub/grub.cfg; umount \$m"
fi
stop_vm

# --- 2. Windows as it was ---------------------------------------------------------------
sfdisk -d "$T" > "$ART/table-after.txt"
grep -q '^label: dos' "$ART/table-after.txt" && pass "still an MBR partition table (never converted)" || fail "table: $(head -3 "$ART/table-after.txt")"
[[ "$(sfdisk -d "$T" | grep -E 'target.raw[12] :')" == "$ENTRIES" ]] && pass "Windows' table entries unchanged (System Reserved still the active one)" || fail "Windows' entries changed"
[[ "$(dd if="$T" bs=1 skip=440 count=6 status=none | od -An -tx1 | tr -d ' \n')" == "$SIG" ]] && pass "the disk signature unchanged" || fail "disk signature changed"
[[ "$(part_sum "$P1" "$N1")" == "$S1" && "$(part_sum "$P2" "$N2")" == "$S2" ]] && pass "System Reserved and C: byte-identical" || fail "a Windows partition changed"
grep -q 'target.raw3 : .*type=ef' "$ART/table-after.txt" && grep -q 'target.raw4 : .*type=83' "$ART/table-after.txt" \
    && pass "ours: an 0xEF boot partition (no drive letter in Windows) and a Linux root, primary" || fail "our partitions: $(cat "$ART/table-after.txt")"
dd if="$T" bs=512 count=1 status=none | grep -aq GRUB && pass "GRUB is in the MBR" || fail "no GRUB in the MBR"
b3=$(awk -F'[ ,=]+' '/target.raw3 :/ { for (i = 1; i <= NF; i++) if ($i == "start") print $(i + 1) }' "$ART/table-after.txt")
MTOOLS_SKIP_CHECK=1 mtype -i "$T@@$((b3 * 512))" ::/sg-original-mbr.bin > "$W/saved.bin" 2>/dev/null
[[ "$(wc -c < "$W/saved.bin")" == 446 && "$(sha256sum < "$W/saved.bin" | cut -d' ' -f1)" == "$MBR446" ]] \
    && pass "Windows' MBR code and signature kept in our boot partition (sg-original-mbr.bin)" || fail "sg-original-mbr.bin ($(wc -c < "$W/saved.bin") bytes)"

# --- 3. the installed disk alone --------------------------------------------------------
start_vm installed -drive "if=virtio,format=raw,file=$T"
wait_up 300 && pass "it starts from its own GRUB under SeaBIOS" || { fail "the installed disk did not come up"; tail -30 "$ART/installed-serial.log"; exit 1; }
ssh_guest "[ ! -d /sys/firmware/efi ] && [ \"\$(hostname)\" = sg-mbr ] && ls /efi >/dev/null && [ \"\$(findmnt -n -o SOURCE /efi | grep '^/dev/' | tail -1)\" = /dev/vda3 ]" \
    && pass "the root, and /efi is our boot partition" || fail "installed: $(ssh_guest 'findmnt /efi; hostname' 2>&1 | tr '\n' ' ')"
cfg=$(ssh_guest "cat /efi/grub/grub.cfg")
grep -q "menuentry 'Windows'" <<<"$cfg" && grep -qi "search --no-floppy --fs-uuid --set=root --hint=hd0,msdos1 $WIN_UUID" <<<"$cfg" \
    && pass "GRUB's menu has Windows (System Reserved, by its UUID, its partition on this disk first)" || fail "no Windows entry (uuid $WIN_UUID): $(grep -A6 Windows <<<"$cfg")"
grep -q 'set timeout=5' <<<"$cfg" && pass "...and waits 5 seconds, as with Windows on the disk" || fail "timeout: $(grep timeout <<<"$cfg")"

# --- 4. Windows from the menu -----------------------------------------------------------------
ssh_guest "grub-editenv /efi/grub/grubenv set next_entry=windows; sync"
ssh_guest "systemctl reboot" >/dev/null 2>&1 || true
ok=0
for _ in $(seq 1 45); do grep -aq 'SG-FAKE-WINDOWS-BOOT' "$ART/installed-serial.log" && { ok=1; break; }; sleep 2; done
[[ $ok == 1 ]] && pass "Windows from GRUB's menu: its boot partition's boot sector starts" || fail "Windows' boot sector never ran"
reset_vm || fail "reset"
wait_up 300 && pass "the next start is Stained Glass OS again (next_entry once)" || fail "no start after Windows"

# --- 5. Windows' MBR code back ----------------------------------------------------------------
ssh_guest "sg-grub-bios --restore-mbr --disk /dev/vda" > "$ART/restore.log" 2>&1 && pass "sg-grub-bios --restore-mbr" || fail "restore-mbr: $(cat "$ART/restore.log")"
stop_vm
cmp -s <(head -c 440 "$T") "$W/winmbr.bin" && [[ "$(dd if="$T" bs=1 skip=440 count=6 status=none | od -An -tx1 | tr -d ' \n')" == "$SIG" ]] \
    && pass "...Windows' MBR code is back; signature and table as they are" || fail "the MBR after restore"

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL"; fi
exit $RC
