#!/usr/bin/env bash
# The Phase 0 gate, host side.
#
# Boots the image headless in QEMU, waits for ssh, and runs sg-session-check in
# the guest. Saves a screenshot either way, because a failing gate with no
# picture is a bad afternoon.
#
# Exit code is the gate's verdict.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
ARTIFACTS="$BUILD/artifacts"
IMAGE="${SG_IMAGE:-$BUILD/sg-image.raw}"
SSH_KEY="$BUILD/ssh/id_ed25519"

SSH_PORT="${SG_SSH_PORT:-2222}"
MEM="${SG_VM_MEM:-4096}"
CPUS="${SG_VM_CPUS:-4}"

# TCG is roughly an order of magnitude slower than KVM, and a Wine session
# start is not a light workload, so the budget scales with the accelerator.
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ACCEL=kvm
    BOOT_TIMEOUT="${SG_BOOT_TIMEOUT:-300}"
    CHECK_TIMEOUT="${SG_CHECK_TIMEOUT:-180}"
else
    ACCEL=tcg
    BOOT_TIMEOUT="${SG_BOOT_TIMEOUT:-1800}"
    CHECK_TIMEOUT="${SG_CHECK_TIMEOUT:-900}"
fi

QMP_SOCK="$BUILD/qmp.sock"
SERIAL_LOG="$ARTIFACTS/serial.log"
QEMU_PID=""

log()  { echo "[boot-test] $*"; }
fail() { echo "[boot-test] FAIL: $*" >&2; }

cleanup() {
    local rc=$?
    if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
        log "shutting down the VM"
        python3 "$HERE/test/qmp.py" "$QMP_SOCK" quit >/dev/null 2>&1 || true
        # Give QEMU a moment to go on its own before insisting.
        for _ in $(seq 1 20); do
            kill -0 "$QEMU_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
    rm -f "$QMP_SOCK"
    exit $rc
}
trap cleanup EXIT INT TERM

# --- preflight -------------------------------------------------------------
[[ -f "$IMAGE"   ]] || { fail "image not found at $IMAGE -- run 'make image' first"; exit 2; }
[[ -f "$SSH_KEY" ]] || { fail "ssh key not found at $SSH_KEY -- run 'make image' first"; exit 2; }

OVMF_CODE=""
for candidate in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
                 /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF_CODE.fd; do
    [[ -f "$candidate" ]] && { OVMF_CODE="$candidate"; break; }
done
[[ -n "$OVMF_CODE" ]] || { fail "no OVMF firmware found; install the 'ovmf' package"; exit 2; }
OVMF_VARS_SRC="${OVMF_CODE/CODE/VARS}"
[[ -f "$OVMF_VARS_SRC" ]] || { fail "no OVMF vars template beside $OVMF_CODE"; exit 2; }

mkdir -p "$ARTIFACTS"
: > "$SERIAL_LOG"

# The image and the firmware vars are both written to during a boot. Work on
# copies so the gate is repeatable and never mutates the build output.
RUN_IMAGE="$BUILD/run-disk.raw"
RUN_VARS="$BUILD/run-vars.fd"
log "copying image for this run"
cp --reflink=auto "$IMAGE" "$RUN_IMAGE"
cp "$OVMF_VARS_SRC" "$RUN_VARS"

# --- boot ------------------------------------------------------------------
log "booting: accel=$ACCEL mem=${MEM}M cpus=$CPUS ssh=localhost:$SSH_PORT"
rm -f "$QMP_SOCK"

qemu_args=(
    -machine "q35,accel=$ACCEL"
    -m "$MEM"
    -smp "$CPUS"
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$RUN_VARS"
    -drive "if=virtio,format=raw,file=$RUN_IMAGE"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    -device virtio-net-pci,netdev=net0
    # virtio-gpu gives the compositor a real DRM device without a host GPU.
    -device virtio-vga
    -display none
    -serial "file:$SERIAL_LOG"
    -qmp "unix:$QMP_SOCK,server,nowait"
    -no-reboot
)
[[ "$ACCEL" == kvm ]] && qemu_args+=(-cpu host)

qemu-system-x86_64 "${qemu_args[@]}" &
QEMU_PID=$!

ssh_guest() {
    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        -p "$SSH_PORT" root@127.0.0.1 "$@"
}

# --- wait for the guest ----------------------------------------------------
log "waiting up to ${BOOT_TIMEOUT}s for ssh"
deadline=$(( SECONDS + BOOT_TIMEOUT ))
until ssh_guest true 2>/dev/null; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        fail "QEMU exited during boot"
        tail -40 "$SERIAL_LOG" | sed 's/^/    /'
        exit 1
    fi
    if (( SECONDS >= deadline )); then
        fail "guest did not come up for ssh within ${BOOT_TIMEOUT}s"
        python3 "$HERE/test/qmp.py" "$QMP_SOCK" screendump "$ARTIFACTS/screenshot-boot-timeout.ppm" || true
        tail -60 "$SERIAL_LOG" | sed 's/^/    /'
        exit 1
    fi
    sleep 5
done
log "ssh is up after $(( BOOT_TIMEOUT - (deadline - SECONDS) ))s"

# --- the actual check ------------------------------------------------------
# sg-session-check must run as the session user: it talks to that session's
# X display and inspects that user's Wine processes.
log "running sg-session-check in the guest"
set +e
ssh_guest "SG_CHECK_TIMEOUT=$CHECK_TIMEOUT runuser -u sguser -- /usr/bin/sg-session-check" 2>&1 | tee "$ARTIFACTS/session-check.log"
RC=${PIPESTATUS[0]}
set -e

# --- evidence --------------------------------------------------------------
# Always screenshot. A passing gate should show a desktop; a failing one shows
# whatever went wrong, which is usually more informative than the log.
log "capturing screenshot"
SHOT="$ARTIFACTS/screenshot.ppm"
if python3 "$HERE/test/qmp.py" "$QMP_SOCK" screendump "$SHOT"; then
    if command -v qemu-img >/dev/null && command -v convert >/dev/null 2>&1; then
        convert "$SHOT" "$ARTIFACTS/screenshot.png" 2>/dev/null || true
    fi
    log "screenshot: $SHOT"
else
    fail "could not capture a screenshot"
fi

ssh_guest "journalctl -b --no-pager" > "$ARTIFACTS/journal.log" 2>/dev/null || true

echo
if [[ $RC -eq 0 ]]; then
    log "GATE PASS"
else
    log "GATE FAIL (rc=$RC) -- artifacts in $ARTIFACTS"
fi
exit $RC
