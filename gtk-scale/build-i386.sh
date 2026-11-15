#!/bin/bash
# GTK 3 and GTK 4 for i386, patched as build-debs.sh patches them for amd64.
#
#   gtk-scale/build-i386.sh gtk3|gtk4 CACHE_DIR OUT_DIR
#
# GTK's libraries are Multi-Arch: same: a machine with the i386 copy (Steam's
# dependencies pull libgtk-3-0t64:i386) needs it at exactly the amd64 copy's
# version, or apt cannot take our GTK at all -- not on an image that installs
# Steam, not on a Debian machine turned into a Stained Glass one. So the
# repository carries the i386 builds too, built from the same Debian source,
# patch and version by build-debs.sh itself inside an i386 trixie chroot
# (kept in CACHE_DIR/i386-root, made once with mmdebstrap). Only the i386
# packages are copied to OUT_DIR: the architecture-independent ones
# (libgtk-3-common...) are the amd64 build's.
#
# Needs root (sudo -n) for the chroot.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WHICH=${1:?usage: build-i386.sh gtk3|gtk4 CACHE_DIR OUT_DIR}
CACHE=$(realpath -m "${2:?usage}")
OUT=$(realpath -m "${3:?usage}")
case "$WHICH" in gtk3) SRC=gtk+3.0 ;; gtk4) SRC=gtk4 ;; *) echo "build-i386: gtk3 or gtk4" >&2; exit 2 ;; esac

ROOT="$CACHE/i386-root"
SUDO=${SG_SUDO-sudo -n}
mkdir -p "$CACHE/i386" "$OUT"
if [[ ! -x "$ROOT/usr/bin/dpkg-buildpackage" ]]; then
    $SUDO rm -rf "$ROOT.part"
    $SUDO mmdebstrap --mode=root --arch=i386 --variant=buildd \
        --include=devscripts,fakeroot,patch,ca-certificates \
        --components=main trixie "$ROOT.part" \
        "deb http://deb.debian.org/debian trixie main" \
        "deb-src http://deb.debian.org/debian trixie main" \
        "deb http://deb.debian.org/debian-security trixie-security main" \
        "deb-src http://deb.debian.org/debian-security trixie-security main" >&2
    $SUDO rm -rf "$ROOT"; $SUDO mv "$ROOT.part" "$ROOT"
fi

# build-debs.sh and the patches, the cache and the output, inside the chroot
M="$ROOT/sg"
$SUDO mkdir -p "$M/gtk-scale" "$M/cache" "$M/out"
cleanup() {
    for d in "$M/out" "$M/cache" "$M/gtk-scale" "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/proc"; do
        mountpoint -q "$d" && $SUDO umount -l "$d"
    done
    return 0
}
trap cleanup EXIT
$SUDO mount -t proc proc "$ROOT/proc"
$SUDO mount --bind /dev "$ROOT/dev"
$SUDO mount --bind /dev/pts "$ROOT/dev/pts"
$SUDO mount --bind "$HERE" "$M/gtk-scale"
$SUDO mount --bind "$CACHE/i386" "$M/cache"
W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-gtk-i386.XXXXXX")
trap 'cleanup; $SUDO rm -rf "$W"' EXIT
$SUDO mount --bind "$W" "$M/out"
$SUDO cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

$SUDO chroot "$ROOT" /bin/sh -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
    apt-get update -q >/dev/null
    apt-get build-dep -y -q '$SRC' >/dev/null
    SG_JOBS='${SG_JOBS:-$(nproc)}' TMPDIR=/var/tmp bash /sg/gtk-scale/build-debs.sh '$WHICH' /sg/cache /sg/out"

n=0
for d in "$W"/*_i386.deb; do
    [[ -e "$d" ]] || continue
    cp "$d" "$OUT"/; n=$((n + 1))
done
[[ "$n" -gt 0 ]] || { echo "build-i386: $SRC built no i386 packages" >&2; exit 1; }
echo "build-i386: $SRC for i386, $n packages"
