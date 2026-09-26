#!/usr/bin/env bash
# The live boot, timed and watched: from the firmware to Setup, with the
# Stained Glass splash on the screen and no text console (QA B2, B4).
#
# Boots the ISO as a CD (as a person does) beside a blank disk, takes a
# screendump every 2 s, and waits for Setup ("setup ready" in the journal).
# Then it records where the time went -- systemd-analyze, blame, the critical
# chain to greetd, sg-prefix-init's phases -- and checks:
#   - the splash: a frame with the four tiles of the diamond (purple, magenta,
#     amber, turquoise) on a dark screen
#   - no text console: after the splash first shows, no frame until Setup is
#     the kernel/systemd text console (grey text on black)
#   - the time to Setup is under SG_BOOT_BUDGET seconds (default 90)
#
#   make boot-time-test            (ISO=build/sg-live.iso)
#   ARTIFACTS=DIR keeps the frames (PNG), the profile and the serial log.
# Run under flock /home/david/Stained-Glass-OS/.sg-image.lock.
set -uo pipefail
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$HERE/build"
ISO="${ISO:-$BUILD/sg-live.iso}"
ARTIFACTS="${ARTIFACTS:-$BUILD/boot-time}"
BUDGET="${SG_BOOT_BUDGET:-90}"
SSH_PORT="${SSH_PORT:-2239}"
ACCEL=kvm; [[ -w /dev/kvm ]] || ACCEL=tcg
OVMF_CODE=/usr/share/OVMF/OVMF_CODE_4M.fd
OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.fd
RC=0
log()  { echo "boot-time: $*"; }
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

[[ -f "$ISO" ]] || { echo "SKIP: no ISO at $ISO (make iso)"; exit 77; }
command -v convert >/dev/null || { echo "SKIP: ImageMagick missing"; exit 77; }
rm -rf "$ARTIFACTS"; mkdir -p "$ARTIFACTS/frames"
W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-boot-time.XXXXXX")
QMP_SOCK="$W/qmp.sock"
SSH_KEY="$W/key"
ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY"
cp "$OVMF_VARS_SRC" "$W/vars.fd"
truncate -s 24G "$W/target.raw"
ssh_guest() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -o ConnectTimeout=5 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
if ssh_guest true 2>/dev/null; then echo "FAIL: something already answers on port $SSH_PORT -- a VM left over?"; exit 1; fi
cleanup() {
    set +e
    [[ -n "${SHOTS:-}" ]] && kill "$SHOTS" 2>/dev/null
    [[ -n "${QEMU_PID:-}" ]] && kill "$QEMU_PID" 2>/dev/null && wait "$QEMU_PID" 2>/dev/null
    rm -rf "$W"
}
trap cleanup EXIT INT TERM

# shellcheck disable=SC2054  # the commas are inside quoted QEMU arguments
qemu_args=(
    -machine "q35,accel=$ACCEL" -m 6144 -smp 4
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,unit=1,file=$W/vars.fd"
    -drive "if=none,id=live,format=raw,media=cdrom,readonly=on,file=$ISO" -device ide-cd,drive=live,bootindex=0
    -drive "if=virtio,format=raw,file=$W/target.raw"
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" -device virtio-net-pci,netdev=net0
    -device virtio-vga -display none -serial "file:$ARTIFACTS/serial.log" -no-reboot
    -qmp "unix:$QMP_SOCK,server,nowait"
    -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$SSH_KEY.pub")"
)
[[ "$ACCEL" == kvm ]] && qemu_args+=(-cpu host)
log "booting $ISO ($ACCEL)"
START=$SECONDS
qemu-system-x86_64 "${qemu_args[@]}" &
QEMU_PID=$!
# a frame every 2 s, named by the second it was taken
(
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        t=$(( SECONDS - START ))
        python3 "$HERE/test/qmp.py" "$QMP_SOCK" screendump "$ARTIFACTS/frames/$(printf %04d "$t").ppm" >/dev/null 2>&1
        sleep 2
    done
) &
SHOTS=$!

setup_at=""
until [[ -n "$setup_at" ]]; do
    kill -0 "$QEMU_PID" 2>/dev/null || { fail "QEMU exited during the boot"; tail -30 "$ARTIFACTS/serial.log"; exit 1; }
    (( SECONDS - START < 600 )) || { fail "Setup did not appear within 600 s"; break; }
    if ssh_guest "journalctl -b -t sg-setup --no-pager -o cat 2>/dev/null | grep -q 'setup ready'" 2>/dev/null; then
        setup_at=$(( SECONDS - START ))
    fi
    sleep 2
done
sleep 4
kill "$SHOTS" 2>/dev/null; SHOTS=""

