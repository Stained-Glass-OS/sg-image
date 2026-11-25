#!/usr/bin/env bash
# An installed machine with an NVIDIA Ada card (10de:2680-28ff) and no GSP
# firmware keeps its screen from the initrd on: nouveau, which removed the
# firmware framebuffer and then failed (a black screen from the boot logo
# on), is kept out of the initrd by sg-nouveau-guard, which sg-firmware-initrd
# puts into the machine's sg-firmware.initrd -- shipped by apt, made again for
# each new kernel's entry. As Windows keeps the Basic Display Adapter until a
# working driver is there.
#
#   An installed disk (install-test.sh's build/install-target.raw, or
#   SG_INSTALLED_DISK) booted in QEMU with ramfb only (the firmware's
#   framebuffer, no DRM device). QEMU has no NVIDIA card: the card is the
#   guard's stand-in, a fake PCI device directory (SG_GUARD_SYSFS) given to
#   sg-firmware-initrd and, in a cpio of its own, to the initrd -- whose
#   nouveau is loaded on purpose (rd.modules_load=nouveau for the image's
#   systemd initrd; /etc/initramfs-tools/modules for Debian's), as udev
#   loads it for a real card.
#   1. sg-firmware-initrd (with the fake card) writes the guard into
#      sg-firmware.initrd; with NVIDIA's driver (modprobe.blacklist=nouveau
#      in /etc/kernel/cmdline) it is left out again.
#   2. The image's entry (mkosi's systemd initrd) with the fake card: nouveau
#      is not in the kernel after the boot, the kernel log has the guard's
#      line, the framebuffer is still /dev/fb0, and the first screen (the
#      first-run setup or the login screen) comes up on it at once.
#   3. A new kernel's entry as a Debian kernel update makes it
#      (update-initramfs, kernel-install add -- with sg-session's plugins):
#      it loads sg-firmware.initrd too, and booted with the fake card the
#      same holds.
#
#   SG_NOUVEAU_DEBS=DIR: install DIR/*.deb first (packages not yet released).
#   SG_NOUVEAU_MUTANT=NO_GUARD: sg-firmware-initrd never adds the guard:
#   steps 1-3 must fail. SG_NOUVEAU_MUTANT=NO_QUICK: sg-common.sh never
#   sends the compositor to the Basic Display Adapter at once: the login
#   screen checks of 2 and 3 must fail (wlroots' ten-second wait).
# shellcheck disable=SC2015,SC2317  # pass || fail; cleanup via trap
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
DISK="${SG_INSTALLED_DISK:-$BUILD/install-target.raw}"
SSH_KEY="${SG_SSH_KEY:-$BUILD/ssh/id_ed25519}"
SSH_PORT="${SG_SSH_PORT:-2294}"
W="${SG_NOUVEAU_WORK:-$BUILD/nouveau-initrd-vm-test}"
QMP_SOCK="$W/qmp.sock"
QEMU_PID=""
RC=0
PATH="$PATH:/usr/sbin:/sbin"
log()  { echo "[nouveau-initrd-vm-test] $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[[ -f "$DISK" ]] || { echo "no installed disk at $DISK -- run test/install-test.sh first"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- make image"; exit 2; }
[[ -r /dev/kvm ]] || { echo "SKIP: needs KVM"; exit 77; }
command -v qemu-system-x86_64 >/dev/null || { echo "SKIP: no qemu"; exit 77; }
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
if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi

cp --reflink=auto "$DISK" "$W/disk.raw"
cp "${OVMF_CODE/CODE/VARS}" "$W/vars.fd"
boot() { # LABEL
    log "booting the installed disk ($1)"
    # shellcheck disable=SC2054  # commas inside QEMU arguments
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,unit=1,file=$W/vars.fd" \
        -vga none -device ramfb \
        -drive "if=virtio,format=raw,file=$W/disk.raw" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0 \
        -display none -serial "file:$W/serial-$1.log" -qmp "unix:$QMP_SOCK,server,nowait" -no-reboot \
        -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$SSH_KEY.pub")" &
    QEMU_PID=$!
    local deadline=$(( SECONDS + 400 ))
    until ssh_guest true 2>/dev/null; do
        kill -0 "$QEMU_PID" 2>/dev/null && (( SECONDS < deadline )) || { fail "the installed system did not come up ($1)"; tail -20 "$W/serial-$1.log"; exit 1; }
        sleep 4
    done
}
# a restart: -no-reboot ends QEMU at the reset, and the same disk and
# firmware variables (the one-shot entry) start again
restart() { # LABEL
    ssh_guest "systemctl reboot" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
    kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""
    boot "$1"
}

