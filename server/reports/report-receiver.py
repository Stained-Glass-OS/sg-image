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
#
# Reports are read by people and by the project's AI agents (only ones a
# person reviewed first), so a report must be one sg-bugreport.exe made (its
# sections, in order) and must not try to instruct an AI ("ignore previous
# instructions", role markers, ...): such an upload is refused and its
# address blocked for BLOCK_DAYS (David 2026-10-02). Blocked addresses are
# kept in STATE/blocked.json.
# Kept under STATE (systemd's StateDirectory), with the sender's address
# (for the limits only), and published without it under PUBLIC -- the
# website's Debug Reports, sorted by program (index.html for people,
# index.json for agents), so anyone can see what is tested and what fails
# (David 2026-10-02). The client leaves out the account and computer names.
#
#   POST /api/report      body: the report      -> 201 {"id": "..."}
#                         429 (Retry-After), 413, 415, 400 otherwise
#
# SPDX-License-Identifier: AGPL-3.0-or-later
import collections
import datetime
import html
import json
import re
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
PUBLIC = os.environ.get("SG_REPORT_PUBLIC", "/srv/www/reports")
MARK = b"Stained Glass OS problem report"
BLOCK_DAYS = int(os.environ.get("SG_REPORT_BLOCK_DAYS", 30))
# what sg-bugreport.exe writes, in this order
SECTIONS = [rb"Stained Glass OS problem report\r?\n", rb"\nCreated: ", rb"\n== System ==\r?\n", rb"\nSystem: "]
INJECTION = [re.compile(p, re.I) for p in (
    r"\b(ignore|disregard|forget|override)\b.{0,40}\b(previous|prior|above|earlier|all|any|your|the)\b.{0,30}"
    r"\b(instructions?|prompts?|rules|directions|guidelines|messages?|context)\b",
    r"\bsystem\s+prompt\b", r"\bnew\s+instructions?\b", r"\bprompt\s+injection\b", r"\bjailbreak",
    r"\byou\s+are\s+(now\s+)?(an?\s+)?(ai|assistant|language\s+model|llm|chatbot|agent)\b",
    r"\b(act|behave|respond)\s+as\s+(an?\s+)?(ai|assistant|developer\s+mode|dan)\b",
    r"\bdo\s+anything\s+now\b", r"\b(dear|hey|attention|note\s+to)\s+(ai|assistant|claude|chatgpt|gpt|llm|agent)\b",
    r"<\|?\s*(im_start|im_end|endoftext|system|assistant)\s*\|?>", r"\[/?(inst|system)\]",
    r"(^|\n)\s*(assistant|human|###\s*(instruction|system|response))\s*:",
    r"\b(curl|wget)\b[^\n]{0,200}\|\s*(ba)?sh\b", r"\brm\s+-rf\s+/", r"\bbase64\s+-d\b",
)]
ALLOWED = frozenset(b"\t\n\r") | frozenset(range(32, 127))

lock = threading.Lock()
blocked = {}   # address -> blocked until (epoch seconds)


def load_blocked():
    try:
        with open(os.path.join(STATE, "blocked.json")) as f:
            blocked.update(json.load(f))
    except (OSError, ValueError):
        pass


def block(address, why):
    with lock:
        blocked[address] = time.time() + BLOCK_DAYS * 86400
        now = time.time()
        for a in [a for a, t in blocked.items() if t < now]:
            del blocked[a]
        tmp = os.path.join(STATE, "blocked.json.tmp")
        with open(tmp, "w") as f:
            json.dump(blocked, f)
        os.replace(tmp, os.path.join(STATE, "blocked.json"))
    sys.stderr.write("blocked %s for %d days: %s\n" % (address, BLOCK_DAYS, why))


def is_blocked(address):
    with lock:
        return blocked.get(address, 0) > time.time()


def suspicious(text):
    """why a report is not one of ours, or tries to instruct an AI; "" if fine"""
    pos = 0
    for sec in SECTIONS:
        m = re.compile(sec).search(text.encode("ascii"), pos)
        if not m:
            return "not laid out as a problem report"
        pos = m.start() + 1   # sections share their line breaks
    for rx in INJECTION:
        m = rx.search(text)
        if m:
            return "looks like instructions to an AI: %r" % m.group(0)[:60]
    return ""
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
        if is_blocked(address):
            return self.answer(403, {"error": "reports from this address are not taken"})
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
        why = suspicious(body.decode("ascii"))
        if why:
            block(address, why)
            return self.answer(403, {"error": "this does not look like a report from Report a problem; "
                                               "reports from this address are no longer taken"})
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
        try:
            publish(rid, now, body)
        except OSError as e:
            sys.stderr.write("publishing %s failed: %s\n" % (rid, e))
        return self.answer(201, {"id": rid, "url": "https://freesoft.page/reports/#" + rid})

    def do_GET(self):
        self.answer(405, {"error": "reports are sent with POST"})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.headers.get("X-Sg-Client-Ip", "-") if hasattr(self, "headers") and self.headers else "-",
                                      fmt % args))


# ---- the public Debug Reports --------------------------------------------------------------

def field(text, name):
    m = re.search(r"^%s:\s*(.+)$" % re.escape(name), text, re.M)
    return m.group(1).strip()[:200] if m else ""


