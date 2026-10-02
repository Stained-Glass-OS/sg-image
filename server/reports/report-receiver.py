#!/usr/bin/python3
# The problem report receiver on freesoft.page: Report a problem
# (sg-shell's sg-bugreport.exe) sends its plain-text report here, where the
# project reads them (server/reports/reports.sh) -- no mail (David
# 2026-10-02).
#
# Behind Caddy (/api/report, which caps the body and passes the client's
# address in X-Sg-Client-Ip; this listens on 127.0.0.1 only). A report must
# be printable ASCII text (tabs and line breaks too), at most MAX_BYTES, and
# one of ours; each address may send 2 a minute and 20 a day, and all of
# them together DAY_TOTAL a day, so nobody can fill the disk or flood it.
# Kept under STATE (systemd's StateDirectory), one file each, never served.
#
#   POST /api/report      body: the report      -> 201 {"id": "..."}
#                         429 (Retry-After), 413, 415, 400 otherwise
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import collections
import datetime
import json
import os
import secrets
import shutil
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BYTES = int(os.environ.get("SG_REPORT_MAX_BYTES", 512 * 1024))
PER_MINUTE = int(os.environ.get("SG_REPORT_PER_MINUTE", 2))
PER_DAY = int(os.environ.get("SG_REPORT_PER_DAY", 20))
DAY_TOTAL = int(os.environ.get("SG_REPORT_DAY_TOTAL", 1000))
MIN_FREE = int(os.environ.get("SG_REPORT_MIN_FREE", 2 * 1024 ** 3))   # keep 2 GB for apt and ISOs
STATE = os.environ.get("STATE_DIRECTORY", os.environ.get("SG_REPORT_DIR", "/var/lib/sg-reports"))
LISTEN = os.environ.get("SG_REPORT_LISTEN", "127.0.0.1:8091")
MARK = b"Stained Glass OS problem report"
ALLOWED = frozenset(b"\t\n\r") | frozenset(range(32, 127))

lock = threading.Lock()
sent = collections.defaultdict(collections.deque)   # address -> times of its reports (the last day)
all_sent = collections.deque()                      # every report's time (the last day)


def allow(address, now):
    """None, or the seconds to wait."""
    with lock:
        for q in (sent[address], all_sent):
            while q and now - q[0] > 86400:
                q.popleft()
        q = sent[address]
        if len(all_sent) >= DAY_TOTAL:
            return int(86400 - (now - all_sent[0])) + 1
        if len(q) >= PER_DAY:
            return int(86400 - (now - q[0])) + 1
        recent = [t for t in q if now - t < 60]
        if len(recent) >= PER_MINUTE:
            return int(60 - (now - recent[0])) + 1
        q.append(now)
        all_sent.append(now)
        if len(sent) > 5000:   # addresses not heard from for a day are forgotten
            for a in [a for a, t in sent.items() if not t or now - t[-1] > 86400]:
                del sent[a]
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = "sg-report-receiver"

    def answer(self, code, body, extra=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path.split("?")[0] != "/api/report":
            return self.answer(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self.answer(411, {"error": "length required"})
        if length <= 0:
            return self.answer(400, {"error": "empty report"})
        if length > MAX_BYTES:
            return self.answer(413, {"error": "a report is at most %d bytes" % MAX_BYTES})
        address = self.headers.get("X-Sg-Client-Ip") or self.client_address[0]
        wait = allow(address, time.time())
        if wait is not None:
            return self.answer(429, {"error": "too many reports from here; try again later", "retry_after": wait},
                               {"Retry-After": str(wait)})
        body = self.rfile.read(length)
        if len(body) != length:
            return self.answer(400, {"error": "the report was cut off"})
        if not set(body) <= ALLOWED:
            return self.answer(415, {"error": "a report is plain ASCII text"})
        if MARK not in body[:4096]:
            return self.answer(400, {"error": "not a Stained Glass OS problem report"})
        if shutil.disk_usage(STATE).free < MIN_FREE:
            return self.answer(507, {"error": "the server cannot take reports right now"})
        now = datetime.datetime.now(datetime.timezone.utc)
        rid = now.strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(3)
        day = os.path.join(STATE, now.strftime("%Y-%m-%d"))
        os.makedirs(day, mode=0o750, exist_ok=True)
        path = os.path.join(day, rid + ".txt")
        with open(path + ".tmp", "wb") as f:
            f.write(b"Received: %s from %s\n" % (now.isoformat().encode(), address.encode("ascii", "replace")))
            f.write(body)
        os.chmod(path + ".tmp", 0o640)
        os.replace(path + ".tmp", path)
        return self.answer(201, {"id": rid})

    def do_GET(self):
        self.answer(405, {"error": "reports are sent with POST"})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.headers.get("X-Sg-Client-Ip", "-") if hasattr(self, "headers") and self.headers else "-",
                                      fmt % args))


def main():
    host, port = LISTEN.rsplit(":", 1)
    os.makedirs(STATE, exist_ok=True)
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()


if __name__ == "__main__":
    main()
