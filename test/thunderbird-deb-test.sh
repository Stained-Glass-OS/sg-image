#!/bin/bash
# Our thunderbird package (thunderbird/build-deb.sh) installs, in throwaway
# Debian trixie roots (rootless mmdebstrap, nothing on this machine changes):
#
#   upgrade  a machine with Debian's thunderbird (and a thunderbird-l10n
#            package) takes ours with apt: Debian's layout (symlinked
#            chrome/defaults/isp) becomes ours, Debian's pref file and AppArmor
#            profile go, the version is ours, `thunderbird --version` says the
#            packaged version, dpkg and apt are content;
#   fresh    a machine without it: apt installs ours with its own Depends
#            only, and no library the program needs is missing (our Depends
#            line is complete).
#
# And the package carries Mozilla's tarball unmodified (every file of it, the
# same bytes), plus only our policies.json and the dictionaries link.
#
#   test/thunderbird-deb-test.sh DEB TARBALL [--mutants]
#
# --mutants builds the package with each SG_MUTANT_TB_* hook of build-deb.sh
# (no epoch: apt would not upgrade Debian's; no symlink_to_dir; Debian's
# conffiles kept) and expects this gate to FAIL for each.
# Downloads are cached in ${SG_TB_TEST_CACHE:-build/thunderbird-cache/test-apt}.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
DEB=${1:?usage: thunderbird-deb-test.sh DEB TARBALL [--mutants]}
TARBALL=${2:?usage}
DEB=$(realpath "$DEB"); TARBALL=$(realpath "$TARBALL")
CACHE=${SG_TB_TEST_CACHE:-$HERE/build/thunderbird-cache/test-apt}
mkdir -p "$CACHE"; CACHE=$(realpath "$CACHE")
export TMPDIR=${TMPDIR:-/var/tmp}

