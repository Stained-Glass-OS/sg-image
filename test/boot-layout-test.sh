#!/bin/bash
# shellcheck disable=SC2015,SC2016  # pass/fail chains; commands run in the guest
# Kernel packages upgrade, and the new kernel boots (sg-session's
# sg-boot-layout, sg-kernel-entries). /boot used to be the FAT boot partition,
# where dpkg cannot replace a kernel package's files ("unable to make backup
# link": FAT has no hard links). Now /boot is on the root file system and the
# boot partition is at /efi (or /xbootldr beside Windows). In QEMU:
#
#   new  a disk Setup installed with the new layout (SG_LAYOUT_DISK, default
#        build/install-target.raw from `make install-test` /
#        `install-dualboot-test` with the package under test): the layout is
#        there; the running kernel's package is reinstalled (same name, same
#        version: what failed on FAT) and its new entry, on trial (+3), boots,
#        is blessed, and the desktop comes up on it.
#   old  a disk installed before (SG_OLD_DISK): updated to SG_SESSION_DEB
#        (+ SG_EXTRA_DEBS) and restarted, sg-boot-layout moves it over at that
#        boot; the old entries are still there; then the same reinstall and
#        boot as above.
#
# Needs KVM and the network (Debian's archive, for the kernel package).
# SG_LAYOUT_SCENARIOS="new old" picks. `make boot-layout-test`.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=${SG_BUILD:-$HERE/build}
KEY="$BUILD/ssh/id_ed25519"
PORT=${SG_SSH_PORT:-2396}
W=${SG_LAYOUT_WORK:-/var/tmp/sg-boot-layout-test}
ART="$BUILD/artifacts-boot-layout"
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[ -f "$KEY" ] || { echo "SKIP: no ssh key"; exit 77; }
mkdir -p "$W" "$ART"
QPID=""
stop() { [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""; }
trap 'stop; rm -f "$W/disk.raw"' EXIT INT TERM
SSHO=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
g() { ssh "${SSHO[@]}" -p "$PORT" root@127.0.0.1 "$@"; }
wait_ssh() { local i=0; sleep 10; until g true 2>/dev/null; do i=$((i + 1)); [ $i -lt 100 ] || return 1; sleep 3; done; }
boot() {
    stop
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,unit=1,file="$W/vars.fd" \
        -drive if=virtio,format=raw,file="$W/disk.raw" \
        -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$KEY.pub")" \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 -device virtio-net-pci,netdev=n0 \
        -display none -serial file:"$ART/serial-$1.log" -monitor none >"$ART/qemu-$1.log" 2>&1 &
    QPID=$!
    wait_ssh
}
restart() { g systemctl reboot >/dev/null 2>&1; sleep 15; wait_ssh; }
fresh() { rm -f "$W/disk.raw"; cp --sparse=always "$1" "$W/disk.raw"; cp "${OVMF_CODE/CODE/VARS}" "$W/vars.fd"; }
layout_ok() {   # the new layout on the running machine
    g 'ls /efi /xbootldr >/dev/null 2>&1; r=$(sed -n "s/^BOOT_ROOT=//p" /etc/kernel/install.conf | tail -1)
       [ -n "$r" ] && ls "$r/loader/entries" >/dev/null && [ "$(findmnt -n -o FSTYPE --target /boot)" != vfat ] && ls /boot/vmlinuz-* >/dev/null && ! findmnt -n /boot >/dev/null' 2>/dev/null
}
reinstall_and_boot() {   # $1: the scenario's name
    local k ent cur
    k=$(g uname -r)
    g "timeout 900 apt-get -q update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive timeout 1800 apt-get -y -q install --reinstall linux-image-$k" \
        > "$ART/reinstall-$1.log" 2>&1 \
        && pass "$1: the running kernel's package reinstalls (same name: dpkg replaces /boot's files)" \
        || { fail "$1: the kernel package did not reinstall (reinstall-$1.log)"; return; }
    ent=$(g 'r=$(sed -n "s/^BOOT_ROOT=//p" /etc/kernel/install.conf | tail -1); ls "$r/loader/entries"' | tr '\n' ' ')
    case "$ent" in *"-$k+3.conf"*) pass "$1: its new entry is on trial ($ent)" ;; *) fail "$1: no new entry on trial: $ent" ;; esac
    restart || { fail "$1: no ssh after the restart"; return; }
    sleep 30
    cur=$(g 'bootctl status 2>/dev/null | sed -n "s/^ *Current Entry: //p"')
    ent=$(g 'r=$(sed -n "s/^BOOT_ROOT=//p" /etc/kernel/install.conf | tail -1); ls "$r/loader/entries"' | tr '\n' ' ')
    [ "$cur" = "$(g cat /etc/kernel/entry-token)-$k.conf" ] && pass "$1: that entry booted ($cur)" || fail "$1: booted '$cur'"
    case "$ent" in *"-$k+"*) fail "$1: not blessed: $ent" ;; *) pass "$1: the start was good: blessed, its recovery twin made ($ent)" ;; esac
    g 'pgrep -x Xwayland >/dev/null && pgrep -x sg-compositor >/dev/null' && pass "$1: the desktop runs on it" || fail "$1: no desktop"
}

