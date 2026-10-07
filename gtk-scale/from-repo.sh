#!/bin/sh
# gtk-scale/from-repo.sh OUT: the image's two patched GTK 3 packages
# (libgtk-3-0t64, libgtk-3-common) as https://freesoft.page/apt publishes
# them, each verified against the SHA-256 in the repository's index. For CI,
# which has no deb-src and no 1.5 h for a GTK build (SG_GTK_FROM_REPO=1);
# releases build them with build-debs.sh.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
OUT=${1:?usage: from-repo.sh OUT}
REPO=${SG_APT_URL:-https://freesoft.page/apt}
T=$(mktemp -d) && trap 'rm -rf "$T"' EXIT
curl -fsSL --retry 3 "$REPO/dists/trixie/main/binary-amd64/Packages" -o "$T/Packages"
mkdir -p "$OUT"
for pkg in libgtk-3-0t64 libgtk-3-common; do
    # the newest +sg build of the package in the index
    entry=$(awk -v p="$pkg" 'BEGIN { RS = ""; FS = "\n" }
        { name = ""; ver = ""; file = ""; sum = ""
          for (i = 1; i <= NF; i++) {
            if ($i ~ /^Package: /) name = substr($i, 10)
            else if ($i ~ /^Version: /) ver = substr($i, 10)
            else if ($i ~ /^Filename: /) file = substr($i, 11)
            else if ($i ~ /^SHA256: /) sum = substr($i, 9) }
          if (name == p && ver ~ /\+sg/) print ver, file, sum }' "$T/Packages" | sort -V | tail -1)
    [ -n "$entry" ] || { echo "from-repo: $pkg (+sg) is not in $REPO" >&2; exit 1; }
    set -- $entry
    curl -fsSL --retry 3 "$REPO/$2" -o "$OUT/$(basename "$2")"
    echo "$3  $OUT/$(basename "$2")" | sha256sum -c - >/dev/null || { echo "from-repo: $pkg checksum mismatch" >&2; exit 1; }
    echo "from-repo: $pkg $1"
done
