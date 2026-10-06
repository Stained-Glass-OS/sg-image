#!/bin/bash
# shellcheck disable=SC2015,SC2016  # pass/fail chains; commands run in the guest
# A Microsoft Surface gets its touch screen and pen support by update, and no
# other PC is changed (sg-session's sg-hwsupport.service / sg-drivers
# --install-platform). End to end in QEMU, on a disk Setup installed (the
# install gate's build/install-target.raw, copied):
#
#   1. QEMU tells the guest it is a Surface Pro 7 (SMBIOS type 1). The disk is
#      updated to the sg-session package under test (SG_SESSION_DEB) and
#      restarted: at boot sg-hwsupport adds the linux-surface archive (its
#      key, its pin) and installs the real linux-image-surface, iptsd and
#      libwacom-surface from pkg.surfacelinux.com; the new kernel's entry
#      counts its tries.
#   2. Restarted again, the Surface kernel is running, its entry blessed
#      (systemd-bless-boot), the desktop up.
#   3. Its tries used up (the entry renamed +0-3, as systemd-boot leaves a
#      kernel that failed three times), the stock kernel boots by itself.
#   4. A fresh copy with QEMU's own SMBIOS: updated and restarted, the unit
#      does not run (ConditionFirmware) and nothing of it is on the disk.
#
# Needs the network (Debian, pkg.surfacelinux.com), KVM, and
# SG_SESSION_DEB (plus SG_EXTRA_DEBS for dependencies the archive lacks).
# Not part of `make test`: run it on purpose (`make surface-test`).
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=${SG_BUILD:-$HERE/build}
SRC_DISK=${SG_SURFACE_DISK:-$BUILD/install-target.raw}
DEB=${SG_SESSION_DEB:?SG_SESSION_DEB: the sg-session package to test}
KEY="$BUILD/ssh/id_ed25519"
PORT=${SG_SSH_PORT:-2398}
W=${SG_SURFACE_WORK:-/var/tmp/sg-surface-test}
ART="$BUILD/artifacts-surface"
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[ -f "$SRC_DISK" ] || { echo "SKIP: no installed disk ($SRC_DISK: run make install-dualboot-test)"; exit 77; }
[ -f "$KEY" ] && [ -f "$DEB" ] || { echo "SKIP: no ssh key or package"; exit 77; }
mkdir -p "$W" "$ART"
QPID=""
stop() { [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""; }
trap 'stop; rm -f "$W/disk.raw"' EXIT INT TERM
SSHO=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
g() { ssh "${SSHO[@]}" -p "$PORT" root@127.0.0.1 "$@"; }
wait_ssh() { local i=0; sleep 10; until g true 2>/dev/null; do i=$((i + 1)); [ $i -lt 100 ] || return 1; sleep 3; done; }
boot() {   # boot [SMBIOS type 1 string]
    stop
    local smb=()
    [ -n "${1:-}" ] && smb=(-smbios "$1")
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,unit=1,file="$W/vars.fd" \
        -drive if=virtio,format=raw,file="$W/disk.raw" "${smb[@]}" \
        -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$KEY.pub")" \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 -device virtio-net-pci,netdev=n0 \
        -display none -serial file:"$ART/serial-$2.log" -monitor none >"$ART/qemu-$2.log" 2>&1 &
    QPID=$!
    wait_ssh
}
restart() { g systemctl reboot >/dev/null 2>&1; sleep 15; wait_ssh; }
fresh() { rm -f "$W/disk.raw"; cp --sparse=always "$SRC_DISK" "$W/disk.raw"; cp "${OVMF_CODE/CODE/VARS}" "$W/vars.fd"; }
update() {
    # shellcheck disable=SC2086  # a list of packages
    scp "${SSHO[@]}" -P "$PORT" "$DEB" ${SG_EXTRA_DEBS:-} root@127.0.0.1:/root/ >/dev/null &&
        g 'apt-get -q update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get -y -q install /root/*.deb' >"$ART/update-$1.log" 2>&1
}
SURFACE="type=1,manufacturer=Microsoft Corporation,product=Surface Pro 7,family=Surface"

# --- 1. a Surface, updated -------------------------------------------------------
fresh
boot "$SURFACE" surface1 || { fail "the Surface VM did not come up"; exit 1; }
[ "$(g cat /sys/class/dmi/id/product_name)" = "Surface Pro 7" ] || fail "the guest does not see a Surface Pro 7"
update surface || { fail "the update did not install (update-surface.log)"; exit 1; }
restart || { fail "no ssh after the update's restart"; exit 1; }
i=0; while [ "$(g systemctl show -p ActiveState --value sg-hwsupport.service)" = activating ] && [ $i -lt 200 ]; do sleep 5; i=$((i + 1)); done
g 'journalctl -b -u sg-hwsupport -o cat --no-pager' > "$ART/hwsupport.log" 2>&1
if g 'dpkg-query -W -f "\${Status}\n" linux-image-surface iptsd libwacom-surface' 2>/dev/null | grep -c 'install ok installed' | grep -qx 3; then
    pass "at the next boot the Surface's kernel, iptsd and libwacom were installed"
else fail "the Surface packages were not installed (hwsupport.log)"; fi
g 'apt-cache policy surface-control' | grep -q 'Candidate: (none)' && pass "the archive's other packages are pinned away" \
    || fail "the linux-surface archive is not pinned"
ent=$(g 'ls /boot/loader/entries' | tr '\n' ' ')
lst() { g 'ls /boot/loader/entries'; }
lst | grep -q -- '-surface-.*+3\.conf$' && pass "the Surface kernel's entry counts its tries ($ent)" || fail "entries: $ent"
lst | grep -q 'surface.*-recovery' && fail "a recovery twin while on trial: $ent"
# --- 2. its kernel runs ----------------------------------------------------------
restart || { fail "no ssh on the Surface kernel"; exit 1; }
sleep 20
k=$(g uname -r)
case "$k" in *-surface-*) pass "the Surface kernel runs ($k)" ;; *) fail "the kernel is $k" ;; esac
ent=$(g 'ls /boot/loader/entries' | tr '\n' ' ')
lst | grep -q -- '-surface-.*+[0-9]' && fail "not blessed: $ent" || pass "its start was good: the counter is gone ($ent)"
g 'pgrep -x sg-compositor >/dev/null && pgrep -x Xwayland >/dev/null' && pass "the desktop's compositor and Xwayland run on it" \
    || fail "no compositor or Xwayland on the Surface kernel"
