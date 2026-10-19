#!/usr/bin/env bash
# Dedicated Chromium for wacdp. Launched by systemd (wacdp-chrome.service).
# Flags matter:
#  --headless=new        Xvfb headful would not bind the debug port here
#  --user-agent=...      WhatsApp Web rejects the HeadlessChrome UA ("update Chrome" page)
#  --proxy-server=...    egress proxy needs auth; local forwarder on :8888 injects it
#                        (Chrome --proxy-server cannot take embedded credentials)
#  --ignore-certificate-errors
#                        egress proxy does TLS interception; its CA is not in Chrome's NSS db.
#                        Scoped risk: this browser only ever talks to WhatsApp Web, and
#                        WhatsApp messages are E2E-encrypted at the app layer anyway.
set -euo pipefail
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"
exec /home/hatch/workspace/chrome/chrome-linux64/chrome \
  --headless=new --no-sandbox --disable-gpu \
  --ignore-certificate-errors \
  --user-agent="$UA" \
  --remote-debugging-port=9429 \
  --proxy-server=http://127.0.0.1:8888 \
  --user-data-dir=/home/hatch/workspace/wacdp/.chrome-profile \
  --window-size=1280,800 about:blank
