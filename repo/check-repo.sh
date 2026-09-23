#!/usr/bin/env bash
# Verify a built repository the way an installed machine will: apt, with only
# the archive public key trusted, must accept it -- and must reject a copy whose
# package index was altered after signing. Runs unprivileged in a throwaway apt
# root; touches nothing on the host.
#
#   repo/check-repo.sh REPO_DIR
set -euo pipefail

REPO=$(cd "$1" && pwd)
KEYRING="$REPO/stained-glass-archive-keyring.gpg"
RC=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; RC=1; }

# apt_root REPO -> a fresh apt root whose only source is REPO.
apt_root() {
    local r; r=$(mktemp -d)
    mkdir -p "$r/etc/apt/sources.list.d" "$r/etc/apt/preferences.d" "$r/etc/apt/apt.conf.d" \
             "$r/var/lib/apt/lists/partial" "$r/var/cache/apt/archives/partial" "$r/var/lib/dpkg"
    : > "$r/var/lib/dpkg/status"
    printf 'Types: deb\nURIs: file:%s\nSuites: trixie\nComponents: main\nSigned-By: %s\n' \
        "$1" "$KEYRING" > "$r/etc/apt/sources.list.d/stained-glass.sources"
    echo "$r"
}
apt_opts() {
    echo -o "Dir=$1" -o "Dir::State::status=$1/var/lib/dpkg/status" \
         -o Debug::NoLocking=1 -o APT::Update::Error-Mode=any -o APT::Sandbox::User="$(id -un)"
}

# 1. The real repository is accepted, and apt sees every package in it.
R=$(apt_root "$REPO")
# shellcheck disable=SC2046
if out=$(apt-get $(apt_opts "$R") update 2>&1); then
    pass "apt accepts the signed repository"
    want=$(find "$REPO/pool" -name '*.deb' | wc -l)
    # shellcheck disable=SC2046
    got=$(apt-cache $(apt_opts "$R") dumpavail | grep -c '^Package:' || true)
    if [[ "$got" -eq "$want" ]]; then pass "apt lists all $want packages"
    else fail "apt lists $got packages, the pool has $want"; fi
else
    fail "apt rejected the repository"; printf '%s\n' "$out" | sed 's/^/      /'
fi
rm -rf "$R"

# 2. The same repository with its index altered after signing is rejected.
T=$(mktemp -d)
cp -a "$REPO/." "$T/"
printf '\nPackage: injected\nVersion: 9.9\nArchitecture: all\n' >> "$T/dists/trixie/main/binary-amd64/Packages"
rm -f "$T/dists/trixie/main/binary-amd64/Packages."*
R=$(apt_root "$T")
# shellcheck disable=SC2046
if apt-get $(apt_opts "$R") update >/dev/null 2>&1; then
    fail "apt accepted an index altered after signing"
else
    pass "apt rejects an index altered after signing"
fi
rm -rf "$R" "$T"

echo
if [[ $RC -eq 0 ]]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit $RC
