#!/bin/sh
# The report receiver's rules, on a port of its own: a report is taken (201),
# a third in a minute is refused (429), a 21st in a day (429), non-ASCII
# (415), too big (413), not a report (400). Run: sh server/reports/test-receiver.sh
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d); RC=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; RC=1; }
start() {   # PER_MINUTE PER_DAY
    [ -n "${P:-}" ] && kill "$P" 2>/dev/null; sleep 0.3
    SG_REPORT_DIR="$T/state" SG_REPORT_LISTEN=127.0.0.1:18091 SG_REPORT_PER_MINUTE=$1 SG_REPORT_PER_DAY=$2 \
        SG_REPORT_MAX_BYTES=4096 SG_REPORT_MIN_FREE=0 python3 "$HERE/report-receiver.py" 2>"$T/log" & P=$!
    i=0; while ! python3 -c 'import socket; socket.create_connection(("127.0.0.1",18091),1)' 2>/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
}
post() {   # file [ip] -> http code
    python3 - "$1" "${2:-10.0.0.1}" <<'PY'
import sys, urllib.request, urllib.error
data = open(sys.argv[1], "rb").read()
req = urllib.request.Request("http://127.0.0.1:18091/api/report", data=data, headers={"X-Sg-Client-Ip": sys.argv[2], "Content-Type": "text/plain"})
try:
    print(urllib.request.urlopen(req, timeout=5).status)
except urllib.error.HTTPError as e:
    print(e.code)
PY
}
trap 'kill $P 2>/dev/null; rm -rf "$T"' EXIT
printf 'Stained Glass OS problem report\nCreated: now\n' > "$T/ok.txt"
printf 'Stained Glass OS problem report\n\303\251\n' > "$T/utf8.txt"
python3 -c 'print("Stained Glass OS problem report"); print("x" * 5000)' > "$T/big.txt"
printf 'hello\n' > "$T/other.txt"
start 2 20
[ "$(post "$T/ok.txt")" = 201 ] && [ -n "$(find "$T/state" -name '*.txt')" ] && pass "a report is taken and kept" || fail "a report was not taken"
post "$T/ok.txt" >/dev/null
[ "$(post "$T/ok.txt")" = 429 ] && pass "a third in a minute from one address is refused" || fail "no limit per minute"
[ "$(post "$T/ok.txt" 10.0.0.2)" = 201 ] && pass "...another address is not" || fail "another address was refused"
[ "$(post "$T/utf8.txt" 10.0.0.3)" = 415 ] && pass "non-ASCII text is refused" || fail "non-ASCII taken"
[ "$(post "$T/big.txt" 10.0.0.4)" = 413 ] && pass "too big is refused" || fail "too big taken"
[ "$(post "$T/other.txt" 10.0.0.5)" = 400 ] && pass "something not a report is refused" || fail "not a report taken"
start 100 20
n=0; for i in $(seq 1 21); do c=$(post "$T/ok.txt" 10.0.0.9); [ "$c" = 201 ] && n=$((n+1)); done
[ "$n" = 20 ] && pass "20 a day from one address, not 21" || fail "a day's limit: $n taken"
[ "$RC" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$RC"
