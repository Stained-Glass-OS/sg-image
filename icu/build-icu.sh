#!/bin/sh
# ICU for Windows programs, built from Debian's ICU source with mingw-w64:
# Windows 10 has ICU in System32 -- icuuc.dll, icuin.dll and the combined
# icu.dll, unversioned C API names -- and programs use it (Qt 6's Windows
# builds: calibre, CMake's GUI; winget). A Unix (native) build first, for the
# tools the cross build runs; then the mingw build with U_DISABLE_RENAMING
# (u_strlen, not u_strlen_76), its data as a DLL; then forwarders under the
# System32 names, each export passed on to the versioned DLL.
#
#   build-icu.sh SOURCE.tar.gz OUT_DIR [ARCH...]     (ARCH: x86_64 i686; default x86_64)
#
# The programs that use the system's ICU are 64-bit (Qt 6, winget); i686 can
# be asked for. OUT_DIR/ARCH gets the DLLs and LICENSE.icu.
set -eu
SRC=$1 OUT=$2; shift 2
ARCHS=${*:-x86_64}
J=${J:-3}
W=$(mktemp -d /var/tmp/sg-icu-build.XXXXXX)
trap 'rm -rf "$W"' EXIT
tar -C "$W" -xzf "$SRC"
S="$W/icu/source"
ver=$(sed -n 's/^#define U_ICU_VERSION_MAJOR_NUM \([0-9]*\).*/\1/p' "$S/common/unicode/uvernum.h")
[ -n "$ver" ] || { echo "build-icu: no ICU version in $SRC" >&2; exit 1; }

mkdir "$W/native"
(cd "$W/native" && sh "$S/runConfigureICU" Linux --disable-tests --disable-samples >/dev/null && nice make -j"$J" >/dev/null)

# The locales ICU lists as installed (res_index's InstalledLocales), without
# those .NET cannot make a culture of: Windows' own ICU is older and has none
# of them, and with this ICU every CultureInfo.GetCultures() threw ("bgc is an
# invalid culture identifier") -- MeediOS lost its core and crashed at every
# click (David, 2026-10-03). Found with .NET 10 against this ICU 76: each
# available locale given to CultureInfo.GetCultureInfo. Their data stays; only
# the list leaves them out, so nothing enumerates them.
DOTNET_UNKNOWN="bgc bgc_IN bho bho_IN cv cv_RU en_MV en_US_POSIX gaa gaa_GH hi_Latn hi_Latn_IN ko_CN ku_TR kxv kxv_Deva
    kxv_Deva_IN kxv_Latn kxv_Latn_IN kxv_Orya kxv_Orya_IN kxv_Telu kxv_Telu_IN lij lij_IT lmo lmo_IT oc_ES raj raj_IN
    syr_IQ szl szl_PL tok tok_001 vec vec_IT"
dat="$S/data/in/icudt${ver}l.dat"     # icupkg takes the package's name from this file's
N="$W/native"
R="$W/res-index"
mkdir -p "$R/out"
export LD_LIBRARY_PATH="$N/lib"
# items are named without the package's prefix (res_index.res, not icudt76l/...)
"$N/bin/icupkg" -x res_index.res -d "$R" "$dat"
(cd "$R" && "$N/bin/derb" -s "$R" -d "$R" -e UTF-8 res_index.res)
[ -s "$R/res_index.txt" ] || { echo "build-icu: res_index.res could not be read" >&2; exit 1; }
n0=$(grep -c '{ "" }' "$R/res_index.txt")
for l in $DOTNET_UNKNOWN; do
    sed -i "/^ *$l { \"\" }\$/d" "$R/res_index.txt"
done
pat=$(echo $DOTNET_UNKNOWN | sed 's/ /|/g')
left=$(grep -cE "^ *($pat) \{" "$R/res_index.txt" || true)
[ "$left" = 0 ] || { echo "build-icu: res_index still lists $left of the locales .NET cannot use" >&2; exit 1; }
grep -q '^ *en_US { "" }$' "$R/res_index.txt" || { echo "build-icu: res_index.txt is not what was expected" >&2; exit 1; }
# as ICU's own build writes it: without it, "res_index" reads as a locale whose parent is "res"
sed -i 's/^res_index{$/res_index:table(nofallback){/' "$R/res_index.txt"
"$N/bin/genrb" -q -e UTF-8 -s "$R" -d "$R/out" res_index.txt
"$N/bin/icupkg" -s "$R/out" -a res_index.res "$dat"
echo "build-icu: installed locales $n0 -> $(grep -c '{ "" }' "$R/res_index.txt") (without those .NET cannot use)"
unset LD_LIBRARY_PATH

