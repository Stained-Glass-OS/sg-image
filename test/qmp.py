#!/usr/bin/env python3
"""Minimal QMP client: enough to take a screenshot and to shut a guest down.

QEMU speaks a line-delimited JSON protocol on its monitor socket. We need three
commands out of it, so a full library would be more dependency than value.
"""
import json
import socket
import sys


class QMP:
    def __init__(self, path, timeout=30):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.file = self.sock.makefile("rw", encoding="utf-8", newline="\n")
        self._read()               # the greeting
        self.command("qmp_capabilities")

    def _read(self):
        """Return the next message that is a reply, skipping async events."""
        while True:
            line = self.file.readline()
            if not line:
                raise RuntimeError("QMP connection closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            return msg

    def command(self, name, **args):
        req = {"execute": name}
        if args:
            req["arguments"] = args
        self.file.write(json.dumps(req) + "\n")
        self.file.flush()
        reply = self._read()
        if "error" in reply:
            raise RuntimeError(f"{name} failed: {reply['error']}")
        return reply.get("return")

    def close(self):
        try:
            self.file.close()
            self.sock.close()
        except OSError:
            pass


# QEMU key names ("qcodes") for what the gate needs to type. Lower-case
# letters and digits are their own qcode; everything else is spelled out here.
# Only characters the lab credentials use are supported, on purpose: an
# unsupported character should fail loudly, not be typed as something else.
QCODES = {"-": "minus", " ": "spc", ".": "dot", "_": ("shift", "minus")}


def key_list(ch):
    if ch.isascii() and (ch.islower() or ch.isdigit()):
        return [ch]
    if ch.isascii() and ch.isupper():
        return ["shift", ch.lower()]
    code = QCODES.get(ch)
    if code is None:
        raise ValueError(f"cannot type {ch!r}")
    return list(code) if isinstance(code, tuple) else [code]


def send_keys(qmp, names):
    """Press the keys together and release them, like a real keyboard."""
    qmp.command("send-key", keys=[{"type": "qcode", "data": n} for n in names], **{"hold-time": 60})


def main():
    if len(sys.argv) < 3:
        print("usage: qmp.py SOCKET {screendump FILE | type TEXT | key CHORD | quit | status}", file=sys.stderr)
        return 2
    sock_path, action = sys.argv[1], sys.argv[2]
    qmp = QMP(sock_path)
    try:
        if action == "type":
            # Real key events through QEMU's keyboard: kernel, libinput,
            # compositor, Wine -- the same path a person's typing takes.
            import time
            for ch in sys.argv[3]:
                send_keys(qmp, key_list(ch))
                time.sleep(0.08)
            print("typed %d characters" % len(sys.argv[3]))
        elif action == "key":
            # One chord, e.g. "ret" or "meta_l+l".
            send_keys(qmp, sys.argv[3].split("+"))
            print("sent %s" % sys.argv[3])
        elif action == "screendump":
            qmp.command("screendump", filename=sys.argv[3])
            print(f"screendump written to {sys.argv[3]}")
        elif action == "quit":
            qmp.command("quit")
        elif action == "status":
            print(json.dumps(qmp.command("query-status")))
        else:
            print(f"unknown action: {action}", file=sys.stderr)
            return 2
    finally:
        qmp.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
