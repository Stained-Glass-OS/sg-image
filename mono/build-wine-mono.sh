#!/bin/sh
# Builds our Wine Mono: upstream wine-mono at $MONO_TAG with mono/patches/
# applied (wine-mono-*.patch to wine-mono itself, mono-*.patch to its mono
# submodule, corefx-*.patch to mono's external/corefx), to <src>/wine-mono-<version>-x86.tar.xz -- the tarball the
# Makefile pins as MONO_TARBALL. What the patches carry: the README there.
#
#   mono/build-wine-mono.sh [SRC-DIR]     (default /var/tmp/wine-mono-build)
#
# Wine Mono's build runs Wine; here always in a scratch HOME and prefix, never
# the person's ~/.wine (its makefile uses the default prefix). Its MSI tables
# need util-linux's uuidgen -s (name-based GUIDs); without it they get "{}"
# and the support MSI does not install (1627), so a stand-in is provided
# where uuidgen is missing.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
MONO_TAG=${MONO_TAG:-wine-mono-9.4.0}
SRC=${1:-/var/tmp/wine-mono-build}
if [ ! -d "$SRC/.git" ]; then
    git clone --branch "$MONO_TAG" --recursive https://gitlab.winehq.org/mono/wine-mono.git "$SRC"
    for p in "$HERE"/patches/wine-mono-*.patch; do git -C "$SRC" apply "$p"; done
    for p in "$HERE"/patches/mono-*.patch; do git -C "$SRC/mono" apply "$p"; done
    # mono's own submodule, corefx (System.Drawing's Brush comes from it)
    for p in "$HERE"/patches/corefx-*.patch; do git -C "$SRC/mono/external/corefx" apply "$p"; done
fi
W="$SRC/.sg-build"
mkdir -p "$W/home" "$W/bin"
if ! command -v uuidgen >/dev/null; then
    cat > "$W/bin/uuidgen" <<'PY'
#!/usr/bin/env python3
# uuidgen -s -n NAMESPACE -N NAME: a name-based (SHA-1) UUID, as util-linux's
import sys, uuid
a = sys.argv[1:]
assert '-s' in a
print(uuid.uuid5(uuid.UUID(a[a.index('-n') + 1]), a[a.index('-N') + 1]))
PY
    chmod +x "$W/bin/uuidgen"
fi
export HOME="$W/home" WINEPREFIX="$W/home/pfx" WINEDEBUG=-all WINEDLLOVERRIDES="winemenubuilder.exe=d"
export PATH="$W/bin:$PATH"
[ -d "$WINEPREFIX" ] || { wineboot -i >/dev/null 2>&1; wineserver -w; }
nice make -C "$SRC" -j"${JOBS:-3}" bin
ls -l "$SRC"/wine-mono-*-x86.tar.xz
