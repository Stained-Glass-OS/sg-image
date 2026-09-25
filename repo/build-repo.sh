#!/usr/bin/env bash
# Build the signed Stained Glass OS apt repository from the image's packages.
#
#   repo/build-repo.sh OUT_DIR DEB...
#
# Produces a standard layout -- pool/main/<package>/<file>.deb and
# dists/trixie/{Release,InRelease,Release.gpg} with main/binary-amd64 indexes --
# signed with the archive key kept in ~/.sgkeys (SG_KEY_DIR), never in a
# repository. Machines verify it with the public key the image ships
# (/usr/share/keyrings/stained-glass-archive-keyring.gpg).
#
# apt upgrades only to a *higher* version, so a package whose contents changed
# without a new version would never reach a machine. If PUBLISHED_DIR (a
# checkout of what is live) is given, a package already there under the same
# version but with different contents is refused: bump the version instead.
set -euo pipefail

OUT=$1; shift
KEY_DIR="${SG_KEY_DIR:-$HOME/.sgkeys}"
export GNUPGHOME="$KEY_DIR/gnupg"
SUITE=trixie
COMPONENT=main
ARCH=amd64

log() { echo "[repo] $*"; }
[[ -d "$GNUPGHOME" ]] || { echo "no signing key at $GNUPGHOME -- see stained-glass docs/package-repository.md" >&2; exit 2; }
FPR=$(gpg --list-secret-keys --with-colons "Stained Glass OS Archive" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
[[ -n "$FPR" ]] || { echo "no 'Stained Glass OS Archive' secret key in $GNUPGHOME" >&2; exit 2; }

rm -rf "$OUT"
mkdir -p "$OUT/dists/$SUITE/$COMPONENT/binary-$ARCH"

for deb in "$@"; do
    pkg=$(dpkg-deb -f "$deb" Package)
    ver=$(dpkg-deb -f "$deb" Version)
    dest="$OUT/pool/$COMPONENT/$pkg"
    mkdir -p "$dest"
    cp "$deb" "$dest/"
    if [[ -n "${PUBLISHED_DIR:-}" ]]; then
        live="$PUBLISHED_DIR/pool/$COMPONENT/$pkg/$(basename "$deb")"
        if [[ -f "$live" ]] && ! cmp -s "$live" "$deb"; then
            echo "refusing: $pkg $ver is already published with different contents." >&2
            echo "          Machines would never receive the change -- bump the version." >&2
            exit 1
        fi
    fi
    log "  $pkg $ver"
done

cd "$OUT"
apt-ftparchive packages "pool/$COMPONENT" > "dists/$SUITE/$COMPONENT/binary-$ARCH/Packages"
gzip -9 -k "dists/$SUITE/$COMPONENT/binary-$ARCH/Packages"
xz -9 -k "dists/$SUITE/$COMPONENT/binary-$ARCH/Packages"
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="Stained Glass OS" \
    -o APT::FTPArchive::Release::Label="Stained Glass OS" \
    -o APT::FTPArchive::Release::Suite="$SUITE" \
    -o APT::FTPArchive::Release::Codename="$SUITE" \
    -o APT::FTPArchive::Release::Architectures="$ARCH all" \
    -o APT::FTPArchive::Release::Components="$COMPONENT" \
    -o APT::FTPArchive::Release::Description="Stained Glass OS packages" \
    release "dists/$SUITE" > "dists/$SUITE/Release"
gpg --batch --yes --local-user "$FPR" --clearsign -o "dists/$SUITE/InRelease" "dists/$SUITE/Release"
gpg --batch --yes --local-user "$FPR" --armor --detach-sign -o "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"
gpg --export "$FPR" > stained-glass-archive-keyring.gpg

# GitHub Pages: serve files as they are, no Jekyll processing.
: > .nojekyll
cat > index.html <<EOF
<!doctype html><meta charset="utf-8"><title>Stained Glass OS packages</title>
<h1>Stained Glass OS apt repository</h1>
<p>Signed with key <code>$FPR</code>
(<a href="stained-glass-archive-keyring.gpg">stained-glass-archive-keyring.gpg</a>).</p>
<pre>Types: deb
URIs: https://freesoft.page/apt
Suites: $SUITE
Components: $COMPONENT
Signed-By: /usr/share/keyrings/stained-glass-archive-keyring.gpg</pre>
<p>Source: <a href="https://github.com/Stained-Glass-OS">github.com/Stained-Glass-OS</a></p>
EOF
log "built and signed ($FPR) in $OUT"
