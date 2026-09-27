#!/bin/bash
# Chrome in a signed-in session on a VM with a real display: does its GPU
# process die (as under Xvfb, llvmpipe through WineD3D), and how much memory
# does it take? Boots the image with boot-test's machinery and keeps it; then,
# as a person would: Chrome is started from Run (Win+R, through QEMU's
# keyboard), and every CHROME_SAMPLE seconds each Chrome process's memory is
# sampled, for CHROME_WAIT seconds. Reports GPU-process deaths, OOM kills and
# crash dumps.
#
#   CHROME_DIR=/path/to/Chrome-bin [SG_GPU=virgl] [SG_VM_MEM=8192] test/chrome-gpu-test.sh
#
# SG_GPU=virgl passes OpenGL through to this machine's GPU (the nearest a VM
# gets to real hardware); without it the guest draws with llvmpipe. Chrome is
# the user's to supply (the enterprise MSI, unpacked) -- never committed or
# shipped. Output: build/artifacts/chrome-*.txt.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHROME_DIR=${CHROME_DIR:?set CHROME_DIR to an unpacked Chrome-bin}
[[ -f "$CHROME_DIR/chrome.exe" ]] || { echo "chrome-gpu-test: no chrome.exe in $CHROME_DIR" >&2; exit 2; }
WAIT=${CHROME_WAIT:-240}
SAMPLE=${CHROME_SAMPLE:-15}
URL=${CHROME_URL:-https://www.example.com/}
ART="$HERE/build/artifacts"
KEY="$HERE/build/ssh/id_ed25519"
PORT=${SG_SSH_PORT:-2222}
guest() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "$PORT" root@127.0.0.1 "$@"; }

# before sign-in: Chrome into the guest, and a batch file that starts it
# with its log to a file
PRE=$(mktemp "${TMPDIR:-/var/tmp}/chrome-pre.XXXXXX")
cat > "$PRE" <<PREEOF
#!/bin/bash
set -e
tar -C "$(dirname "$CHROME_DIR")" -cf - "$(basename "$CHROME_DIR")" | \
    ssh -i "\$SG_SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -p "\$SG_SSH_PORT" root@127.0.0.1 \
    'mkdir -p /var/tmp/chrome && tar -C /var/tmp/chrome -xf - && chmod -R a+rX /var/tmp/chrome && chmod 1777 /tmp && \
     printf "@echo off\r\nZ:\\\\\\\\var\\\\\\\\tmp\\\\\\\\chrome\\\\\\\\$(basename "$CHROME_DIR")\\\\\\\\chrome.exe --no-first-run --no-default-browser-check --enable-logging=stderr --v=0 $URL > Z:\\\\\\\\tmp\\\\\\\\chrome-run.txt 2>&1\r\n" > /var/tmp/chrome/run.bat && \
     echo "chrome copied: \$(du -sh /var/tmp/chrome | cut -f1)"'
PREEOF
chmod +x "$PRE"
trap 'rm -f "$PRE"' EXIT

# sign in and keep the machine (the check only waits for the session)
export SG_PRE_LOGIN="$PRE" SG_GUEST_CHECK=custom SG_CHECK_NAME="the session is up" SG_TEST_LOCK=0 SG_KEEP_VM=1
export SG_CHECK_CMD='for i in $(seq 1 300); do ls /run/user/*/sg-session.env >/dev/null 2>&1 && [ -e /var/lib/stained-glass/prefix/.sg-initialized ] && break; sleep 1; done; ls /run/user/*/sg-session.env && echo PASS session'
"$HERE/test/boot-test.sh" > "$ART/chrome-boot.txt" 2>&1
QMP=$(sed -n 's/.*qmp socket: //p' "$ART/chrome-boot.txt" | tail -1)
[[ -S "$QMP" ]] || QMP=$(ls -t /tmp/sg-boot-test.*/qmp.sock 2>/dev/null | head -1)
[[ -S "$QMP" ]] || { echo "chrome-gpu-test: the VM did not stay up (see $ART/chrome-boot.txt)"; exit 1; }
cleanup_vm() { python3 "$HERE/test/qmp.py" "$QMP" quit >/dev/null 2>&1 || true; }
trap 'rm -f "$PRE"; cleanup_vm' EXIT
sleep 10

# start it as a person does: Run, the batch file, Enter
python3 "$HERE/test/qmp.py" "$QMP" key meta_l+r >/dev/null; sleep 3
python3 "$HERE/test/qmp.py" "$QMP" type 'Z:\var\tmp\chrome\run.bat' >/dev/null
python3 "$HERE/test/qmp.py" "$QMP" key ret >/dev/null

: > "$ART/chrome-memory.txt"
for (( t = SAMPLE; t <= WAIT; t += SAMPLE )); do
    sleep "$SAMPLE"
    guest "echo \"t=${t}s free=\$(free -m | awk '/Mem:/{print \$7}')MB\"; \
           ps -u sguser -o rss=,args= | grep -a 'chrome.exe' | grep -v grep | \
           sed -E 's/.*--type=([a-z-]+).*/\\1/; t; s/.*/browser/' | sort | uniq -c | tr '\n' ' '; \
           echo; ps -u sguser -o rss=,args= | grep -a 'chrome.exe' | grep -v grep | \
           awk '{ t = \"browser\"; if (match(\$0, /--type=[a-z-]+/)) t = substr(\$0, RSTART + 7, RLENGTH - 7); \
                  printf \"  %-16s %6d MB\\n\", t, \$1 / 1024 }'" >> "$ART/chrome-memory.txt" 2>&1
done

guest "cat /var/tmp/chrome/run.bat; echo \"chrome processes now: \$(ps -u sguser -o args= | grep -ac 'chrome.exe')\"; \
       echo \"gpu process exits: \$(grep -ac 'GPU process exited unexpectedly' /tmp/chrome-run.txt)\"; \
       echo \"couldn't create surface: \$(grep -ac \"Couldn't create surface\" /tmp/chrome-run.txt)\"; \
       echo \"fatal: \$(grep -ac 'FATAL' /tmp/chrome-run.txt)\"; \
       echo \"oom kills: \$(journalctl -b -k -o cat --no-pager | grep -c 'Out of memory: Killed')\"; \
       journalctl -b -k -o cat --no-pager | grep 'Out of memory: Killed' | cut -c1-140; \
       echo \"crash dumps: \$(find / -xdev -path '*Crashpad/reports/*' -type f 2>/dev/null | wc -l)\"; \
       grep -aE 'FATAL|GPU process exited|Couldn.t create surface' /tmp/chrome-run.txt | tail -5 | cut -c1-200" > "$ART/chrome-result.txt" 2>&1
cat "$ART/chrome-memory.txt" "$ART/chrome-result.txt"
