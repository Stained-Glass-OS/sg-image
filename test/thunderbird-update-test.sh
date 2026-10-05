#!/bin/bash
# thunderbird/update.sh's decisions, against stand-ins for Mozilla's
# product-details and archive and for our apt repository (file:// URLs; the
# tarball and its signed SHA512SUMS are Mozilla's real ones, so the
# signature check is the real one):
#
#   newer       Mozilla has a newer version than the cached package: it is
#               downloaded, verified, built, cached and staged;
#   same        Mozilla has the cached version: the cached package is staged,
#               nothing is downloaded (the archive stand-in is empty);
#   unreachable Mozilla cannot be reached: the cached package is staged and the
#               build goes on; with nothing cached and nothing published it
#               fails;
#   seeded      nothing cached, Mozilla has what our repository publishes: the
#               published package is fetched and staged, nothing is built;
#   tampered    the tarball differs from Mozilla's signed SHA-512: not built,
#               the cached package is kept;
#   forged      SHA512SUMS altered (its signature no longer good): not built.
#
#   test/thunderbird-update-test.sh MOZ_DL_DIR [--mutants]
#
# MOZ_DL_DIR holds a Mozilla release's thunderbird-<v>.tar.xz, SHA512SUMS and
# SHA512SUMS.asc (update.sh's cache, build/thunderbird-cache/dl/<v>).
# --mutants: SG_MUTANT_TB_COMPARE (the version check the wrong way round),
# SG_MUTANT_TB_NO_VERIFY (no signature/checksum check) and
# SG_MUTANT_TB_UNREACHABLE_FATAL (Mozilla unreachable fails the build) must
# each make this gate fail.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DL=$(realpath "${1:?usage: thunderbird-update-test.sh MOZ_DL_DIR [--mutants]}")
V=$(basename "$DL")
export TMPDIR=${TMPDIR:-/var/tmp}
if [[ "${2:-}" == --mutants ]]; then
    rc=0
    for m in SG_MUTANT_TB_COMPARE SG_MUTANT_TB_NO_VERIFY SG_MUTANT_TB_UNREACHABLE_FATAL; do
        if env "$m=1" "$0" "$DL" > "$TMPDIR/tb-update-mutant.log" 2>&1; then
            echo "MUTANT $m: gate PASSED (should fail)"; rc=1
        else
            echo "MUTANT $m: gate failed, as it must ($(grep -m1 '^FAIL' "$TMPDIR/tb-update-mutant.log"))"
        fi
    done
    rm -f "$TMPDIR/tb-update-mutant.log"
    exit $rc
fi
[[ -f "$DL/thunderbird-$V.tar.xz" && -f "$DL/SHA512SUMS" && -f "$DL/SHA512SUMS.asc" ]] \
    || { echo "SKIP: no Mozilla release files in $DL"; exit 77; }
REV=$(sed -n 's/^REV=//p' "$HERE/thunderbird/REV")
W=$(mktemp -d "$TMPDIR/sg-tb-update-test.XXXXXX"); trap 'rm -rf "$W"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }

