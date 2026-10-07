#!/bin/sh
# The front page says how big the ISO is ("about N GB", stained-glass
# site/index.md); it said 2 GB for a 3 GB ISO (site review 2026-10-07). Before
# an upload: fail when the page's figure is more than 1 GB off this ISO's size.
#
#   release/iso-size-check.sh ISO
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
iso=$1
url=${SG_SITE_INDEX_URL:-https://raw.githubusercontent.com/Stained-Glass-OS/stained-glass/main/site/index.md}
bytes=$(stat -c %s "$iso")
page=$(curl -fsSL --max-time 30 "$url") || { echo "iso-size-check: cannot fetch $url -- not checked" >&2; exit 0; }
said=$(printf '%s\n' "$page" | sed -n 's/.*sg-live-latest\.iso.*about \([0-9][0-9.]*\) GB.*/\1/p' | head -1)
[ -n "$said" ] || { echo "iso-size-check: no \"about N GB\" beside sg-live-latest.iso in $url" >&2; exit 1; }
awk -v b="$bytes" -v s="$said" 'BEGIN {
    gb = b / 1e9; d = gb - s; if (d < 0) d = -d
    printf "iso-size-check: the ISO is %.2f GB; the front page says about %s GB\n", gb, s
    if (d > 1) { printf "iso-size-check: FAIL -- update site/index.md (stained-glass) to about %d GB\n", gb + 0.5; exit 1 }
}'
