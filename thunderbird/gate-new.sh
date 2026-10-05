#!/bin/sh
# The gates a newly built thunderbird package must pass before a release
# takes it (thunderbird/update.sh runs this as SG_TB_GATE; a failure keeps
# the Thunderbird we had):
#   test/thunderbird-deb-test.sh   it installs over Debian's and fresh;
#   SG Mail's own gates against it (make -C $SG_MAIL test TB_DEB=...), when
#   the sg-mail checkout is there and SG_TB_NO_MAIL_GATES is not 1 -- a new
#   Thunderbird must not break SG Mail's window (its experiment API reaches
#   into Thunderbird's internals, which change between versions).
#
#   thunderbird/gate-new.sh DEB TARBALL
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DEB=$(realpath "$1"); TAR=$(realpath "$2")
"$HERE/test/thunderbird-deb-test.sh" "$DEB" "$TAR" || exit 1
SG_MAIL=${SG_MAIL:-$HERE/../sg-mail}
if [ "${SG_TB_NO_MAIL_GATES:-0}" != 1 ] && [ -d "$SG_MAIL" ]; then
    # a root of its own, made for this package (never one left from before)
    root=/var/tmp/sgmail/root-tbgate-$$
    make -C "$SG_MAIL" test TB_DEB="$DEB" ROOT="$root"; rc=$?
    # the root is the subordinate ids' (rootless mmdebstrap): removed the same way
    unshare --map-auto --map-root-user rm -rf "$root" 2>/dev/null || :
    [ "$rc" = 0 ] || { echo "[thunderbird] SG Mail's gates failed on $(dpkg-deb -f "$DEB" Version)"; exit 1; }
fi
exit 0