# --- where the time went ---------------------------------------------------------
{
    echo "== wall clock: QEMU start to Setup ready (polled every 2 s): ${setup_at:-never} s"
    echo "== journal: 'setup ready', monotonic (s since the kernel started)"
    ssh_guest "journalctl -b -t sg-setup -o short-monotonic --no-pager | grep 'setup ready' | head -1"
    echo "== systemd-analyze"; ssh_guest "systemd-analyze"
    echo "== blame (top 25)"; ssh_guest "systemd-analyze blame --no-pager | head -25"
    echo "== critical chain to greetd"; ssh_guest "systemd-analyze critical-chain --no-pager greetd.service"
    echo "== sg-prefix-init, and what it logged"
    ssh_guest "journalctl -b -u sg-prefix-init -o short-monotonic --no-pager | head -60"
    echo "== plymouth"; ssh_guest "systemctl is-active plymouth-start.service plymouth-quit.service 2>&1; cat /proc/cmdline"
    echo "== os-release"; ssh_guest "ls -l /etc/os-release; cat /etc/os-release"
} > "$ARTIFACTS/profile.txt" 2>&1
sed -n '1,12p' "$ARTIFACTS/profile.txt"
readymono=$(ssh_guest "journalctl -b -t sg-setup -o short-monotonic --no-pager | grep 'setup ready' | head -1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'" 2>/dev/null)
fw=$(ssh_guest "systemd-analyze | head -1" 2>/dev/null | sed -n 's/.* \([0-9.]*\)s (firmware).*/\1/p')
ld=$(ssh_guest "systemd-analyze | head -1" 2>/dev/null | sed -n 's/.* \([0-9.]*\)s (loader).*/\1/p')
total=$(python3 -c "import sys; print(round(float(sys.argv[1] or 0) + float(sys.argv[2] or 0) + float(sys.argv[3] or 0)))" "${readymono:-0}" "${fw:-0}" "${ld:-0}" 2>/dev/null)
log "firmware ${fw:-?}s + loader ${ld:-?}s + kernel to Setup ${readymono:-?}s = ${total:-?}s"
echo "== firmware+loader+kernel-to-Setup: ${total:-?} s" >> "$ARTIFACTS/profile.txt"

# --- the frames --------------------------------------------------------------------
# For each frame (one pixel in 16): the share of pixels near each tile
# colour, of dark pixels, and of the text console's grey (170,170,170).
analyse() {
    python3 - "$1" <<'PY'
import sys
tiles = [(0x8A,0x2B,0xE2), (0xC0,0x2B,0x8A), (0xE0,0x9A,0x1E), (0x1E,0xC0,0xB0)]
data = open(sys.argv[1], "rb").read()
# binary PPM (P6): magic, width, height, maxval, one whitespace, then RGB
fields = []; i = 0
while len(fields) < 4:
    while data[i:i+1].isspace(): i += 1
    j = i
    while not data[j:j+1].isspace(): j += 1
    fields.append(data[i:j]); i = j
i += 1
w, h = int(fields[1]), int(fields[2])
px = data[i:i + w * h * 3]
n = 0; near = [0]*4; dark = 0; grey = 0
for y in range(0, h, 4):
    row = y * w * 3
    for x in range(0, w, 4):
        k = row + x * 3
        r, g, b = px[k], px[k+1], px[k+2]; n += 1
        if r < 40 and g < 40 and b < 40: dark += 1; continue
        if abs(r-170) < 12 and abs(g-170) < 12 and abs(b-170) < 12: grey += 1
        for t, (tr, tg, tb) in enumerate(tiles):
            if abs(r-tr) < 40 and abs(g-tg) < 40 and abs(b-tb) < 40: near[t] += 1
n = max(n, 1)
splash = all(k / n > 0.0005 for k in near) and dark / n > 0.6
text = grey / n > 0.004 and dark / n > 0.8 and not splash
print("splash" if splash else "text" if text else "other", "%.4f" % (min(near) / n), "%.3f" % (dark / n), "%.4f" % (grey / n))
PY
}
first_splash=""; texts_after=""; : > "$ARTIFACTS/frames.txt"
for f in "$ARTIFACTS"/frames/*.ppm; do
    [[ -s "$f" ]] || continue
    t=$(basename "$f" .ppm); t=$((10#$t))
    [[ -n "$setup_at" ]] && (( t > setup_at )) && { rm -f "$f"; continue; }
    a=$(analyse "$f"); echo "$t $a" >> "$ARTIFACTS/frames.txt"
    case "$a" in
    splash*) [[ -z "$first_splash" ]] && first_splash=$t ;;
    text*)   [[ -n "$first_splash" ]] && texts_after="$texts_after $t" ;;
    esac
    convert "$f" -resize 50% "${f%.ppm}.png" 2>/dev/null && rm -f "$f"
done

[[ -n "$setup_at" ]] && pass "Setup appeared ${setup_at}s after QEMU started (firmware to Setup ${total:-?}s)" || fail "no Setup"
[[ -n "$first_splash" ]] && pass "the Stained Glass splash is on the screen (first at ${first_splash}s)" \
    || fail "no frame showed the splash (frames.txt)"
[[ -n "$first_splash" && -z "$texts_after" ]] && pass "no text console after the splash, up to Setup" \
    || fail "the text console showed after the splash at:${texts_after:- (no splash)}"
[[ -n "$total" && "$total" -le "$BUDGET" ]] && pass "firmware to Setup in ${total}s, within ${BUDGET}s" \
    || fail "firmware to Setup took ${total:-?}s (budget ${BUDGET}s)"

# --- who the system says it is (QA B3) ---------------------------------------------
osr=$(ssh_guest "cat /etc/os-release" 2>/dev/null)
osv() { sed -n "s/^$1=\"\\{0,1\\}\\([^\"]*\\)\"\\{0,1\\}\$/\\1/p" <<<"$osr" | head -1; }
if [[ "$(osv ID)" == stained-glass && "$(osv ID_LIKE)" == debian && "$(osv NAME)" == "Stained Glass OS" \
      && "$(osv PRETTY_NAME)" == "Stained Glass OS "* && -n "$(osv VERSION_ID)" && -n "$(osv IMAGE_VERSION)" ]]; then
    pass "os-release: $(osv PRETTY_NAME) (ID=$(osv ID), VERSION_ID=$(osv VERSION_ID), IMAGE_VERSION=$(osv IMAGE_VERSION))"
else
    fail "os-release is not Stained Glass OS: $(osv PRETTY_NAME) (ID=$(osv ID))"
fi
[[ "$(ssh_guest "readlink /etc/os-release" 2>/dev/null)" == ../usr/lib/os-release ]] \
    && pass "/etc/os-release links to /usr/lib/os-release" || fail "/etc/os-release is not the link to /usr/lib/os-release"

[[ $RC = 0 ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
