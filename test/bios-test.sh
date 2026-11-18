#!/usr/bin/env bash
# Legacy BIOS (SeaBIOS, no UEFI): the ISO boots, Setup installs a system a
# BIOS can start, and its kernel updates keep starting -- with boot counting:
# a new kernel that cannot come up gives way to the previous one by itself.
#
#   1. The ISO as a USB stick, under SeaBIOS: the live system comes up (no
#      /sys/firmware/efi); sg-install installs onto a blank disk: GPT, a BIOS
#      boot partition, the system partition with GRUB in it.
#   2. The installed disk alone, under SeaBIOS: it starts from its own GRUB,
#      root, kernels and boot-complete as on UEFI.
#   3. A kernel update (kernel-install add, as Debian's kernel packages run
#      it): GRUB's menu follows; the new kernel is on trial, starts, and is
#      marked good.
#   4. A new kernel GRUB cannot load: the start comes back on the previous
#      kernel, no keypress (its tries used up at once), and it is marked bad.
#   5. A new kernel that starts but never comes up (its initrd broken): each
#      start takes a try off; after three, GRUB starts the previous kernel by
#      itself (the VM is reset when a start hangs, as a person or a watchdog
#      would), and the new one is marked bad.
#
#   SG_LIVE_ISO=build/sg-live.iso test/bios-test.sh
#   SG_BIOS_MUTANT=NO_COUNT: the installed machine's grub.cfg without the
#   counting (step 5 must fail).
# shellcheck disable=SC2015,SC2317  # pass || fail; cleanup via trap
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
ISO="${SG_LIVE_ISO:-$BUILD/sg-live.iso}"
SSH_KEY="$BUILD/ssh/id_ed25519"
SSH_PORT="${SG_SSH_PORT:-2227}"
W="$BUILD/bios-test"
ART="$BUILD/artifacts-bios"
QMP_SOCK="$W/qmp.sock"
QEMU_PID=""
PATH="$PATH:/usr/sbin:/sbin"
RC=0
log()  { echo "[bios-test] $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[[ -f "$ISO" ]] || { echo "no ISO at $ISO -- make iso"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- make image"; exit 2; }
[[ -r /dev/kvm ]] || { echo "SKIP: needs KVM"; exit 77; }
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu"; exit 77; }
rm -rf "$W" "$ART"; mkdir -p "$W" "$ART"
cleanup() { set +e; [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; wait 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM

ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
qmp() { python3 "$HERE/test/qmp.py" "$QMP_SOCK" "$@" >/dev/null 2>&1; }
# a hard reset (the reset button; test/qmp.py has no such action)
reset_vm() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from qmp import QMP; q = QMP(sys.argv[2]); q.command("system_reset"); q.close()' "$HERE/test" "$QMP_SOCK"; }
if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi

# start_vm NAME DRIVES...: SeaBIOS (QEMU's default firmware: no -bios, no pflash)
start_vm() {
    local name=$1; shift
    # shellcheck disable=SC2054  # commas inside QEMU arguments
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 4 "$@" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0 \
        -device virtio-vga -display none -serial "file:$ART/$name-serial.log" \
        -qmp "unix:$QMP_SOCK,server,nowait" \
        -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$SSH_KEY.pub")" &
    QEMU_PID=$!
}
# wait_up SECONDS: until ssh answers (0) or not (1)
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
# reboot_to SECONDS: reboot from inside, wait for the next start to answer
reboot_to() {
    ssh_guest "systemctl reboot" >/dev/null 2>&1 || true
    sleep 15
    wait_up "$1"
}

# --- 1. the ISO under SeaBIOS, and Setup's installer --------------------------
cp --reflink=auto "$ISO" "$W/stick.img"
truncate -s 24G "$W/target.raw"
log "booting the ISO as a USB stick under SeaBIOS"
start_vm live -drive "if=virtio,format=raw,file=$W/stick.img" -drive "if=virtio,format=raw,file=$W/target.raw"
if wait_up 300; then pass "the ISO boots the live system under a legacy BIOS (SeaBIOS)"
else fail "the live system did not come up under SeaBIOS"; tail -20 "$ART/live-serial.log"; exit 1; fi
ssh_guest "[ ! -d /sys/firmware/efi ] && grep -qw sg.live=iso /proc/cmdline" \
    && pass "it runs without UEFI, from the ISO" || fail "not a BIOS live boot"
pw=$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_lowercase) for _ in range(12)))')
if printf '%s\n' "$pw" | ssh_guest "sg-install --disk /dev/vdb --user alice --password-stdin --hostname sg-bios --yes" > "$ART/install.log" 2>&1; then
    pass "sg-install installed onto the blank disk"
