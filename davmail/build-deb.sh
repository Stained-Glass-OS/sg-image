#!/bin/bash
# Package DavMail as a .deb: sg-davmail.
#
#   davmail/build-deb.sh VERSION BUILD ZIP SOURCES_DIR OUT_DIR
#
# DavMail (https://davmail.sourceforge.net, Mickael Guessant, GPL-2.0) is a
# gateway: it talks to Microsoft 365 / Outlook.com (Microsoft Graph) and
# Exchange (EWS) and offers the open protocols on this computer -- CalDAV and
# CardDAV here. SG Mail (sg-mail) runs it per user, on the loopback only, so
# that Thunderbird's own CalDAV and CardDAV clients read and write Microsoft
# calendars and contacts (David 2026-10-06; no Thunderbird release does yet).
# The Microsoft sign-in is DavMail's own (its sign-in window and token
# cache); nothing of ours takes part in it.
#
# Why our own package: Debian trixie's davmail is 6.3.0, before DavMail's
# Graph backend was usable (6.8) and before 7.0's Graph fixes -- and Exchange
# Online retires EWS from October 2026. So: upstream's platform-independent
# release (davmail-VERSION-BUILD.zip, pinned by sha256 in the Makefile),
# unmodified, under /usr/share/sg-davmail, with
#   - its bundled jcifs (LGPL) left out for Debian's libjcifs-java, the same
#     1.3.19, whose source Debian publishes;
#   - Debian's SWT (libswt-gtk-4-java and its WebKitGTK browser) for DavMail's
#     sign-in window; Debian's Java runtime;
#   - /usr/bin/sg-davmail, our launcher (classpath, SWT, java options);
#   - the corresponding source of what is under a copyleft licence, in
#     /usr/share/doc/sg-davmail/source: DavMail's own source release and the
#     sources of the bundled jcharset (GPL-2.0), JavaMail (CDDL/GPL-2.0+CE)
#     and JavaBeans Activation (CDDL), each pinned by sha256 in the Makefile.
#
# A new upstream version, or a change here, must come with a new package
# version (the repository refuses changed contents under an unchanged
# version): bump DAVMAIL_REV in the Makefile for a packaging change.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail
DM_VERSION=${1:?usage: build-deb.sh VERSION BUILD ZIP SOURCES_DIR OUT_DIR [REV]}
DM_BUILD=${2:?usage}
ZIP=${3:?usage}
SRCDIR=${4:?usage}
OUT=${5:?usage}
REV=${6:-1}
PKG=sg-davmail
VERSION=$DM_VERSION-sg$REV

