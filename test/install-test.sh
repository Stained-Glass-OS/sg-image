#!/usr/bin/env bash
# The F5 gate: install Stained Glass from the live system onto a blank disk,
# then boot that disk alone and sign in as the owner the installer created.
#
#   1. boot the image through its "live" entry (root read-only under an
#      overlay) with a second, blank disk attached;
#   2. sg-install refuses the disk it runs from and lists the blank one;
#      then Setup -- the wizard the live system shows where the login screen
#      would be -- is driven through QEMU's keyboard, as a person would: it
#      installs onto the blank disk as a new owner with a generated password,
#      and its "Restart now" restarts the machine;
#   3. power off; boot the installed disk ALONE (fresh firmware variables, no
#      stick) and run the full boot gate as that owner -- sign in by typing,
#      session check, lock and unlock -- plus checks of what the installer
#      did: its own hostname and machine id, the root grown to the disk, no
#      live entry, no lab account.
#
# Needs mtools, and what boot-test.sh needs.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
IMAGE="${SG_IMAGE:-$BUILD/sg-image.raw}"
SSH_KEY="$BUILD/ssh/id_ed25519"
SSH_PORT="${SG_SSH_PORT:-2223}"
TARGET="$BUILD/install-target.raw"
TARGET_BYTES="${SG_TARGET_BYTES:-24G}"
LIVE_IMAGE="$BUILD/install-live.raw"
LIVE_VARS="$BUILD/install-live-vars.fd"
OWNER=alice
OWNER_PASS_FILE="$BUILD/install-owner-password"
ARTIFACTS="$BUILD/artifacts-install"
QMP_SOCK="$BUILD/install-qmp.sock"
QEMU_PID=""

log()  { echo "[install-test] $*"; }
fail() { echo "[install-test] FAIL: $*" >&2; RC=1; }
RC=0

[[ -f "$IMAGE" ]] || { echo "no image at $IMAGE -- run 'make image'"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- run 'make image'"; exit 2; }
if [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm; BOOT_TIMEOUT=300; INSTALL_TIMEOUT=900
else ACCEL=tcg; BOOT_TIMEOUT=1800; INSTALL_TIMEOUT=5400; fi
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { OVMF_CODE=$c; break; }; done
[[ -n "$OVMF_CODE" ]] || { echo "no OVMF"; exit 2; }

rm -rf "$ARTIFACTS"; mkdir -p "$ARTIFACTS"
# shellcheck disable=SC2317  # invoked via trap
cleanup() { set +e; [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM

# The owner's password: generated here, lower-case letters and digits so it
# types as plain keys, never committed.
python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_lowercase + string.digits) for _ in range(14)), end="")' > "$OWNER_PASS_FILE"
chmod 600 "$OWNER_PASS_FILE"

# --- the stick: a copy of the image that boots its live entry ---------------
log "preparing the live medium and a blank ${TARGET_BYTES} disk"
cp --reflink=auto "$IMAGE" "$LIVE_IMAGE"
cp "${OVMF_CODE/CODE/VARS}" "$LIVE_VARS"
rm -f "$TARGET"; truncate -s "$TARGET_BYTES" "$TARGET"
# The ESP is edited in place with mtools, as mkosi.postoutput does.
esp_start=$(/usr/sbin/sfdisk -d "$LIVE_IMAGE" | awk -F'[ ,=]+' 'toupper($0) ~ /TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ {
    for (i = 1; i <= NF; i++) if ($i == "start") { print $(i + 1); exit } }')
ESP="$LIVE_IMAGE@@$((esp_start * 512))"
export MTOOLS_SKIP_CHECK=1
live_entry=$(mdir -b -i "$ESP" ::/loader/entries | sed -n 's#.*/\([^/]*-live\.conf\)$#\1#p' | head -1)
[[ -n "$live_entry" ]] || { echo "FAIL: the image has no live boot entry (mkosi.postoutput)"; exit 1; }
printf 'default %s\ntimeout 0\n' "$live_entry" > "$ARTIFACTS/loader.conf"
mcopy -o -i "$ESP" "$ARTIFACTS/loader.conf" ::/loader/loader.conf
log "booting the live entry: $live_entry"

ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}

