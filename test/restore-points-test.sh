#!/bin/bash
# shellcheck disable=SC2015,SC2016  # pass/fail chains; commands run in the guest
# Restore points and going back, in QEMU (sg-session's sg-snapshot, 0.1.0-180):
#
#   btrfs  a disk Setup installed (SG_RP_DISK, default build/install-target.raw
#          from `make install-test`; SG_SESSION_DEB installs a package under
#          test first): the system is @ with its subvolumes; an apt run that
#          changes packages (hello, from Debian) takes a restore point,
#          labelled, with a boot entry; that entry, started once, runs the
#          restore point (hello not there; the files made since in the home
#          and the Windows programs' prefix are); then, on the current system,
#          going back to it (what Settings asks sg-admind for): at the restart
#          hello is gone, the home and prefix files stay, the version is kept
#          from apt, the old system deleted, the desktop comes up.
#   ext4   a disk installed before 0.1.0-180 (SG_RP_EXT4_DISK; skipped without):
#          updated to SG_SESSION_DEB; a later build of it (+t1, made here)
#          installed: the replaced version is kept; "Undo the last update",
#          at the restart, puts it back before anyone signs in and pins +t1.
#          Then the conversion: scheduled (the checks pass), the restart runs
#          it in its own initrd and restarts again into btrfs @ with the
#          subvolumes, the home and prefix files there, the conversion
#          recorded and the old file system kept; a restore point is taken by
#          the next apt run; undoing the conversion makes it ext4 again with
#          the files as they were before it.
#
# Needs KVM and the network (Debian's archive). SG_RP_SCENARIOS="btrfs ext4".
# `make restore-points-test`.
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=${SG_BUILD:-$HERE/build}
KEY=${SG_SSH_KEY:-$BUILD/ssh/id_ed25519}
PORT=${SG_SSH_PORT:-2394}
W=${SG_RP_WORK:-/var/tmp/sg-restore-points-test}
ART="$BUILD/artifacts-restore-points"
OVMF_CODE=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
[ -f "$KEY" ] || { echo "SKIP: no ssh key"; exit 77; }
mkdir -p "$W" "$ART"
QPID=""
stop() { [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""; }
trap 'stop; rm -f "$W/disk.raw"' EXIT INT TERM
SSHO=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
g() { ssh "${SSHO[@]}" -p "$PORT" root@127.0.0.1 "$@"; }
put() { scp -q "${SSHO[@]}" -P "$PORT" "$1" root@127.0.0.1:"$2"; }
wait_ssh() { local i=0; sleep 10; until g true 2>/dev/null; do i=$((i + 1)); [ "$i" -lt "${1:-100}" ] || return 1; sleep 3; done; }
boot() {
    stop
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 4 \
        -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,unit=1,file="$W/vars.fd" \
        -drive if=virtio,format=raw,file="$W/disk.raw" \
        -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(base64 -w0 < "$KEY.pub")" \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$PORT"-:22 -device virtio-net-pci,netdev=n0 \
        -display none -serial file:"$ART/serial-$1.log" -monitor none -qmp unix:"$W/qmp.sock",server=on,wait=off >"$ART/qemu-$1.log" 2>&1 &
    QPID=$!
    wait_ssh
}
# a key at the boot menu, as a person would press it (QEMU's monitor)
qmp_key() { printf '{"execute":"qmp_capabilities"}\n{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"%s"}]}}\n' "$1" | socat -t1 - UNIX-CONNECT:"$W/qmp.sock" >/dev/null 2>&1; }
# a restart, and the system up again (the conversion restarts twice: a longer wait)
restart() { g systemctl reboot >/dev/null 2>&1; sleep 20; wait_ssh "${1:-100}"; }
fresh() { rm -f "$W/disk.raw"; cp --sparse=always "$1" "$W/disk.raw"; cp "${OVMF_CODE/CODE/VARS}" "$W/vars.fd"; }
st() { g cat /run/stained-glass-snapshot/status 2>/dev/null; }
install_deb() {   # the package under test, with what it needs from the archive
    [ -n "${SG_SESSION_DEB:-}" ] || return 0
    put "$SG_SESSION_DEB" /root/sg-session-test.deb
    g "timeout 600 apt-get -q update >/dev/null 2>&1; ${SG_MUTANT_RP_ENV:-} DEBIAN_FRONTEND=noninteractive timeout 1800 apt-get -y -q install /root/sg-session-test.deb" \
        > "$ART/install-$1.log" 2>&1 && pass "$1: the package under test installs ($(dpkg-deb -f "$SG_SESSION_DEB" Version))" \
        || { fail "$1: the package under test did not install (install-$1.log)"; return 1; }
    g 'sg-snapshot status >/dev/null 2>&1'
}

for s in ${SG_RP_SCENARIOS:-btrfs ext4}; do
    case $s in
    btrfs)
        D=${SG_RP_DISK:-$BUILD/install-target.raw}
        [ -f "$D" ] || { echo "SKIP btrfs: no $D (make install-test)"; continue; }
        fresh "$D"; boot btrfs-1 || { fail "btrfs: no ssh"; continue; }
        install_deb btrfs || continue
        g '[ "$(findmnt -n -o FSTYPE,FSROOT / | tr -s " ")" = "btrfs /@" ] && grep -qx "LAYOUT yes" /run/stained-glass-snapshot/status' \
            && pass "btrfs: the system is @, with restore points" || { fail "btrfs: not our layout: $(g 'findmnt /; cat /run/stained-glass-snapshot/status')"; continue; }
        # (the package under test's own update just took a restore point; apt runs within 5 minutes of one are the same run)
        [ -z "${SG_SESSION_DEB:-}" ] || sleep 310
        g 'timeout 600 apt-get -q update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive timeout 900 apt-get -y -q install hello' > "$ART/hello.log" 2>&1
        id=$(st | sed -n 's/^SNAPSHOT \([0-9-]*\)\t.*\tauto\tyes\tUpdates: hello .* installed\(\t[a-z]*\)\?$/\1/p' | head -1)
        [ -n "$id" ] && grep -q "sg-snapshot: restore point $id" "$ART/hello.log" \
            && pass "btrfs: apt's run took a restore point ($id), labelled with what it changed" || { fail "btrfs: no restore point: $(st)"; continue; }
        e=$(g "ls /efi /xbootldr 2>/dev/null; r=\$(sed -n 's/^BOOT_ROOT=//p' /etc/kernel/install.conf | tail -1); cat \$r/loader/entries/Sg-restore-$id.conf")
        printf '%s\n' "$e" | grep -q '^title Stained Glass OS -- before the update of ' && printf '%s\n' "$e" | grep -q "rootflags=subvol=@snapshots/$id/boot .*sg.snapshot=$id" \
            && pass "btrfs: the boot menu has it: Stained Glass OS -- before the update of <date>" || fail "btrfs: its entry: $e"
        g 'echo "written after the restore point" > /root/after.txt; mkdir -p /home/rp-test; echo letter > /home/rp-test/letter.txt
           echo app > "/var/lib/stained-glass/prefix/drive_c/rp-test-app.txt"'
        g "bootctl set-oneshot Sg-restore-$id.conf" && restart && sleep 20
        g "grep -qw sg.snapshot=$id /proc/cmdline && [ \"\$(findmnt -n -o FSROOT /)\" = /@snapshots/$id/boot ] && ! dpkg -s hello >/dev/null 2>&1 \
           && [ ! -e /root/after.txt ] && [ -f /home/rp-test/letter.txt ] && [ -f /var/lib/stained-glass/prefix/drive_c/rp-test-app.txt ] \
           && grep -qx 'BOOTED $id' /run/stained-glass-snapshot/status" \
            && pass "btrfs: started from the boot menu, the restore point runs: hello not installed, the system's later file not there; homes and the Windows side as they are" \
            || fail "btrfs: running the restore point: $(g 'cat /proc/cmdline; findmnt /; dpkg -l hello | tail -1')"
        restart && sleep 20
        g 'dpkg -s hello >/dev/null && [ -f /root/after.txt ]' && pass "btrfs: the next ordinary start is the current system again" || fail "btrfs: not back on the current system"
        out=$(g "sg-snapshot rollback $id" 2>&1)
        printf '%s\n' "$out" | grep -qx "PENDING $id" && st | grep -qx 'PENDING rollback' \
            && pass "btrfs: going back is set for the restart (Settings: Restart required)" || fail "btrfs: rollback: $out"
        restart && sleep 30
        g "! dpkg -s hello >/dev/null 2>&1 && [ ! -e /root/after.txt ] && [ -f /home/rp-test/letter.txt ] && [ -f /var/lib/stained-glass/prefix/drive_c/rp-test-app.txt ] \
           && [ \"\$(findmnt -n -o FSROOT /)\" = /@ ]" \
            && pass "btrfs: after going back hello is gone and the system's later file too; the home and the Windows programs' files are kept" \
            || fail "btrfs: after going back: $(g 'dpkg -l hello | tail -1; ls /root /home/rp-test')"
        g 'grep -qs "^Package: hello" /etc/apt/preferences.d/sg-went-back' && fail "btrfs: a package the update first installed is pinned away" \
            || pass "btrfs: a package the update first installed may be installed again (no pin)"
        g 'm=$(mktemp -d); mount -o subvolid=5 "$(findmnt -n -o SOURCE / | sed "s/\[.*//")" $m; ls $m | grep -q "^@old-"; r=$?; umount $m; [ $r = 1 ]' \
            && pass "btrfs: the system that was replaced is deleted at the start" || fail "btrfs: @old- left"
        g 'grep -q "^SNAPSHOT .*Before going back" /run/stained-glass-snapshot/status' && pass "btrfs: the system as it was is a restore point, to return to" \
            || fail "btrfs: no 'before going back' restore point"
        g 'for i in $(seq 1 40); do pgrep -x sg-compositor >/dev/null && exit 0; sleep 3; done; exit 1' && pass "btrfs: the login screen's compositor runs" || fail "btrfs: no compositor"
        stop ;;
    bootmenu)
        # a start that did not finish: the loader shows its menu, with the restore points, at the next one,
        # until a start succeeds (sg-boot-health, sg-session 0.1.0-183). Needs SG_SESSION_DEB of that version.
        D=${SG_RP_DISK:-$BUILD/install-target.raw}
        [ -f "$D" ] || { echo "SKIP bootmenu: no $D (make install-test)"; continue; }
        fresh "$D"; boot bootmenu-1 || { fail "bootmenu: no ssh"; continue; }
        # a machine installed with a hidden menu (Setup wrote timeout 0 before sg-session 0.1.0-188; this disk shares the PC
        # with another system, so it has timeout 5): the package brings the 3 seconds
        g 'sed -i "s/^timeout .*/timeout 0/" /efi/loader/loader.conf; grep -qx "timeout 0" /efi/loader/loader.conf' || { fail "bootmenu: loader.conf not writable"; continue; }
        install_deb bootmenu || continue
        g 'grep -qx "timeout 3" /efi/loader/loader.conf' && pass "bootmenu: the package changed the hidden menu (timeout 0) to 3 seconds" || fail "bootmenu: loader.conf: $(g 'cat /efi/loader/loader.conf')"
        g 'test -x /usr/bin/sg-boot-health' || { echo "SKIP bootmenu: sg-session has no sg-boot-health (SG_SESSION_DEB 0.1.0-183 or later)"; continue; }
        g 'timeout 600 apt-get -q update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive timeout 900 apt-get -y -q install hello' > "$ART/hello-bootmenu.log" 2>&1
        g 'grep -q "^SNAPSHOT .*auto" /run/stained-glass-snapshot/status' || { fail "bootmenu: no restore point to list"; continue; }
        g 'systemctl is-enabled sg-boot-health.service sg-boot-ok.service >/dev/null' && pass "bootmenu: sg-boot-health and sg-boot-ok are enabled by the package" || fail "bootmenu: units not enabled"
        BHV=/sys/firmware/efi/efivars/LoaderConfigTimeoutOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
        waitok='for i in $(seq 1 60); do [ "$(systemctl show -p ExecMainExitTimestampMonotonic --value sg-boot-ok.service)" != 0 ] && exit 0; sleep 2; done; exit 1'
        # 1. a start that finishes takes the request back
        g 'SG_BOOTHEALTH_GRACE=0 sg-boot-health ok'   # (installing the package ran begin in this start)
        off=$(stat -c %s "$ART/serial-bootmenu-1.log")
        restart && g "$waitok" && g "[ ! -e $BHV ]" && tail -c +$((off + 1)) "$ART/serial-bootmenu-1.log" | grep -aq 'Boot in 3 s' && ! tail -c +$((off + 1)) "$ART/serial-bootmenu-1.log" | grep -aq 'Boot in 10 s' \
            && pass "bootmenu: a start that finished showed the menu for 3 seconds (not the failed-start 10) and left no request (the variable is gone)" || fail "bootmenu: request left after a good start: $(g "ls $BHV; systemctl status sg-boot-ok.service" 2>&1 | tail -5)"
        # 2. a start that never finishes (sg-boot-ok held back) leaves the request: 10 seconds
        g 'mkdir -p /etc/systemd/system/sg-boot-ok.service.d; printf "[Service]\nExecStart=\nExecStart=/bin/sleep infinity\n" > /etc/systemd/system/sg-boot-ok.service.d/hold.conf'
        # (mutant: the early service is gone, as if the package did not ship it -- the gate must notice)
        [ -z "${SG_MUTANT_RP_NO_BEGIN:-}" ] || g 'systemctl mask sg-boot-health.service'
        # (sg-boot-ok has started, plus longer than its grace: a start that finishes has taken the request back by now)
        restart && g 'for i in $(seq 1 90); do [ "$(systemctl show -p ActiveEnterTimestampMonotonic --value sg-boot-ok.service)" != 0 ] && exit 0; sleep 3; done; exit 1'; sleep 30
        v=$(g "cat $BHV 2>/dev/null | tail -c +5 | tr -d '\\0'")
        [ "$v" = 10 ] && pass "bootmenu: a start that did not finish asked for the menu at the next one (10 seconds)" || fail "bootmenu: no request after an unfinished start (value '$v')"
        # 3. the power goes: the next start shows the menu, with the restore points
        stop; boot bootmenu-2 || { fail "bootmenu: no ssh after the unfinished start"; continue; }
        sleep 5
        grep -aq 'Boot in 10 s' "$ART/serial-bootmenu-2.log" && grep -aq 'before the update of' "$ART/serial-bootmenu-2.log" \
            && pass "bootmenu: the start after it showed the boot menu, with the restore point" || fail "bootmenu: no boot menu on the console after an unfinished start"
        # 4. a start that finishes ends it: no menu at the one after
        g 'rm -rf /etc/systemd/system/sg-boot-ok.service.d'
        restart && g "$waitok" && g "[ ! -e $BHV ]" && pass "bootmenu: once a start finished, the request is gone again" || fail "bootmenu: request left after the good start"
        # 5. a person at the keyboard: Space during the countdown holds the menu (then Enter starts the default).
        #    (Not Esc: systemd-boot answers it with "Press Enter to reboot into firmware interface".)
        off=$(stat -c %s "$ART/serial-bootmenu-2.log")
        g systemctl reboot >/dev/null 2>&1
        for _ in $(seq 1 240); do tail -c +$((off + 1)) "$ART/serial-bootmenu-2.log" | grep -aq 'Boot in' && break; sleep 0.5; done
        qmp_key spc
        sleep 12
        if g true 2>/dev/null; then fail "bootmenu: Space did not hold the menu (the system started by itself)"
        else pass "bootmenu: Space during the 3 seconds held the menu (nothing started after 12 s)"; fi
        qmp_key ret
        wait_ssh && pass "bootmenu: Enter then started the system" || fail "bootmenu: no start after Enter"
        stop ;;
    goback)
        # Settings > Recovery > Go back, as the UI does it (sg-admind's restore-point verb, asked as SYSTEM), then
        # "check for updates": the versions the restore point was taken before must not come back -- every package
        # of the update, however many apt runs it took -- while a NEWER version still installs.
        D=${SG_RP_DISK:-$BUILD/install-target.raw}
        [ -f "$D" ] || { echo "SKIP goback: no $D (make install-test)"; continue; }
        [ -n "${SG_SESSION_DEB:-}" ] || { echo "SKIP goback: SG_SESSION_DEB not given"; continue; }
        t=$(mktemp -d); v=$(dpkg-deb -f "$SG_SESSION_DEB" Version)
        mkrepo() {   # $1: the phase; the archive of that phase in $t/repo$1: dummy $2, sg-session $v$3
            mkdir -p "$t/repo$1"
            for n in 1.0 2.0 3.0; do
                rm -rf "$t/d$n"; mkdir -p "$t/d$n/DEBIAN"
                printf 'Package: sg-rp-dummy\nVersion: %s\nArchitecture: all\nMaintainer: Stained Glass OS <test@stained-glass.invalid>\nDescription: gate\n' "$n" > "$t/d$n/DEBIAN/control"
                fakeroot dpkg-deb -b "$t/d$n" "$t/repo$1/sg-rp-dummy_${n}_all.deb" >/dev/null
            done
            for sfx in "" +t1 +t2; do
                rm -rf "$t/r$sfx"; dpkg-deb -R "$SG_SESSION_DEB" "$t/r$sfx"; sed -i "s/^Version: .*/Version: $v$sfx/" "$t/r$sfx/DEBIAN/control"
                fakeroot dpkg-deb -b -Zzstd "$t/r$sfx" "$t/repo$1/sg-session_$v${sfx}_amd64.deb" >/dev/null
            done
            case $1 in
                1) rm -f "$t"/repo1/sg-rp-dummy_[23]* "$t"/repo1/*+t* ;;
                2) rm -f "$t"/repo2/sg-rp-dummy_3* "$t"/repo2/*+t2* ;;
            esac
            (cd "$t/repo$1" && dpkg-scanpackages -m . /dev/null > Packages 2>/dev/null)
        }
        usedeb() {   # the archive of phase $1 in the guest
            g 'mkdir -p /srv/repo; rm -f /srv/repo/*' && scp -q "${SSHO[@]}" -P "$PORT" "$t"/repo"$1"/* root@127.0.0.1:/srv/repo/ \
                && g 'echo "deb [trusted=yes] file:///srv/repo ./" > /etc/apt/sources.list.d/zz-rp-local.list; apt-get update -q >/dev/null 2>&1; true'
        }
        for n in 1 2 3; do mkrepo $n; done
        fresh "$D"; boot goback-1 || { fail "goback: no ssh"; continue; }
        g 'mkdir -p /root/off; for f in /etc/apt/sources.list.d/*; do grep -qs freesoft "$f" && mv "$f" /root/off/; done; true'
        usedeb 1 && g 'DEBIAN_FRONTEND=noninteractive apt-get -y -q install sg-rp-dummy=1.0' > "$ART/goback-dummy1.log" 2>&1 || { fail "goback: no dummy 1.0"; continue; }
        install_deb goback || continue
        sleep 310       # (apt runs within 5 minutes of a restore point are the same run)
        g 'cat > /root/admin-req.sh' <<'EOS'
#!/bin/sh
# one request to sg-admind as SYSTEM, the way Settings makes it; prints the reply
id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
req=$(printf '%s\n' "$@")
runuser -u sgsystem -- sh -c "printf '%s\n' \"\$1\" > /run/stained-glass-admin/requests/.t$id && mv /run/stained-glass-admin/requests/.t$id /run/stained-glass-admin/requests/$id.req" sh "$req"
for _ in $(seq 1 60); do [ -e /run/stained-glass-admin/replies/$id.rep ] && break; sleep 2; done
cat /run/stained-glass-admin/replies/$id.rep
EOS
        # the update: two apt runs (an upgrade of our package, then another package), within minutes
        usedeb 2
        g 'DEBIAN_FRONTEND=noninteractive apt-get -y -q install sg-session' > "$ART/goback-up1.log" 2>&1
        # (mutants: the code that runs from here on, now that the upgrade has installed its own copy)
        [ -z "${SG_MUTANT_RP_GOBACK:-}" ] || g "sed -i 's/E(\"SG_MUTANT_SNAP_$SG_MUTANT_RP_GOBACK\")/True/' /usr/bin/sg-snapshot"
        g 'DEBIAN_FRONTEND=noninteractive apt-get -y -q install sg-rp-dummy' > "$ART/goback-up2.log" 2>&1
        id=$(st | sed -n 's/^SNAPSHOT \([0-9-]*\)\t.*\tauto\tyes\tUpdates: .*sg-rp-dummy 1.0 to 2.0.*/\1/p' | head -1)
        g "[ \"\$(dpkg-query -W -f '\${Version}' sg-rp-dummy)\" = 2.0 ] && dpkg-query -W -f '\${Version}' sg-session | grep -qx '$v+t1'" \
            && [ -n "$id" ] && pass "goback: the update (sg-session $v+t1, then sg-rp-dummy 2.0) is one restore point ($id) that records both" \
            || { fail "goback: the update's restore point: $(st)"; continue; }
        out=$(g "sh /root/admin-req.sh restore-point rollback $id" 2>&1)
        printf '%s\n' "$out" | head -1 | grep -qx OK && st | grep -qx 'PENDING rollback' \
            && pass "goback: Settings' Go back (sg-admind restore-point rollback) is set for the restart" || { fail "goback: sg-admind: $out"; continue; }
        restart && sleep 30
        g "[ \"\$(findmnt -n -o FSROOT /)\" = /@ ] && [ \"\$(dpkg-query -W -f '\${Version}' sg-rp-dummy)\" = 1.0 ] && dpkg-query -W -f '\${Version}' sg-session | grep -qx '$v'" \
            && pass "goback: after the restart the system is the restore point's: sg-session $v, sg-rp-dummy 1.0" \
            || fail "goback: after going back: $(g "findmnt / ; dpkg -l sg-session sg-rp-dummy | tail -2")"
        g "grep -qx 'Pin: version $v+t1' /etc/apt/preferences.d/sg-went-back && grep -qx 'Pin: version 2.0' /etc/apt/preferences.d/sg-went-back" \
            && pass "goback: the restored system keeps both versions of the update from apt (sg-went-back)" || fail "goback: pins: $(g 'cat /etc/apt/preferences.d/sg-went-back 2>&1')"
        # check for updates: Settings' button (sg-admind update-check), PackageKit's list, and apt itself
        usedeb 2
        g 'sh /root/admin-req.sh update-check >/dev/null; sleep 5; for i in $(seq 1 60); do systemctl is-active -q sg-update-prepare.service || exit 0; sleep 3; done'
        g 'pkcon get-updates 2>&1' > "$ART/goback-pkcon.txt"
        g 'DEBIAN_FRONTEND=noninteractive apt-get -y -q upgrade' > "$ART/goback-upgrade.log" 2>&1
        if ! grep -q 'sg-rp-dummy\|sg-session' "$ART/goback-pkcon.txt" \
                && g "[ \"\$(dpkg-query -W -f '\${Version}' sg-rp-dummy)\" = 1.0 ] && dpkg-query -W -f '\${Version}' sg-session | grep -qx '$v'" \
                && ! g 'grep -qs "sg-rp-dummy" /var/lib/PackageKit/prepared-update'; then
            pass "goback: checking for updates (Settings, PackageKit, apt upgrade) does not bring the removed versions back"
        else fail "goback: the updater brought them back: $(g "dpkg -l sg-session sg-rp-dummy | tail -2"; tail -5 "$ART/goback-pkcon.txt")"; fi
        # a NEWER version still installs
        usedeb 3
        g 'DEBIAN_FRONTEND=noninteractive apt-get -y -q upgrade' > "$ART/goback-newer.log" 2>&1
        g "[ \"\$(dpkg-query -W -f '\${Version}' sg-rp-dummy)\" = 3.0 ] && dpkg-query -W -f '\${Version}' sg-session | grep -qx '$v+t2'" \
            && pass "goback: a newer version (sg-session $v+t2, sg-rp-dummy 3.0) still installs" || fail "goback: newer versions: $(g "dpkg -l sg-session sg-rp-dummy | tail -2"; tail -5 "$ART/goback-newer.log")"
        rm -rf "$t"
        stop ;;
    ext4)
        D=${SG_RP_EXT4_DISK:-}
        [ -n "$D" ] && [ -f "$D" ] || { echo "SKIP ext4: SG_RP_EXT4_DISK (a disk installed before 0.1.0-180) not given"; continue; }
        [ -n "${SG_SESSION_DEB:-}" ] || { echo "SKIP ext4: SG_SESSION_DEB not given"; continue; }
        fresh "$D"; boot ext4-1 || { fail "ext4: no ssh"; continue; }
        install_deb ext4 || continue
        g '[ "$(findmnt -n -o FSTYPE /)" = ext4 ]' && pass "ext4: the system drive is ext4" || { fail "ext4: not ext4"; continue; }
        # a later build of the package under test, as an update would bring
        t=$(mktemp -d); dpkg-deb -R "$SG_SESSION_DEB" "$t/r"
        v=$(dpkg-deb -f "$SG_SESSION_DEB" Version)
        sed -i "s/^Version: .*/Version: $v+t1/" "$t/r/DEBIAN/control"
        fakeroot dpkg-deb -b -Zzstd "$t/r" "$t/next.deb" >/dev/null && put "$t/next.deb" /root/next.deb; rm -rf "$t"
        g 'echo "my notes" > /home/rp-notes.txt; echo winapp > /var/lib/stained-glass/prefix/drive_c/rp-test-app.txt
           DEBIAN_FRONTEND=noninteractive apt-get -y -q install /root/next.deb' > "$ART/next.log" 2>&1
        st | grep -q "^UNDO .*sg-session $v to $v+t1" && grep -q "kept for undo: sg-session $v" "$ART/next.log" \
            && pass "ext4: the update kept the version it replaced (sg-session $v)" || { fail "ext4: nothing kept: $(st)"; continue; }
        g 'sg-snapshot undo-update' >/dev/null && restart && sleep 20
        g "dpkg-query -W -f '\${Version} \${db:Status-Abbrev}' sg-session" | grep -qx "$v ii " \
            && g "grep -q '^Pin: version $v+t1' /etc/apt/preferences.d/sg-went-back && grep -q '^UNDONE .*yes' /run/stained-glass-snapshot/status" \
            && pass "ext4: Undo the last update put sg-session $v back at the start, and keeps $v+t1 from apt" \
            || fail "ext4: undo: $(g 'dpkg -l sg-session | tail -1; journalctl -b -u sg-undo-update -o cat | tail -3')"
        out=$(g 'sg-snapshot convert-schedule' 2>&1)
        printf '%s\n' "$out" | grep -qx SCHEDULED && pass "ext4: the conversion is scheduled (its checks pass)" || { fail "ext4: convert-schedule: $out"; continue; }
        restart 300 && sleep 30
        g '[ "$(findmnt -n -o FSTYPE,FSROOT / | tr -s " ")" = "btrfs /@" ] && [ "$(findmnt -n -o FSROOT /home)" = /@home ] \
           && [ "$(findmnt -n -o FSROOT /var/lib/stained-glass/prefix)" = /@prefix ] && [ -f /home/rp-notes.txt ] \
           && [ -f /var/lib/stained-glass/prefix/drive_c/rp-test-app.txt ] && grep -q "^CONVERT converted" /run/stained-glass-snapshot/status \
           && grep -qx "SAVED yes" /run/stained-glass-snapshot/status' \
            && pass "ext4: converted at the restart: btrfs @ with its subvolumes, the home and Windows programs' files there, the old file system kept" \
            || { fail "ext4: after the conversion: $(g 'findmnt /; cat /run/stained-glass-snapshot/status; cat /var/lib/stained-glass-convert/convert.log | tail -5')"; continue; }
        g 'pgrep -x sg-compositor >/dev/null || sleep 60; pgrep -x sg-compositor >/dev/null' && pass "ext4: the converted system starts its login screen" || fail "ext4: no compositor after the conversion"
        g 'timeout 600 apt-get -q update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive timeout 900 apt-get -y -q install hello' > "$ART/hello-converted.log" 2>&1
        grep -q 'sg-snapshot: restore point' "$ART/hello-converted.log" && pass "ext4: the converted system takes restore points" || fail "ext4: no restore point after converting"
        g 'echo "after the conversion" > /home/rp-later.txt'
        out=$(g 'sg-snapshot convert-undo' 2>&1)
        printf '%s\n' "$out" | grep -qx SCHEDULED && pass "ext4: undoing the conversion is scheduled" || { fail "ext4: convert-undo: $out"; continue; }
        restart 300 && sleep 30
        g '[ "$(findmnt -n -o FSTYPE /)" = ext4 ] && [ -f /home/rp-notes.txt ] && [ ! -e /home/rp-later.txt ] && ! dpkg -s hello >/dev/null 2>&1 \
           && grep -q "^CONVERT undone" /run/stained-glass-snapshot/status' \
            && pass "ext4: undone: ext4 again, as it was before the conversion" || fail "ext4: after undo: $(g 'findmnt /; cat /run/stained-glass-snapshot/status')"
        g 'r=$(sed -n "s/^BOOT_ROOT=//p" /etc/kernel/install.conf | tail -1); ! ls $r/loader/entries | grep -q "^Sg-restore-"' \
            && pass "ext4: no restore points left in the boot menu" || fail "ext4: restore point entries left"
        stop ;;
    esac
done
[ $RC = 0 ] && echo "restore-points-test: PASS" || echo "restore-points-test: FAIL"
exit $RC