boot first
if [[ -n "${SG_NOUVEAU_DEBS:-}" ]]; then
    ssh_guest "mkdir -p /root/debs" && scp -q -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -P "$SSH_PORT" "$SG_NOUVEAU_DEBS"/*.deb root@127.0.0.1:/root/debs/ \
        && ssh_guest "dpkg -i --force-depends /root/debs/*.deb" > "$W/debs.log" 2>&1 \
        && log "installed $(cd "$SG_NOUVEAU_DEBS" && echo ./*.deb)" || { fail "installing $SG_NOUVEAU_DEBS: $(tail -3 "$W/debs.log")"; exit 1; }
fi
ssh_guest "dpkg-query -W sg-session" | sed 's/^/    /'
if [[ "${SG_NOUVEAU_MUTANT:-}" == NO_QUICK ]]; then
    ssh_guest "sed -i 's/^    export SG_BASIC_DISPLAY=1\$/    :/' /usr/lib/stained-glass/sg-common.sh" && log "MUTANT: no Basic Display Adapter at once"
fi
# The fake card (the guard's stand-in) in the root, and as a cpio for the
# initrd; sg-firmware-initrd then, as at the next boot's service run.
FW_TOOL=/usr/bin/sg-firmware-initrd
if [[ "${SG_NOUVEAU_MUTANT:-}" == NO_GUARD ]]; then
    ssh_guest "sed 's/^    return ada and not nouveau_blacklisted()\$/    return False/' /usr/bin/sg-firmware-initrd > /root/fwi-mutant && ! cmp -s /root/fwi-mutant /usr/bin/sg-firmware-initrd" \
        && log "MUTANT: sg-firmware-initrd never adds the guard" || log "MUTANT: (this sg-firmware-initrd has no guard to remove)"
    ssh_guest "[ -f /root/fwi-mutant ] || cp /usr/bin/sg-firmware-initrd /root/fwi-mutant"
    FW_TOOL="python3 /root/fwi-mutant"
fi
ssh_guest "set -e; d=/sg-gate-pci/0000:01:00.0; mkdir -p /var/lib\$d; echo 0x10de > /var/lib\$d/vendor; echo 0x030000 > /var/lib\$d/class; echo 0x2860 > /var/lib\$d/device
    cd /var/lib && find sg-gate-pci | cpio -o -H newc --quiet --owner=0:0 > /root/sg-gate-pci.initrd" || { fail "the fake card"; exit 1; }
BOOT_ROOT=$(ssh_guest "sed -n 's/^BOOT_ROOT=//p' /etc/kernel/install.conf | tail -1; ls /efi /xbootldr >/dev/null 2>&1" | head -1)
[[ -n "$BOOT_ROOT" ]] || BOOT_ROOT=/efi
DEFAULT=$(ssh_guest "ls $BOOT_ROOT/loader/entries/ | grep -v -e -recovery -e -live -e sg-gate | sort -V | tail -1")
log "boot partition $BOOT_ROOT, default entry $DEFAULT"

# --- 1. the guard in sg-firmware.initrd ------------------------------------------------
fwi() { ssh_guest "SG_GUARD_SYSFS=/var/lib/sg-gate-pci $FW_TOOL update" 2>&1 | sed 's/^/    /'; }
fwi
has_guard() { # entry name: its sg-firmware.initrd carries the guard
    ssh_guest "set -e; e=$BOOT_ROOT/loader/entries/$1; i=\$(sed -n 's#^initrd \(.*/sg-firmware\.initrd\)\$#\1#p' \$e | tail -1)
        [ -n \"\$i\" ] && [ \"\$(tail -1 \$e)\" = \"initrd \$i\" ] || exit 1
        cpio -it --quiet < $BOOT_ROOT\$i | grep -qx usr/lib/stained-glass/sg-nouveau-guard
        cpio -it --quiet < $BOOT_ROOT\$i | grep -qx usr/lib/modprobe.d/sg-nouveau-guard.conf" 2>/dev/null
}
has_guard "$DEFAULT" && pass "with the (fake) Ada card and no driver, the entry's last initrd, sg-firmware.initrd, carries the guard" \
    || fail "no guard in $DEFAULT's sg-firmware.initrd: $(ssh_guest "cat $BOOT_ROOT/loader/entries/$DEFAULT" 2>&1 | grep initrd | tr '\n' ' ')"
