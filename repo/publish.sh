#!/usr/bin/env bash
# Publish the repository to https://freesoft.page/apt (the project's server;
# it used to be GitHub Pages, whose 100 MB file limit kept the speech model
# out of the repository).
#
#   repo/publish.sh DEB...
#
# 1. fetch what is live (to refuse a changed package under an unchanged version);
# 2. build and sign the repository (repo/build-repo.sh);
# 3. verify it with apt (repo/check-repo.sh) -- a failure publishes nothing;
# 4. rsync it to the server: files first, the signed indices last, so a
#    machine never sees an index naming a package not yet there.
#
# Signing happens here, where the key is; no CI system holds it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# ssh target and directory; the key is ~/.ssh/sg unless SG_APT_SSH_KEY says.
HOST="${SG_APT_HOST:-root@freesoft.page}"
DIR="${SG_APT_DIR:-/srv/www/apt}"
KEY="${SG_APT_SSH_KEY:-$HOME/.ssh/sg}"
SSH="ssh -i $KEY -o BatchMode=yes"
LIVE="$HERE/build/apt-live"
OUT="$HERE/build/apt"

log() { echo "[publish] $*"; }

log "fetching the live repository"
rm -rf "$LIVE"
mkdir -p "$LIVE"
rsync -a -e "$SSH" "$HOST:$DIR/" "$LIVE/"
[[ -d "$LIVE/pool" ]] || log "  nothing published yet"

# The site is replaced by exactly the packages given, so a live package left
# off the command line would vanish from every machine's sources (sg-shell
# did, once). Refuse unless it is named in SG_PUBLISH_DROP.
given=" "
for deb in "$@"; do given+="$(basename "$deb" | cut -d_ -f1) "; done
if [[ -d "$LIVE/pool" ]]; then
    while read -r live_pkg; do
        [[ "$given" == *" $live_pkg "* ]] && continue
        [[ " ${SG_PUBLISH_DROP:-} " == *" $live_pkg "* ]] && { log "  dropping $live_pkg, as asked"; continue; }
        echo "[publish] REFUSED: $live_pkg is published and not given; pass its .deb, or SG_PUBLISH_DROP=$live_pkg" >&2
        exit 1
    done < <(find "$LIVE/pool" -name '*.deb' -printf '%f\n' | cut -d_ -f1 | sort -u)
fi

PUBLISHED_DIR="$LIVE" "$HERE/repo/build-repo.sh" "$OUT" "$@"
"$HERE/repo/check-repo.sh" "$OUT"

log "publishing"
rsync -a -e "$SSH" --exclude dists/ "$OUT/" "$HOST:$DIR/"
rsync -a --delete-after -e "$SSH" "$OUT/" "$HOST:$DIR/"
log "live at https://freesoft.page/apt"
