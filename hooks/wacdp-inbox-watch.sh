#!/usr/bin/env bash
# wacdp-inbox-watch — wakes an agent when new WhatsApp unreads land in the
# daemon's webhook inbox. Cheap 60s poll (~zero cost); the woken agent applies
# Ahmed's triage policy (approved 2026-10-12): auto-react 👍 to simple
# acknowledgements, summarize everything else. NEVER auto-send.
#
# State: byte offset into webhook_inbox.jsonl (append-only). Only
# event=="unread" wakes; "wedge" events are health alarms for the watchdog.
set -uo pipefail
source "$HATCH_HOOK_RUNTIME"

INBOX=/home/hatch/workspace/wacdp/webhook_inbox.jsonl
STATE_DIR="$HOME/hooks/state/wacdp-inbox-watch"
OFFSET_FILE="$STATE_DIR/offset"
DRY="${HATCH_HOOK_DRY_RUN:-0}"
mkdir -p "$STATE_DIR"

finish_wake() { wake "$1" "$2"; exit 0; }
finish_silent() { silent "$1" "$2"; exit 0; }

[ -f "$INBOX" ] || finish_silent "inbox file not present yet" '{}'

size=$(stat -c %s "$INBOX")
offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
# Never re-emit history: if the file shrank (rotation/rewrite), fast-forward
# to the new EOF silently instead of re-reading from 0.
[ "$offset" -gt "$size" ] && { echo "$size" > "$OFFSET_FILE"; finish_silent "inbox shrank; fast-forwarded" '{}'; }
[ "$offset" -eq "$size" ] && finish_silent "no new inbox entries" '{}'

payload=$(python3 - "$INBOX" "$offset" <<'EOF'
import json, sys
path, off = sys.argv[1], int(sys.argv[2])
events = []
with open(path) as f:
    f.seek(off)
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("event") == "unread":
            for c in obj.get("chats", []):
                events.append({
                    "who": c.get("who"),
                    "sender": c.get("sender", ""),
                    "preview": c.get("preview"),
                    "unread": c.get("unread"),
                })
print(json.dumps(events))
EOF
)

[ "$DRY" != "1" ] && echo "$size" > "$OFFSET_FILE"

if [ "$payload" = "[]" ] || [ -z "$payload" ]; then
  finish_silent "no new unreads" '{}'
else
  n=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$payload")
  finish_wake "new WhatsApp unread(s)" "{\"chats\": $payload, \"count\": $n}"
fi
