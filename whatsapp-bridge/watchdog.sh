#!/bin/bash
# watchdog.sh — keeps the WhatsApp bridge healthy (run every 6h by the
# com.whatsapp.mcp.watchdog LaunchAgent). Self-healing:
#   1. Process down            -> kickstart (KeepAlive should handle it, but ensure it).
#   2. Real "client outdated (405)" in the log -> auto-run update-bridge.sh (pull upstream,
#      rebuild, verify, rollback). update-bridge.sh handles its own notifications.
#   3. Healthy                 -> log OK.
# NOTE: grep matches the real error strings ("client outdated" / "(405)") — NOT a bare
# "405", which would false-match millisecond timestamps like 16:11:57.405.

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/watchdog.log"
LABEL="com.whatsapp.mcp.bridge"
UID_NUM="$(id -u)"
notify(){ osascript -e "display notification \"$1\" with title \"WhatsApp Bridge\"" >/dev/null 2>&1; }
ts(){ date '+%Y-%m-%d %H:%M:%S'; }

if ! pgrep -f "$DIR/whatsapp-bridge" >/dev/null 2>&1; then
  echo "$(ts) DOWN -> kickstarting" >> "$LOG"
  launchctl kickstart -k "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1
  notify "Bridge was down — restarted it."
  exit 0
fi

if tail -120 "$DIR/bridge.log" 2>/dev/null | grep -qiE "client outdated|\(405\)"; then
  echo "$(ts) 405 detected -> running update-bridge.sh (self-heal)" >> "$LOG"
  notify "WhatsApp version bump detected — auto-updating the bridge…"
  bash "$DIR/update-bridge.sh" >> "$LOG" 2>&1
  exit 0
fi

echo "$(ts) OK — process up, no 405" >> "$LOG"
exit 0
