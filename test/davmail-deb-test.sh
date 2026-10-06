#!/bin/sh
# Gate: the sg-davmail package (davmail/build-deb.sh) -- DavMail, SG Mail's
# gateway to Microsoft mail, calendars and contacts.
#   test/davmail-deb-test.sh DEB [--mutants]
# Checks: upstream's DavMail jar and libraries, unmodified (the same bytes as
# the pinned release zip), but not its jcifs (Debian's libjcifs-java, a
# dependency); the corresponding source of the copyleft parts in the
# package; the runtime it depends on (a Java runtime, SWT with WebKitGTK for
# the sign-in window); /usr/bin/sg-davmail; and, when a root with Java is at
# hand (SG_DAVMAIL_TEST_ROOT, default SG Mail's test root with DavMail's
# runtime: /var/tmp/sgmail/root-tb*), that DavMail starts from the unpacked
# package, listens on the loopback only and asks for DavMail's own sign-in
# ("Basic realm=DavMail Gateway"). SG Mail's davmail gates test the rest.
# --mutants: build-deb.sh with each test hook: the gate must fail.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DEB=$(realpath "$1")
if [ "${2:-}" = --mutants ]; then
    rc=0
    W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-davmail-mut.XXXXXX")
    ver=$(sed -n 's/^DAVMAIL_VERSION *:= *//p' "$HERE/Makefile"); bld=$(sed -n 's/^DAVMAIL_BUILD *:= *//p' "$HERE/Makefile")
    cache=$HERE/build/davmail-cache
    for m in SG_MUTANT_DAVMAIL_BUNDLE_JCIFS SG_MUTANT_DAVMAIL_NO_SOURCE; do
        rm -rf "$W/out"
        env "$m=1" "$HERE/davmail/build-deb.sh" "$ver" "$bld" "$cache/davmail-$ver-$bld.zip" "$cache" "$W/out" >/dev/null 2>&1
        if sh "$0" "$W"/out/sg-davmail_*_all.deb >/dev/null 2>&1; then echo "SURVIVED $m"; rc=1; else echo "KILLED  $m"; fi
    done
    rm -rf "$W"
    [ $rc = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
    exit $rc
fi
W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-davmail-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
dpkg-deb -x "$DEB" "$W/root" || { echo "FAIL  not a package: $DEB"; exit 1; }
ver=$(sed -n 's/^DAVMAIL_VERSION *:= *//p' "$HERE/Makefile"); bld=$(sed -n 's/^DAVMAIL_BUILD *:= *//p' "$HERE/Makefile")
zip=$HERE/build/davmail-cache/davmail-$ver-$bld.zip
S=$W/root/usr/share/sg-davmail
mkdir -p "$W/zip" && unzip -q "$zip" -d "$W/zip"
cmp -s "$W/zip/davmail.jar" "$S/davmail.jar" && pass "DavMail $ver ($bld): upstream's davmail.jar, unmodified" || fail "davmail.jar is not upstream's"
same=1
for j in "$W/zip/lib"/*.jar; do
    b=$(basename "$j")
    case $b in jcifs-*) [ ! -e "$S/lib/$b" ] || same=0 ;; *) cmp -s "$j" "$S/lib/$b" || same=0 ;; esac
done
[ "$(ls "$S/lib" | wc -l)" = "$(( $(ls "$W/zip/lib" | wc -l) - 1 ))" ] || same=0
[ $same = 1 ] && pass "its libraries, unmodified, without its bundled jcifs" || fail "the libraries differ from upstream's (or jcifs is bundled): $(ls "$S/lib" | tr '\n' ' ')"
dep=$(dpkg-deb -f "$DEB" Depends)
case $dep in *libjcifs-java*) pass "jcifs from Debian (libjcifs-java, with its source in Debian)" ;; *) fail "no libjcifs-java dependency: $dep" ;; esac
case $dep in *openjdk-21-jre*libswt-gtk-4-java*libswt-webkit-gtk-4-jni*) pass "depends on a Java runtime and SWT with WebKitGTK (the sign-in window)" ;; *) fail "runtime dependencies: $dep" ;; esac
src=$W/root/usr/share/doc/sg-davmail/source
n=0; for f in "davmail-srconly-$ver-$bld.tgz" jcharset-2.0-sources.jar javax.mail-1.6.2-sources.jar activation-1.1.1-sources.jar; do [ -s "$src/$f" ] && n=$((n+1)); done
[ $n = 4 ] && tar tzf "$src/davmail-srconly-$ver-$bld.tgz" 2>/dev/null | grep -q 'src/java/davmail/DavGateway.java' \
    && pass "the corresponding source: DavMail's, jcharset's, JavaMail's, Activation's" || fail "source missing in /usr/share/doc/sg-davmail/source ($n of 4)"
grep -q 'GPL-2.0+' "$W/root/usr/share/doc/sg-davmail/copyright" && grep -q 'not affiliated' "$W/root/usr/share/doc/sg-davmail/copyright" \
    && pass "copyright: DavMail GPL-2.0+, each library's licence, not affiliated" || fail "copyright incomplete"
[ -x "$W/root/usr/bin/sg-davmail" ] && sh -n "$W/root/usr/bin/sg-davmail" && pass "/usr/bin/sg-davmail" || fail "no /usr/bin/sg-davmail"

# DavMail runs from the unpacked package (a root with its runtime)
R=${SG_DAVMAIL_TEST_ROOT:-$(ls -d /var/tmp/sgmail/root-tb* /var/tmp/*/root-tb* 2>/dev/null | while read -r d; do ls "$d"/usr/lib/jvm/*/bin/java >/dev/null 2>&1 && [ -e "$d/usr/share/java/swt4.jar" ] && echo "$d"; done | head -1)}
if [ -n "$R" ] && ls "$R"/usr/lib/jvm/*/bin/java >/dev/null 2>&1; then
    mkdir -p "$W/home"
    cat > "$W/home/davmail.properties" <<P
davmail.server=true
davmail.enableTray=false
davmail.allowRemote=false
davmail.bindAddress=127.0.0.1
davmail.caldavPort=18899
davmail.imapPort=
davmail.smtpPort=
davmail.popPort=
davmail.ldapPort=
davmail.disableUpdateCheck=true
davmail.mode=O365Graph
davmail.authenticator=davmail.exchange.auth.O365StoredTokenAuthenticator
davmail.logFilePath=$W/home/davmail.log
P
    cat > "$W/probe.sh" <<P
"$W/root/usr/bin/sg-davmail" "$W/home/davmail.properties" -notray -server > "$W/home/out" 2>&1 &
for i in \$(seq 1 60); do ss -Hltn | grep -q ':18899 ' && break; sleep 0.5; done
ss -Hltn | grep ':18899 '
python3 -c "
import http.client
c = http.client.HTTPConnection('127.0.0.1', 18899, timeout=20)
c.request('PROPFIND', '/users/someone@example.com/calendar/', '', {'Depth': '0'})
r = c.getresponse(); print('STATUS', r.status, r.getheader('WWW-Authenticate'))"
P
    out=$(bwrap --die-with-parent --unshare-net --unshare-pid --ro-bind "$R" / --tmpfs /var/tmp --bind "$W" "$W" --dev /dev --proc /proc --tmpfs /tmp \
          --setenv HOME "$W/home" sh "$W/probe.sh" 2>&1)
    echo "$out" | grep -q 'STATUS 401 Basic realm="DavMail Gateway"' && pass "DavMail starts and asks for its own sign-in (401, realm DavMail Gateway)" \
        || fail "DavMail did not answer: $out $(tail -5 "$W/home/out" 2>/dev/null)"
    l=$(echo "$out" | grep ':18899 ')
    [ -n "$l" ] && ! echo "$l" | grep -qv '127\.0\.0\.1\]*:18899 ' && pass "on the loopback only" || fail "not on the loopback only: $l"
else
    echo "SKIP  running DavMail: no root with Java and SWT (SG_DAVMAIL_TEST_ROOT; sg-mail: make root)"
fi
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
