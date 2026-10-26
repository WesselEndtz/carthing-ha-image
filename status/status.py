#!/usr/bin/env python3
"""Car Thing status screen (127.0.0.1:8080): the kiosk opens this first. It shows whether Bluetooth, the bond with the
Pi, the PAN link and the dashboard are OK, and forwards to the dashboard once it is reachable. The dashboard sends the
kiosk back here when it loses its connection, so a problem shows up as a readable checklist instead of a browser error."""
import json
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PI = "98:FE:54:01:0F:66"
DASH = ("10.44.0.1", 8790)
PAGE = (Path(__file__).parent / "status.html").read_text()


def run(*cmd: str) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""


def status() -> dict:
    show, info = run("bluetoothctl", "show"), run("bluetoothctl", "info", PI)
    ip = next((l.split()[3].split("/")[0] for l in run("ip", "-4", "-o", "addr", "show", "bnep0").splitlines()), None)
    try:
        socket.create_connection(DASH, timeout=1.5).close()
        dash = True
    except OSError:
        dash = False
    log = [l for l in run("journalctl", "-u", "carthing-pan", "-n", "12", "--no-pager", "-o", "cat").splitlines()
           if "bpf-firewall" not in l and "AdvertisementMonitor" not in l][-6:]
    clock_ok = time.localtime().tm_year >= 2026        # no RTC and often no NTP: don't show a clock that is years off
    return {"time": time.strftime("%H:%M:%S") if clock_ok else "", "uptime": run("cat", "/proc/uptime").split(" ")[0],
            "powered": "Powered: yes" in show, "paired": "Paired: yes" in info, "bonded": "Bonded: yes" in info,
            "connected": "Connected: yes" in info, "ip": ip, "dashboard": dash, "log": log}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        return

    def do_GET(self):
        body, ctype = (json.dumps(status()), "application/json") if self.path.startswith("/status.json") \
            else (PAGE, "text/html; charset=utf-8")
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


ThreadingHTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
