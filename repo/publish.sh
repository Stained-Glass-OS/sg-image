#!/usr/bin/env bash
# Publish the repository to GitHub Pages: https://stained-glass-os.github.io/apt
#
#   repo/publish.sh DEB...
#
# 1. fetch what is live (to refuse a changed package under an unchanged version);
# 2. build and sign the repository (repo/build-repo.sh);
# 3. verify it with apt (repo/check-repo.sh) -- a failure publishes nothing;
# 4. replace the live site with a single orphan commit, so wine-sg's ~56 MB per
#    release never accumulates in git history.
#
# Signing happens here, where the key is; no CI system holds it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
REMOTE="${SG_APT_REMOTE:-https://github.com/Stained-Glass-OS/apt.git}"
LIVE="$HERE/build/apt-live"
OUT="$HERE/build/apt"

log() { echo "[publish] $*"; }

log "fetching the live repository"
rm -rf "$LIVE"
if git ls-remote --exit-code "$REMOTE" main >/dev/null 2>&1; then
    git clone -q --depth 1 --branch main "$REMOTE" "$LIVE"
else
    log "  nothing published yet"
    mkdir -p "$LIVE"
fi

PUBLISHED_DIR="$LIVE" "$HERE/repo/build-repo.sh" "$OUT" "$@"
"$HERE/repo/check-repo.sh" "$OUT"

log "publishing"
cd "$OUT"
rm -rf .git
git init -q -b main
git add -A
git -c user.name="Stained Glass OS" -c user.email="dev@stained-glass.example" \
    commit -q -m "Repository as of $(date -u +%Y-%m-%dT%H:%MZ)"
git push -q --force "$REMOTE" main
rm -rf .git
log "live at https://stained-glass-os.github.io/apt (Pages may take a minute)"
