#!/usr/bin/env bash
# The staged-update gate: updates download while the machine runs and install
# on the next reboot -- as on Windows and PureOS (vision backlog F3).
#
# A canary package proves it end to end:
#   1. boot the image; install sg-update-canary 1.0;
#   2. publish 2.0 in a local test repository inside the guest;
#   3. run sg-update-prepare, as its daily timer would;
#   4. assert 2.0 is downloaded and the next boot is marked -- but that 1.0 is
#      still installed: nothing may change under a running system;
#   5. reboot; the offline-update boot installs 2.0 and reboots again;
#   6. assert 2.0 is installed, the mark is cleared, and the machine still
#      reaches its login screen.
#
# The test repository is unsigned and marked trusted, inside a throwaway VM,
# for the canary only. The real repository is signed; see
# stained-glass/docs/package-repository.md.
#
# Knobs as boot-test.sh: SG_BOOT_TIMEOUT, SG_SSH_PORT, SG_VM_MEM, SG_VM_CPUS,
# SG_IMAGE, SG_KEEP_VM.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
BUILD="$HERE/build"
IMAGE="${SG_IMAGE:-$BUILD/sg-image.raw}"
SSH_KEY="$BUILD/ssh/id_ed25519"
ARTIFACTS="$BUILD/artifacts"
SERIAL_LOG="$ARTIFACTS/update-serial.log"
SSH_PORT="${SG_SSH_PORT:-2222}"
MEM="${SG_VM_MEM:-4096}"
CPUS="${SG_VM_CPUS:-4}"
ACCEL=tcg; [[ -w /dev/kvm ]] && ACCEL=kvm
BOOT_TIMEOUT="${SG_BOOT_TIMEOUT:-300}"
[[ "$ACCEL" == tcg ]] && BOOT_TIMEOUT=$((BOOT_TIMEOUT * 6))

log()  { echo "[update-test] $*"; }
fail() { echo "[update-test] FAIL: $*" >&2; }

WORK=$(mktemp -d)
QEMU_PID=""
# shellcheck disable=SC2317  # invoked through the EXIT trap
cleanup() {
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        if [[ "${SG_KEEP_VM:-0}" == 1 ]]; then
            log "SG_KEEP_VM=1 -- leaving the guest running (qemu pid $QEMU_PID)"
        else
            kill "$QEMU_PID" 2>/dev/null || true
        fi
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

[[ -f "$IMAGE"   ]] || { fail "image not found at $IMAGE -- run 'make image' first"; exit 2; }
[[ -f "$SSH_KEY" ]] || { fail "ssh key not found at $SSH_KEY -- run 'make image' first"; exit 2; }
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -f "$c" ]] && { OVMF_CODE="$c"; break; }
done
[[ -n "$OVMF_CODE" ]] || { fail "no OVMF firmware found"; exit 2; }
mkdir -p "$ARTIFACTS"; : > "$SERIAL_LOG"

# --- the canary, in two versions -----------------------------------------------
canary() {  # canary VERSION -> builds $WORK/sg-update-canary_VERSION_all.deb
    local v=$1 d="$WORK/canary-$1"
    mkdir -p "$d/DEBIAN" "$d/usr/share/sg-update-canary"
    echo "$v" > "$d/usr/share/sg-update-canary/VERSION"
    cat > "$d/DEBIAN/control" <<EOF
Package: sg-update-canary
Version: $v
Architecture: all
Maintainer: Stained Glass OS <dev@stained-glass.example>
Description: test-only package for the staged-update gate
 Installed and upgraded by sg-image's update-test.sh. Never shipped.
EOF
    dpkg-deb --root-owner-group --build "$d" "$WORK/sg-update-canary_${v}_all.deb" >/dev/null
}
canary 1.0
canary 2.0
mkdir -p "$WORK/repo"
cp "$WORK/sg-update-canary_2.0_all.deb" "$WORK/repo/"
( cd "$WORK/repo" && apt-ftparchive packages . > Packages && apt-ftparchive release . > Release )