# --- 3. a kernel that cannot start: the stock one again ---------------------------
g 'cd /boot/loader/entries && for e in *-surface-*.conf; do case $e in *-recovery.conf) rm -f "$e" ;; *) mv "$e" "${e%.conf}+0-3.conf" ;; esac; done'
restart || { fail "no ssh after the failed kernel"; exit 1; }
k=$(g uname -r)
case "$k" in *-surface-*) fail "a kernel with its tries used up still boots ($k)" ;; *) pass "with its tries used up the stock kernel boots ($k)" ;; esac
stop
# --- 4. not a Surface ----------------------------------------------------------
fresh
boot "" plain || { fail "the plain VM did not come up"; exit 1; }
update plain || { fail "the update did not install on the plain VM"; exit 1; }
restart || { fail "no ssh after the plain VM's restart"; exit 1; }
sleep 20
g 'systemctl status sg-hwsupport --no-pager' 2>&1 | grep -q 'ConditionFirmware=.*was not met' \
    && pass "on another PC the unit does not run (ConditionFirmware)" || fail "the unit's condition on QEMU's DMI"
left=$(g 'ls /etc/apt/sources.list.d /etc/apt/preferences.d /etc/kernel/install.conf 2>/dev/null; dpkg -l "linux-image-*surface*" iptsd 2>/dev/null | grep ^ii' | grep -i -E 'surface|install.conf|iptsd')
[ -z "$left" ] && pass "and nothing of it is on the disk" || fail "left on another PC: $left"
exit $RC
