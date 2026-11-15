#!/bin/sh
# stained-glass-desktop (desktop-deb/build-deb.sh), without a machine:
#   - it builds, from mkosi.conf's package list;
#   - what a desktop cannot work without is in Depends, and nothing that only an
#     image needs is anywhere (systemd-boot would take a Debian machine's booting
#     from GRUB);
#   - every package of the image's list is in it, but the ones left out on purpose;
#   - its maintainer scripts are POSIX sh, and postinst/postrm use only
#     reversible means (a diversion, a remembered display manager, masks).
# The conversion itself is rehearsed on a Debian 13 + MATE VM (see
# desktop-deb/build-deb.sh); this gate keeps the package honest between runs.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
T=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-desktop-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
"$HERE/desktop-deb/build-deb.sh" "$T" >/dev/null || { fail "stained-glass-desktop did not build"; exit 1; }
DEB=$(ls "$T"/stained-glass-desktop_*_all.deb)
pass "built $(basename "$DEB")"
f() { dpkg-deb -f "$DEB" "$1" | tr ',' '\n' | sed 's/^ *//; s/ .*//' | grep -v '^$'; }
DEP=$(f Depends); REC=$(f Recommends)
for p in wine-sg sg-session sg-shell sg-compositor greetd login libpam-systemd network-manager; do
    echo "$DEP" | grep -qx "$p" || fail "Depends lacks $p"
done
pass "Depends has the desktop's core"
for p in systemd-boot linux-image-amd64 dbus-broker spice-vdagent; do
    printf '%s\n%s\n' "$DEP" "$REC" | grep -qx "$p" && fail "$p (image-only) is in the package"
done
pass "nothing image-only"
missing=$(sed -n '/^Packages=/,/^$/p' "$HERE/mkosi.conf" | grep -E '^\s+[a-z0-9]' | sed 's/^\s*//' | sort -u \
    | grep -vxE 'systemd-boot|linux-image-amd64|dbus-broker|spice-vdagent|efibootmgr|mokutil|systemd-repart|fdisk|dosfstools' \
    | while read -r p; do printf '%s\n%s\n' "$DEP" "$REC" | grep -qx "$p" || echo "$p"; done)
[ -z "$missing" ] && pass "every package of the image's list is in it" || fail "missing from the package: $missing"
dpkg-deb -e "$DEB" "$T/ctl"
for s in preinst postinst postrm; do
    sh -n "$T/ctl/$s" && pass "$s is valid sh" || fail "$s does not parse"
done
grep -q 'previous-display-manager' "$T/ctl/postinst" && grep -q 'previous-display-manager' "$T/ctl/postrm" \
    && pass "the previous display manager is remembered and given back" || fail "display manager not given back on purge"
grep -q 'dpkg-divert.*--remove' "$T/ctl/postrm" && pass "postrm removes its diversions" || fail "postrm leaves diversions"
grep -qE 'systemctl (disable|stop|mask).*(smbd|nftables|ufw|NetworkManager|systemd-networkd)' "$T/ctl/postinst" \
    && fail "postinst turns off a service the owner set up" || pass "postinst turns off nothing the owner set up"
echo "$REC" | grep -qx sg-apps && pass "the bundled Windows applications come with it (sg-apps)" || fail "sg-apps not pulled in"
echo "$DEP" | grep -qx sg-session && dpkg-deb -f "$DEB" Depends | grep -q 'sg-session (>= 0.1.0-251)' \
    && pass "it needs the sg-session that reads profile-in-home" || fail "no versioned sg-session dependency"
dpkg-deb -c "$DEB" | grep -q './etc/stained-glass/profile-in-home$' && pass "it ships profile-in-home (homes stay where they are)" || fail "profile-in-home not shipped"
# the fstab lines, against a scratch fstab: one bind mount per person, gone on purge
F="$T/fstab"; printf 'UUID=x / ext4 defaults 0 1\n' > "$F"
sed -n "/--- people's homes are their Windows profiles/,/daemon-reload/p" "$T/ctl/postinst" | sed "s#/etc/fstab#$F#g; s#systemctl#:#g" > "$T/pi.sh"
sh "$T/pi.sh" 2>/dev/null; sh "$T/pi.sh" 2>/dev/null
me=$(id -un)
n=$(grep -c "^# stained-glass-desktop: $me\$" "$F")
[ "$n" = 1 ] && grep -q " /var/lib/stained-glass/prefix/drive_c/users/$me none bind,nofail," "$F" \
    && pass "install bind-mounts each home on its profile, once (nofail)" || fail "fstab after install: $(cat "$F")"
sed -n "/the homes' bind mounts on their profiles/,/^    fi/p" "$T/ctl/postrm" | sed "s#/etc/fstab#$F#g; s#umount #: #; s#rmdir #: #; s#systemctl#:#g" > "$T/pr.sh"
sh "$T/pr.sh" 2>/dev/null
[ "$(cat "$F")" = "UUID=x / ext4 defaults 0 1" ] && pass "purge takes the lines out again, and nothing else" || fail "fstab after purge: $(cat "$F")"
exit $RC
