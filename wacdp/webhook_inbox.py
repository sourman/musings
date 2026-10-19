#!/usr/bin/env python3
"""Local webhook receiver for the wacdp daemon.

Listens on 127.0.0.1:8899 and appends each POST body (one JSON object per
line) to webhook_inbox.jsonl. Dingbub triages the inbox on schedule.
Localhost-only; no auth needed (the daemon's bearer key is ignored here).
"""
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

DIR = Path(__file__).resolve().parent
INBOX = DIR / "webhook_inbox.jsonl"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            self.send_response(400)
            self.end_headers()
            return
        payload["_received_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        with INBOX.open("a", encoding="utf-8") as f:
            f.write(json.dumps(payload, ensure_ascii=False) + "\n")
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):  # stay quiet
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8899), Handler).serve_forever()