# --- boot ---------------------------------------------------------------------------
# Unlike boot-test.sh there is no -no-reboot: this test reboots the guest, and
# the offline-update boot reboots it again by itself.
RUN_IMAGE="$BUILD/update-disk.raw"
RUN_VARS="$BUILD/update-vars.fd"
cp --reflink=auto "$IMAGE" "$RUN_IMAGE"
cp "${OVMF_CODE/CODE/VARS}" "$RUN_VARS"
log "booting: accel=$ACCEL mem=${MEM}M ssh=localhost:$SSH_PORT"
# shellcheck disable=SC2054  # the commas are inside quoted QEMU arguments
qemu_args=(
    -machine "q35,accel=$ACCEL" -m "$MEM" -smp "$CPUS"
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$RUN_VARS"
    -drive "if=virtio,format=raw,file=$RUN_IMAGE"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device virtio-net-pci,netdev=net0
    -device virtio-vga -display none
    -serial "file:$SERIAL_LOG"
)
[[ "$ACCEL" == kvm ]] && qemu_args+=(-cpu host)
# lab ssh: the gate key as a systemd credential (tmpfiles writes it to
# /root/.ssh/authorized_keys); the image itself carries no key
qemu_args+=(-smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$SSH_KEY.pub")")
qemu-system-x86_64 "${qemu_args[@]}" &
QEMU_PID=$!

ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
wait_ssh_up() {
    local deadline=$(( SECONDS + $1 ))
    until ssh_guest true 2>/dev/null; do
        kill -0 "$QEMU_PID" 2>/dev/null || { fail "QEMU exited"; tail -30 "$SERIAL_LOG"; exit 1; }
        (( SECONDS < deadline )) || { fail "no ssh after $1s"; tail -30 "$SERIAL_LOG"; exit 1; }
        sleep 3
    done
}
wait_ssh_down() {
    local deadline=$(( SECONDS + $1 ))
    while ssh_guest true 2>/dev/null; do
        (( SECONDS < deadline )) || { fail "the guest did not go down within $1s"; exit 1; }
        sleep 2
    done
}
send() { ssh_guest "cat > '$2'" < "$1"; }

wait_ssh_up "$BOOT_TIMEOUT"
log "ssh is up"

# --- 1. install the canary, 2. publish the update -----------------------------------
send "$WORK/sg-update-canary_1.0_all.deb" /var/tmp/sg-update-canary_1.0_all.deb
ssh_guest "dpkg -i /var/tmp/sg-update-canary_1.0_all.deb >/dev/null && mkdir -p /var/tmp/sg-test-repo"
for f in sg-update-canary_2.0_all.deb Packages Release; do
    send "$WORK/repo/$f" "/var/tmp/sg-test-repo/$f"
done
# Only the test repository: with Debian's own sources live, a real security
# update could join the transaction and make the test depend on the day it runs.
ssh_guest "mkdir -p /etc/apt/sources.list.d \
    && for f in /etc/apt/sources.list.d/*.sources; do [ -e \"\$f\" ] && mv \"\$f\" \"\$f.disabled\"; done; \
    echo 'deb [trusted=yes] file:/var/tmp/sg-test-repo ./' > /etc/apt/sources.list.d/sg-update-test.list"

RC=0
pass() { printf 'PASS  %s\n' "$*"; }
check_fail() { printf 'FAIL  %s\n' "$*"; RC=1; }
canary_version() { ssh_guest "dpkg-query -W -f '\${Version}' sg-update-canary" 2>/dev/null; }

v=$(canary_version)
if [[ "$v" == 1.0 ]]; then pass "canary 1.0 installed"; else check_fail "canary before: '$v'"; fi

# --- 3. download, as the timer would ------------------------------------------------
log "running sg-update-prepare"
ssh_guest "systemctl start sg-update-prepare.service; journalctl -u sg-update-prepare -b --no-pager -o cat" \
    > "$ARTIFACTS/update-prepare.log" 2>&1 || true
sed 's/^/    /' "$ARTIFACTS/update-prepare.log" | tail -8

# --- 4. staged, not applied ------------------------------------------------------------
if ssh_guest "test -L /system-update"; then pass "the next boot is marked for installing updates"
else check_fail "no /system-update mark after sg-update-prepare"; fi
v=$(canary_version)
if [[ "$v" == 1.0 ]]; then pass "nothing installed yet: canary still 1.0 while running"
else check_fail "canary changed before the reboot: '$v'"; fi

# --- 5. reboot through the offline update ---------------------------------------------
log "rebooting to install"
ssh_guest "systemctl reboot" 2>/dev/null || true
wait_ssh_down 120
log "installing and rebooting (no ssh during the update boot)"
wait_ssh_up $(( BOOT_TIMEOUT * 2 ))

# --- 6. applied, and the machine still works -----------------------------------------
v=$(canary_version)
if [[ "$v" == 2.0 ]]; then pass "canary 2.0 installed by the offline update"
else check_fail "canary after the update boot: '$v'"; fi
if ssh_guest "test ! -e /system-update"; then pass "the update mark is cleared"
else check_fail "/system-update still present: the next boot would update again"; fi
ssh_guest "journalctl -b -1 -u packagekit-offline-update --no-pager -o cat" \
    > "$ARTIFACTS/offline-update.log" 2>&1 || true
deadline=$(( SECONDS + BOOT_TIMEOUT ))
until ssh_guest "journalctl -b -t sg-login --no-pager -o cat | grep -q 'greeter ready'" 2>/dev/null; do
    (( SECONDS < deadline )) || break
    sleep 3
done
if ssh_guest "journalctl -b -t sg-login --no-pager -o cat | grep -q 'greeter ready'" 2>/dev/null; then
    pass "the updated machine reaches its login screen"
else
    check_fail "no login screen after the update"
fi

echo
if [[ $RC -eq 0 ]]; then echo "RESULT: PASS"; log "GATE PASS"; else echo "RESULT: FAIL"; log "GATE FAIL"; fi
exit $RC
