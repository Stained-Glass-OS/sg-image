#!/usr/bin/env bash
# The F5 gate: install Stained Glass OS from the live system, then boot the
# installed disk alone and sign in as the owner Setup created.
#
# Two scenarios (SG_INSTALL_SCENARIO):
#
#   blank     the hybrid path, as a person trying it first would take it:
#             Setup's first screen -> "Try Stained Glass OS" -> the live
#             desktop, whose own session gate must pass -> "Install Stained
#             Glass OS" from its desktop shortcut, Setup in a window -> on the
#             blank disk, New (which also makes the system partition), then
#             install onto the new partition.
#   dualboot  a disk that already carries Windows' layout -- an EFI system
#             partition holding a Windows boot manager, a reserved partition,
#             a data partition -- and unallocated space. Setup, full screen
#             from the login screen, installs into the unallocated space.
#             Afterwards the Windows boot manager, the reserved and data
#             partitions and their table entries must be byte-identical, and
#             the installed system must boot from its own boot partition.
#
# Both then power off, boot the installed disk ALONE (fresh firmware
# variables, no stick) and run the full boot gate as the owner -- sign in by
# typing, session check, lock and unlock -- plus checks of what the installer
# did.
#
# Needs mtools, dosfstools, e2fsprogs, fdisk, and what boot-test.sh needs.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
IMAGE="${SG_IMAGE:-$BUILD/sg-image.raw}"
SCENARIO="${SG_INSTALL_SCENARIO:-blank}"
SSH_KEY="$BUILD/ssh/id_ed25519"
SSH_PORT="${SG_SSH_PORT:-2223}"
TARGET="$BUILD/install-target.raw"
LIVE_IMAGE="$BUILD/install-live.raw"
LIVE_VARS="$BUILD/install-live-vars.fd"
OWNER=alice
OWNER_PASS_FILE="$BUILD/install-owner-password"
ARTIFACTS="$BUILD/artifacts-install-$SCENARIO"
QMP_SOCK="$BUILD/install-qmp.sock"
QEMU_PID=""
PATH="$PATH:/usr/sbin:/sbin"
ESP_GUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B

log()  { echo "[install-test:$SCENARIO] $*"; }
fail() { echo "[install-test:$SCENARIO] FAIL: $*" >&2; RC=1; }
pass() { echo "PASS  $*"; }
RC=0

