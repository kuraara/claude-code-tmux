#!/usr/bin/env bash
# hotspot/install.sh: optional add-on. While Claude Code is waiting to be signed in, the Pi
# runs its own Wi-Fi network; join it from a phone and open the sign-in page. Once Claude is
# signed in, the hotspot goes off and Wi-Fi goes back to normal.
#
# Works with the Docker container or the bare-metal install, on Raspberry Pi OS Bookworm or
# later (NetworkManager). Run it on the host:
#
#   curl -fsSL https://raw.githubusercontent.com/kuraara/claude-code-tmux/main/hotspot/install.sh | sudo bash
#
# Or let install-bare-metal.sh do it:  ... | sudo HOTSPOT=1 bash
#
# Settings (first install only; afterwards edit /etc/default/claude-hotspot and run
# "sudo systemctl restart claude-hotspot"):
#   PORT       the sign-in page's port on this host     default: 8765
#   SSID       network name                             default: <hostname>-claude
#   PASSWORD   8 to 63 characters                       default: random, shown at the end
#   SHARE      1 = phones get internet through the Pi's Ethernet (needed to open the
#              Anthropic sign-in link unless the phone uses mobile data); 0 = phones reach
#              only this Pi                             default: 1
#   COUNTRY    two-letter Wi-Fi country, e.g. AU        default: leave it as it is
#
# The Pi needs another connection (Ethernet) while the hotspot is on: Claude has to reach
# Anthropic to finish signing in, and the Wi-Fi chip can't be a hotspot and a client at once.
# If Wi-Fi is the Pi's only connection, the hotspot stays off and the log says why.
#
# Remove:  sudo systemctl disable --now claude-hotspot && sudo /opt/claude-tmux/pi-hotspot.sh remove
set -euo pipefail

RAW=${RAW:-https://raw.githubusercontent.com/kuraara/claude-code-tmux/main}
DIR=/opt/claude-tmux
CONF=/etc/default/claude-hotspot
PORT=${PORT:-8765}

die() { echo "claude-hotspot: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run it with sudo"
command -v systemctl >/dev/null || die "needs systemd"
command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager ||
  die "needs NetworkManager (Raspberry Pi OS Bookworm or later; on older ones: sudo raspi-config, Advanced Options, Network Config, NetworkManager)"
nmcli -t -f TYPE device | grep -qx wifi || die "this machine has no Wi-Fi"

export DEBIAN_FRONTEND=noninteractive
missing=""
for p in curl jq iw qrencode; do command -v $p >/dev/null || missing="$missing $p"; done
command -v nft >/dev/null || command -v iptables >/dev/null || missing="$missing nftables"
[ -z "$missing" ] || { apt-get update -qq && apt-get install -y -qq $missing >/dev/null; }

# The two scripts: next to this file (a clone of the repo), or from GitHub (curl | bash).
install -d -m 755 "$DIR"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || echo /nonexistent)
for f in pi-hotspot.sh claude-hotspot-watch.sh; do
  if [ -f "$HERE/$f" ]; then install -m 755 "$HERE/$f" "$DIR/$f"
  else curl -fsSL "$RAW/hotspot/$f" -o "$DIR/$f" && chmod 755 "$DIR/$f"; fi
done

if [ ! -f "$CONF" ]; then
  SSID=${SSID:-$(hostname | cut -c1-24)-claude}
  PASSWORD=${PASSWORD:-$(LC_ALL=C tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' </dev/urandom | head -c 12 || true)}
  [ ${#PASSWORD} -ge 8 ] && [ ${#PASSWORD} -le 63 ] || die "PASSWORD must be 8 to 63 characters"
  umask 077
  cat > "$CONF" <<EOF
# claude-hotspot settings. After changing them: sudo systemctl restart claude-hotspot
# The sign-in page's status, as seen from this host.
STATUS_URL=http://127.0.0.1:$PORT/api/status
SSID='$SSID'
PASSWORD='$PASSWORD'
# 1: phones get internet through this Pi's Ethernet. 0: phones reach only this Pi.
SHARE=${SHARE:-1}
IFACE=${IFACE:-wlan0}
${COUNTRY:+COUNTRY=$COUNTRY}
# Seconds between checks.
INTERVAL=15
EOF
  umask 022
fi
# shellcheck disable=SC1090
. "$CONF"
PORT=$(echo "$STATUS_URL" | sed -n 's|.*:\([0-9]*\)/.*|\1|p')

cat > /etc/systemd/system/claude-hotspot.service <<EOF
[Unit]
Description=Wi-Fi hotspot while Claude Code waits to be signed in
Wants=NetworkManager.service
After=NetworkManager.service network-online.target

[Service]
ExecStart=$DIR/claude-hotspot-watch.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q claude-hotspot
systemctl restart claude-hotspot

ADDR=${ADDRESS:-10.42.0.1/24}; ADDR=${ADDR%/*}
echo
echo "claude-hotspot is installed. While Claude is waiting to be signed in, this Pi runs:"
echo "  Wi-Fi:     $SSID"
echo "  Password:  $PASSWORD"
echo "  Then open: http://$ADDR:${PORT:-8765}"
echo "It goes off by itself once Claude is signed in. Settings: $CONF"
echo "Log: journalctl -u claude-hotspot"
esc() { printf '%s' "$1" | sed 's/[\\;,:"]/\\&/g'; }
if command -v qrencode >/dev/null; then
  echo
  echo "Scan to join:"
  qrencode -t ANSIUTF8 "WIFI:T:WPA;S:$(esc "$SSID");P:$(esc "$PASSWORD");;"
fi
