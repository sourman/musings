# Slack ↔ WhatsApp bridge: options research (2026-10-13)

Researched at Ahmed's request ("search around and let's discuss the options").
Verifies/extends the architecture the assistant sketched at ~14:52 UTC.

## Decision: Slack → WhatsApp (inbound to the bridge box)

| Option | Needs | Verdict |
|---|---|---|
| **Socket Mode** — app opens an outbound WebSocket to Slack via `apps.connections.open` with an app-level token (`xapp-…`, `connections:write`); events arrive as JSON envelopes over the socket | Outbound HTTPS/WSS only; no public URL, no Request URL, no signing secret | **Right answer for this box** — works behind NAT on any machine with internet. Officially supported; used in production by many bridge projects. |
| **Events API** — Slack pushes events to a public HTTPS Request URL | Publicly routable URL (or ngrok tunnel for dev), plus signature verification | **Ruled out** — this VM has no public address; needs ingress we don't have. |

Confirmations from multiple independent implementations: Socket Mode is "egress-only" (outbound dial, no public request URL/TLS/reverse proxy/HMAC signing secret), production-ready, and the accepted transport when a box can't receive inbound webhooks. The Python `slack_sdk` ships a `SocketModeClient`; the bridge also needs the regular Web API client with the bot token.

One token note: two tokens, don't mix them up — `xapp-…` (app-level, `connections:write`) opens the socket; `xoxb-…` (bot token, `chat:write`) posts messages.

## Decision: WhatsApp → Slack (posting to the channel)

| Option | Needs | Verdict |
|---|---|---|
| **Incoming webhook** — Slack gives one URL per channel; POST JSON text | Just the webhook URL | Simplest, but fixed to one channel, fewer controls. |
| **`chat.postMessage` via bot token** | App with `chat:write`, installed; bot must be *invited to the channel* | **Right answer** — same app is needed anyway for Socket Mode, so one app covers both directions; full formatting, threads, reactions, edit/delete. |

Since the app exists either way, use the bot token for both directions.

## Scopes — refined for the actual setup

Ahmed's bridge channel is a **private** channel (his private channel still isn't visible to us). The earlier list (`chat:write`, `channels:history`, `channels:read`) is incomplete for that:

- **Bot token scopes:** `chat:write` (post), `groups:history` + `groups:read` (read private channels — `channels:history` only covers public ones), `channels:history`/`channels:read` (harmless to keep)
- **Event subscriptions:** enable events; subscribe to **`message.groups`** (private channel messages), optionally `message.channels` for public ones
- **App-level token:** `connections:write` (Socket Mode)
- **After install:** `/invite @bridge-app` in the target channel. `chat:write.public` does **not** cover private channels — no invite, no posting.
- Reinstall the app to the workspace after any scope change.

## Gotchas to build around (from real-world write-ups)

1. **Slack returns HTTP 200 with `{"ok": false, "error": "not_in_channel"}` in the body.** The bridge must check `body.ok`, not the HTTP status — otherwise misconfigurations (bot not invited) look like silent successes.
2. **Rate limit ~1 msg/sec/channel** on `chat.postMessage` — fine for this use; queue outbound posts per channel.
3. **Always set `text`** on every message (even with Block Kit) — it's used for notifications/sidebar previews; without it messages notify blank.
4. **Only one Socket Mode connection per app-level token** — one bridge process holds it.

## Local-side wiring (already verified pieces)

- WA → Slack: the daemon already POSTs `{event: "unread", chats: [{who, sender, preview, unread, muted}]}` to the local webhook (`webhook_inbox.py` appends to `webhook_inbox.jsonl`). The bridge tails that stream, filters to the paired group JID/name, formats `[sender] preview`, POSTs via `chat.postMessage`.
  - Caveat: the payload carries only the **chat-list snippet** (per the 2026-10-08 triage note). Long messages may arrive truncated in Slack unless we extend the scraper or add a read step.
- Slack → WA: Socket Mode client receives `message.groups` events for the paired channel; ignore anything from the bot itself (`bot_id` present / own user ID); take the text and hand it to `send_to_contact.py` with the group name (already verified working).
- Loop prevention: bot-posted messages are identifiable (bot_id); the bridge never re-forwards its own posts. Own WhatsApp sends generate no unreads, so no WA-side echo.
- Bridge runs as a supervised unit next to the existing five, with tokens stored like the proxy creds.

## Open questions for Ahmed (already put to him; research needs no nudge)

1. Create the Slack app + hand over bot token (`xoxb-`) and app token (`xapp-`).
2. Which Slack channel pairs with "WhatsApp slack bridging" — needs the exact name or an invite; the bot must be added to the channel.
3. Policy: should Ahmed's own WhatsApp messages in the group also appear in Slack, or only incoming ones?
4. Bridge vs. triage overlap: the agentic triage chain (`wacdp-inbox-watch`) reads the same inbox file. When the group is bridged programmatically, should triage still summarize/react there? Decide before go-live.
5. Hygiene: the group currently contains an unrecognized number (an unrecognized number). Resolve/remove it before bridging to a Slack channel.

## What Ahmed still needs to do (blocked list, unchanged)

Slack app creation → tokens → channel name/invite. Nothing on our side is buildable until the tokens exist; the bridge can be written and dry-run against the tokens the moment they're handed over.
