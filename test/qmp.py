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


def main():
    if len(sys.argv) < 3:
        print("usage: qmp.py SOCKET {screendump FILE | quit | status}", file=sys.stderr)
        return 2
    sock_path, action = sys.argv[1], sys.argv[2]
    qmp = QMP(sock_path)
    try:
        if action == "screendump":
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