for a in $ARCHS; do
    host=$a-w64-mingw32
    # the plain compilers, or their posix-threads twins (all a CI runner may have)
    cc=$host-gcc cxx=$host-g++
    command -v "$cxx" >/dev/null || { cc=$host-gcc-posix; cxx=$host-g++-posix; }
    command -v "$cxx" >/dev/null || { echo "build-icu: $host-g++ is missing" >&2; exit 1; }
    b="$W/$a"
    mkdir "$b"
    # posix-threads compilers link winpthread: statically, so the DLLs import
    # only system DLLs -- a search directory first in line whose pthread
    # import libraries are the static archive
    sp="$W/static-pthread-$a"
    mkdir "$sp"
    wp=$("$cc" -print-file-name=libwinpthread.a)
    if [ -f "$wp" ]; then ln -s "$wp" "$sp/libpthread.dll.a"; ln -s "$wp" "$sp/libwinpthread.dll.a"; fi
    (cd "$b" && CC="$cc" CXX="$cxx" CPPFLAGS="-DU_DISABLE_RENAMING=1" CFLAGS="-O2" CXXFLAGS="-O2" \
        LDFLAGS="-L$sp -static-libgcc -static-libstdc++ -Wl,--exclude-libs,ALL" \
        sh "$S/configure" --host="$host" --with-cross-build="$W/native" --enable-shared --disable-static \
        --disable-tests --disable-samples --disable-extras --disable-tools --disable-icuio --disable-layoutex \
        --with-data-packaging=library >/dev/null && nice make -j"$J" >/dev/null)
    o="$OUT/$a"
    rm -rf "$o"; mkdir -p "$o"
    for l in icuuc icuin icudt; do
        f=$(ls "$b/lib/$l$ver.dll" "$b/bin/$l$ver.dll" 2>/dev/null | head -1)
        [ -f "$f" ] || { echo "build-icu: $l$ver.dll was not built ($a)" >&2; exit 1; }
        cp "$f" "$o/"
    done
    "$host-strip" "$o/icuuc$ver.dll" "$o/icuin$ver.dll"
    # forwarders: icuuc.dll -> icuuc$ver.dll, icuin.dll -> icuin$ver.dll,
    # icu.dll -> both (Windows 10 1903's combined name)
    exports() { "$host-objdump" -p "$1" | awk '/\[Ordinal\/Name Pointer\] Table/ { on = 1; next } on && NF == 0 { exit } on { print $NF }'; }
    fwd() { # NAME TARGET...
        name=$1; shift
        { echo "LIBRARY $name.dll"; echo "EXPORTS"
          for t in "$@"; do exports "$o/$t.dll" | sed "s/.*/    & = $t.&/"; done; } > "$b/$name.def"
        echo 'int __stdcall DllMain(void *h, unsigned r, void *p) { return 1; }' > "$b/$name.c"
        "$cc" -O2 -shared -nostdlib -o "$o/$name.dll" "$b/$name.c" "$b/$name.def" \
            -Wl,--entry,$( [ "$a" = i686 ] && echo _DllMain@12 || echo DllMain ) -lkernel32
    }
    fwd icuuc "icuuc$ver"
    fwd icuin "icuin$ver"
    fwd icu "icuuc$ver" "icuin$ver"
    cp "$S/../LICENSE" "$o/LICENSE.icu"
    # what the forwarders must carry, and that the DLLs need nothing but
    # Windows' own and each other
    for f in u_strlen u_strToUpper ubrk_open ucnv_open; do
        "$host-objdump" -p "$o/icuuc.dll" | grep -q "Forwarder RVA -- icuuc$ver\.$f\$" || { echo "build-icu: icuuc.dll does not forward $f" >&2; exit 1; }
    done
    for f in ucol_open udat_open uregex_open; do
        "$host-objdump" -p "$o/icu.dll" | grep -q "Forwarder RVA -- icuin$ver\.$f\$" || { echo "build-icu: icu.dll does not forward $f" >&2; exit 1; }
    done
    bad=$(for d in "$o/icuuc$ver.dll" "$o/icuin$ver.dll"; do "$host-objdump" -p "$d" | sed -n 's/.*DLL Name: //p'; done |
          grep -viE "^(icuuc|icudt|icuin)$ver\.dll$|^(kernel32|advapi32|msvcrt|user32)\.dll$" || true)
    [ -z "$bad" ] || { echo "build-icu: unexpected imports: $bad" >&2; exit 1; }
done
echo "ICU $ver: $(for a in $ARCHS; do ls "$OUT/$a" | tr '\n' ' '; done)"
