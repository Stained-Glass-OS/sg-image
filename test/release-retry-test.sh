#!/bin/bash
# release.sh's once-more rule: a gate is run again only when every failure in
# its log is one of the boot-timing checks (TIMING_CHECKS) -- never for any
# other failure, nor for a log with no failure lines (a crash).
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
eval "$(sed -n '/^TIMING_CHECKS=/p; /^only_timing_failures() {/,/^}/p' "$HERE/release/release.sh")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RC=0
t() { # expect(yes|no) description lines...
    local want=$1 what=$2; shift 2
    printf '%s\n' "$@" > "$T/log"
    if only_timing_failures "$T/log"; then got=yes; else got=no; fi
    [ "$got" = "$want" ] && echo "PASS  $what" || { echo "FAIL  $what (got $got)"; RC=1; }
}
t yes "only the splash failed: once more" "PASS  wineserver is running" "FAIL  no frame of the boot showed the splash" "[boot-test] GATE FAIL (rc=1)"
t yes "only the first-run setup was late: once more" "FAIL  the first-run setup did not appear at the first boot"
t no "the splash and something else: stop" "FAIL  no frame of the boot showed the splash" "FAIL  explorer.exe is not running"
t no "another failure alone: stop" "FAIL  the lock screen did not come up"
t no "no failure line at all (a crash, a timeout): stop" "[boot-test] booting" "Segmentation fault"
t no "a passing log: nothing to retry" "PASS  everything" "[boot-test] GATE PASS"
exit $RC