[[ "$DM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "build-deb: odd DavMail version '$DM_VERSION'" >&2; exit 1; }
W=$(mktemp -d "${TMPDIR:-/var/tmp}/sg-davmail-deb.XXXXXX")
trap 'rm -rf "$W"' EXIT
R="$W/root"
S="$R/usr/share/$PKG"
D="$R/usr/share/doc/$PKG"
mkdir -p "$W/zip" "$S/lib" "$D/source" "$R/DEBIAN" "$R/usr/bin" "$OUT"
unzip -q "$ZIP" -d "$W/zip"
[[ -f "$W/zip/davmail.jar" && -d "$W/zip/lib" ]] || { echo "build-deb: $ZIP is not DavMail's platform-independent release" >&2; exit 1; }
got=$(unzip -p "$W/zip/davmail.jar" META-INF/MANIFEST.MF | tr -d '\r' | sed -n 's/^Implementation-Version: //p')
[[ -z "$got" || "$got" == "$DM_VERSION"* ]] || { echo "build-deb: $ZIP is DavMail $got, not $DM_VERSION" >&2; exit 1; }
cp "$W/zip/davmail.jar" "$S/"
for j in "$W/zip/lib"/*.jar; do
    case $(basename "$j") in
        # Debian's libjcifs-java instead (test hook: test/davmail-deb-test.sh's mutant)
        jcifs-*.jar) [[ "${SG_MUTANT_DAVMAIL_BUNDLE_JCIFS:-0}" == 1 ]] || continue ;;
    esac
    cp "$j" "$S/lib/"
done
for f in "davmail-srconly-$DM_VERSION-$DM_BUILD.tgz" jcharset-2.0-sources.jar javax.mail-1.6.2-sources.jar activation-1.1.1-sources.jar; do
    [[ -f "$SRCDIR/$f" ]] || { echo "build-deb: missing $SRCDIR/$f (the corresponding source)" >&2; exit 1; }
    [[ "${SG_MUTANT_DAVMAIL_NO_SOURCE:-0}" == 1 ]] || cp "$SRCDIR/$f" "$D/source/"
done

cat > "$R/usr/bin/sg-davmail" <<'EOF'
#!/bin/sh
# DavMail, as Stained Glass OS packages it (sg-davmail): the gateway between
# Microsoft 365 / Outlook.com / Exchange and CalDAV, CardDAV (and IMAP, SMTP,
# LDAP) on this computer. Arguments are DavMail's own:
#   sg-davmail [/path/to/davmail.properties] [-notray] [-server]
# SG Mail runs it per user as the systemd user service sg-mail-davmail@.
# (beside this script: /usr/bin -> /usr/share/sg-davmail; an unpacked
# package's tree works as well)
SHARE=$(cd "$(dirname "$(readlink -f "$0")")/../share/sg-davmail" && pwd) || exit 1
CP="$SHARE/davmail.jar:$SHARE/lib/*:/usr/share/java/jcifs.jar"
# the sign-in window: SWT with its WebKitGTK browser (Debian's)
if [ -e /usr/share/java/swt4.jar ]; then
    CP="$CP:/usr/share/java/swt4.jar"
    LD_LIBRARY_PATH=/usr/lib/jni${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    export LD_LIBRARY_PATH
fi
# SWT draws through X11 here (Stained Glass OS's Linux programs use Xwayland)
GDK_BACKEND=${GDK_BACKEND:-x11}
export GDK_BACKEND
: "${SG_DAVMAIL_JAVA_OPTS:=-Xmx384M -Dsun.net.inetaddr.ttl=60 --enable-native-access=ALL-UNNAMED}"
# shellcheck disable=SC2086  # the options, split
exec java $SG_DAVMAIL_JAVA_OPTS -cp "$CP" davmail.DavGateway "$@"
EOF
chmod 0755 "$R/usr/bin/sg-davmail"

cat > "$D/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: DavMail
Upstream-Contact: Mickael Guessant <mguessan@free.fr>
Source: https://sourceforge.net/projects/davmail/files/davmail/$DM_VERSION/
 davmail-$DM_VERSION-$DM_BUILD.zip, upstream's platform-independent release,
 unmodified (its bundled jcifs jar left out for Debian's libjcifs-java).
 The corresponding source is in /usr/share/doc/sg-davmail/source:
 davmail-srconly-$DM_VERSION-$DM_BUILD.tgz (DavMail), and the -sources.jar
 of jcharset 2.0, JavaMail 1.6.2 and JavaBeans Activation 1.1.1 (Maven
 Central). Upstream's full source release with every bundled library,
 davmail-src-$DM_VERSION-$DM_BUILD.tgz, is at the address above.
Comment: Packaged by Stained Glass OS (sg-image davmail/). Stained Glass OS is
 not affiliated with DavMail's author or with Microsoft. DavMail signs in to
 Microsoft with its own registration and its own sign-in window.

Files: usr/share/sg-davmail/davmail.jar
Copyright: 2009-2026 Mickael Guessant and DavMail contributors
License: GPL-2.0+
 On Debian systems the full text is in /usr/share/common-licenses/GPL-2.

Files: usr/share/sg-davmail/lib/jcharset-*.jar
Copyright: Amichai Rothman
License: GPL-2.0
 /usr/share/common-licenses/GPL-2 (source: source/jcharset-2.0-sources.jar)

Files: usr/share/sg-davmail/lib/javax.mail-*.jar usr/share/sg-davmail/lib/activation-*.jar
Copyright: Oracle and/or its affiliates; Sun Microsystems
License: CDDL-1.1 or GPL-2.0 with Classpath exception
 https://javaee.github.io/javamail/LICENSE (sources: source/*-sources.jar)

Files: usr/share/sg-davmail/lib/commons-*.jar usr/share/sg-davmail/lib/http*.jar
 usr/share/sg-davmail/lib/jackrabbit-*.jar usr/share/sg-davmail/lib/jettison-*.jar
 usr/share/sg-davmail/lib/reload4j-*.jar usr/share/sg-davmail/lib/woodstox-*.jar
 usr/share/sg-davmail/lib/stax-api-*.jar
Copyright: The Apache Software Foundation and the respective authors
License: Apache-2.0
 /usr/share/common-licenses/Apache-2.0

Files: usr/share/sg-davmail/lib/htmlcleaner-*.jar usr/share/sg-davmail/lib/stax2-api-*.jar
 usr/share/sg-davmail/lib/jdom-*.jar
Copyright: the HtmlCleaner, StAX2 and JDOM authors
License: BSD-3-clause or BSD-style (JDOM licence)

Files: usr/share/sg-davmail/lib/slf4j-*.jar
Copyright: QOS.ch
License: MIT

Files: usr/bin/sg-davmail
Copyright: Stained Glass OS contributors
License: AGPL-3.0-or-later
EOF

chmod -R u=rwX,go=rX "$R/usr"
size=$(du -sk "$R/usr" | cut -f1)
cat > "$R/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: Stained Glass OS <ke7oxh@gmail.com>
Installed-Size: $size
Section: mail
Priority: optional
Homepage: https://davmail.sourceforge.net/
Depends: openjdk-21-jre | openjdk-25-jre | java11-runtime, libswt-gtk-4-java, libswt-cairo-gtk-4-jni, libswt-webkit-gtk-4-jni, libjcifs-java
Description: DavMail gateway for Microsoft 365, Outlook.com and Exchange
 DavMail $DM_VERSION (build $DM_BUILD): a gateway that talks to Microsoft 365
 and Outlook.com (Microsoft Graph) or an Exchange server (EWS) and offers
 CalDAV, CardDAV, IMAP, SMTP and LDAP on this computer, so that standard
 mail, calendar and address book programs work with those accounts. SG Mail
 uses it for Microsoft calendars and contacts. DavMail's sign-in to
 Microsoft is its own, in its own window.
EOF
dpkg-deb --root-owner-group -Zxz --build "$R" "$OUT/${PKG}_${VERSION}_all.deb" >/dev/null
echo "[davmail-deb] $OUT/${PKG}_${VERSION}_all.deb"