ssh_guest "cp /etc/kernel/cmdline /root/cmdline.keep && sed -i 's/\$/ modprobe.blacklist=nouveau/' /etc/kernel/cmdline"
fwi
has_guard "$DEFAULT" && fail "the guard stayed with NVIDIA's driver installed (nouveau blacklisted)" \
    || pass "with NVIDIA's driver (modprobe.blacklist=nouveau) it is left out again"
ssh_guest "cp /root/cmdline.keep /etc/kernel/cmdline"
fwi

# a boot entry of the gate's: the default one, the fake card's cpio after
# the others, nouveau loaded in the initrd on purpose, the stand-in in the
# initrd's environment (PID 1's, the kernel's unknown NAME=VALUE options)
gate_entry() { # SOURCE-ENTRY NAME
    ssh_guest "set -e; B=$BOOT_ROOT; e=\$B/loader/entries/$1; dir=\$(sed -n 's#^initrd[[:space:]]*\(.*\)/[^/]*\$#\1#p' \$e | head -1)
        cp /root/sg-gate-pci.initrd \$B\$dir/sg-gate-pci.initrd
        sed -e 's/^title .*/title gate: fake NVIDIA Ada card/' \
            -e 's#^options .*#& rd.modules_load=nouveau systemd.setenv=SG_GUARD_SYSFS=/sg-gate-pci SG_GUARD_SYSFS=/sg-gate-pci sg.gate=nouveau#' \$e > \$B/loader/entries/$2
        echo \"initrd \$dir/sg-gate-pci.initrd\" >> \$B/loader/entries/$2
        bootctl set-oneshot $2"
}
check_boot() { # what
    local out
    out=$(ssh_guest "grep -q sg.gate=nouveau /proc/cmdline && echo gate
        grep -q '^nouveau ' /proc/modules && echo loaded
        journalctl -b -t sg-nouveau-guard --no-pager -o cat | grep -q 'not loading nouveau' && echo said
        [ -e /dev/fb0 ] && [ ! -e /dev/dri ] && echo fb" 2>&1 | paste -sd' ')
    if [[ "$out" == "gate said fb" ]]; then
        pass "$1: nouveau stayed out of the initrd, the kernel log says why, the firmware framebuffer is still the screen"
    else fail "$1: $out (want: gate said fb -- 'loaded' means nouveau was loaded in the initrd)"; fi
    # the first screen: the first-run setup (an installed disk not yet
    # started) or the login screen
    local t=0
    until ssh_guest "journalctl -b -t sg-login --no-pager -o cat | grep -q 'greeter ready' || journalctl -b -t sg-oobe --no-pager -o cat | grep -q 'sg-oobe: state'" 2>/dev/null; do
        (( t < 240 )) || { fail "$1: no first-run setup or login screen on the firmware framebuffer"; break; }
        sleep 4; t=$(( t + 4 ))
    done
    (( t < 240 )) && pass "$1: the first screen (first-run setup or login screen) comes up on it (Basic Display Adapter)"
    # (the compositor's line comes either way: after wlroots' wait it reads
    # 00:00:10.0xx, at once 00:00:00.0xx)
    out=$(ssh_guest "journalctl -b --no-pager -o cat | grep -cE '[0-9]{2}:[0-9]{2}:([0-9][1-9]|[1-9][0-9])\.[0-9]+ .*No GPU can be used'; journalctl -b --no-pager -o cat | grep -c 'the Basic Display Adapter at once'" 2>&1 | paste -sd' ')
    [[ "$out" == "0 "[1-9]* ]] && pass "$1: ...at once, without wlroots' ten-second wait for a GPU (sg_basic_display_env)" \
        || fail "$1: the first screen waited ten seconds for a GPU first (waits, at once: $out)"
    qmp screendump "$W/$2.ppm"
    # what sg-boot-report's screen and report say about the graphics
    ssh_guest "python3 -c 'import importlib.machinery as m; r = m.SourceFileLoader(\"r\", \"/usr/bin/sg-boot-report\").load_module(); print(\"\\n\".join(r.summary(\"(gate)\")))'" > "$W/$2-report.txt" 2>&1
    grep -q 'sg-nouveau-guard: not loading nouveau.*sg-drivers --install-recommended' "$W/$2-report.txt" \
        && pass "$1: sg-boot-report's graphics section has the guard's line, with what to run" \
        || fail "$1: sg-boot-report does not show the guard's line ($W/$2-report.txt)"
}

# what the guard's kernel-log line tells the owner to run: sg-drivers offers
# NVIDIA's own driver for the card
drv=$(ssh_guest "printf '0000:01:00.0 10de 2860 030000\\n' > /tmp/pci-ada; SG_DRIVERS_PCI=/tmp/pci-ada sg-drivers --list | cut -f4" 2>&1)
[[ " $drv " == *" nvidia-open "* ]] && pass "sg-drivers offers NVIDIA's driver for the card (${drv//$'\n'/ })" \
    || fail "sg-drivers for an Ada card: '$drv'"

# --- 2. the image's entry ---------------------------------------------------------------
gate_entry "$DEFAULT" sg-gate-image.conf || fail "the gate's entry"
restart image
check_boot "the image's initrd (systemd), fake Ada card" image

# --- 3. a new kernel's entry, as a Debian kernel update makes it ---------------------------
KVER=$(ssh_guest "uname -r")
log "a Debian initrd for $KVER (update-initramfs) and its entry (kernel-install add)"
ssh_guest "echo nouveau >> /etc/initramfs-tools/modules
    update-initramfs -c -k $KVER >/dev/null 2>&1 || update-initramfs -u -k $KVER >/dev/null 2>&1
    lsinitramfs /boot/initrd.img-$KVER | grep -qx usr/lib/stained-glass/sg-nouveau-guard && echo 'PASS  Debian'\"'\"'s initrd has the guard script beside its modprobe.d line (initramfs-tools hook)' || echo 'FAIL  Debian'\"'\"'s initrd has no guard script'
    cp -a $BOOT_ROOT/loader/entries /root/entries.before
    SG_GUARD_SYSFS=/var/lib/sg-gate-pci kernel-install add $KVER /boot/vmlinuz-$KVER /boot/initrd.img-$KVER >/dev/null 2>&1; echo rc=\$?" 2>&1 \
    | tee "$W/kernel-install.log" | grep -E '^(PASS|FAIL)'
grep -q '^FAIL' "$W/kernel-install.log" && RC=1
[[ "${SG_NOUVEAU_MUTANT:-}" == NO_GUARD ]] && ssh_guest "SG_GUARD_SYSFS=/var/lib/sg-gate-pci $FW_TOOL update" >/dev/null 2>&1
NEW=$(ssh_guest "ls $BOOT_ROOT/loader/entries/ | grep -v -e -recovery -e -live -e sg-gate | while read -r e; do grep -q 'initrd.img-' $BOOT_ROOT/loader/entries/\$e && echo \$e; done | tail -1")
if [[ -n "$NEW" ]] && has_guard "$NEW"; then
    pass "the new kernel's entry ($NEW, Debian's initrd) loads sg-firmware.initrd with the guard, last"
else fail "the new kernel's entry '$NEW': $(ssh_guest "cat $BOOT_ROOT/loader/entries/$NEW" 2>&1 | grep initrd | tr '\n' ' ')"; fi
if [[ -n "$NEW" ]]; then
    gate_entry "$NEW" sg-gate-debian.conf || fail "the gate's entry (Debian)"
    restart debian
    check_boot "Debian's initrd (initramfs-tools), fake Ada card" debian
fi

if [[ "${SG_NOUVEAU_KEEP:-0}" == 1 ]]; then
    log "SG_NOUVEAU_KEEP=1: the VM stays up (qemu pid $QEMU_PID, ssh port $SSH_PORT, disk $W/disk.raw)"
    QEMU_PID=""; exit $RC
fi
ssh_guest "systemctl poweroff" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
kill "$QEMU_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null; QEMU_PID=""
rm -f "$W/disk.raw"
echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL"; fi
exit $RC
