#!/bin/sh
# sg-iso-count: ISO lines are added into the daily count (bytes / ISO size)
# and the log is emptied; other lines and failed requests are not counted.
# Run: sh server/stats/test-iso-count.sh
set -u
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; RC=0
mkdir -p "$T/iso"; truncate -s 1000 "$T/iso/sg-live-x.iso"
export SG_ISO_LOG="$T/iso.log" SG_ISO_COUNTS="$T/counts.tsv" SG_ISO_DIR="$T/iso"
line() { printf '{"ts":%s,"request":{"method":"GET","uri":"%s"},"status":%s,"size":%s}\n' "$1" "$2" "$3" "$4"; }
{ line 1794614400 /iso/sg-live-x.iso 200 1000
  line 1794614500 /iso/sg-live-x.iso 206 500
  line 1794614600 /iso/sg-live-x.iso 404 0
  line 1794614700 /iso/SHA256SUMS 200 100; } > "$T/iso.log"
line 1794700800 /iso/sg-live-latest.iso 200 1500 > "$T/iso-2026-11-15T00-00-00.000.log"
python3 "$HERE/sg-iso-count" || RC=1
grep -q "^2026-11-14	2	1500	1.5$" "$T/counts.tsv" && echo "PASS  day 1: 2 requests, 1.5 downloads" || { echo "FAIL  day 1"; cat "$T/counts.tsv"; RC=1; }
grep -q "^2026-11-15	1	1500	1.5$" "$T/counts.tsv" && echo "PASS  rolled file counted" || { echo "FAIL  rolled file"; RC=1; }
[ ! -s "$T/iso.log" ] && [ ! -e "$T/iso-2026-11-15T00-00-00.000.log" ] && echo "PASS  logs emptied" || { echo "FAIL  logs left"; RC=1; }
line 1794614800 /iso/sg-live-x.iso 200 1000 >> "$T/iso.log"
python3 "$HERE/sg-iso-count" || RC=1
grep -q "^2026-11-14	3	2500	2.5$" "$T/counts.tsv" && echo "PASS  added to the day's count" || { echo "FAIL  second run"; cat "$T/counts.tsv"; RC=1; }
python3 "$HERE/sg-iso-count" --show | grep -q "total .* 4 requests" && echo "PASS  --show total" || { echo "FAIL  --show"; RC=1; }
grep -q -E '([0-9]{1,3}\.){3}[0-9]{1,3}' "$T/counts.tsv" && { echo "FAIL  an address in the counts"; RC=1; } || echo "PASS  no address kept"
exit $RC
