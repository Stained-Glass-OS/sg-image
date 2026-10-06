#!/bin/sh
# sg-dymo-lw5xx's filter (dymo-deb) prints a LabelWriter 550 job through CUPS:
#   - a text job to a queue with DYMO's lw550.ppd comes out as the 5xx command
#     stream DYMO's source writes (ESC A status request, ESC s job id, ESC e/h
#     density and quality, ESC T speed, ESC M media, ESC n label index, ESC D
#     raster header with 1 bit per pixel, raster lines with the text in them,
#     ESC G short form feed, ESC E form feed, ESC Q end of job);
#   - the queue's make and model is "DYMO LabelWriter 550", which wine-sg
#     names the printer's Windows driver after (0871) and DYMO Connect wants;
#   - a filter killed while it holds the printer's lock (a job cancelled
#     mid-print, a crash) does not stop the next job (dymo-deb patch 0002;
#     with upstream's boost semaphore every later job failed with "Unable to
#     get synchronization lock" until a restart);
#   - run outside CUPS (no destination to look up), the filter still locks
#     ("Unable to get synchronization lock: Invalid argument" upstream);
#   - with the queue's defaults as sg-dymo-queue sets them (the loaded roll's
#     page, landscape), two lines of text print along the label, whole.
# No root, no printer, no network: a CUPS server of the test's own (a copy of
# cupsd, so the system's AppArmor profile for /usr/sbin/cupsd does not keep
# it from running the filter from a scratch dir) and a backend that plays a
# 550 with labels loaded (test/dymo-fake-backend).
#
#   test/dymo-print-test.sh [CACHE_DIR]
#   SG_DYMO_FILTER=/path/raster2dymolw_v2 test/dymo-print-test.sh   (a given
#     build of the filter: the mutation run uses upstream's, unpatched)
#   SG_DYMO_MUTANT=portrait test/dymo-print-test.sh   (the queue left portrait:
#     the two-line label check must fail)
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CACHE=${1:-$HERE/build/dymo-cache}
CUPSD=${CUPSD:-/usr/sbin/cupsd}
LPADMIN=${LPADMIN:-/usr/sbin/lpadmin}
for t in "$CUPSD" "$LPADMIN"; do [ -x "$t" ] || { echo "SKIP: $t missing"; exit 77; }; done
for t in lp lpstat cancel python3 g++; do command -v $t >/dev/null || { echo "SKIP: $t missing"; exit 77; }; done
[ -x /usr/lib/cups/filter/gstoraster ] || { echo "SKIP: cups-filters (gstoraster) missing"; exit 77; }
[ -f /usr/include/cups/raster.h ] || { echo "SKIP: libcupsimage2-dev/libcups2-dev missing"; exit 77; }
unset DISPLAY WAYLAND_DISPLAY
RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
T=$(mktemp -d /var/tmp/sg-dymoprint.XXXXXX); CP=
trap '[ -n "$CP" ] && { kill "$CP" 2>/dev/null; wait "$CP" 2>/dev/null; }; rm -rf "$T"' EXIT INT TERM

# the filter and the PPDs, as the package builds them
"$HERE/dymo-deb/build-deb.sh" "$CACHE" "$T/unused" "$T/drv" >"$T/build.log" 2>&1 || { fail "the driver did not build: $(tail -3 "$T/build.log")"; exit 1; }
[ -n "${SG_DYMO_FILTER:-}" ] && cp "$SG_DYMO_FILTER" "$T/drv/raster2dymolw_v2"

