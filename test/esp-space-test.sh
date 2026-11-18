#!/usr/bin/env bash
# A kernel update never fills the boot partition, and never fails for want of
# room on it (sg-session's sg-boot-space, 0.1.0-268) -- with real Debian
# kernel packages through apt, on a machine Setup installed (UEFI), its EFI
# system partition made nearly full on purpose (a filler file that is not
# ours, so nothing may remove it).
#
#   1. Room for one kernel: apt installs it; its entry is written, on trial.
#   2. Room for none: the next kernel package installs and apt succeeds; the
#      kernel that is neither running nor the new one is taken off the boot
#      partition to make room (its package stays installed).
#   3. No room even with every other kernel gone: apt succeeds all the same;
#      nothing is copied and nothing removed (every entry as it was); the
#      notice is left; the retry service, run with still no room, forces
#      nothing in and the notice stays.
#   4. The machine still starts (reboot) -- the notice and the kernel's entry
#      never both, never neither; with room again (the filler gone), the
#      retry puts the kernel on the boot partition and the notice goes; it
#      starts again.
# After every step: dpkg is clean (no half-configured package) and every boot
# entry names files that exist.
#
#   SG_ESP_DISK=build/install-target.raw test/esp-space-test.sh
#     an installed disk (install-test's blank scenario leaves one); the gate
#     works on a copy. SG_SESSION_DEB / SG_SHELL_DEB: packages to install on
#     it first (testing them before a release), as an upgrade would.
#   SG_ESP_MUTANT=NO_GUARD: without the kernel-install plugin (step 2 must
#     fail: ENOSPC inside dpkg).
# Needs KVM, OVMF and the Debian archive (apt); skips (77) without.
# shellcheck disable=SC2015,SC2016,SC2317  # pass || fail; guest commands in single quotes; cleanup via trap
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
SRC="${SG_ESP_DISK:-$BUILD/install-target.raw}"
SSH_KEY="$BUILD/ssh/id_ed25519"
SSH_PORT="${SG_SSH_PORT:-2228}"
W="$BUILD/esp-space-test"
DISK="$W/disk.raw"
QEMU_PID=""
PATH="$PATH:/usr/sbin:/sbin"
RC=0
log()  { echo "[esp-space-test] $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[[ -f "$SRC" ]] || { echo "no installed disk at $SRC -- make install-blank-test (or SG_ESP_DISK=)"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- make image"; exit 2; }
[[ -r /dev/kvm ]] || { echo "SKIP: needs KVM"; exit 77; }
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
[[ -f "$OVMF_CODE" ]] || { echo "SKIP: no OVMF"; exit 77; }
rm -rf "$W"; mkdir -p "$W"
cleanup() { set +e; [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; wait 2>/dev/null; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM

ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
scp_guest() {
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -P "$SSH_PORT" "$@"
}
if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi

log "copying $SRC"
cp --reflink=auto "$SRC" "$DISK"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$W/vars.fd"
start_vm() {
    # shellcheck disable=SC2054  # commas inside QEMU arguments
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$W/vars.fd" \
        -drive "if=virtio,format=raw,file=$DISK" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0 \
        -device virtio-vga -display none -serial "file:$W/serial.log" \
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
reboot_to() { ssh_guest "systemctl reboot" >/dev/null 2>&1 || true; sleep 15; wait_up "$1"; }
stop_vm() {
    ssh_guest "systemctl poweroff" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
    kill "$QEMU_PID" 2>/dev/null || true; wait "$QEMU_PID" 2>/dev/null || true; QEMU_PID=""
}

# the guest's view: free bytes on /efi, our entries, dangling entries, dpkg state
G_FREE='ls /efi >/dev/null 2>&1; df -B1 --output=avail /efi | tail -1 | tr -d " "'
# (restore points' entries left out: sg-snapshot makes one at each apt run)
G_ENTRIES='ls /efi >/dev/null 2>&1; ls /efi/loader/entries | grep -v "^Sg-" | sort'
# every file an entry names exists (restore points' too)
G_DANGLING='for e in /efi/loader/entries/*.conf; do sed -n "s/^\(linux\|initrd\)[[:space:]]\{1,\}//p" "$e" | sed "s/[[:space:]]*$//" | while read -r f; do [ -f "/efi$f" ] || echo "${e##*/} -> $f"; done; done'
clean_state() {
    local d a
    d=$(ssh_guest "$G_DANGLING")
    a=$(ssh_guest "dpkg --audit 2>&1; dpkg -l 'linux-image*' | awk 'NR > 5 && \$1 !~ /^(ii|un|rc|hi)\$/'")
    [[ -z "$d" ]] && pass "$1: every entry names files that exist" || fail "$1: dangling entries: $d"
    [[ -z "$a" ]] && pass "$1: dpkg clean (nothing half-installed)" || fail "$1: dpkg: $a"
}
# fill_to BYTES: the filler file grown or shrunk so BYTES are free on /efi
fill_to() {
    ssh_guest "ls /efi >/dev/null 2>&1; f=\$(df -B1 --output=avail /efi | tail -1 | tr -d ' '); cur=\$(stat -c %s /efi/sg-gate-filler 2>/dev/null || echo 0);
        n=\$(( cur + f - $1 )); [ \$n -lt 0 ] && n=0; rm -f /efi/sg-gate-filler; [ \$n -gt 0 ] && fallocate -l \$n /efi/sg-gate-filler 2>/dev/null || head -c \$n /dev/zero > /efi/sg-gate-filler; sync"
}
apt_install() {   # rc of apt; its output in $W/apt-N.log
    ssh_guest "DEBIAN_FRONTEND=noninteractive apt-get install -y $*" > "$W/apt-$STEP.log" 2>&1
}

MB=$((1024 * 1024))
log "starting the installed disk (UEFI)"
start_vm
wait_up 300 || { fail "the installed disk did not come up"; exit 1; }
for deb in ${SG_SESSION_DEB:-} ${SG_SHELL_DEB:-}; do
    scp_guest "$deb" root@127.0.0.1:/var/tmp/ >/dev/null && ssh_guest "dpkg -i /var/tmp/${deb##*/}" > "$W/dpkg-${deb##*/}.log" 2>&1 \
        && pass "installed ${deb##*/} (as an upgrade)" || { fail "dpkg -i ${deb##*/}"; exit 1; }
done
ssh_guest "test -x /usr/lib/kernel/install.d/85-sg-boot-space.install" || { fail "the image has no sg-boot-space (sg-session 0.1.0-268)"; exit 1; }
if [[ "${SG_ESP_MUTANT:-}" == NO_GUARD ]]; then
    log "MUTANT: no kernel-install plugin"
    ssh_guest "rm -f /usr/lib/kernel/install.d/85-sg-boot-space.install"
fi
RUN=$(ssh_guest "uname -r")
RT="${RUN/-amd64/-rt-amd64}" CLOUD="${RUN/-amd64/-cloud-amd64}"
ssh_guest "apt-get update -qq" > "$W/apt-update.log" 2>&1
ssh_guest "apt-cache show linux-image-$RT linux-image-$CLOUD" >/dev/null 2>&1 \
    || { echo "SKIP: linux-image-$RT / -$CLOUD not in the archive (or no network)"; exit 77; }
log "running $RUN; extra kernels: $RT, $CLOUD; ESP free $(ssh_guest "$G_FREE")"

# --- 1. room for one ----------------------------------------------------------
STEP=1
fill_to $((130 * MB))
apt_install "linux-image-$RT" && pass "1: room for one kernel: apt installs $RT" || fail "1: apt failed (log $W/apt-1.log)"
ssh_guest "ls /efi/loader/entries/*-$RT+3.conf" >/dev/null 2>&1 && pass "1: its entry, on trial" || fail "1: no entry for $RT: $(ssh_guest "$G_ENTRIES" | tr '\n' ' ')"
clean_state 1

# --- 2. room for none: the other kernel makes room ----------------------------
STEP=2
fill_to $((10 * MB))
apt_install "linux-image-$CLOUD"; rc=$?
[[ $rc == 0 ]] && pass "2: no room: apt installs $CLOUD all the same" || fail "2: apt rc $rc (log $W/apt-2.log: $(grep -i 'space\|error' "$W/apt-2.log" | head -3 | tr '\n' ' '))"
E=$(ssh_guest "$G_ENTRIES")
grep -q -- "-$CLOUD+3.conf" <<<"$E" && pass "2: $CLOUD has its entry" || fail "2: no entry for $CLOUD: $(tr '\n' ' ' <<<"$E")"
! grep -q -- "-$RT" <<<"$E" && ssh_guest "! test -d /efi/*/$RT" && pass "2: $RT (neither running nor new) taken off the boot partition" \
    || fail "2: $RT still there: $(tr '\n' ' ' <<<"$E")"
ssh_guest "dpkg -s linux-image-$RT >/dev/null && test -f /boot/vmlinuz-$RT" && pass "2: ...its package and /boot files stay" || fail "2: $RT's package or /boot files gone"
grep -q -- "-$RUN" <<<"$E" && pass "2: the running kernel's entry stays" || fail "2: running $RUN's entry gone"
clean_state 2

# --- 3. no room even with every other kernel gone: nothing touched --------------
STEP=3
fill_to $((2 * MB))
BEFORE=$(ssh_guest "$G_ENTRIES")
apt_install "--reinstall linux-image-$RT"; rc=$?
[[ $rc == 0 ]] && pass "3: no room at all: apt succeeds" || fail "3: apt rc $rc (log $W/apt-3.log)"
[[ "$(ssh_guest "$G_ENTRIES")" == "$BEFORE" ]] && pass "3: nothing copied, nothing removed: every entry as it was" \
    || fail "3: entries changed: $(ssh_guest "$G_ENTRIES" | tr '\n' ' ')"
ssh_guest "grep -qx 'kernel=$RT' /var/lib/stained-glass/notices/boot-space" && pass "3: the notice names $RT" || fail "3: no notice"
ssh_guest "systemctl is-enabled sg-boot-space-retry.service" >/dev/null 2>&1 && pass "3: the retry service is enabled" || fail "3: sg-boot-space-retry.service not enabled"
ssh_guest "systemctl start sg-boot-space-retry.service" > "$W/retry-full.log" 2>&1
[[ "$(ssh_guest "$G_ENTRIES")" == "$BEFORE" ]] && ssh_guest "test -f /var/lib/stained-glass/notices/boot-space" \
    && pass "3: the retry with still no room: nothing forced in, the notice stays" || fail "3: retry without room: $(ssh_guest "$G_ENTRIES" | tr '\n' ' ')"
clean_state 3

# --- 4. it still starts; the retry with room ------------------------------------
STEP=4
reboot_to 300 && pass "4: the machine starts ($(ssh_guest "uname -r"))" || { fail "4: no start after the full-ESP update"; exit 1; }
sleep 10
# (started on another kernel, the one it ran before may now make room at the
# boot's retry: then the kernel is there and the notice gone -- never one
# without the other)
n_rt=$(ssh_guest "ls /efi >/dev/null 2>&1; ls /efi/loader/entries/ | grep -c -- '-$RT\(+[0-9-]*\)\{0,1\}\.conf\$'")
if ssh_guest "test -f /var/lib/stained-glass/notices/boot-space"; then
    [[ "$n_rt" == 0 ]] && pass "4: after the start: still no room, the notice stays, no entry" || fail "4: a notice and an entry for $RT"
else
    [[ "$n_rt" -ge 1 ]] && pass "4: after the start: the boot's retry found room (the previous kernel no longer running), $RT is there and the notice gone" \
        || fail "4: the notice went without $RT's entry"
fi
ssh_guest "rm -f /efi/sg-gate-filler; sync; systemctl start sg-boot-space-retry.service" > "$W/retry.log" 2>&1
ssh_guest "ls /efi/loader/entries/*-$RT+3.conf /efi/loader/entries/*-$RT.conf 2>/dev/null | grep -q ." && pass "4: room again: $RT is on the boot partition" \
    || fail "4: retry did not add $RT: $(ssh_guest "$G_ENTRIES" | tr '\n' ' ')"
ssh_guest "! test -f /var/lib/stained-glass/notices/boot-space" && pass "4: ...and the notice is gone" || fail "4: notice kept after the kernel fitted"
clean_state 4
reboot_to 300 && pass "4: and it starts again ($(ssh_guest "uname -r"))" || fail "4: no start after the retry"
stop_vm

[[ $RC == 0 ]] && echo "[esp-space-test] GATE PASS" || echo "[esp-space-test] GATE FAIL"
exit "$RC"