# shellcheck disable=SC2054  # the commas are inside quoted QEMU arguments
qemu_args=(
    -machine "q35,accel=$ACCEL" -m 4096 -smp 4
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$LIVE_VARS"
    -drive "if=virtio,format=raw,file=$LIVE_IMAGE"
    -drive "if=virtio,format=raw,file=$TARGET"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0
    -device virtio-vga -display none -serial "file:$ARTIFACTS/live-serial.log" -no-reboot
    -qmp "unix:$QMP_SOCK,server,nowait"
)
[[ "$ACCEL" == kvm ]] && qemu_args+=(-cpu host)
if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi
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
    echo "PASS  the live system runs with its root read-only under an overlay"
else fail "the live boot is not read-only"; fi
disks=$(ssh_guest "sg-install --list" 2>&1 || true)
echo "$disks" > "$ARTIFACTS/disks.txt"
if printf '%s\n' "$disks" | grep -q '^/dev/vdb' && ! printf '%s\n' "$disks" | grep -q '^/dev/vda'; then
    echo "PASS  --list offers the blank disk and not the one it runs from"
else fail "--list: $disks"; fi
if ssh_guest "echo x | sg-install --disk /dev/vda --user bob --password-stdin --yes" >/dev/null 2>&1; then
    fail "installing over the running disk was allowed"
else echo "PASS  it refuses to install over the disk it runs from"; fi
if ssh_guest "echo x | sg-install --disk /dev/vdb --user bob --password-stdin" >/dev/null 2>&1; then
    fail "it erased a disk without --yes"
else echo "PASS  it will not erase a disk without --yes"; fi

LIVE_MACHINE_ID=$(ssh_guest "cat /etc/machine-id")

# --- Setup, driven from the keyboard -----------------------------------------
qmp()  { python3 "$HERE/test/qmp.py" "$QMP_SOCK" "$@" >/dev/null; }
shot() { python3 "$HERE/test/qmp.py" "$QMP_SOCK" screendump "$ARTIFACTS/$1.ppm" >/dev/null 2>&1 || true; }
# Wait until Setup has reported page $1 (the wizard logs each page change).
page() {
    local limit=${2:-120} t=0
    until ssh_guest "journalctl -b -t sg-setup --no-pager -o cat | grep -q 'page $1\$'" 2>/dev/null; do
        (( t < limit )) || { fail "Setup never reached its '$1' page"; shot "stuck-$1"; return 1; }
        sleep 2; t=$(( t + 2 ))
    done
    sleep 1
}
if [[ "$(ssh_guest "stat -c '%U:%G %a' /run/stained-glass-setup/installd.sock" 2>/dev/null)" == "root:sggreet 660" ]]; then
    echo "PASS  the installer service's socket is the login screen's alone (root:sggreet 660)"
else fail "installd socket: $(ssh_guest "ls -l /run/stained-glass-setup/installd.sock" 2>&1)"; fi
if ! ssh_guest "journalctl -b -t sg-setup --no-pager -o cat | grep -q 'setup ready'" 2>/dev/null; then
    t=0; until ssh_guest "journalctl -b -t sg-setup --no-pager -o cat | grep -q 'setup ready'" 2>/dev/null; do
        (( t < BOOT_TIMEOUT )) || { shot stuck-setup; fail "Setup did not appear in place of the login screen"; exit 1; }
        sleep 3; t=$(( t + 3 ))
    done