mkdir -p "$T/root/ppd" "$T/cache" "$T/state" "$T/spool" "$T/log" "$T/bin/filter" "$T/bin/backend"
for d in /usr/lib/cups/*; do case "${d##*/}" in filter|backend) ;; *) ln -s "$d" "$T/bin/" ;; esac; done
for d in /usr/lib/cups/filter/*; do ln -s "$d" "$T/bin/filter/"; done
for d in /usr/lib/cups/backend/*; do ln -s "$d" "$T/bin/backend/"; done
cp "$T/drv/raster2dymolw_v2" "$T/bin/filter/"
install -m 755 "$HERE/test/dymo-fake-backend" "$T/bin/backend/dymofake"
cat > "$T/root/cupsd.conf" <<EOF
Listen $T/cups.sock
LogLevel debug
<Location />
Order allow,deny
Allow all
</Location>
EOF
cat > "$T/root/cups-files.conf" <<EOF
ServerRoot $T/root
CacheDir $T/cache
StateDir $T/state
RequestRoot $T/spool
TempDir $T/spool
ErrorLog $T/log/error_log
AccessLog $T/log/access_log
PageLog $T/log/page_log
ServerBin $T/bin
DataDir /usr/share/cups
User $(id -un)
Group $(id -gn)
EOF
cp "$CUPSD" "$T/cupsd"
"$T/cupsd" -f -c "$T/root/cupsd.conf" -s "$T/root/cups-files.conf" > "$T/cupsd.out" 2>&1 & CP=$!
export CUPS_SERVER="$T/cups.sock"
i=0; while [ ! -S "$T/cups.sock" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
OUT="$T/printer.bin"
"$LPADMIN" -p LW550 -E -v "dymofake:$OUT" -P "$T/drv/lw550.ppd" 2>/dev/null
lpstat -v LW550 >/dev/null 2>&1 || { echo "SKIP: the test's CUPS server did not take the queue"; cat "$T/cupsd.out"; exit 77; }
mm=$(lpoptions -p LW550 2>/dev/null | grep -o "printer-make-and-model='[^']*'")
[ "$mm" = "printer-make-and-model='DYMO LabelWriter 550'" ] && pass "the queue's make and model is DYMO LabelWriter 550 (the Windows driver name)" \
    || fail "make and model: $mm"

done_job() {   # wait up to $1 s for the queue to be empty
    j=0; while [ $j -lt "$1" ]; do lpstat -o LW550 2>/dev/null | grep -q . || return 0; sleep 1; j=$((j + 1)); done; return 1
}
printf 'Stained Glass OS\nLabelWriter 550\n' > "$T/label.txt"
lp -d LW550 -o media=w72h154 "$T/label.txt" >/dev/null
done_job 90 || fail "the job did not finish in 90 s"
python3 - "$OUT" > "$T/check.out" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
ok = []
def need(cond, what): ok.append((cond, what))
need(d.startswith(b'\x1bA'), 'starts with a status request (ESC A)')
s = d.find(b'\x1bs')
need(s >= 0 and s < 8, 'ESC s job id next')
for cmd, what in ((b'\x1be', 'density'), (b'\x1bh', 'quality'), (b'\x1bT', 'speed'), (b'\x1bM', 'media'), (b'\x1bn', 'label index')):
    need(d.find(cmd, s) > s, 'ESC %s (%s)' % (chr(cmd[1]), what))
h = d.find(b'\x1bD', s)
need(h > 0 and d[h + 2] == 1, 'ESC D raster header, 1 bit per pixel')
need(h > 0 and sum(1 for b in d[h + 12:-8] if b) > 50, 'the label has the text in it (black dots)')
need(d.endswith(b'\x1bE\x1bQ'), 'ends with ESC E (form feed) and ESC Q (end of job)')
need(d.find(b'\x1bG', h) > h, 'ESC G short form feed after the label')
for c, w in ok:
    print(('ok   ' if c else 'BAD  ') + w)
print('bytes', len(d))
PY
if [ -s "$OUT" ] && ! grep -q '^BAD' "$T/check.out"; then
    pass "a text job comes out as the 5xx command stream ($(tail -1 "$T/check.out"))"
else
    fail "the 550 stream is not what DYMO's driver writes:"; sed 's/^/      /' "$T/check.out"
    grep -E 'raster2dymolw|ERROR|lock' "$T/log/error_log" | tail -5 | sed 's/^/      /'
fi

# the queue as sg-session's sg-dymo-queue leaves it: the loaded roll's page
# (30336, 1 x 2-1/8 in) and landscape. Two lines of text printed without
# options run along the label, whole: the raster is the label's length
# (about 2 in of lines) by its width, and the text's dots fit inside it,
# longer along the label than across. (Portrait, the text ran across the
# 1 in label and was cut off: "Stained Gl".)
ORIENT=4; [ "${SG_DYMO_MUTANT:-}" = portrait ] && ORIENT=3
"$LPADMIN" -p LW550 -o PageSize=w72h154.1 -o orientation-requested-default=$ORIENT 2>/dev/null
: > "$OUT"
printf 'Stained Glass OS\nDYMO 550 test\n' > "$T/two.txt"
lp -d LW550 "$T/two.txt" >/dev/null
done_job 90 || fail "the two-line job did not finish in 90 s"
python3 - "$OUT" > "$T/orient.out" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
h = d.find(b'\x1bD')
if h < 0:
    print('BAD  no raster'); sys.exit()
lines = int.from_bytes(d[h + 4:h + 8], 'little')
dots = int.from_bytes(d[h + 8:h + 12], 'little')
nb = dots // 8
xs, ys = [], []
p = h + 12
for x in range(lines):
    row = d[p:p + nb]; p += nb
    if len(row) < nb or row[:1] == b'\x1b':
        break
    for y in range(dots):
        if row[y // 8] & (0x80 >> (y % 8)):
            xs.append(x); ys.append(y)
print('raster %d lines x %d dots' % (lines, dots))
if not xs:
    print('BAD  no text'); sys.exit()
along, across = max(xs) - min(xs) + 1, max(ys) - min(ys) + 1
print('text %d along x %d across, lines %d-%d, dots %d-%d' % (along, across, min(xs), max(xs), min(ys), max(ys)))
print(('ok   ' if 560 <= lines <= 660 else 'BAD  ') + 'the label is 2-1/8 in long (%d lines at 300 dpi)' % lines)
print(('ok   ' if along > 2 * across else 'BAD  ') + 'the text runs along the label')
# the text starts at the printable area's edge; whole, it ends before the
# other end and keeps off both sides
print(('ok   ' if min(ys) > 0 and max(ys) < dots - 1 and min(xs) > 0 else 'BAD  ') + 'the text is whole (ends before the label does, off both sides)')
PY
if grep -q '^ok' "$T/orient.out" && ! grep -q '^BAD' "$T/orient.out"; then
    pass "two lines of text print along the 30336 label, whole ($(sed -n 's/^text //p' "$T/orient.out"))"
else
    fail "the two-line label:"; sed 's/^/      /' "$T/orient.out"
fi

# a filter killed while it holds the printer's lock
: > "$OUT.stall"; : > "$OUT"
lp -d LW550 "$T/label.txt" >/dev/null
k=0; while [ $k -lt 60 ] && ! grep -q 'locked \|TryLock(' "$T/log/error_log"; do sleep 0.5; k=$((k + 1)); done
sleep 1
pid=$(pgrep -x -u "$(id -u)" raster2dymolw_v || true)
if [ -n "$pid" ]; then
    kill -9 $pid
    sleep 1
    cancel -a LW550 2>/dev/null; done_job 30
    rm -f "$OUT.stall"; : > "$OUT"
    /usr/sbin/cupsenable LW550 2>/dev/null || cupsenable LW550 2>/dev/null
    lp -d LW550 "$T/label.txt" >/dev/null
    if done_job 25 && [ -s "$OUT" ] && python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); sys.exit(not d.endswith(b"\x1bE\x1bQ"))' "$OUT"; then
        pass "after a filter was killed holding the printer's lock, the next job prints"
    else
        fail "after a filter was killed holding the printer's lock, the next job did not print: $(grep -E 'lock' "$T/log/error_log" | tail -1)"
    fi
else
    rm -f "$OUT.stall"
    fail "the filter of the stalled job was not found to kill"
fi

# outside CUPS: no destination to look up
/usr/sbin/cupsfilter -p "$T/drv/lw550.ppd" -m application/vnd.cups-raster "$T/label.txt" > "$T/label.ras" 2>/dev/null
[ -s "$T/label.ras" ] || fail "cupsfilter made no raster for the stand-alone run"
out=$(cd "$T" && PRINTER= TMPDIR="$T/spool" CUPS_SERVER="$T/none.sock" "$T/drv/raster2dymolw_v2" 1 user t 1 "" "$T/label.ras" 2>&1 </dev/null >"$T/alone.bin")
if printf '%s\n' "$out" | grep -q 'Unable to get synchronization lock'; then
    fail "outside CUPS the filter cannot lock: $(printf '%s\n' "$out" | grep -m1 'synchronization')"
else
    grep -q 'locked ' <<EOF2 && pass "outside CUPS (no destination) the filter still takes its lock" || fail "outside CUPS: $(printf '%s\n' "$out" | tail -2)"
$out
EOF2
fi
[ $RC = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $RC
