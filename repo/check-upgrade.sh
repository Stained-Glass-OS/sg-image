#!/bin/bash
# Refuse to publish a package whose version is lower than the one already
# live: apt keeps the installed (higher) version, so machines would never get
# the new build. sg-d3d did this (release 616): its version carried only the
# patches' hash, and 3.1.1+sg9302f260 sorts below 3.1.1+sg21616153.
#
#   repo/check-upgrade.sh LIVE_DIR DEB...
#
# LIVE_DIR is the fetched live repository (its pool/); a package not live yet
# passes. Exit 1 naming each package that would go backwards.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
LIVE=${1:?usage: check-upgrade.sh LIVE_DIR DEB...}
shift
bad=0
for deb in "$@"; do
    pkg=$(dpkg-deb -f "$deb" Package)
    ver=$(dpkg-deb -f "$deb" Version)
    [[ "$ver" != 0~placeholder ]] || continue
    for live in "$LIVE"/pool/*/"$pkg"/"$pkg"_*.deb; do
        [[ -f "$live" ]] || continue
        lv=$(dpkg-deb -f "$live" Version)
        if dpkg --compare-versions "$ver" lt "$lv"; then
            echo "refusing: $pkg $ver is lower than the published $lv;" >&2
            echo "          apt would keep $lv on every machine -- raise the version." >&2
            bad=1
        fi
    done
done
exit "$bad"
