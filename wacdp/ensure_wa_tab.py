#!/usr/bin/env python3
"""After a VM reboot, Chrome boots to about:blank and the daemon's chat-list
scrape finds no WhatsApp tab ("no_chat_list" wedge). This re-navigates a page
tab to web.whatsapp.com so the persisted session (profile cookies) loads again.

Idempotent: no-op when a WhatsApp tab already exists. Retries ~60s for Chrome
to bind the CDP port after (re)start.
"""
from __future__ import annotations

import asyncio
import json
import sys
import time
import urllib.request

import websockets

CDP = "http://127.0.0.1:9429"
WA_URL = "https://web.whatsapp.com/"


def tabs():
    return json.load(urllib.request.urlopen(f"{CDP}/json/list", timeout=5))


async def navigate(ws_url: str) -> None:
    async with websockets.connect(ws_url, max_size=10_000_000) as ws:
        await ws.send(
            json.dumps(
                {"id": 1, "method": "Page.navigate", "params": {"url": WA_URL}}
            )
        )
        await ws.recv()


def main() -> int:
    for _ in range(12):
        try:
            entries = tabs()
        except Exception:
            time.sleep(5)
            continue
        pages = [t for t in entries if t.get("type") == "page"]
        if any("whatsapp" in (t.get("url") or "").lower() for t in pages):
            print("whatsapp tab already present")
            return 0
        if pages:
            try:
                asyncio.run(navigate(pages[0]["webSocketDebuggerUrl"]))
            except Exception as exc:  # noqa: BLE001
                print(f"navigate failed: {exc}")
                return 1
            print("navigated a tab to web.whatsapp.com")
            return 0
        time.sleep(5)
    print("no page tabs on CDP after retries")
    return 1


if __name__ == "__main__":
    sys.exit(main())
