#!/bin/bash
# Our thunderbird package for this build: Mozilla's newest release on the
# channel, built once and then reused.
#
#   thunderbird/update.sh CACHE_DIR OUT_DIR
#
# 1. What we have: the newest thunderbird_*.deb in CACHE_DIR; on a machine
#    without one, the one our apt repository publishes (SG_TB_REPO).
# 2. What Mozilla has: product-details' thunderbird_versions.json, the
#    channel's key (SG_TB_CHANNEL: release -> LATEST_THUNDERBIRD_VERSION,
#    esr -> THUNDERBIRD_ESR). The package we want is 1:<that>-sg<REV>.
# 3. Ours is that version (or newer): reuse it. Otherwise download Mozilla's
#    tarball, SHA512SUMS and SHA512SUMS.asc; the signature must be good and
#    made by Mozilla's release key (primary fingerprint pinned below; its
#    signing subkeys rotate, gpg checks they are bound to it), and the
#    tarball's SHA-512 must be the one listed. Then build-deb.sh, then
#    SG_TB_GATE (a command given the new .deb and the tarball; the Makefile
#    runs the package gate and SG Mail's gates) -- only a package that passed
#    replaces the cached one.
# 4. Copy the chosen package to OUT_DIR, and its source id to OUT_DIR/SOURCES
#    (repo/build-repo.sh keeps an already-published build of the same source).
#
# Mozilla unreachable, or a new version that fails to download, verify, build
# or pass its gates: the cached package is used and a WARNING printed -- the
# release goes on with the Thunderbird it has. Only with nothing cached and
# nothing published does this fail.
#
# Test hooks: SG_TB_PRODUCT_DETAILS, SG_TB_ARCHIVE, SG_TB_REPO (URLs; file://
# works) and the mutants SG_MUTANT_TB_COMPARE, SG_MUTANT_TB_NO_VERIFY,
# SG_MUTANT_TB_UNREACHABLE_FATAL (test/thunderbird-update-test.sh).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CACHE=${1:?usage: update.sh CACHE_DIR OUT_DIR}
OUT=${2:?usage}
CHANNEL=${SG_TB_CHANNEL:-release}
PD=${SG_TB_PRODUCT_DETAILS:-https://product-details.mozilla.org/1.0/thunderbird_versions.json}
ARCHIVE=${SG_TB_ARCHIVE:-https://archive.mozilla.org/pub/thunderbird/releases}
REPO=${SG_TB_REPO:-https://freesoft.page/apt}
# Mozilla Software Releases <release@mozilla.com>
MOZILLA_KEY_FPR=14F26682D0916CDD81E37B6D61B7B526D98F0353
REV=$(sed -n 's/^REV=//p' "$HERE/REV")
CURL="curl -fsSL --retry 2 --connect-timeout 20 --max-time ${SG_TB_TIMEOUT:-900}"

log() { echo "[thunderbird] $*" >&2; }
mkdir -p "$CACHE" "$OUT"
CACHE=$(realpath "$CACHE")
W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-tb-update.XXXXXX")
trap 'rm -rf "$W"' EXIT

debver() { dpkg-deb -f "$1" Version; }
newest_cached() {
    local best='' bv='' d v
    for d in "$CACHE"/thunderbird_*_amd64.deb; do
        [[ -f "$d" ]] || continue
        v=$(debver "$d")
        if [[ -z "$best" ]] || dpkg --compare-versions "$v" gt "$bv"; then best=$d; bv=$v; fi
    done
    echo "$best"
}
# the source id: Mozilla's tarball (its listed SHA-512) and our packaging
srcid() { # tarball-sha512
    { echo "$1"; cat "$HERE/build-deb.sh" "$HERE/policies.json" "$HERE/thunderbird.desktop" "$HERE/REV"; } | sha256sum | cut -c1-40
}

stage() { # deb, how
    local deb=$1 src
    cp "$deb" "$OUT/"
    src=$(cat "$deb.src" 2>/dev/null || echo "unknown-$(sha256sum "$deb" | cut -c1-16)")
    echo "thunderbird $src" >> "$OUT/SOURCES"
    echo "[thunderbird] staged $(basename "$deb") ($2)"
    exit 0
}
give_up() { # reason: keep what we have, or fail
    if [[ -n "$CUR" ]]; then
        log "WARNING: $1 -- keeping thunderbird $(debver "$CUR")"
        stage "$CUR" "kept: $1"
    fi
    log "ERROR: $1, and no thunderbird package cached in $CACHE or published at $REPO"
    exit 1
}

# 1. what we have
CUR=$(newest_cached)
if [[ -z "$CUR" ]]; then
    # a machine new to releases: start from what the repository publishes
    if $CURL -o "$W/Packages" "$REPO/dists/trixie/main/binary-amd64/Packages" 2>/dev/null; then
        f=$(awk '/^Package: thunderbird$/{p=1} p&&/^Filename:/{print $2; exit} /^$/{p=0}' "$W/Packages")
        sum=$(awk '/^Package: thunderbird$/{p=1} p&&/^SHA256:/{print $2; exit} /^$/{p=0}' "$W/Packages")
        if [[ -n "$f" ]] && $CURL -o "$W/pub.deb" "$REPO/$f" \
                && echo "$sum  $W/pub.deb" | sha256sum -c - >/dev/null 2>&1; then
            mv "$W/pub.deb" "$CACHE/$(basename "$f")"
            $CURL -o "$CACHE/$(basename "$f").src" "$REPO/$f.src" 2>/dev/null || rm -f "$CACHE/$(basename "$f").src"
            CUR=$CACHE/$(basename "$f")
            log "seeded the cache with the published $(basename "$f")"
        fi
    fi
fi

# 2. what Mozilla has
if [[ "${SG_MUTANT_TB_UNREACHABLE_FATAL:-0}" == 1 ]]; then
    $CURL -o "$W/versions.json" "$PD" || { log "ERROR: product-details unreachable"; exit 1; }
fi
$CURL -o "$W/versions.json" "$PD" 2>/dev/null || give_up "Mozilla's product-details ($PD) unreachable"
case "$CHANNEL" in
    release) key=LATEST_THUNDERBIRD_VERSION ;;
    esr) key=THUNDERBIRD_ESR ;;
    *) log "ERROR: SG_TB_CHANNEL must be release or esr"; exit 1 ;;