case "$SCENARIO" in blank|dualboot) ;; *) echo "SG_INSTALL_SCENARIO is blank or dualboot"; exit 2 ;; esac
[[ -f "$IMAGE" ]] || { echo "no image at $IMAGE -- run 'make image'"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- run 'make image'"; exit 2; }
for t in sfdisk mkfs.vfat mkfs.ext4 mcopy mtype; do command -v "$t" >/dev/null || { echo "need $t"; exit 2; }; done
if [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm; BOOT_TIMEOUT=300; INSTALL_TIMEOUT=900
else ACCEL=tcg; BOOT_TIMEOUT=1800; INSTALL_TIMEOUT=5400; fi
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { OVMF_CODE=$c; break; }; done
[[ -n "$OVMF_CODE" ]] || { echo "no OVMF"; exit 2; }
# The live VM runs Secure Boot capable firmware with no keys enrolled (setup
# mode): the SecureBoot variable exists, so mokutil works as on a real PC, but
# nothing is enforced, so the unsigned boot loader still starts.
LIVE_CODE=$OVMF_CODE LIVE_MACHINE="q35,accel=__ACCEL__"
if [[ -f /usr/share/OVMF/OVMF_CODE_4M.secboot.fd ]]; then
    LIVE_CODE=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd LIVE_MACHINE="q35,smm=on,accel=__ACCEL__"
fi

rm -rf "$ARTIFACTS"; mkdir -p "$ARTIFACTS"
# shellcheck disable=SC2317  # invoked via trap
cleanup() { set +e; [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM     # and stop: a gate killed must not carry on

# The owner's password: generated here, lower-case letters and digits so it
# types as plain keys, never committed.
python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(14)), end="")' > "$OWNER_PASS_FILE"
chmod 600 "$OWNER_PASS_FILE"
export MTOOLS_SKIP_CHECK=1

# --- the stick: a copy of the image that boots its live entry ---------------
log "preparing the live medium"
cp --reflink=auto "$IMAGE" "$LIVE_IMAGE"
cp "${OVMF_CODE/CODE/VARS}" "$LIVE_VARS"
esp_start=$(sfdisk -d "$LIVE_IMAGE" | awk -F'[ ,=]+' -v t="$ESP_GUID" 'toupper($0) ~ "TYPE=" t {
    for (i = 1; i <= NF; i++) if ($i == "start") { print $(i + 1); exit } }')
ESP="$LIVE_IMAGE@@$((esp_start * 512))"
live_entry=$(mdir -b -i "$ESP" ::/loader/entries | sed -n 's#.*/\([^/]*-live\.conf\)$#\1#p' | head -1)
[[ -n "$live_entry" ]] || { echo "FAIL: the image has no live boot entry (mkosi.postoutput)"; exit 1; }
printf 'default %s\ntimeout 0\n' "$live_entry" > "$ARTIFACTS/loader.conf"
mcopy -o -i "$ESP" "$ARTIFACTS/loader.conf" ::/loader/loader.conf

# --- the disk to install to ----------------------------------------------------
rm -f "$TARGET"
# Partition N's raw bytes and its table entry, for "untouched" checks.
part_sum() {
    local start size
    read -r start size < <(sfdisk -d "$TARGET" | awk -v n="$1" -F'[ ,=]+' '$1 ~ "raw" n "$" {
        for (i = 1; i <= NF; i++) { if ($i == "start") s = $(i + 1); if ($i == "size") z = $(i + 1) } print s, z }')
    dd if="$TARGET" bs=512 skip="$start" count="$size" status=none | sha256sum | cut -d' ' -f1
}
part_entry() { sfdisk -d "$TARGET" | grep -E "raw$1 :"; }
if [[ "$SCENARIO" == blank ]]; then
    truncate -s 24G "$TARGET"
else
    # Windows' layout: ESP (100 MB, with a boot manager), MSR (16 MB), a data
    # partition (4 GB), then 27 GB unallocated.
    truncate -s 32G "$TARGET"
    printf 'label: gpt\nstart=2048, size=204800, type=%s, name="EFI system partition"\nsize=32768, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE, name="Microsoft reserved partition"\nsize=8388608, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="Basic data partition"\n' \
        "$ESP_GUID" | sfdisk -q "$TARGET"
    W="$BUILD/win-parts"; rm -rf "$W"; mkdir -p "$W/data"
    head -c 1500000 /dev/urandom > "$W/bootmgfw.efi"
    mkfs.vfat -F 32 -n SYSTEM -C "$W/esp.img" 102400 >/dev/null
    mmd -i "$W/esp.img" ::/EFI ::/EFI/Microsoft ::/EFI/Microsoft/Boot
    mcopy -i "$W/esp.img" "$W/bootmgfw.efi" ::/EFI/Microsoft/Boot/bootmgfw.efi
    head -c 4096 /dev/urandom > "$W/data/marker.bin"
    mkfs.ext4 -q -F -L Windows -d "$W/data" "$W/data.img" 4G
    dd if="$W/esp.img" of="$TARGET" bs=512 seek=2048 conv=notrunc status=none
    head -c $((16 * 1024 * 1024)) /dev/urandom | dd of="$TARGET" bs=512 seek=206848 conv=notrunc status=none
    dd if="$W/data.img" of="$TARGET" bs=512 seek=239616 conv=notrunc status=none
    BOOTMGR_SUM=$(sha256sum < "$W/bootmgfw.efi" | cut -d' ' -f1)
    MSR_SUM=$(part_sum 2); DATA_SUM=$(part_sum 3)
    ENTRIES_BEFORE=$(for n in 1 2 3; do part_entry "$n"; done)
    log "the target carries Windows' layout: ESP with a boot manager, MSR, data, 27 GB unallocated"
fi

ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}

# shellcheck disable=SC2054  # the commas are inside quoted QEMU arguments
qemu_args=(
    -machine "${LIVE_MACHINE/__ACCEL__/$ACCEL}" -m 4096 -smp 4
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$LIVE_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$LIVE_VARS"
    -drive "if=virtio,format=raw,file=$LIVE_IMAGE"
    -drive "if=virtio,format=raw,file=$TARGET"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0
    -device virtio-vga -display none -serial "file:$ARTIFACTS/live-serial.log" -no-reboot
    -qmp "unix:$QMP_SOCK,server,nowait"
)
[[ "$ACCEL" == kvm ]] && qemu_args+=(-cpu host)
[[ "$LIVE_CODE" == *secboot* ]] && qemu_args+=(-global "driver=cfi.pflash01,property=secure,value=on")
if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi
log "booting the live entry: $live_entry"
qemu-system-x86_64 "${qemu_args[@]}" &
QEMU_PID=$!
deadline=$(( SECONDS + BOOT_TIMEOUT ))
until ssh_guest true 2>/dev/null; do
    kill -0 "$QEMU_PID" 2>/dev/null || { echo "FAIL: QEMU exited during the live boot"; tail -30 "$ARTIFACTS/live-serial.log"; exit 1; }
    (( SECONDS < deadline )) || { echo "FAIL: the live system did not come up"; exit 1; }
    sleep 5
done
log "live system is up"

# --- the installer's own checks ----------------------------------------------
# / is the overlay; the stick's root partition under it must be mounted
# read-only (the kernel's ext4 state: one superblock, one state).
if ssh_guest "grep -q systemd.volatile=overlay /proc/cmdline && [ \"\$(findmnt -n -o FSTYPE /)\" = overlay ] \
        && grep -qx ro /proc/fs/ext4/vda2/options"; then
    pass "the live system runs with its root read-only under an overlay"
else fail "the live boot is not read-only"; fi
layout=$(ssh_guest "sg-install --layout" 2>&1 || true)
echo "$layout" > "$ARTIFACTS/layout-before.txt"
if printf '%s\n' "$layout" | grep -q '^DISK /dev/vdb' && ! printf '%s\n' "$layout" | grep -q '/dev/vda'; then
    pass "the layout offers the target disk and nothing of the disk it runs from"
else fail "--layout: $layout"; fi
if ssh_guest "echo x | sg-install --disk /dev/vda --user bob --password-stdin --yes" >/dev/null 2>&1; then
    fail "installing over the running disk was allowed"
else pass "it refuses to install over the disk it runs from"; fi
if ssh_guest "sg-install --delete /dev/vda2 --yes" >/dev/null 2>&1; then
    fail "deleting a partition of the disk it runs from was allowed"
else pass "it refuses to change the partitions of the disk it runs from"; fi
if ssh_guest "echo x | sg-install --disk /dev/vdb --user bob --password-stdin" >/dev/null 2>&1; then
    fail "it erased a disk without --yes"
else pass "it will not erase a disk without --yes"; fi
if [[ "$(ssh_guest "stat -c '%U:%G %a' /run/stained-glass-setup/installd.sock" 2>/dev/null)" == "root:sgsetup 660" ]]; then
    pass "the installer service's socket is Setup's alone (root:sgsetup 660)"
else fail "installd socket: $(ssh_guest "ls -l /run/stained-glass-setup/installd.sock" 2>&1)"; fi
# Secure Boot module signing, as Setup does it with Secure Boot on (forced
# here: the VM's firmware has it off): a key of this machine's own, DKMS told
# to sign with it, and an enrollment request the firmware holds for the next
# boot. The request is withdrawn again afterwards.
mok=$(ssh_guest "r=\$(mktemp -d); mkdir -p \$r/etc; echo mok-test > \$r/etc/hostname
    pw=\$(SG_SECUREBOOT=1 sg-drivers --secure-boot-enroll --root \$r) || { echo FAILED; exit; }
    echo \"\$pw\" | grep -Eq '^MOKPASSWORD [0-9]{8}\$' && echo password
    [ \"\$(stat -c %a \$r/var/lib/dkms/mok.key)\" = 600 ] && echo private
    openssl x509 -inform der -in \$r/var/lib/dkms/mok.pub -noout -subject | grep -q 'Stained Glass OS mok-test' && echo cert
    grep -q mok.key \$r/etc/dkms/framework.conf.d/50-stained-glass-mok.conf && echo dkms
    mokutil --list-new 2>/dev/null | grep -q 'Stained Glass OS mok-test' && echo requested
    mokutil --revoke-import >/dev/null 2>&1; rm -rf \$r" 2>&1)
echo "$mok" > "$ARTIFACTS/secure-boot.txt"
if [[ "$(printf '%s\n' "$mok" | paste -sd' ')" == "password private cert dkms requested" ]]; then
    pass "Secure Boot: a key of the machine's own, root-only, DKMS signing with it, enrollment requested with a one-time password"
else fail "Secure Boot module signing: $mok"; fi
if ssh_guest "grep -q 'non-free non-free-firmware' /etc/apt/sources.list.d/debian.sources && [ -x /usr/bin/nvidia-detect ]"; then
    pass "Debian's non-free archive is a package source, and nvidia-detect is here to choose NVIDIA drivers"
else fail "non-free sources or nvidia-detect missing"; fi

LIVE_MACHINE_ID=$(ssh_guest "cat /etc/machine-id")

# --- Setup, driven from the keyboard -----------------------------------------
qmp()  { python3 "$HERE/test/qmp.py" "$QMP_SOCK" "$@" >/dev/null; }
shot() { python3 "$HERE/test/qmp.py" "$QMP_SOCK" screendump "$ARTIFACTS/$1.ppm" >/dev/null 2>&1 || true; }
# How many times Setup has reported page $1 (the wizard logs each change).
seen() {
    local n
    n=$(ssh_guest "journalctl -b -t sg-setup --no-pager -o cat | grep -c 'page $1\$'; true" 2>/dev/null | head -1)
    echo "${n:-0}"
}
# Wait until page $1 has been reported $2 times (default 1).
page() {
    local want=${2:-1} limit=${3:-120} t=0
    until [[ "$(seen "$1")" -ge "$want" ]]; do
        (( t < limit )) || { fail "Setup never reached its '$1' page (#$want)"; shot "stuck-$1"; return 1; }
        sleep 2; t=$(( t + 2 ))
    done
    sleep 1
}
logged() { ssh_guest "journalctl -b -t sg-setup --no-pager -o cat | grep -q '$1'" 2>/dev/null; }
wait_logged() {
    local t=0
    until logged "$1"; do (( t < ${2:-90} )) || { fail "Setup never logged '$1'"; return 1; }; sleep 2; t=$(( t + 2 )); done
}
# Press Enter until page $1 has been seen $2 times: the first keys after a
# window appears can be lost (see boot-test.sh).
press_until() {
    local _
    for _ in 1 2 3 4; do
        qmp key ret
        for _ in 1 2 3 4 5; do [[ "$(seen "$1")" -ge "${2:-1}" ]] && return 0; sleep 2; done
    done
    return 1
}
t=0; until logged 'setup ready'; do
    (( t < BOOT_TIMEOUT )) || { shot stuck-setup; fail "Setup did not appear in place of the login screen"; exit 1; }
    sleep 3; t=$(( t + 3 ))
done
pass "the live system shows Setup in place of the login screen"
# Setup is up: sg-live ran before it (Before=greetd.service).
if ssh_guest "getent passwd live >/dev/null && [ -z \"\$(getent shadow live | cut -d: -f2)\" ] && id -nG live | tr ' ' '\\n' | grep -qx sgsetup"; then
    pass "the live session's account exists on the live boot, with no password"
else fail "live account: $(ssh_guest 'getent passwd live; id live' 2>&1)"; fi
if ssh_guest "test -f '/var/lib/stained-glass/prefix/drive_c/users/Public/Desktop/Install Stained Glass OS.lnk' \
        && test -f '/var/lib/stained-glass/prefix/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Install Stained Glass OS.lnk'"; then
    pass "'Install Stained Glass OS' is on the desktop and in the Start menu"
else fail "no Install shortcuts: $(ssh_guest 'journalctl -b -u sg-live --no-pager -o cat | tail -5' 2>&1)"; fi
set +e
page welcome && sleep 2 && shot setup-welcome
qmp key shift; sleep 1

# The account page, then: the owner, typed.
account() {
    qmp type "Alice Owner"; qmp key tab
    qmp type "$OWNER"; qmp key tab
    qmp type "$(cat "$OWNER_PASS_FILE")"; qmp key tab
    qmp type "$(cat "$OWNER_PASS_FILE")"; qmp key tab
    qmp type sg-installed; shot setup-account
    qmp key ret
}
# From Setup's start page on, to the partitioner. (Only the first two pages
# are seen twice on the hybrid path: the full-screen Setup is left from its
# start page.)
to_disk() {
    local n=1
    qmp key ret                                   # Install now
    page license "$n" && shot setup-license
    qmp key spc; qmp key ret                      # accept, Next
    page type "$n" && shot setup-type
    qmp key ret                                   # Custom
    page account "$n"
    account
    page disk "$n"
}

if [[ "$SCENARIO" == blank ]]; then
    press_until start 1 || fail "Setup's first page did not move on"
    shot setup-start
    qmp key tab; sleep 1; qmp key ret             # Try Stained Glass OS
    wait_logged 'sg-setup: try' 60
    log "trying the live system"
    t=0; until ssh_guest "loginctl list-sessions --no-legend | grep -qw live"; do
        (( t < BOOT_TIMEOUT )) || { fail "the live session never started"; shot stuck-try; break; }
        sleep 3; t=$(( t + 3 ))
    done
    if ssh_guest "SG_CHECK_TIMEOUT=240 runuser -u live -- /usr/bin/sg-session-check" > "$ARTIFACTS/live-session-check.log" 2>&1; then
        pass "'Try Stained Glass OS' signs in to a working live desktop"
    else fail "the live desktop's session check: $(tail -5 "$ARTIFACTS/live-session-check.log")"; fi
    sleep 3; shot live-desktop
    # What double-clicking the desktop shortcut runs: its target, as the live
    # user, in the live session. (The shortcut itself is checked for that
    # target; opening .lnk files through ShellExecute is the shell's.)
    lnk='/var/lib/stained-glass/prefix/drive_c/users/Public/Desktop/Install Stained Glass OS.lnk'
    if ssh_guest "grep -aqF 'Z:\\usr\\libexec\\stained-glass\\sg-setup64.exe' '$lnk'"; then
        pass "the desktop shortcut points at Setup"
    else fail "the desktop shortcut's target"; fi
    ssh_guest "cat > /tmp/sg-open-setup.sh" <<'EOS'
. /usr/lib/stained-glass/sg-common.sh
. "$(sg_session_env)"
export DISPLAY XDG_RUNTIME_DIR WAYLAND_DISPLAY WINEPREFIX
sg_wine_env
exec wine 'Z:\usr\libexec\stained-glass\sg-setup64.exe'
EOS
    ssh_guest "chmod 755 /tmp/sg-open-setup.sh; nohup runuser -u live -- sh /tmp/sg-open-setup.sh >/dev/null 2>&1 &"
    if page welcome 2 90; then pass "Setup, opened from the live desktop, starts its bridge and opens in a window"; fi
    sleep 3; shot setup-windowed
    qmp key shift; sleep 1
    press_until start 2
    to_disk
    wait_logged 'selected Drive 0 Unallocated Space' 60
    sleep 2; shot setup-disk
    # New on the blank disk: Refresh, then New; the size offered is all of
    # it; Apply; and OK to the system partition it needs.
    qmp key tab; qmp key tab; qmp key ret
    sleep 2; shot setup-new
    qmp key ret                                   # Apply
    sleep 2; shot setup-new-system
    qmp key ret                                   # OK: additional partitions
    wait_logged 'selected Drive 0 Partition 2' 90 && pass "New on a blank disk made a system partition and the new one, and selected it"
    sleep 2; shot setup-after-new
    qmp key ret                                   # Next
    page ready 1
else
    press_until start 1 || fail "Setup's first page did not move on"
    to_disk
    wait_logged 'selected Drive 0 Unallocated Space' 60 && pass "the partitioner preselects the unallocated space beside Windows"
    sleep 2; shot setup-disk
    qmp key ret                                   # Next
    page ready 1
fi
shot setup-ready
qmp key tab; qmp key ret                          # focus starts on Back; Tab to Install
log "installing onto /dev/vdb as $OWNER, through Setup"
page installing 1
sleep 20; shot setup-installing
page "done" 1 "$INSTALL_TIMEOUT" && shot setup-done
set -e
ssh_guest "journalctl -b -t sg-setup -t sg-installd --no-pager -o cat; journalctl -b -u 'sg-installd@*' --no-pager -o cat" \
    > "$ARTIFACTS/setup.log" 2>&1 || true
ssh_guest "sg-install --layout" > "$ARTIFACTS/layout-after.txt" 2>&1 || true
if grep -q 'page done$' "$ARTIFACTS/setup.log"; then
    pass "Setup installed Stained Glass OS"
else
    fail "Setup did not finish"; grep -E 'page|sg-installd|failed' "$ARTIFACTS/setup.log" | tail -20; exit 1
fi
qmp key ret                                       # Restart now
for _ in $(seq 1 60); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
if kill -0 "$QEMU_PID" 2>/dev/null; then
    fail "'Restart now' did not restart the machine"
    kill "$QEMU_PID" 2>/dev/null || true
else
    pass "'Restart now' restarts the machine"
fi
wait "$QEMU_PID" 2>/dev/null || true; QEMU_PID=""

# --- what else is on the disk: untouched ----------------------------------------
if [[ "$SCENARIO" == dualboot ]]; then
    tesp="$TARGET@@$((2048 * 512))"
    if [[ "$(mtype -i "$tesp" ::/EFI/Microsoft/Boot/bootmgfw.efi | sha256sum | cut -d' ' -f1)" == "$BOOTMGR_SUM" ]]; then
        pass "the Windows boot manager is byte-identical"
    else fail "the Windows boot manager changed"; fi
    if [[ "$(part_sum 2)" == "$MSR_SUM" && "$(part_sum 3)" == "$DATA_SUM" ]]; then
        pass "the reserved and data partitions are byte-identical"
    else fail "the reserved or data partition changed"; fi
    if [[ "$(for n in 1 2 3; do part_entry "$n"; done)" == "$ENTRIES_BEFORE" ]]; then
        pass "the existing partitions' table entries are unchanged"
    else fail "partition table entries changed: $(sfdisk -d "$TARGET")"; fi
    sfdisk -d "$TARGET" > "$ARTIFACTS/table-after.txt"
    if grep -qi 'type=BC13C2FF-59E6-4262-A352-B275FD6F7172' "$ARTIFACTS/table-after.txt" \
            && grep -qi 'type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709' "$ARTIFACTS/table-after.txt"; then
        pass "Setup made a boot partition and a root partition of its own in the unallocated space"
    else fail "new partitions: $(cat "$ARTIFACTS/table-after.txt")"; fi
    if mtype -i "$tesp" ::/loader/loader.conf 2>/dev/null | grep -q '^timeout 5'; then
        pass "with Windows on the disk, the boot menu is shown"
    else fail "loader.conf: $(mtype -i "$tesp" ::/loader/loader.conf 2>&1)"; fi
fi

# --- the installed disk, alone ------------------------------------------------
log "booting the installed disk alone, signing in as $OWNER"
POST_CHECK="set -e
[ \"\$(hostname)\" = sg-installed ] && echo 'PASS  hostname is the one chosen' || { echo 'FAIL  hostname'; exit 1; }
[ \"\$(cat /etc/machine-id)\" != '$LIVE_MACHINE_ID' ] && [ -s /etc/machine-id ] && echo 'PASS  a machine id of its own' || { echo 'FAIL  machine id'; exit 1; }
sz=\$(df -B1 --output=size / | tail -1); [ \"\$sz\" -gt 12000000000 ] && echo \"PASS  the root fills its partition (\$sz bytes)\" || { echo \"FAIL  root size (\$sz)\"; exit 1; }
grep -q 'root=PARTUUID=' /proc/cmdline && [ \"\$(findmnt -n -o PARTUUID /)\" = \"\$(sed -n 's/.*root=PARTUUID=\\([^ ]*\\).*/\\1/p' /proc/cmdline)\" ] && echo 'PASS  the root is named on the kernel command line, and it is the one mounted' || { echo 'FAIL  root= on the command line'; cat /proc/cmdline; exit 1; }
grep -q 'root=PARTUUID=' /etc/kernel/cmdline && echo 'PASS  later kernels get the same command line' || { echo 'FAIL  /etc/kernel/cmdline'; exit 1; }
ls /boot /efi >/dev/null 2>&1; ! ls /boot/loader/entries/ /efi/loader/entries/ 2>/dev/null | grep -q -- -live.conf && echo 'PASS  no live entry on the installed machine' || { echo 'FAIL  live entry left behind'; exit 1; }
! getent passwd sguser >/dev/null && echo 'PASS  no lab account' || { echo 'FAIL  lab account left behind'; exit 1; }
! getent passwd live >/dev/null && ! systemctl is-active --quiet sg-live.service && [ ! -e /run/stained-glass-setup/installd.sock ] && echo 'PASS  no live account and no installer service' || { echo 'FAIL  live pieces on the installed machine'; exit 1; }
id -nG $OWNER | tr ' ' '\\n' | grep -qx sg-admins && echo 'PASS  the owner is an administrator' || { echo 'FAIL  owner not in sg-admins'; exit 1; }
[ -s /etc/ssh/ssh_host_ed25519_key ] && echo 'PASS  ssh host keys generated on this machine' || { echo 'FAIL  no host keys'; exit 1; }
grep -q stained-glass-os.github.io/apt /etc/apt/sources.list.d/stained-glass.sources && [ -s /usr/share/keyrings/stained-glass-archive-keyring.gpg ] && [ -f /etc/apt/sources.list.d/debian.sources ] && echo 'PASS  Debian and the Stained Glass OS repository, with its key, are the package sources' || { echo 'FAIL  package sources'; exit 1; }
dpkg -s wine-sg sg-session >/dev/null 2>&1 && echo 'PASS  wine-sg and sg-session are installed packages' || { echo 'FAIL  packages'; exit 1; }
grep -q 'non-free non-free-firmware' /etc/apt/sources.list.d/debian.sources && echo 'PASS  the installed machine has Debian non-free and non-free-firmware' || { echo 'FAIL  non-free sources'; exit 1; }
t=0; while [ -e /etc/stained-glass/drivers.pending ] && [ \$t -lt 180 ]; do sleep 5; t=\$((t + 5)); done
[ ! -e /etc/stained-glass/drivers.pending ] && journalctl -b -u sg-drivers --no-pager -o cat | grep -q 'needs no third-party drivers' && echo 'PASS  third-party drivers, chosen in Setup, were settled at the first boot (this VM needs none)' || { echo 'FAIL  sg-drivers at the first boot'; journalctl -b -u sg-drivers --no-pager -o cat | tail -5; exit 1; }
printf '0000:01:00.0 10de 1c82 030000\\n' > /tmp/pci-current; printf '0000:01:00.0 10de 1180 030000\\n' > /tmp/pci-kepler; printf '0000:00:01.0 1af4 1050 030000\\n' > /tmp/pci-none
cur=\$(SG_DRIVERS_PCI=/tmp/pci-current sg-drivers --list | cut -f4); kep=\$(SG_DRIVERS_PCI=/tmp/pci-kepler sg-drivers --list | cut -f4); none=\$(SG_DRIVERS_PCI=/tmp/pci-none sg-drivers --list | cut -f4)
[ \"\$cur\" = 'nvidia-driver firmware-misc-nonfree linux-image-amd64 linux-headers-amd64' ] && [ \"\$kep\" = - ] && [ -z \"\$none\" ] && echo 'PASS  Debian nvidia-detect chooses: a GeForce GTX 1050 Ti gets nvidia-driver; a Kepler card nothing (nouveau stays); no NVIDIA card nothing' || { echo \"FAIL  driver choice: current='\$cur' kepler='\$kep' none='\$none'\"; exit 1; }
if timeout 300 apt-get -q update >/tmp/apt-update.log 2>&1; then
    rec=\$(SG_DRIVERS_PCI=/tmp/pci-current sg-drivers --recommended)
    apt-get -q -s install \$rec >/tmp/apt-sim.log 2>&1 && grep -q '^Inst nvidia-driver ' /tmp/apt-sim.log && grep -q '^Inst nvidia-kernel-dkms ' /tmp/apt-sim.log && echo \"PASS  apt resolves the NVIDIA set against the archive (\$rec; DKMS module included)\" || { echo 'FAIL  apt cannot resolve the NVIDIA set'; tail -15 /tmp/apt-sim.log; exit 1; }
else echo 'SKIP  the archive is unreachable from the VM: apt resolution not checked'; fi"
if [[ "$SCENARIO" == dualboot ]]; then
    POST_CHECK="$POST_CHECK
ls /boot >/dev/null; [ \"\$(lsblk -n -o PARTTYPE \"\$(findmnt -n -o SOURCE -t vfat /boot)\")\" = bc13c2ff-59e6-4262-a352-b275fd6f7172 ] && echo 'PASS  the kernels are on its own boot partition, not in Windows'\"'\"' system partition' || { echo 'FAIL  /boot'; findmnt /boot; exit 1; }
[ -f /efi/EFI/Microsoft/Boot/bootmgfw.efi ] && echo 'PASS  the Windows boot manager is still in the system partition' || { echo 'FAIL  bootmgfw.efi'; exit 1; }"
else
    POST_CHECK="$POST_CHECK
[ -d /boot/stained-glass ] && [ -f /boot/loader/loader.conf ] && echo 'PASS  the kernels are in the system partition under its own name' || { echo 'FAIL  /boot layout'; ls -R /boot | head -20; exit 1; }"
fi

set +e
SG_IMAGE="$TARGET" SG_LOGIN_USER="$OWNER" SG_LOGIN_PASSWORD_FILE="$OWNER_PASS_FILE" \
    SG_POST_CHECK="$POST_CHECK" SG_SSH_PORT="$SSH_PORT" "$HERE/test/boot-test.sh"
BRC=$?
set -e
[[ $BRC -eq 0 ]] || RC=1

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL"; fi
exit $RC
