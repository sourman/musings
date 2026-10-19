#!/usr/bin/env bash
# Idempotent: (re)install wacdp systemd units and ensure the stack is running.
# /etc does not survive VM replacement, but ~/workspace does, so this script
# is the source of truth and is re-run by a watchdog cron.
#
# Two-tier persistence (2026-10-12): wacdp-monitor is the cheap local tier — a
# 30s dumb health loop that restarts failed units without an agent. The
# 15-minute agent watchdog is tier 2: it recreates everything (including the
# monitor) after a VM replacement and does the judgment-heavy checks.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# Stop legacy nohup instances so systemd takes over cleanly (stale pids ok).
# IMPORTANT: supervise.sh writes supervise.pid with the systemd unit's own main
# PID and daemon.py writes daemon.pid for its child, so never kill a pid that
# already belongs to one of the managed units — doing so deactivated and
# restarted wacdp-daemon on every watchdog run (journal: "Deactivated
# successfully" -> "Scheduled restart job").
pid_in_managed_unit() {
  local pid="$1" cg
  cg="$(ps -o cgroup= -p "$pid" 2>/dev/null || true)"
  case "$cg" in
    *wacdp-forwarder.service*|*wacdp-chrome.service*|*wacdp-webhook.service*|*wacdp-daemon.service*) return 0 ;;
  esac
  return 1
}
for p in /tmp/wachrome.pid /tmp/fwdproxy.pid "$DIR/supervise.pid" "$DIR/daemon.pid"; do
  if [ -f "$p" ]; then
    pid="$(cat "$p" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      if pid_in_managed_unit "$pid"; then
        echo "skip $pid (in managed systemd unit)" >&2
      else
        kill "$pid" 2>/dev/null || true
      fi
    fi
  fi
done
sleep 1

# Proxy env file for the forwarder (created once, 600).
if [ ! -f "$DIR/.proxy_env" ]; then
  {
    echo "https_proxy=${https_proxy:-}"
    echo "HTTPS_PROXY=${HTTPS_PROXY:-}"
  } > "$DIR/.proxy_env"
  chmod 600 "$DIR/.proxy_env"
fi

# Webhook receiver address the daemon posts to (local inbox, triaged by Dingbub).
if [ ! -f "$DIR/config.json" ]; then
  cat > "$DIR/config.json" << 'JSON'
{
  "webhook_url": "http://127.0.0.1:8899/hook",
  "webhook_key": "local",
  "denylist": []
}
JSON
  chmod 600 "$DIR/config.json"
fi

changed=0
for u in wacdp-forwarder.service wacdp-chrome.service wacdp-webhook.service wacdp-daemon.service wacdp-monitor.service; do
  if ! cmp -s "$DIR/systemd/$u" "/etc/systemd/system/$u" 2>/dev/null; then
    cp "$DIR/systemd/$u" "/etc/systemd/system/$u"
    changed=1
  fi
done
[ "$changed" = 1 ] && systemctl daemon-reload

chmod +x "$DIR/run-chrome.sh" "$DIR/supervise.sh" "$DIR/ensure.sh" "$DIR/webhook_inbox.py" "$DIR/ensure-stack.sh" "$DIR/ensure_wa_tab.py" "$DIR/monitor.sh"

# Python deps the daemon needs (rootfs does not survive VM replacement; pip
# needs the egress proxy env, so a failure here is non-fatal — the daemon's
# hourly wedge alarm still fires if scraping stays broken).
python3 -c "import websockets" 2>/dev/null || \
  python3 -m pip install --quiet --break-system-packages websockets || true

systemctl enable --now wacdp-forwarder.service wacdp-chrome.service wacdp-webhook.service wacdp-daemon.service wacdp-monitor.service >/dev/null 2>&1 || true
sleep 2
for u in wacdp-forwarder wacdp-chrome wacdp-webhook wacdp-daemon wacdp-monitor; do
  echo "$u: $(systemctl is-active "$u.service" 2>/dev/null)"
done

# After a VM replacement Chrome boots to about:blank; point a tab back at
# WhatsApp Web so the daemon's chat-list scrape finds the persisted session.
python3 "$DIR/ensure_wa_tab.py" || true
