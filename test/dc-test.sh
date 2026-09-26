#!/usr/bin/env bash
# The domain controller gate (D2): the image's DC role.
#
# Boots the image and runs sg-dc-provision for the test domain SGTEST.LAN with
# a password generated here (never committed), then checks the directory the
# way a Windows member would find and use it:
#
#   - the workstation role runs no Samba server at all until a role is chosen
#   - a weak Administrator password is refused, and provisioning twice is
#   - DNS: the domain's SRV records (_ldap, _kerberos) and the DC's A record
#   - Kerberos: a ticket for Administrator with the right password, none with
#     a wrong one
#   - the directory: a user created with samba-tool exists and can get a ticket
#   - SMB: the sysvol and netlogon shares, with a Kerberos ticket
#   - after a reboot it all comes back
#
# Needs what boot-test.sh needs.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$HERE/build"
IMAGE="${SG_IMAGE:-$BUILD/sg-image.raw}"
SSH_KEY="$BUILD/ssh/id_ed25519"
SSH_PORT="${SG_SSH_PORT:-2225}"
RUN_IMAGE="${SG_DC_RUN_IMAGE:-$BUILD/dc-run.raw}"
RUN_VARS="$BUILD/dc-run-vars.fd"
ARTIFACTS="$BUILD/artifacts-dc"
ADMIN_PASS_FILE="$BUILD/dc-admin-password"
REALM=SGTEST.LAN
QEMU_PID=""
RC=0

