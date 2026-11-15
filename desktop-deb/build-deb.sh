#!/bin/bash
# Package "Stained Glass OS on an existing Debian": stained-glass-desktop.
#
#   desktop-deb/build-deb.sh OUT_DIR
#
# A Debian 13 machine with our apt source turns into a Stained Glass machine
# with `apt install stained-glass-desktop`, and back with
# `apt purge stained-glass-desktop` (then `apt autoremove`). It brings what the
# image installs (mkosi.conf's Packages=, read here, so the two cannot drift
# apart) and does at install what the image build does
# (mkosi.postinst.chroot): greetd as the display manager, the Windows system's
# services, tty1 kept free for the login screen, os-release saying Stained
# Glass OS. The previous display manager and Debian's os-release come back on
# purge.
#
# Not here, on purpose: what only an image needs (systemd-boot, which would take
# the machine's booting from GRUB; the live medium's and the installer's
# pieces; VM agents; dbus-broker in place of a running dbus-daemon).
#
# The version counts this repository's commits that changed what the package
# says (mkosi.conf, mkosi.extra, desktop-deb): it only ever goes up, and
# changed contents always come with a new one (the repository refuses changed
# contents under an unchanged version).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
OUT=${1:?usage: build-deb.sh OUT_DIR}
HERE=$(cd "$(dirname "$0")/.." && pwd)
PKG=stained-glass-desktop
n=$(git -C "$HERE" rev-list --count HEAD -- mkosi.conf mkosi.extra desktop-deb 2>/dev/null) \
    || { echo "build-deb: $HERE is not a git checkout (the version is counted from its history)" >&2; exit 1; }
VERSION="0.1.$n"

# What the image installs, without what only an image needs. Our own packages
# come through sg-session's Depends (wine-sg, sg-shell's friends) and are named
# below where they are not.
SKIP='^(systemd-boot|linux-image-amd64|dbus-broker|spice-vdagent|efibootmgr|mokutil|systemd-repart|fdisk|dosfstools)$'
IMAGE_PKGS=$(sed -n '/^Packages=/,/^$/p' "$HERE/mkosi.conf" | grep -E '^\s+[a-z0-9]' | sed 's/^\s*//' \
    | grep -vE '^#' | grep -vE "$SKIP" | sort -u)
[ "$(printf '%s\n' "$IMAGE_PKGS" | wc -l)" -gt 100 ] || { echo "build-deb: read too few packages from mkosi.conf" >&2; exit 1; }
# What a working desktop cannot do without: Depends. The rest of the image's
# list: Recommends (apt installs those too, and a missing firmware or font
# never blocks the install).
CORE="wine-sg sg-session sg-shell sg-compositor greetd login libpam-systemd xwayland network-manager systemd-resolved pipewire pipewire-pulse wireplumber fonts-inter fonts-liberation xsettingsd"
# GTK with our fractional-scaling fix (sg-image gtk-scale/; "+sg" sorts above
# Debian's same version), which the image carries: without a versioned
# dependency apt keeps Debian's build until the next full upgrade.
GTK="libgtk-3-0t64 (>= 3.24.49-3+sg), libgtk-4-1 (>= 4.18.6+ds-2+sg)"
# profile-in-home (below) needs the sg-profile-create that reads it
VERSIONED="sg-session (>= 0.1.0-251), $GTK"
OURS="sg-speech-model-parakeet sg-davmail sg-apps"
# shellcheck disable=SC2086  # word splitting wanted: lists of package names
dep=$(printf '%s, ' $CORE); dep="${dep%, }, $VERSIONED"
rec=$(printf '%s\n' $IMAGE_PKGS $OURS | grep -vxF -f <(printf '%s\n' $CORE) | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')

W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-desktop-deb.XXXXXX")
trap 'rm -rf "$W"' EXIT
R="$W/root"
mkdir -p "$R/DEBIAN" "$R/usr/share/doc/$PKG" "$R/etc/greetd" "$R/etc/NetworkManager/conf.d" "$R/etc/stained-glass"
chmod 755 "$R"
cp "$HERE/mkosi.extra/etc/greetd/config.toml" "$R/etc/greetd/config.toml"
cp "$HERE/mkosi.extra/etc/NetworkManager/conf.d/50-stained-glass.conf" "$R/etc/NetworkManager/conf.d/"
# People keep their homes where they are: each Windows profile becomes a link
# to its person's home (sg-session 0.1.0-251, sg-profile-create), not the
# home a link into the prefix -- a home in use would be copied there, and its
# private files opened up.
cat > "$R/etc/stained-glass/profile-in-home" <<'PIH'
# Stained Glass OS on an existing Debian (stained-glass-desktop): a person's
# Windows profile, C:\users\<name>, is a link to their home, which stays
# where it is. Remove this file before someone's first sign-in to have their
# home moved into the profile instead, as on a machine installed from the
# Stained Glass image.
PIH
for s in preinst postinst postrm; do install -m 0755 "$HERE/desktop-deb/$s" "$R/DEBIAN/$s"; done
printf '/etc/greetd/config.toml\n/etc/NetworkManager/conf.d/50-stained-glass.conf\n/etc/stained-glass/profile-in-home\n' > "$R/DEBIAN/conffiles"
cat > "$R/usr/share/doc/$PKG/copyright" <<'COPY'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: stained-glass-desktop
Source: https://github.com/Stained-Glass-OS/stained-glass

Files: *
Copyright: 2026 David Hamner and the Stained Glass OS contributors
License: AGPL-3.0-or-later
COPY
chmod -R u=rwX,go=rX "$R/usr" "$R/etc"

cat > "$R/DEBIAN/control" <<CTRL
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: Stained Glass OS <ke7oxh@gmail.com>
Installed-Size: $(du -sk "$R" | cut -f1)
Section: metapackages
Priority: optional
Depends: $dep
Recommends: $rec
Description: Stained Glass OS on an existing Debian
 Turns a Debian 13 machine into a Stained Glass OS machine: the packages the
 Stained Glass image installs, its login screen (greetd in place of the
 previous display manager), the Windows system's services, and os-release
 naming Stained Glass OS. Purging this package brings back the previous display
 manager and Debian's os-release; apt autoremove then takes the rest away.
CTRL
mkdir -p "$OUT"
dpkg-deb --root-owner-group -Zxz -b "$R" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "[$PKG] built ${PKG}_${VERSION}_all.deb"