for s in ${SG_LAYOUT_SCENARIOS:-new old}; do
    case $s in
    new)
        D=${SG_LAYOUT_DISK:-$BUILD/install-target.raw}
        [ -f "$D" ] || { echo "SKIP  new: no installed disk ($D)"; continue; }
        fresh "$D"; boot new || { fail "new: the VM did not come up"; continue; }
        layout_ok && pass "new: /boot on the root file system, the boot partition at BOOT_ROOT" \
            || fail "new: the layout: $(g 'findmnt --target /boot; cat /etc/kernel/install.conf' 2>&1 | tr '\n' ' ')"
        reinstall_and_boot new
        stop ;;
    old)
        D=${SG_OLD_DISK:-}
        { [ -n "$D" ] && [ -f "$D" ] && [ -f "${SG_SESSION_DEB:-}" ]; } || { echo "SKIP  old: SG_OLD_DISK and SG_SESSION_DEB needed"; continue; }
        fresh "$D"; boot old1 || { fail "old: the VM did not come up"; continue; }
        g 'findmnt -n -o FSTYPE /boot' | grep -qx vfat && pass "old: before the update /boot is the FAT boot partition" || fail "old: not the old layout"
        before=$(g 'ls /boot/loader/entries' | tr '\n' ' ')
        # shellcheck disable=SC2086  # a list of packages
        scp "${SSHO[@]}" -P "$PORT" "$SG_SESSION_DEB" ${SG_EXTRA_DEBS:-} root@127.0.0.1:/root/ >/dev/null &&
            g 'apt-get -q update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get -y -q install /root/*.deb' > "$ART/update-old.log" 2>&1 \
            || { fail "old: the update did not install"; continue; }
        restart || { fail "old: no ssh after the update's restart"; continue; }
        g 'journalctl -b -u sg-boot-layout -o cat --no-pager' > "$ART/boot-layout-old.log" 2>&1
        layout_ok && pass "old: moved over at the next boot: /boot on the root file system, the boot partition at BOOT_ROOT" \
            || fail "old: not moved: $(tail -3 "$ART/boot-layout-old.log" | tr '\n' ' ')"
        after=$(g 'r=$(sed -n "s/^BOOT_ROOT=//p" /etc/kernel/install.conf | tail -1); ls "$r/loader/entries"' | tr '\n' ' ')
        miss=""; for e in $before; do case " $after " in *" $e "*) ;; *) miss="$miss $e" ;; esac; done
        [ -z "$miss" ] && pass "old: every boot entry is still there" || fail "old: entries lost:$miss"
        restart || { fail "old: no ssh at the second boot"; continue; }
        layout_ok && pass "old: and so at the boot after (fstab, not the move)" || fail "old: the layout did not hold at the next boot"
        reinstall_and_boot old
        stop ;;
    esac
done
exit $RC
