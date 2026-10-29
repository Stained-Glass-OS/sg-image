#!/bin/bash
# shellcheck disable=SC2015,SC2016  # pass/fail one-liners only print; the grep pattern is literal
# A new build of a package must sort above the published one, or apt keeps
# the old one on every machine. Release 616 published sg-d3d
# 3.1.1+sg9302f260 (DXVK 0004) under the live 3.1.1+sg21616153: apt called it
# a downgrade and Windows Terminal's pane stayed black.
#   - sg-d3d's version now leads with when dxvk/patches last changed: it sorts
#     above what was published (make d3d-patchrev);
#   - repo/check-upgrade.sh (run by publish) refuses a lower version, passes
#     a higher, an equal and a new package.
# SG_CHECK_UPGRADE= another check-upgrade.sh (mutation test).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHECK=${SG_CHECK_UPGRADE:-$HERE/repo/check-upgrade.sh}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-upgrade-order.XXXXXX")
trap 'rm -rf "$W"' EXIT

deb() { # PKG VERSION DIR -> path of a minimal .deb
    local r="$W/root-$1-$RANDOM"
    mkdir -p "$r/DEBIAN" "$3"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: Stained Glass OS <ke7oxh@gmail.com>\nDescription: test\n' "$1" "$2" > "$r/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$r" "$3/${1}_${2}_all.deb" >/dev/null
    echo "$3/${1}_${2}_all.deb"
}
OLD=3.1.1+sg21616153+vkd3d3.0.1+icu76.1+sg1-1   # live before release 616
deb sg-d3d "$OLD" "$W/live/pool/main/sg-d3d" >/dev/null
deb sg-other 1.0-1 "$W/live/pool/main/sg-other" >/dev/null

rev=$(make -s -C "$HERE" d3d-patchrev)
NEW="3.1.1+sg$rev+vkd3d3.0.1+icu76.1+sg1-1"
dpkg --compare-versions "$NEW" gt "$OLD" \
  && pass "sg-d3d's version now ($NEW) is above the one live before 616" \
  || fail "sg-d3d's version $NEW is not above $OLD: apt would keep the old DXVK"

"$CHECK" "$W/live" "$(deb sg-d3d 3.1.1+sg9302f260+vkd3d3.0.1+icu76.1+sg1-1 "$W/hashonly")" 2>"$W/err" \
  && fail "a lower version (616's hash-only sg-d3d) was let through" \
  || { grep -q "lower than the published" "$W/err" && pass "a lower version is refused: $(head -1 "$W/err")" \
       || fail "refused, but not for the version: $(cat "$W/err")"; }
"$CHECK" "$W/live" "$(deb sg-d3d "$NEW" "$W/new")" \
  && pass "a higher version passes" || fail "a higher version was refused"
"$CHECK" "$W/live" "$(deb sg-other 1.0-1 "$W/same")" \
  && pass "an unchanged version passes (build-repo judges its contents)" || fail "an equal version was refused"
"$CHECK" "$W/live" "$(deb sg-brand-new 0.1-1 "$W/fresh")" \
  && pass "a package not published yet passes" || fail "a new package was refused"
grep -q 'check-upgrade.sh" "$LIVE" "$@"' "$HERE/repo/publish.sh" \
  && pass "publish runs the check on what it publishes" || fail "repo/publish.sh does not run check-upgrade.sh"

[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
