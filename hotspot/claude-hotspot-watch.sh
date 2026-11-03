#!/usr/bin/env bash
# claude-hotspot-watch.sh: keeps a Wi-Fi hotspot up while Claude Code is waiting to be signed in,
# and takes it down once Claude is signed in. Runs on the host as the claude-hotspot service.
#
# It reads the sign-in page's /api/status, so it works with the Docker container and the
# bare-metal install alike. Settings live in /etc/default/claude-hotspot (see install.sh).
set -u

CONF=${CONF:-/etc/default/claude-hotspot}
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
STATUS_URL=${STATUS_URL:-http://127.0.0.1:8765/api/status}
INTERVAL=${INTERVAL:-15}
RETRY_AFTER=${RETRY_AFTER:-300}
HOTSPOT_SCRIPT=${HOTSPOT_SCRIPT:-/opt/claude-tmux/pi-hotspot.sh}
# For pi-hotspot.sh. AUTOSTART=0: after a reboot this service decides, not NetworkManager.
export SSID PASSWORD IFACE BAND CHANNEL COUNTRY ADDRESS
export SHARE=${SHARE:-1} AUTOSTART=0

log() { echo "claude-hotspot: $*"; }

hotspot_up() { nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx pi-hotspot; }

# What the hotspot should be for a page state. Empty: leave it as it is (page not answering,
# or Claude's tmux session not running), so a restart doesn't make it flap.
wanted() {
  case $1 in
    ready) echo off ;;
    login | waiting) echo on ;;
    *) echo "" ;;
  esac
}

prev="" failed_at=0
log "watching $STATUS_URL every ${INTERVAL}s"
while true; do
  state=$(curl -fsS -m 10 "$STATUS_URL" 2>/dev/null | jq -r '.state // empty' 2>/dev/null)
  want=$(wanted "${state:-}")
  # Act only when two checks in a row agree.
  if [ -n "$want" ] && [ "$want" = "$prev" ]; then
    if [ "$want" = on ] && ! hotspot_up; then
      if [ $((SECONDS - failed_at)) -ge "$RETRY_AFTER" ] || [ "$failed_at" -eq 0 ]; then
        if out=$("$HOTSPOT_SCRIPT" on 2>&1); then
          log "Claude isn't signed in: hotspot \"${SSID:-}\" is on"
          failed_at=0
        else
          log "couldn't start the hotspot (trying again in ${RETRY_AFTER}s): $(echo "$out" | tail -1)"
          failed_at=$SECONDS
        fi
      fi
    elif [ "$want" = off ] && hotspot_up; then
      "$HOTSPOT_SCRIPT" off >/dev/null 2>&1
      log "Claude is signed in: hotspot off"
    fi
  fi
  prev=$want
  sleep "$INTERVAL"
done