else fail "sg-install: $(tail -5 "$ART/install.log")"; exit 1; fi
stop_vm
table=$(sfdisk -d "$W/target.raw")
printf '%s\n' "$table" > "$ART/table.txt"
if grep -qi 'type=21686148-6449-6E6F-744E-656564454649' <<<"$table" && grep -qi 'type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B' <<<"$table" \
        && grep -qi 'type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709' <<<"$table" && grep -q '^label: gpt' <<<"$table"; then
    pass "the disk is GPT with a BIOS boot partition, the system partition and the root"
else fail "partition table: $table"; fi
if dd if="$W/target.raw" bs=512 count=1 status=none | grep -aq GRUB; then pass "GRUB is in the MBR"
else fail "no GRUB boot code in the MBR"; fi

# --- 2. the installed disk alone ----------------------------------------------------
log "booting the installed disk alone under SeaBIOS"
start_vm installed -drive "if=virtio,format=raw,file=$W/target.raw"
if wait_up 300; then pass "the installed system starts from its own GRUB under SeaBIOS"
else fail "the installed system did not come up"; tail -30 "$ART/installed-serial.log"; exit 1; fi
ssh_guest "[ ! -d /sys/firmware/efi ] && [ \"\$(hostname)\" = sg-bios ] && [ \"\$(findmnt -n -o FSTYPE /)\" = btrfs ] && grep -q 'root=PARTUUID=' /proc/cmdline && grep -q 'sg.entry=' /proc/cmdline" \
    && pass "the root (btrfs, root=PARTUUID=) and the entry GRUB started (sg.entry=)" || fail "the installed boot: $(ssh_guest 'cat /proc/cmdline')"
ssh_guest "ls /efi >/dev/null; [ -f /efi/grub/grub.cfg ] && [ -f /efi/grub/grubenv ] && grep -qx BOOT_ROOT=/efi /etc/kernel/install.conf" \
    && pass "GRUB, its menu and grubenv are in the system partition (vfat: GRUB can write grubenv there)" || fail "/efi/grub"
for _ in $(seq 1 30); do ssh_guest "systemctl is-active -q sg-grub-bless.service" && break; sleep 4; done
ssh_guest "systemctl is-active -q sg-grub-bless.service" && pass "sg-grub-bless ran after boot-complete" || fail "sg-grub-bless: $(ssh_guest 'systemctl status sg-grub-bless.service --no-pager' 2>&1 | tail -5)"
if [[ "${SG_BIOS_MUTANT:-}" == NO_COUNT ]]; then
    ssh_guest "sed -i 's/set sg_tries=\$((_n - 1)); save_env sg_tries; //' /usr/bin/sg-grub-bios" && log "MUTANT: no boot counting"
fi
K=$(ssh_guest "uname -r")
token=$(ssh_guest "cat /etc/kernel/entry-token")
# The running kernel's files as its boot entry has them (the image's kernel
# has no Debian initrd in /boot: its initrds are the entry's, in /efi).
cur=$(ssh_guest "tr ' ' '\n' < /proc/cmdline | sed -n 's/^sg.entry=//p'")
KIMG=$(ssh_guest "sed -n 's/^linux[[:space:]]*/\/efi/p' /efi/loader/entries/$cur.conf")
KINITRDS=$(ssh_guest "sed -n 's/^initrd[[:space:]]*/\/efi/p' /efi/loader/entries/$cur.conf | tr '\n' ' '")
[[ -n "$KIMG" && -n "$KINITRDS" ]] || fail "the running entry's kernel and initrds ($cur)"

