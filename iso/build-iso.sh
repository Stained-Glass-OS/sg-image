#!/bin/bash
# Turn the finished disk image into a bootable ISO: burn it, attach it to a
# virtual machine's CD drive, or write it to a USB stick (it is hybrid). It
# boots UEFI and legacy BIOS machines straight into the live system -- try Stained Glass OS,
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
#   live/build-id     matches the initrd's copy: which ISO it belongs to
#   boot/grub/        GRUB for legacy BIOS (El Torito image, and the MBR's
#                     code on a stick): the live entries of efi.img, read from it
# plus loader/sg-live.initrd inside efi.img: iso/sg-live-iso, which finds
# the medium in the initrd (a block device, or the .iso file on a partition
# of a multiboot stick such as Ventoy) and attaches root.erofs.
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
# Which ISO this initrd belongs to (sg-live-iso checks the medium's copy): a
# multiboot stick often holds several releases.
BUILD_ID=$(cat /proc/sys/kernel/random/uuid)
mkdir -p "$W/initrd/usr/lib/sg-live/modules"
echo "$BUILD_ID" > "$W/initrd/usr/lib/sg-live/build-id"
echo "$BUILD_ID" > "$W/iso/live/build-id"
# The file systems a multiboot stick (Ventoy) keeps the .iso file on -- not in
# the image's own initrd, which only needs its own disk.
sudo mount -o ro,loop,offset=$((root_start * 512)),sizelimit=$((root_size * 512)) "$IMG" "$MNT"
for m in fs/fat/fat fs/fat/vfat fs/exfat/exfat fs/ntfs3/ntfs3 fs/nls/nls_cp437 fs/nls/nls_iso8859-1 fs/nls/nls_utf8; do
    ko=$(ls "$MNT"/usr/lib/modules/*/kernel/$m.ko* 2>/dev/null | head -1)
    [[ -n "$ko" ]] || { echo "build-iso: the image has no $m module" >&2; sudo umount "$MNT"; exit 1; }
    cp "$ko" "$W/initrd/usr/lib/sg-live/modules/"
done
# sg-session's nouveau guard, in the initrd too (nouveau loads there): an
# NVIDIA card nouveau cannot run without missing firmware keeps the firmware
# framebuffer instead of losing every display (sg-session's sg-nouveau-guard).
if [[ -f "$MNT/usr/lib/modprobe.d/sg-nouveau-guard.conf" && -f "$MNT/usr/lib/stained-glass/sg-nouveau-guard" ]]; then
    mkdir -p "$W/initrd/usr/lib/modprobe.d" "$W/initrd/usr/lib/stained-glass"
    cp "$MNT/usr/lib/modprobe.d/sg-nouveau-guard.conf" "$W/initrd/usr/lib/modprobe.d/"
    install -m 0755 "$MNT/usr/lib/stained-glass/sg-nouveau-guard" "$W/initrd/usr/lib/stained-glass/"
else
    log "warning: the image has no sg-nouveau-guard (sg-session older than 0.1.0-287)"
fi
sudo umount "$MNT"
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
        -e 's/^options \(.*\)$/options \1 root=LABEL=SGLIVEROOT rootfstype=erofs ro systemd.volatile=overlay sg.live=iso systemd.default_device_timeout_sec=300/' \
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

# --- legacy BIOS: GRUB (i386-pc) from the same entries ----------------------------
# A BIOS machine boots the El Torito image boot/grub/i386-pc/eltorito.img (CD),
# or the MBR code (GRUB's boot_hybrid.img), which loads it (USB stick). GRUB
# reads the kernels and initrds out of efi.img itself (loopback): the live
# entries are the UEFI ones, line for line -- same kernel, initrds, options.
log "adding the legacy BIOS boot loader (GRUB)"
GRUB_PC=/usr/lib/grub/i386-pc
[[ -f "$GRUB_PC/boot_hybrid.img" ]] || { echo "build-iso: GRUB for BIOS is missing (apt install grub-pc-bin)" >&2; exit 1; }
mkdir -p "$W/iso/boot/grub/i386-pc"
cp "$GRUB_PC"/*.mod "$GRUB_PC"/*.lst "$W/iso/boot/grub/i386-pc/"
# This medium's own GRUB finds this medium (several ISOs on one machine): a
# file named after the build.
: > "$W/iso/boot/grub/$BUILD_ID.mark"
# Floppies are searched too: a BIOS that boots a stick as USB-FDD/USB-ZIP
# shows it to GRUB as a floppy, and --no-floppy left GRUB without its prefix
# (the "grub rescue>" prompt).
cat > "$W/early.cfg" <<EOF
search --set=root --file /boot/grub/$BUILD_ID.mark
set prefix=(\$root)/boot/grub
EOF
grub-mkimage -O i386-pc-eltorito -c "$W/early.cfg" -p /boot/grub -o "$W/iso/boot/grub/i386-pc/eltorito.img" \
    biosdisk iso9660 part_gpt part_msdos fat loopback search search_fs_file configfile normal linux echo test \
    gzio all_video gfxterm || { echo "build-iso: grub-mkimage failed" >&2; exit 1; }
{
    printf 'set timeout=3\nset default=0\nloopback esp /boot/efi.img\n'
    printf 'insmod all_video\nterminal_output console\n'
    for e in "$W"/esp/loader/entries/*-live.conf; do
        awk '
            /^title / { sub(/^title /, ""); title = $0 }
            /^linux / { linux = $2 }
            /^initrd / { initrd = initrd " (esp)" $2 }
            /^options / { sub(/^options /, ""); options = $0 }
            END {
                printf "menuentry \"%s\" {\n", title
                printf "    linux (esp)%s %s\n", linux, options
                printf "    initrd%s\n", initrd
                printf "}\n"
            }' "$e"
    done
} > "$W/iso/boot/grub/grub.cfg"

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
Stained Glass OS -- live and installation medium (UEFI or legacy BIOS).

Stained Glass OS is not Microsoft Windows and is not affiliated with Microsoft;
see NOTICE.txt.

Boot it (a DVD, a virtual machine's CD drive, or a USB stick written with
dd or any image writer, or copied as a file onto a Ventoy stick) and choose
"Stained Glass OS (live: try or install)".
Nothing on the computer changes until you run Setup.
EOF
rm -f "$OUT"
# El Torito: the BIOS image first (a BIOS boots the default entry), then the
# UEFI one; the MBR boot code for a BIOS booting the stick as a disk. UEFI
# boots exactly as before: the EFI El Torito entry, and the appended ESP.
# --mbr-force-bootable: an MBR entry marked active beside the GPT's
# protective one -- many legacy BIOSes (Lenovo's among them) pass over a
# disk whose MBR has no active partition and start the next one: the
# internal disk's own boot loader (grub rescue, emergency mode) instead of
# this stick. Ubuntu's ISOs carry the same entry.
xorriso -as mkisofs -quiet -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock \
    -volid SGLIVE -output "$OUT" \
    -b boot/grub/i386-pc/eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
    --grub2-mbr "$GRUB_PC/boot_hybrid.img" --mbr-force-bootable \
    -eltorito-alt-boot -e boot/efi.img -no-emul-boot \
    -append_partition 2 0xef "$W/iso/boot/efi.img" -appended_part_as_gpt \
    "$W/iso"
log "done: $OUT ($(du -h "$OUT" | cut -f1))"