log()  { echo "[dc-test] $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

[[ -f "$IMAGE" ]] || { echo "no image at $IMAGE -- run 'make image'"; exit 2; }
[[ -f "$SSH_KEY" ]] || { echo "no ssh key -- run 'make image'"; exit 2; }
if [[ -r /dev/kvm && -w /dev/kvm ]]; then ACCEL=kvm; BOOT_TIMEOUT=300; else ACCEL=tcg; BOOT_TIMEOUT=1800; fi
OVMF_CODE=""
for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$c" ]] && { OVMF_CODE=$c; break; }; done
[[ -n "$OVMF_CODE" ]] || { echo "no OVMF"; exit 2; }
rm -rf "$ARTIFACTS"; mkdir -p "$ARTIFACTS"
# shellcheck disable=SC2317  # invoked via trap
cleanup() { set +e; [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM

# An Administrator password AD's default policy accepts: upper, lower, digits.
python3 -c 'import secrets, string
a = string.ascii_letters + string.digits
while True:
    p = "".join(secrets.choice(a) for _ in range(16))
    if any(c.islower() for c in p) and any(c.isupper() for c in p) and any(c.isdigit() for c in p): break
print(p, end="")' > "$ADMIN_PASS_FILE"
chmod 600 "$ADMIN_PASS_FILE"

ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
boot() {
    # shellcheck disable=SC2054  # the commas are inside quoted QEMU arguments
    local args=(
        -machine "q35,accel=$ACCEL" -m 4096 -smp 4
        -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,unit=1,file=$RUN_VARS"
        -drive "if=virtio,format=raw,file=$RUN_IMAGE"
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0
        -device virtio-vga -display none -serial "file:$ARTIFACTS/serial-$1.log" -no-reboot
    )
    [[ "$ACCEL" == kvm ]] && args+=(-cpu host)
    # lab ssh: the gate key as a systemd credential (tmpfiles writes it to
    # /root/.ssh/authorized_keys); the image itself carries no key
    args+=(-smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$SSH_KEY.pub")")
    qemu-system-x86_64 "${args[@]}" &
    QEMU_PID=$!
    local deadline=$(( SECONDS + BOOT_TIMEOUT ))
    until ssh_guest true 2>/dev/null; do
        kill -0 "$QEMU_PID" 2>/dev/null || { echo "FAIL: QEMU exited"; exit 1; }
        (( SECONDS < deadline )) || { echo "FAIL: no ssh"; exit 1; }
        sleep 5
    done
}
shutdown_guest() {
    ssh_guest "systemctl poweroff" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 2; done
    kill "$QEMU_PID" 2>/dev/null || true; wait "$QEMU_PID" 2>/dev/null || true; QEMU_PID=""
}

if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi
if [[ -z "${SG_DC_RUN_IMAGE:-}" || ! -f "$RUN_IMAGE" ]]; then
    log "copying image for this run"
    cp --reflink=auto "$IMAGE" "$RUN_IMAGE"
fi
cp "${OVMF_CODE/CODE/VARS}" "$RUN_VARS"
boot first
log "guest is up"

running=$(ssh_guest "systemctl is-active smbd nmbd samba-ad-dc 2>/dev/null | grep -c '^active'" || true)
if [[ "$running" == 0 ]]; then pass "a workstation runs no Samba server until a role is chosen"
else fail "Samba servers running on a workstation: $(ssh_guest 'systemctl is-active smbd nmbd samba-ad-dc')"; fi

if ssh_guest "echo short | sg-dc-provision --realm $REALM --admin-password-stdin" >/dev/null 2>&1; then
    fail "a weak Administrator password was accepted"
else pass "a weak Administrator password is refused"; fi

log "provisioning $REALM"
if ssh_guest "sg-dc-provision --realm $REALM --admin-password-stdin" < "$ADMIN_PASS_FILE" > "$ARTIFACTS/provision.log" 2>&1; then
    pass "sg-dc-provision made the machine the DC for $REALM"
else
    fail "provisioning failed: $(tail -5 "$ARTIFACTS/provision.log")"
    ssh_guest "cat /var/log/sg-dc-provision.log" > "$ARTIFACTS/samba-provision.log" 2>&1 || true
    exit 1
fi
if ssh_guest "echo 'Xx1xxxxxxx' | sg-dc-provision --realm $REALM --admin-password-stdin" >/dev/null 2>&1; then
    fail "provisioning twice was allowed"
else pass "it refuses to provision twice"; fi

checks() {
    local when=$1
    if ssh_guest "host -t SRV _ldap._tcp.sgtest.lan 127.0.0.1 | grep -q 'dc1.sgtest.lan' && host -t SRV _kerberos._udp.sgtest.lan 127.0.0.1 | grep -q dc1 && host dc1.sgtest.lan 127.0.0.1 | grep -q 'has address'" 2>/dev/null; then
        pass "$when: DNS answers the domain's SRV records and the DC's address"
    else fail "$when: DNS: $(ssh_guest 'host -t SRV _ldap._tcp.sgtest.lan 127.0.0.1' 2>&1)"; fi
    if ssh_guest "kdestroy -A 2>/dev/null; kinit administrator@$REALM >/dev/null && klist | grep -q krbtgt/$REALM@$REALM" < "$ADMIN_PASS_FILE" 2>/dev/null; then
        pass "$when: Kerberos gives Administrator a ticket"
    else fail "$when: no ticket for Administrator"; fi
    if ssh_guest "kdestroy -A 2>/dev/null; echo wrong-password | kinit administrator@$REALM" >/dev/null 2>&1; then
        fail "$when: a wrong password got a ticket"
    else pass "$when: a wrong password gets none"; fi
    if ssh_guest "kinit administrator@$REALM >/dev/null && smbclient -k //dc1.sgtest.lan/netlogon -c ls >/dev/null && smbclient -k //dc1.sgtest.lan/sysvol -c ls >/dev/null" < "$ADMIN_PASS_FILE" 2>/dev/null; then
        pass "$when: the netlogon and sysvol shares answer, with a Kerberos ticket"
    else fail "$when: SMB: $(ssh_guest 'smbclient -k //dc1.sgtest.lan/netlogon -c ls' 2>&1 | tail -2)"; fi
}
checks provisioned

USER_PASS="Us3r$(python3 -c 'import secrets; print(secrets.token_hex(6))')"
if ssh_guest "samba-tool user create alice '$USER_PASS' --given-name=Alice --surname=Test >/dev/null && samba-tool user list | grep -qx alice"; then
    pass "a user created in the directory is listed"
else fail "user create failed"; fi
if ssh_guest "kdestroy -A 2>/dev/null; echo '$USER_PASS' | kinit alice@$REALM >/dev/null && klist | grep -q 'alice@$REALM'" 2>/dev/null; then
    pass "and gets a Kerberos ticket with its password"
else fail "no ticket for the new user"; fi

log "rebooting"
shutdown_guest
boot second
t=0; until ssh_guest "systemctl is-active -q samba-ad-dc" 2>/dev/null || (( t > 120 )); do sleep 3; t=$(( t + 3 )); done
sleep 10
checks "after a reboot"

ssh_guest "journalctl -b --no-pager" > "$ARTIFACTS/journal.log" 2>/dev/null || true
if grep -rq "$(cat "$ADMIN_PASS_FILE")" "$ARTIFACTS"; then fail "the Administrator password appears in the artifacts"
else pass "the Administrator password appears nowhere in the artifacts"; fi
shutdown_guest

echo
if [[ $RC -eq 0 ]]; then log "GATE PASS"; else log "GATE FAIL -- artifacts in $ARTIFACTS"; fi
exit $RC
