#!/bin/bash
# Cut a release from what is pushed, never from a working tree: worktrees of
# every repo at origin/main under ../rel, then image -> boot gate -> net gate
# -> publish (apt) -> ISO -> ISO install gates -> ISO upload. Stops at the
# first failure; nothing is published unless every gate before it passed.
#
#   release/release.sh [--no-publish] [--no-iso-test]
#
# Other agents and people edit the main checkouts; building from them would
# ship their uncommitted work. The worktrees share nothing with them but git
# objects. sg-image's build/ (download caches, the gate ssh key, the lab
# password) is shared by symlink so a release does not re-download 1.5 GB.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(dirname "$HERE")
REL="$ROOT/rel"
LOCK="$ROOT/.sg-image.lock"
PUBLISH=1; ISOTEST=1
for a in "$@"; do
    case "$a" in
        --no-publish) PUBLISH=0 ;;
        --no-iso-test) ISOTEST=0 ;;
        *) echo "usage: release.sh [--no-publish] [--no-iso-test]" >&2; exit 2 ;;
    esac
done
log() { echo "[release] $(date +%H:%M:%S) $*"; }
# Compilers and mkfs spool into TMPDIR; /tmp here is a small tmpfs that
# other work fills (it failed a Wine build once). Keep the release on disk.
export TMPDIR=/var/tmp/sg-release-tmp
mkdir -p "$TMPDIR"

mkdir -p "$REL"
for r in wine-sg sg-session sg-shell sg-compositor sg-image; do
    git -C "$ROOT/$r" fetch -q origin
    if [[ -d "$REL/$r" ]]; then
        git -C "$REL/$r" checkout -q --detach origin/main
    else
        git -C "$ROOT/$r" worktree add -q --detach "$REL/$r" origin/main
    fi
    log "$r at $(git -C "$REL/$r" log --oneline -1 | cut -c1-70)"
done
[[ -e "$REL/sg-image/build" ]] || ln -s "$HERE/build" "$REL/sg-image/build"

export SG_WINE="$REL/wine-sg" SG_SESSION="$REL/sg-session" SG_SHELL="$REL/sg-shell" SG_COMPOSITOR="$REL/sg-compositor"
cd "$REL/sg-image"
L="$HERE/build/release-logs"; mkdir -p "$L"
step() { # name, command...
    local name=$1; shift
    log "$name"
    if ! "$@" > "$L/$name.log" 2>&1; then
        log "FAILED: $name -- $L/$name.log"; tail -15 "$L/$name.log"; exit 1
    fi
    grep -E "GATE (PASS|FAIL)|^FAIL" "$L/$name.log" | tail -4 || true
}
# The VM gates share one image lock with everyone's gate runs. Take it once,
# for the whole release: flock does not queue in order, so releasing it
# between steps let other work in between image and boot gate for an hour.
exec 9>"$LOCK"
log "waiting for the image lock"
flock 9
log "holding the image lock"
# The gates' budgets assume a machine that is not saturated: with other work
# building Wine trees (load 75-90 on 12 cores) a first boot took 11 minutes and
# the gate gave up. Wait, up to an hour, for the load to come down.
limit=$(( $(nproc) * 3 / 2 ))
for _ in $(seq 1 120); do
    load=$(cut -d' ' -f1 /proc/loadavg); load=${load%.*}
    (( load < limit )) && break
    log "load $load (limit $limit): waiting for the machine to calm down"
    sleep 30
done
gate() { "$@"; }

step image     gate make image
step boot-test gate make boot-test
step net-test  gate make net-test
if [[ $PUBLISH == 1 ]]; then step publish gate make publish; fi
step iso       gate make iso
if [[ $ISOTEST == 1 ]]; then step iso-test gate make iso-test; fi
if [[ $PUBLISH == 1 ]]; then step upload-iso make upload-iso; fi
log "release done"
