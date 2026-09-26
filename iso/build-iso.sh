#!/bin/bash
# Turn the finished disk image into a bootable ISO: burn it, attach it to a
# virtual machine's CD drive, or write it to a USB stick (it is hybrid). It
# boots UEFI machines straight into the live system -- try Stained Glass OS,
# or run Setup from it to install.
#
#   iso/build-iso.sh IMAGE OUTPUT.iso
#
# Layout of the ISO (volume label SGLIVE):
#   boot/efi.img      the EFI system partition: El Torito boot image, and the
#                     GPT partition a USB stick boots from. Its only boot entry
#                     is the live one; the plain entry the installer copies to
#                     the disk is kept in loader/install/, where the boot
#                     loader does not look.
#   live/root.erofs   the image's root file system, compressed, read-only.
# plus loader/sg-live.initrd inside efi.img: iso/sg-live-iso, which finds
# the medium in the initrd and attaches root.erofs.
#
# Needs root (sudo) only to read the image's ext4 root file system.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
IMG=${1:?usage: build-iso.sh IMAGE OUTPUT.iso}
OUT=${2:?usage: build-iso.sh IMAGE OUTPUT.iso}
HERE=$(cd "$(dirname "$0")" && pwd)
log() { echo "[iso] $*"; }
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
ROOT_TYPE=4f68bce3-e8cd-4db1-96e7-fbcaf984b709

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-iso.XXXXXX")
MNT="$W/root"
cleanup() {
    mountpoint -q "$MNT" 2>/dev/null && sudo umount "$MNT"
    sudo rm -rf "$W"
}
trap cleanup EXIT

part() { # start and size in sectors of the partition of type $1
    /usr/sbin/sfdisk -J "$IMG" | python3 -c '
import json, sys
t = sys.argv[1]
for p in json.load(sys.stdin)["partitiontable"]["partitions"]:
    if p["type"].lower() == t:
        print(p["start"], p["size"]); break' "$1"
}
read -r esp_start _ < <(part $ESP_TYPE)
read -r root_start root_size < <(part $ROOT_TYPE)
[[ -n "$esp_start" && -n "$root_start" ]] || { echo "build-iso: $IMG has no ESP and root partition" >&2; exit 1; }
export MTOOLS_SKIP_CHECK=1
SRC_ESP="$IMG@@$((esp_start * 512))"

mkdir -p "$W/iso/boot" "$W/iso/live" "$W/esp" "$W/initrd/usr/libexec" \
    "$W/initrd/usr/lib/systemd/system/initrd-root-device.target.wants" "$MNT"

# --- the live initrd -----------------------------------------------------------
install -m 0755 "$HERE/sg-live-iso" "$W/initrd/usr/libexec/sg-live-iso"
install -m 0644 "$HERE/sg-live-iso.service" "$W/initrd/usr/lib/systemd/system/sg-live-iso.service"
ln -s ../sg-live-iso.service "$W/initrd/usr/lib/systemd/system/initrd-root-device.target.wants/sg-live-iso.service"
(cd "$W/initrd" && find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc --quiet --owner=0:0) > "$W/sg-live.initrd"

# --- the EFI system partition --------------------------------------------------
log "copying the system partition"
mcopy -s -n -i "$SRC_ESP" ::/ "$W/esp/"
rm -f "$W/esp/loader/random-seed"
mkdir -p "$W/esp/loader/install"
# The image's own live entries (mkosi.postoutput) boot a USB stick's root
# partition; they are replaced, not kept.
rm -f "$W"/esp/loader/entries/*-live.conf
live=0
for e in "$W"/esp/loader/entries/*.conf; do
    base=${e##*/}
    mv "$e" "$W/esp/loader/install/$base"
    sed -e 's/^title .*/title Stained Glass OS (live: try or install)/' \
        -e 's/^options \(.*\)$/options \1 root=LABEL=SGLIVEROOT rootfstype=erofs ro systemd.volatile=overlay sg.live=iso/' \
        "$W/esp/loader/install/$base" > "$W/esp/loader/entries/${base%.conf}-live.conf"
    echo "initrd /loader/sg-live.initrd" >> "$W/esp/loader/entries/${base%.conf}-live.conf"
    live=$((live + 1))
done
[[ $live -gt 0 ]] || { echo "build-iso: no boot entries in the image's ESP" >&2; exit 1; }
cp "$W/sg-live.initrd" "$W/esp/loader/sg-live.initrd"
printf 'timeout 3\ndefault *-live.conf\n' > "$W/esp/loader/loader.conf"
kib=$(( $(du -sk "$W/esp" | cut -f1) + 16384 ))
mkfs.vfat -C -n SGLIVEESP "$W/iso/boot/efi.img" "$kib" >/dev/null
mcopy -s -i "$W/iso/boot/efi.img" "$W"/esp/* ::/

# --- the root file system --------------------------------------------------------
# Kept beside the ISO and reused while the image is unchanged: compressing is
# most of the time a rebuild takes.
ROOT_CACHE="${OUT%.iso}-root.erofs"
if [[ -f "$ROOT_CACHE" && "$ROOT_CACHE" -nt "$IMG" ]]; then
    log "reusing $ROOT_CACHE (the image is unchanged)"
else
    log "compressing the root file system (a few minutes)"
    sudo mount -o ro,loop,offset=$((root_start * 512)),sizelimit=$((root_size * 512)) "$IMG" "$MNT"
    rm -f "$ROOT_CACHE"
    # mkfs.erofs spools fragment data in TMPDIR: keep it off a tmpfs /tmp.
    sudo TMPDIR="$(dirname "$ROOT_CACHE")" mkfs.erofs -zlzma,level=6 -Eall-fragments,dedupe -L SGLIVEROOT --quiet "$ROOT_CACHE.tmp" "$MNT/"
    sudo umount "$MNT"
    sudo chown "$(id -u):$(id -g)" "$ROOT_CACHE.tmp"
    mv "$ROOT_CACHE.tmp" "$ROOT_CACHE"
fi
ln "$ROOT_CACHE" "$W/iso/live/root.erofs" 2>/dev/null || cp "$ROOT_CACHE" "$W/iso/live/root.erofs"

# --- the ISO -------------------------------------------------------------------------
log "writing $OUT"
NOTICE='Stained Glass OS is NOT Microsoft Windows.

It is an independent, free and open-source operating system designed to be
compatible with Windows programs. It is not a Microsoft product, contains no
Microsoft code, and is not affiliated with, endorsed by, or sponsored by
Microsoft Corporation in any way. Windows is a trademark of Microsoft
Corporation.

Project and source: https://freesoft.page -- https://github.com/Stained-Glass-OS'
printf '%s\n' "$NOTICE" > "$W/iso/NOTICE.txt"
cat > "$W/iso/README.txt" <<'EOF'
Stained Glass OS -- live and installation medium (UEFI).

Stained Glass OS is not Microsoft Windows and is not affiliated with Microsoft;
see NOTICE.txt.

Boot it (a DVD, a virtual machine's CD drive, or a USB stick written with
dd or any image writer) and choose "Stained Glass OS (live: try or install)".
Nothing on the computer changes until you run Setup.
EOF
rm -f "$OUT"
xorriso -as mkisofs -quiet -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock \
    -volid SGLIVE -output "$OUT" \
    -eltorito-alt-boot -e boot/efi.img -no-emul-boot \
    -append_partition 2 0xef "$W/iso/boot/efi.img" -appended_part_as_gpt \
    "$W/iso"
log "done: $OUT ($(du -h "$OUT" | cut -f1))"