# entries_state: the loader entries' names, and grubenv
state() { ssh_guest "ls /efi/loader/entries/; grub-editenv /efi/grub/grubenv list" 2>/dev/null | tr '\n' ' '; }
# add_kernel VERSION KERNEL INITRD...: what a kernel package's postinst does
add_kernel() { local v=$1; shift; ssh_guest "kernel-install add '$v' $*" > "$ART/add-$v.log" 2>&1; }
started() { ssh_guest "tr ' ' '\n' < /proc/cmdline | sed -n 's/^sg.entry=//p'" 2>/dev/null; }

# --- 3. a kernel update that works ------------------------------------------------------
GOOD="$K-sggood"
add_kernel "$GOOD" "$KIMG" "$KINITRDS" || fail "kernel-install add $GOOD: $(cat "$ART/add-$GOOD.log")"
s=$(state)
[[ "$s" == *"$token-$GOOD+3.conf"* && "$s" == *"sg_trial=$token-$GOOD"* && "$s" == *"sg_tries=3"* ]] \
    && pass "a new kernel gets a boot entry on trial (3 tries) and GRUB's menu follows" || fail "after the update: $s"
if reboot_to 300 && [[ "$(started)" == "$token-$GOOD" ]]; then pass "the new kernel starts"
else fail "the new kernel did not start (started: $(started))"; fi
for _ in $(seq 1 30); do s=$(state); [[ "$s" == *"$token-$GOOD.conf"* && "$s" != *sg_trial* ]] && break; sleep 4; done
[[ "$s" == *"$token-$GOOD.conf"* && "$s" != *sg_trial* ]] && pass "it came up: marked good, the trial is over" || fail "not blessed: $s"

# --- 4. a new kernel GRUB cannot load ------------------------------------------------------
# It can never start: its tries are used up at once and the menu is read again
# (sg-grub-bios), so the very start that tried it comes up on the previous
# kernel, no keypress; then it is marked bad.
BAD="$K-sgnoload"
# small files: the boot partition holds the image's large initrds twice already
ssh_guest "head -c 4M /dev/urandom > /boot/vmlinuz-$BAD; head -c 1M /dev/urandom > /boot/initrd.img-$BAD"
add_kernel "$BAD" "/boot/vmlinuz-$BAD" "/boot/initrd.img-$BAD" || fail "kernel-install add $BAD: $(cat "$ART/add-$BAD.log")"
if reboot_to 300 && [[ "$(started)" == "$token-$GOOD" ]]; then
    pass "a new kernel GRUB cannot load: the start comes back on the previous kernel, with no keypress"
else fail "after an unloadable kernel: started '$(started)'"; fi
for _ in $(seq 1 30); do s=$(state); [[ "$s" == *"$token-$BAD+0.conf"* && "$s" != *sg_trial* ]] && break; sleep 4; done
[[ "$s" == *"$token-$BAD+0.conf"* ]] && pass "the unloadable kernel is marked bad (sorted last)" || fail "not marked bad: $s"

# --- 5. a new kernel that starts but never comes up ---------------------------------------
HANG="$K-sghang"
ssh_guest "head -c 1M /dev/urandom > /boot/initrd.img-$HANG"
add_kernel "$HANG" "$KIMG" "/boot/initrd.img-$HANG" || fail "kernel-install add $HANG: $(cat "$ART/add-$HANG.log")"
ssh_guest "systemctl reboot" >/dev/null 2>&1 || true
sleep 15
resets=0
until wait_up 120; do
    resets=$((resets + 1))
    (( resets <= 5 )) || break
    log "the start hangs: reset $resets"
    reset_vm || fail "the reset did not reach the VM"
done
if ssh_guest true 2>/dev/null && [[ "$(started)" == "$token-$GOOD" ]] && (( resets == 3 )); then
    pass "a kernel that never comes up: three tries, then GRUB starts the previous kernel by itself"
else fail "hanging kernel: up=$(ssh_guest true 2>/dev/null && echo y || echo n) started='$(started)' resets=$resets"; fi
for _ in $(seq 1 30); do s=$(state); [[ "$s" == *"$token-$HANG+0.conf"* && "$s" != *sg_trial* ]] && break; sleep 4; done
[[ "$s" == *"$token-$HANG+0.conf"* ]] && pass "the hanging kernel is marked bad" || fail "not marked bad: $s"
stop_vm

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL"; fi
exit $RC