# stand-ins
fake_deb() { # version dir -> a tiny thunderbird package of that version
    local r="$W/fake-$RANDOM"
    mkdir -p "$r/DEBIAN" "$2"
    printf 'Package: thunderbird\nVersion: %s\nArchitecture: amd64\nMaintainer: test <t@example.test>\nDescription: stand-in\n' "$1" > "$r/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$r" "$2/thunderbird_${1#*:}_amd64.deb" >/dev/null
    echo "stand-in-$1" > "$2/thunderbird_${1#*:}_amd64.deb.src"
    rm -rf "$r"
}
pd() { # file with LATEST_THUNDERBIRD_VERSION=$1
    printf '{"LATEST_THUNDERBIRD_VERSION": "%s", "THUNDERBIRD_ESR": "140.17.0esr"}\n' "$1" > "$W/pd-$1.json"
    echo "file://$W/pd-$1.json"
}
mkdir -p "$W/archive/$V/linux-x86_64/en-US" "$W/empty" "$W/tampered/$V/linux-x86_64/en-US" "$W/forged/$V/linux-x86_64/en-US"
ln -s "$DL/thunderbird-$V.tar.xz" "$W/archive/$V/linux-x86_64/en-US/"
cp "$DL/SHA512SUMS" "$DL/SHA512SUMS.asc" "$W/archive/$V/"
# tampered: one byte of the tarball changed, Mozilla's real signed sums
cp "$DL/thunderbird-$V.tar.xz" "$W/tampered/$V/linux-x86_64/en-US/"
printf 'X' | dd of="$W/tampered/$V/linux-x86_64/en-US/thunderbird-$V.tar.xz" bs=1 seek=4096 conv=notrunc status=none
cp "$DL/SHA512SUMS" "$DL/SHA512SUMS.asc" "$W/tampered/$V/"
# forged: the tampered tarball, its SHA-512 written into SHA512SUMS (whose
# signature is then no longer good)
cp "$W/tampered/$V/linux-x86_64/en-US/thunderbird-$V.tar.xz" "$W/forged/$V/linux-x86_64/en-US/"
s=$(sha512sum "$W/forged/$V/linux-x86_64/en-US/thunderbird-$V.tar.xz" | cut -d' ' -f1)
awk -v s="$s" -v f="linux-x86_64/en-US/thunderbird-$V.tar.xz" '$2==f{$1=s} {print $1"  "$2}' "$DL/SHA512SUMS" > "$W/forged/$V/SHA512SUMS"
cp "$DL/SHA512SUMS.asc" "$W/forged/$V/"
# our repository: publishes 1:V-sgREV (a stand-in)
mkdir -p "$W/repo/pool/main/thunderbird" "$W/repo/dists/trixie/main/binary-amd64"
fake_deb "1:$V-sg$REV" "$W/repo/pool/main/thunderbird"
(cd "$W/repo" && apt-ftparchive packages pool/main > dists/trixie/main/binary-amd64/Packages 2>/dev/null)

run() { # case cache-setup(older|same|none) pd-url archive-url repo-url
    local name=$1 setup=$2
    rm -rf "$W/c-$name" "$W/o-$name"; mkdir -p "$W/c-$name" "$W/o-$name"
    case "$setup" in
        older) fake_deb "1:156.0-sg1" "$W/c-$name" ;;
        same) fake_deb "1:$V-sg$REV" "$W/c-$name" ;;
    esac
    SG_TB_PRODUCT_DETAILS=$3 SG_TB_ARCHIVE=$4 SG_TB_REPO=$5 SG_TB_GATE='' SG_TB_TIMEOUT=60 \
        "$HERE/thunderbird/update.sh" "$W/c-$name" "$W/o-$name" > "$W/$name.out" 2> "$W/$name.err"
    echo $? > "$W/$name.rc"
}
staged() { ls "$W/o-$1" 2>/dev/null | grep '\.deb$' | tr '\n' ' ' | sed 's/ $//'; }
rcof() { cat "$W/$1.rc"; }
built_version() { dpkg-deb -f "$W/o-$1/$(staged "$1")" Version 2>/dev/null; }
NOWHERE="file://$W/nowhere"

echo "[thunderbird-update-test] Mozilla $V, packaging revision $REV"
run newer older "$(pd "$V")" "file://$W/archive" "$NOWHERE"
[[ $(rcof newer) == 0 && "$(built_version newer)" == "1:$V-sg$REV" ]] \
    && pass "newer: Mozilla's $V over our 156.0 -> built and staged 1:$V-sg$REV" \
    || fail "newer: rc $(rcof newer), staged '$(staged newer)': $(tail -2 "$W/newer.err" | tr '\n' ' ')"