esac
LATEST=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$W/versions.json" "$key" 2>/dev/null) \
    || give_up "no $key in product-details"
[[ "$LATEST" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)*(esr)?$ ]] || give_up "odd version '$LATEST' in product-details"
WANT=1:$LATEST-sg$REV

# 3. reuse, or build
if [[ -n "$CUR" ]]; then
    have=$(debver "$CUR")
    if [[ "${SG_MUTANT_TB_COMPARE:-0}" == 1 ]]; then cmp=le; else cmp=ge; fi
    if dpkg --compare-versions "$have" "$cmp" "$WANT"; then
        stage "$CUR" "reused: Mozilla's $CHANNEL is $LATEST"
    fi
    log "Mozilla's $CHANNEL is $LATEST; ours is $have: building $WANT"
else
    log "Mozilla's $CHANNEL is $LATEST; nothing cached: building $WANT"
fi
DL="$CACHE/dl/$LATEST"; mkdir -p "$DL"
TAR=thunderbird-$LATEST.tar.xz
for f in SHA512SUMS SHA512SUMS.asc KEY; do
    $CURL -o "$DL/$f.part" "$ARCHIVE/$LATEST/$f" 2>/dev/null && mv "$DL/$f.part" "$DL/$f" || rm -f "$DL/$f.part"
done
[[ -s "$DL/SHA512SUMS" && -s "$DL/SHA512SUMS.asc" ]] || give_up "cannot download Mozilla's SHA512SUMS for $LATEST"
if [[ "${SG_MUTANT_TB_NO_VERIFY:-0}" != 1 ]]; then
    export GNUPGHOME="$W/gnupg"; mkdir -m700 "$GNUPGHOME"
    gpg -q --batch --import "$HERE/mozilla-release-key.asc" 2>/dev/null || true
    # a newer signing subkey comes with the release (KEY); it only counts if
    # Mozilla's pinned primary key certified it, which gpg checks
    [[ ! -s "$DL/KEY" ]] || gpg -q --batch --import "$DL/KEY" 2>/dev/null || true
    gpg --batch --status-fd 1 --verify "$DL/SHA512SUMS.asc" "$DL/SHA512SUMS" > "$W/gpg.status" 2>/dev/null || true
    # VALIDSIG <signing-key> ... <primary-key-fingerprint>
    awk '$2=="VALIDSIG"{print $NF}' "$W/gpg.status" | grep -qx "$MOZILLA_KEY_FPR" \
        || { rm -f "$DL"/SHA512SUMS*; give_up "SHA512SUMS for $LATEST is not signed by Mozilla's release key"; }
fi
SUM=$(awk -v f="linux-x86_64/en-US/$TAR" '$2==f{print $1}' "$DL/SHA512SUMS")
[[ -n "$SUM" ]] || give_up "SHA512SUMS lists no linux-x86_64/en-US/$TAR"
if ! { [[ -f "$DL/$TAR" ]] && echo "$SUM  $DL/$TAR" | sha512sum -c - >/dev/null 2>&1; }; then
    $CURL -o "$DL/$TAR.part" "$ARCHIVE/$LATEST/linux-x86_64/en-US/$TAR" || give_up "cannot download $TAR"
    mv "$DL/$TAR.part" "$DL/$TAR"
fi
if [[ "${SG_MUTANT_TB_NO_VERIFY:-0}" != 1 ]]; then
    echo "$SUM  $DL/$TAR" | sha512sum -c - >/dev/null 2>&1 \
        || { rm -f "$DL/$TAR"; give_up "$TAR does not match Mozilla's signed SHA-512"; }
fi
log "verified $TAR (Mozilla's signed SHA512SUMS, key $MOZILLA_KEY_FPR)"
mkdir -p "$W/deb"
"$HERE/build-deb.sh" "$DL/$TAR" "$LATEST" "$W/deb" >&2 || give_up "build-deb.sh failed for $LATEST"
NEW=$(ls "$W/deb"/thunderbird_*_amd64.deb)
if [[ -n "${SG_TB_GATE:-}" ]]; then
    log "gating the new package: $SG_TB_GATE"
    $SG_TB_GATE "$NEW" "$DL/$TAR" >&2 || give_up "the new thunderbird $LATEST failed its gates ($SG_TB_GATE)"
fi
srcid "$SUM" > "$NEW.src"
# adopt it: the cache keeps the newest package and its tarball only
for d in "$CACHE"/thunderbird_*_amd64.deb; do [[ -f "$d" ]] && rm -f "$d" "$d.src"; done
mv "$NEW" "$NEW.src" "$CACHE/"
for d in "$CACHE"/dl/*; do [[ "$d" == "$DL" ]] || rm -rf "$d"; done
stage "$CACHE/$(basename "$NEW")" "built: Mozilla's $CHANNEL $LATEST"