if [[ "${3:-}" == --mutants ]]; then
    rc=0
    ver=$(dpkg-deb -f "$DEB" Version); ver=${ver#*:}; ver=${ver%-sg*}
    for m in SG_MUTANT_TB_NO_EPOCH SG_MUTANT_TB_NO_SYMLINK_TO_DIR SG_MUTANT_TB_KEEP_CONFFILES; do
        o=$(mktemp -d)
        env "$m=1" "$HERE/thunderbird/build-deb.sh" "$TARBALL" "$ver" "$o" >/dev/null || { echo "MUTANT $m: build failed"; rc=1; continue; }
        if "$0" "$o"/thunderbird_*.deb "$TARBALL" > "$o/log" 2>&1; then
            echo "MUTANT $m: gate PASSED (should fail)"; rc=1
        else
            echo "MUTANT $m: gate failed, as it must ($(grep -m1 '^FAIL' "$o/log"))"
        fi
        rm -rf "$o"
    done
    exit $rc
fi

command -v mmdebstrap >/dev/null || { echo "SKIP: no mmdebstrap"; exit 77; }
W=$(mktemp -d "$TMPDIR/sg-tb-test.XXXXXX"); trap 'rm -rf "$W"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
want=$(dpkg-deb -f "$DEB" Version)
moz=${want#*:}; moz=${moz%-sg*}

# 1. the package carries Mozilla's tarball unmodified
mkdir -p "$W/tar" "$W/deb"
tar -C "$W/tar" -xJf "$TARBALL"
dpkg-deb -x "$DEB" "$W/deb"
if diff -r --no-dereference -x distribution -x dictionaries "$W/tar/thunderbird" "$W/deb/usr/lib/thunderbird" > "$W/diff"; then
    pass "every file of Mozilla's tarball is in the package, unmodified, and nothing else in its directory"
else
    fail "the package's /usr/lib/thunderbird differs from Mozilla's tarball: $(head -3 "$W/diff")"
fi
extra=$(cd "$W/deb/usr/lib/thunderbird" && find distribution dictionaries | sort | tr '\n' ' ')
[[ "$extra" == "dictionaries distribution distribution/policies.json " ]] \
    && pass "beside it only distribution/policies.json and the dictionaries link" || fail "extra files: $extra"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["policies"]; sys.exit(0 if p.get("DisableAppUpdate") is True else 1)' \
    "$W/deb/usr/lib/thunderbird/distribution/policies.json" && pass "policies.json turns Thunderbird's own updater off" || fail "no DisableAppUpdate policy"
rm -rf "$W/tar" "$W/deb"

# 2. upgrade from Debian's, 3. fresh install: checks run inside the root
cp "$DEB" "$W/tb.deb"
cat > "$W/check.sh" <<'EOF'
#!/bin/sh
# runs inside the root, as its root; one line per check
want=$1; moz=$2
r() { if eval "$2" >/dev/null 2>&1; then echo "PASS  $1"; else echo "FAIL  $1"; fi; }
r "thunderbird is ours ($want)" '[ "$(dpkg-query -W -f "\${Version}" thunderbird)" = "$want" ]'
v=$(HOME=/tmp thunderbird --version 2>/dev/null)
r "thunderbird --version says $moz (got: $v)" '[ "$v" = "Mozilla Thunderbird ${moz%esr}" ]'
for d in chrome defaults isp; do
    r "/usr/lib/thunderbird/$d is a directory (Debian's symlink gone)" '[ -d /usr/lib/thunderbird/$d ] && [ ! -L /usr/lib/thunderbird/$d ]'
done
r "no .dpkg-backup left" '[ -z "$(find /usr/lib/thunderbird -maxdepth 1 -name "*.dpkg-*")" ]'
r "Debian's AppArmor profile is gone" '[ ! -e /etc/apparmor.d/usr.bin.thunderbird ]'
r "Debian's pref file is gone" '[ ! -e /etc/thunderbird/pref/thunderbird.js ]'
r "Debian's /usr/share/thunderbird is gone" '[ ! -e /usr/share/thunderbird/omni.ja ]'
r "/usr/bin/thunderbird runs Mozilla's build" '[ "$(readlink -f /usr/bin/thunderbird)" = /usr/lib/thunderbird/thunderbird ]'
r "the desktop entry and icons are ours" '[ -f /usr/share/applications/thunderbird.desktop ] && [ -f /usr/share/icons/hicolor/48x48/apps/thunderbird.png ]'
miss=$(for f in /usr/lib/thunderbird/thunderbird /usr/lib/thunderbird/thunderbird-bin /usr/lib/thunderbird/*.so; do LD_LIBRARY_PATH=/usr/lib/thunderbird ldd "$f" 2>/dev/null; done | grep 'not found' | sort -u | tr '\n' ' ')
r "no library is missing ($miss)" '[ -z "$miss" ]'
r "dpkg --audit is clean" '[ -z "$(dpkg --audit)" ]'
r "apt-get check is content" 'apt-get -qq check'
r "dpkg --verify thunderbird finds nothing changed" '[ -z "$(dpkg --verify thunderbird)" ]'
EOF
chmod +x "$W/check.sh"
mm() { # name, includes, then the install command
    local name=$1 inc=$2 inst=$3
    nice -n 10 mmdebstrap --mode=unshare --variant=apt --format=null --quiet \
        --skip=download/empty --skip=essential/unlink \
        --setup-hook='mkdir -p "$1/var/cache/apt/archives"' \
        --setup-hook="sync-in $CACHE /var/cache/apt/archives/" \
        --include="$inc" \
        --customize-hook="copy-in $W/tb.deb $W/check.sh /tmp" \
        --customize-hook="chroot \"\$1\" sh -c '$inst' > \"\$1/tmp/$name.install\" 2>&1 || echo INSTALL-FAILED >> \"\$1/tmp/$name.install\"" \
        --customize-hook="chroot \"\$1\" /tmp/check.sh '$want' '$moz' > \"\$1/tmp/$name.result\" 2>&1 || true" \
        --customize-hook="chroot \"\$1\" dpkg-query -W -f '\${Package} \${Status}\n' 'thunderbird*' > \"\$1/tmp/$name.pkgs\" 2>&1 || true" \
        --customize-hook="copy-out /tmp/$name.install /tmp/$name.result /tmp/$name.pkgs $W" \
        --customize-hook="sync-out /var/cache/apt/archives $CACHE" \
        trixie /dev/null \
        "deb http://deb.debian.org/debian trixie main" \
        "deb http://deb.debian.org/debian-security trixie-security main" \
        "deb http://deb.debian.org/debian trixie-updates main" > "$W/$name.mm" 2>&1
}
echo "[thunderbird-deb-test] upgrade: Debian's thunderbird -> ours"
if mm upgrade "ca-certificates,thunderbird,thunderbird-l10n-de" \
        "dpkg-query -W thunderbird; DEBIAN_FRONTEND=noninteractive apt-get -y -q install /tmp/tb.deb"; then
    grep -q INSTALL-FAILED "$W/upgrade.install" && fail "apt did not install ours over Debian's: $(grep -E '^E:|downgrad' "$W/upgrade.install" | head -2 | tr '\n' ' ')"
    sed 's/^\(PASS\|FAIL\)  /\1  upgrade: /' "$W/upgrade.result"
    grep -q '^FAIL' "$W/upgrade.result" && RC=1
    grep -q 'thunderbird-l10n-de install ok installed' "$W/upgrade.pkgs" \
        && fail "upgrade: Debian's thunderbird-l10n-de (made for its own version) was left installed" \
        || pass "upgrade: Debian's language pack for its version was taken off with it"
else
    fail "upgrade: mmdebstrap failed: $(tail -3 "$W/upgrade.mm")"
fi
echo "[thunderbird-deb-test] fresh: ours with its own Depends only"
if mm fresh "ca-certificates" "DEBIAN_FRONTEND=noninteractive apt-get -y -q --no-install-recommends install /tmp/tb.deb"; then
    grep -q INSTALL-FAILED "$W/fresh.install" && fail "fresh: apt could not install ours: $(grep '^E:' "$W/fresh.install" | head -2)"
    sed 's/^\(PASS\|FAIL\)  /\1  fresh: /' "$W/fresh.result"
    grep -q '^FAIL' "$W/fresh.result" && RC=1
else
    fail "fresh: mmdebstrap failed: $(tail -3 "$W/fresh.mm")"
fi
[ "$RC" = 0 ] && echo "[thunderbird-deb-test] GATE PASS" || echo "[thunderbird-deb-test] GATE FAIL"
exit $RC
