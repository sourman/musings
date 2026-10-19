# musings

House quality-of-life for the Muse environment: the scripts, units, and
runtime hooks that keep long-running local automation alive on a VM that
gets replaced (fresh root filesystem) roughly hourly. Home (`~`) persists
across replacements; everything else is rebuilt from here.

## What's inside

### `wacdp/` — WhatsApp automation persistence stack

Keeps Ahmed's [wacdp](https://github.com/sourman/wacdp) WhatsApp stack
(headless Chromium + CDP + polling daemon) alive without expensive,
frequent agent check-ins. Three layers, cheapest first:

1. **`monitor.sh`** → `systemd/wacdp-monitor.service`: dumb 30s bash loop.
   Restarts any failed unit itself, with 5-minute per-unit backoff.
   Ordinary failures recover in ~30s, no agent involved.
2. **`hooks/wacdp-stack-down.sh`** (runtime hook, 60s poll): detects wiped
   unit files / dead monitor / monitor backoff / CDP failure and recovers
   programmatically inline (`ensure-stack.sh`, Chrome restarts). Wakes an
   agent only if programmatic recovery fails.
3. **Hourly agent watchdog** (cron `wacdp-stack-watchdog`): backstop and
   judgment tier — scrape-error patterns, wedge events, heartbeat, boot log.

Supporting pieces:

- `ensure-stack.sh` — idempotent: reinstalls the five systemd units if
  missing, ensures all are active. The single entry point recovery calls.
- `run-chrome.sh` — launches the dedicated headless Chromium (CDP :9429).
- `supervise.sh`, `ensure_wa_tab.py` — Chrome supervision helpers.
- `webhook_inbox.py` — local webhook receiver (`:8899/hook`); the daemon
  POSTs unreads here.
- `proxy_forward.py` — local egress-auth proxy forwarder (:8888).
- `systemd/` — the five unit files.
- `bridge/slack-options.md` — research notes for the WhatsApp↔Slack bridge.

### `hooks/` — runtime event hooks

Bash pollers registered with the runtime; each ends in `wake`/`silent`.
A `wake` spawns a worker agent with the registered prompt.

- `wacdp-stack-down.sh` — the recovery tier described above.
- `wacdp-inbox-watch.sh` — watches the webhook inbox, wakes a triage
  worker on new WhatsApp unreads (auto-react 👍 to acks, summarize rest,
  never auto-send).
- `definitions/` — the registered hook definitions (reference copies).

## Deliberately NOT in this repo

Secrets, state, and logs stay on the machine:

- `~/.proxy_env`, `.chrome-profile/` (WhatsApp session), `.synthetic_clicks`
- `webhook_inbox.jsonl`, `state.json`, `*.log`, `boot-history.log`
- `.last_chrome_restart`, `.monitor_backoff`, `qr.png`

## Restoring on a fresh home

1. Copy the scripts into place (`~/workspace/wacdp/`, `~/hooks/scripts/`).
2. Recreate secrets (`wacdp/.proxy_env`, mode 600) and re-link WhatsApp
   via `qr.png` flow if the Chrome profile is gone.
3. Run `ensure-stack.sh`, register the hooks, re-enable them.
