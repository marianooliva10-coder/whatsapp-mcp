#!/bin/bash
# update-bridge.sh — sustainable upkeep for the WhatsApp bridge.
#
# Strategy: TRACK UPSTREAM. The verygoodplugins/whatsapp-mcp project actively
# bumps the whatsmeow library (that's what fixes WhatsApp's periodic "client
# outdated (405)" enforcement). So the durable fix is to pull upstream and
# rebuild — not to hand-pin a version. This script does that SAFELY:
#   fetch upstream -> merge -> build -> restart -> verify it reconnects ->
#   ROLL BACK to the previous working binary if anything fails.
#
# Usage:
#   ./update-bridge.sh                 # pull upstream + rebuild + verify + rollback-on-fail
#   ./update-bridge.sh --force-whatsmeow   # also force whatsmeow@latest (use only if a
#                                          # 405 persists after an upstream pull)
#
# Safe to run unattended (watchdog / monthly launchd) because of verify+rollback.

set -uo pipefail
# Ensure go/git resolve under launchd (which has a minimal PATH).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
BR="$(cd "$(dirname "$0")" && pwd)"      # whatsapp-bridge dir
REPO="$(cd "$BR/.." && pwd)"             # repo root
LABEL="com.whatsapp.mcp.bridge"
UID_NUM="$(id -u)"
ULOG="$BR/update-bridge.log"
FORCE_WM=0; [ "${1:-}" = "--force-whatsmeow" ] && FORCE_WM=1

notify(){ osascript -e "display notification \"$1\" with title \"WhatsApp Bridge\"" >/dev/null 2>&1; }
log(){ echo "$(date '+%F %T') $*" >> "$ULOG"; }

# verify(): returns 0 if the bridge reconnects (no real 405) within ~36s
verify(){
  : > "$BR/bridge.log"
  launchctl kickstart -k "gui/$UID_NUM/$LABEL" >/dev/null 2>&1
  for _ in $(seq 1 12); do
    sleep 3
    grep -qiE "client outdated|\(405\)" "$BR/bridge.log" && return 1
    grep -qiE "successfully connected to whatsapp" "$BR/bridge.log" && return 0
  done
  return 1
}

log "=== update start (force_wm=$FORCE_WM) ==="
# Save a rollback copy of the currently-working binary.
cp "$BR/whatsapp-bridge" "$BR/whatsapp-bridge.rollback" 2>/dev/null

# 1) Pull upstream (clean fast-forward or clean merge — local only adds ops scripts,
#    which upstream never touches, so this never conflicts).
git -C "$REPO" fetch upstream --quiet 2>>"$ULOG" || { log "fetch failed"; notify "Bridge auto-update: git fetch failed."; exit 1; }
if ! git -C "$REPO" merge --no-edit upstream/main >>"$ULOG" 2>&1; then
  log "merge not clean; aborting merge"; git -C "$REPO" merge --abort 2>/dev/null
  notify "Bridge auto-update: upstream merge wasn't clean — needs a human. See update-bridge.log."
  exit 1
fi

# 2) Optionally force latest whatsmeow (manual escape hatch).
if [ "$FORCE_WM" = 1 ]; then
  ( cd "$BR" && go get -u go.mau.fi/whatsmeow@latest && go mod tidy ) >>"$ULOG" 2>&1 || { log "go get failed"; }
fi

# 3) Build.
( cd "$BR" && go build -o whatsapp-bridge.new . ) >>"$ULOG" 2>&1
if [ ! -f "$BR/whatsapp-bridge.new" ]; then
  log "build failed"; notify "Bridge auto-update: build failed. See update-bridge.log."; exit 1
fi
mv "$BR/whatsapp-bridge.new" "$BR/whatsapp-bridge"

# 4) Restart + verify, else roll back.
if verify; then
  log "OK — reconnected on new build"; notify "WhatsApp bridge updated & reconnected."; exit 0
fi
log "verify failed -> rolling back"
cp "$BR/whatsapp-bridge.rollback" "$BR/whatsapp-bridge"
verify >/dev/null 2>&1
if [ "$FORCE_WM" = 0 ]; then
  notify "Bridge update failed & rolled back. If it's a 405, run: update-bridge.sh --force-whatsmeow"
else
  notify "Bridge update failed even with whatsmeow@latest & rolled back. Needs manual attention."
fi
exit 1