def describe(rid, created, text):
    program = field(text, "Name") if "== Program ==" in text else ""
    first_exc = ""
    m = re.search(r"^Exceptions \(by code.*\n\s+\d+\s+(.+)$", text, re.M)
    if m:
        first_exc = m.group(1).strip()[:200]
    net = re.search(r"^\s*(System\.[A-Za-z.]*Exception[^\n]*)", text, re.M)
    notes = ""
    m = re.search(r"== What happened \(the tester's words\) ==\n(.*?)\n\n", text, re.S)
    if m and m.group(1).strip() != "(no notes)":
        notes = " ".join(m.group(1).split())[:300]
    return {
        "id": rid, "created": created.strftime("%Y-%m-%d %H:%M UTC"),
        "program": program or "System report", "product": field(text, "Product"),
        "version": field(text, "Version"), "ended": field(text, "How it ended") or field(text, "Ran for"),
        "exception": first_exc, "dotnet": net.group(1).strip()[:200] if net else "",
        "system": field(text, "System"), "notes": notes,
    }


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:60] or "system"


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Debug Reports - Stained Glass OS</title>
<style>
:root { --bg: #fff; --fg: #1d1b26; --muted: #66617a; --accent: #7b3fe4; --line: #e4e0ee; --card: #f7f5fb; }
@media (prefers-color-scheme: dark) { :root { --bg: #16141c; --fg: #ece9f3; --muted: #a39db5; --accent: #b48cff; --line: #2c2838; --card: #1e1b27; } }
body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 system-ui, sans-serif; }
main { max-width: 980px; margin: 0 auto; padding: 16px; }
a { color: var(--accent); }
header { display: flex; justify-content: space-between; align-items: baseline; flex-wrap: wrap; gap: 8px; }
.app { border: 1px solid var(--line); border-radius: 10px; background: var(--card); margin: 14px 0; padding: 10px 14px; }
.app h2 { margin: 4px 0 6px; font-size: 18px; }
.r { border-top: 1px solid var(--line); padding: 6px 0; font-size: 14px; }
.r code { font-size: 13px; overflow-wrap: anywhere; }
.muted { color: var(--muted); }
</style></head><body><main>
<header><h1>Debug Reports</h1><span class="muted"><a href="/">Stained Glass OS</a> &middot; <a href="index.json">index.json</a></span></header>
<p class="muted">Problem reports testers sent with <b>Report a problem</b>, grouped by program, newest first. Account and
computer names are left out by the sender. These show what is being tried on Stained Glass OS and what still fails.</p>
%s
</main></body></html>
"""


def publish(rid, created, body):
    text = body.decode("ascii")
    meta = describe(rid, created, text)
    d = os.path.join(PUBLIC, slug(meta["program"]))
    os.makedirs(d, exist_ok=True)
    for name, data in ((rid + ".txt", text), (rid + ".json", json.dumps(meta))):
        with open(os.path.join(d, name + ".tmp"), "w") as f:
            f.write(data)
        os.chmod(os.path.join(d, name + ".tmp"), 0o644)
        os.replace(os.path.join(d, name + ".tmp"), os.path.join(d, name))
    rebuild_index()


def rebuild_index():
    with lock:
        apps = collections.defaultdict(list)
        for app in sorted(os.listdir(PUBLIC)):
            p = os.path.join(PUBLIC, app)
            if not os.path.isdir(p):
                continue
            for name in os.listdir(p):
                if name.endswith(".json"):
                    try:
                        with open(os.path.join(p, name)) as f:
                            m = json.load(f)
                    except (OSError, ValueError):
                        continue
                    m["path"] = "%s/%s.txt" % (app, m["id"])
                    apps[m["program"]].append(m)
        for v in apps.values():
            v.sort(key=lambda m: m["id"], reverse=True)
        order = sorted(apps, key=lambda a: (-len(apps[a]), a.lower()))
        parts = []
        for a in order:
            rows = []
            for m in apps[a][:200]:
                what = m["dotnet"] or m["exception"]
                rows.append('<div class="r" id="%s"><a href="%s">%s</a> <span class="muted">%s%s</span>%s%s</div>' % (
                    html.escape(m["id"]), html.escape(m["path"]), html.escape(m["created"]),
                    ("v" + html.escape(m["version"]) + " &middot; ") if m["version"] else "", html.escape(m["ended"]),
                    "<br><code>%s</code>" % html.escape(what) if what else "",
                    "<br>&ldquo;%s&rdquo;" % html.escape(m["notes"]) if m["notes"] else ""))
            title = html.escape(a) + (' <span class="muted">%s</span>' % html.escape(apps[a][0]["product"])
                                      if apps[a][0]["product"] and apps[a][0]["product"] != a else "")
            parts.append('<section class="app" id="%s"><h2>%s <span class="muted">(%d)</span></h2>%s</section>' % (
                html.escape(slug(a)), title, len(apps[a]), "".join(rows)))
        page = PAGE % ("\n".join(parts) or "<p>No reports yet.</p>")
        for name, data in (("index.html", page),
                           ("index.json", json.dumps({a: apps[a] for a in order}, indent=1))):
            with open(os.path.join(PUBLIC, name + ".tmp"), "w") as f:
                f.write(data)
            os.chmod(os.path.join(PUBLIC, name + ".tmp"), 0o644)
            os.replace(os.path.join(PUBLIC, name + ".tmp"), os.path.join(PUBLIC, name))


def main():
    host, port = LISTEN.rsplit(":", 1)
    os.makedirs(STATE, exist_ok=True)
    os.makedirs(PUBLIC, exist_ok=True)
    load_blocked()
    rebuild_index()
    ThreadingHTTPServer((host, int(port)), Handler).serve_forever()


if __name__ == "__main__":
    main()