grep -q "verified thunderbird-$V.tar.xz" "$W/newer.err" && pass "newer: the tarball was verified against Mozilla's signed SHA512SUMS" || fail "newer: no verification logged"
[[ -f "$W/c-newer/thunderbird_$V-sg${REV}_amd64.deb" && ! -f "$W/c-newer/thunderbird_156.0-sg1_amd64.deb" ]] \
    && pass "newer: the cache keeps the new package only" || fail "newer: cache holds $(ls "$W/c-newer" | tr '\n' ' ')"
grep -q "^thunderbird [0-9a-f]\{40\}$" "$W/o-newer/SOURCES" 2>/dev/null && pass "newer: its source id is recorded for the repository" || fail "newer: no SOURCES line"
[[ "$(dpkg-deb -f "$W/o-newer/$(staged newer)" Package 2>/dev/null)" == thunderbird ]] && dpkg-deb -c "$W/o-newer/$(staged newer)" 2>/dev/null | grep -c 'usr/lib/thunderbird/omni.ja' >/dev/null \
    && pass "newer: the staged package is the real build" || fail "newer: the staged package is not the real build"

run same same "$(pd "$V")" "file://$W/empty" "$NOWHERE"
[[ $(rcof same) == 0 && "$(staged same)" == "thunderbird_$V-sg${REV}_amd64.deb" ]] && grep -q 'stand-in' "$W/o-same/SOURCES" \
    && pass "same: Mozilla still at $V -> the cached package is reused, nothing downloaded" \
    || fail "same: rc $(rcof same), staged '$(staged same)': $(tail -2 "$W/same.err" | tr '\n' ' ')"

run unreachable older "$NOWHERE/versions.json" "$NOWHERE" "$NOWHERE"
[[ $(rcof unreachable) == 0 && "$(staged unreachable)" == thunderbird_156.0-sg1_amd64.deb ]] \
    && pass "unreachable: Mozilla unreachable -> the cached package, the build goes on" \
    || fail "unreachable: rc $(rcof unreachable), staged '$(staged unreachable)'"
grep -q WARNING "$W/unreachable.err" && pass "unreachable: a warning says so" || fail "unreachable: no warning"

run nothing none "$NOWHERE/versions.json" "$NOWHERE" "$NOWHERE"
[[ $(rcof nothing) != 0 && -z "$(staged nothing)" ]] \
    && pass "nothing: Mozilla unreachable, nothing cached or published -> fails" \
    || fail "nothing: rc $(rcof nothing), staged '$(staged nothing)'"

run seeded none "$(pd "$V")" "file://$W/empty" "file://$W/repo"
[[ $(rcof seeded) == 0 && "$(staged seeded)" == "thunderbird_$V-sg${REV}_amd64.deb" ]] && grep -q 'stand-in' "$W/o-seeded/SOURCES" \
    && pass "seeded: nothing cached -> our repository's published package, reused" \
    || fail "seeded: rc $(rcof seeded), staged '$(staged seeded)': $(tail -2 "$W/seeded.err" | tr '\n' ' ')"

run tampered older "$(pd "$V")" "file://$W/tampered" "$NOWHERE"
[[ $(rcof tampered) == 0 && "$(staged tampered)" == thunderbird_156.0-sg1_amd64.deb ]] && grep -q 'does not match' "$W/tampered.err" \
    && pass "tampered: a tarball not matching Mozilla's signed SHA-512 is refused, the cached package kept" \
    || fail "tampered: rc $(rcof tampered), staged '$(staged tampered)': $(tail -2 "$W/tampered.err" | tr '\n' ' ')"

run forged older "$(pd "$V")" "file://$W/forged" "$NOWHERE"
[[ $(rcof forged) == 0 && "$(staged forged)" == thunderbird_156.0-sg1_amd64.deb ]] && grep -q 'not signed by Mozilla' "$W/forged.err" \
    && pass "forged: SHA512SUMS whose signature is not Mozilla's is refused" \
    || fail "forged: rc $(rcof forged), staged '$(staged forged)': $(tail -2 "$W/forged.err" | tr '\n' ' ')"

[ "$RC" = 0 ] && echo "[thunderbird-update-test] GATE PASS" || echo "[thunderbird-update-test] GATE FAIL"
exit $RC