fi
echo "PASS  the live system shows Setup in place of the login screen"
set +e
page welcome && sleep 2 && shot setup-welcome
# The first keys after the window appears can be lost (see boot-test.sh);
# warm up with Shift, which cannot press anything, and press "Install now"
# again only while the page has not changed.
qmp key shift; sleep 1
seen() { ssh_guest "journalctl -b -t sg-setup --no-pager -o cat | grep -q 'page $1\$'" 2>/dev/null; }
for _ in 1 2 3; do
    qmp key ret
    for _ in 1 2 3 4 5; do seen disk && break 2; sleep 2; done
done
page disk
sleep 3; shot setup-disk
qmp key ret
page account
qmp type "Alice Owner"; qmp key tab
qmp type "$OWNER"; qmp key tab
qmp type "$(cat "$OWNER_PASS_FILE")"; qmp key tab
qmp type "$(cat "$OWNER_PASS_FILE")"; qmp key tab
qmp type sg-installed; shot setup-account
qmp key ret
page ready && shot setup-ready
qmp key tab; qmp key ret                      # focus starts on Back; Tab to Install
log "installing onto /dev/vdb as $OWNER, through Setup"
page installing
page "done" "$INSTALL_TIMEOUT" && shot setup-done
set -e
ssh_guest "journalctl -b -t sg-setup -t sg-installd --no-pager -o cat; journalctl -b -u 'sg-installd@*' --no-pager -o cat" \
    > "$ARTIFACTS/setup.log" 2>&1 || true
if grep -q 'page done$' "$ARTIFACTS/setup.log"; then
    echo "PASS  Setup installed Stained Glass"
else
    fail "Setup did not finish"; grep -E 'page|sg-installd' "$ARTIFACTS/setup.log" | tail -20; exit 1
fi
qmp key ret                                   # Restart now
for _ in $(seq 1 60); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
if kill -0 "$QEMU_PID" 2>/dev/null; then
    fail "'Restart now' did not restart the machine"
    kill "$QEMU_PID" 2>/dev/null || true
else
    echo "PASS  'Restart now' restarts the machine"
fi
wait "$QEMU_PID" 2>/dev/null || true; QEMU_PID=""

# --- the installed disk, alone ------------------------------------------------
log "booting the installed disk alone, signing in as $OWNER"
POST_CHECK="set -e
[ \"\$(hostname)\" = sg-installed ] && echo 'PASS  hostname is the one chosen' || { echo 'FAIL  hostname'; exit 1; }
[ \"\$(cat /etc/machine-id)\" != '$LIVE_MACHINE_ID' ] && [ -s /etc/machine-id ] && echo 'PASS  a machine id of its own' || { echo 'FAIL  machine id'; exit 1; }
sz=\$(df -B1 --output=size / | tail -1); [ \"\$sz\" -gt 12000000000 ] && echo \"PASS  root grown to the disk (\$sz bytes)\" || { echo \"FAIL  root not grown (\$sz)\"; exit 1; }
! ls /boot/loader/entries/ /efi/loader/entries/ 2>/dev/null | grep -q -- -live.conf && echo 'PASS  no live entry on the installed machine' || { echo 'FAIL  live entry left behind'; exit 1; }
! getent passwd sguser >/dev/null && echo 'PASS  no lab account' || { echo 'FAIL  lab account left behind'; exit 1; }
id -nG $OWNER | tr ' ' '\\n' | grep -qx sg-admins && echo 'PASS  the owner is an administrator' || { echo 'FAIL  owner not in sg-admins'; exit 1; }
[ -s /etc/ssh/ssh_host_ed25519_key ] && echo 'PASS  ssh host keys generated on this machine' || { echo 'FAIL  no host keys'; exit 1; }"

set +e
SG_IMAGE="$TARGET" SG_LOGIN_USER="$OWNER" SG_LOGIN_PASSWORD_FILE="$OWNER_PASS_FILE" \
    SG_POST_CHECK="$POST_CHECK" SG_SSH_PORT="$SSH_PORT" "$HERE/test/boot-test.sh"
BRC=$?
set -e
[[ $BRC -eq 0 ]] || RC=1

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL"; fi
exit $RC
