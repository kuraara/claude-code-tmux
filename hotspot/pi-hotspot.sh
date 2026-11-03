#!/usr/bin/env bash
# pi-hotspot.sh: turn a Raspberry Pi's Wi-Fi into a hotspot you can join from a phone.
#
# For Raspberry Pi OS Bookworm or later (NetworkManager). A phone that joins gets an address
# automatically; the Pi is 10.42.0.1, so its web pages and SSH are reachable from the phone,
# e.g. http://10.42.0.1:8765.
#
#   sudo ./pi-hotspot.sh           start it (set up the first time) and show how to join
#   sudo ./pi-hotspot.sh off       stop it: Wi-Fi goes back to its usual networks
#   sudo ./pi-hotspot.sh status    is it on, and how many devices have joined
#   sudo ./pi-hotspot.sh remove    stop it and forget it
#
# Settings go before the script, e.g.  sudo SSID=my-pi PASSWORD=correcthorse ./pi-hotspot.sh
#   SSID       network name                          default: <hostname>-hotspot
#   PASSWORD   8 to 63 characters                    default: the current one, or a random one
#   IFACE      Wi-Fi interface                       default: wlan0
#   BAND       bg = 2.4 GHz, a = 5 GHz               default: bg (every phone sees it)
#   CHANNEL                                          default: 6 (bg) or 36 (a)
#   COUNTRY    two-letter Wi-Fi country, e.g. GB     default: leave it as it is
#   ADDRESS    the Pi's address on the hotspot       default: 10.42.0.1/24
#   SHARE      1 = phones may use the Pi's other connections (e.g. the internet over
#              Ethernet); 0 = phones reach only the Pi and its containers.    default: 0
#   AUTOSTART  1 = start again after a reboot        default: 1
#   FORCE      1 = go ahead even if Wi-Fi is the Pi's only network connection
#
# The Wi-Fi chip does one job at a time: while the hotspot is on, the Pi can't also be on a
# Wi-Fi network. Give the Pi its own connection over Ethernet.
set -euo pipefail

CON=pi-hotspot
HOOK=/etc/NetworkManager/dispatcher.d/90-pi-hotspot
IFACE=${IFACE:-wlan0}
SSID=${SSID:-$(hostname | cut -c1-24)-hotspot}
BAND=${BAND:-bg}
ADDRESS=${ADDRESS:-10.42.0.1/24}
SHARE=${SHARE:-0}
AUTOSTART=${AUTOSTART:-1}
case $BAND in
  bg) CHANNEL=${CHANNEL:-6} ;;
  a) CHANNEL=${CHANNEL:-36} ;;
  *) echo "pi-hotspot: BAND must be bg (2.4 GHz) or a (5 GHz)" >&2; exit 2 ;;
esac

die() { echo "pi-hotspot: $*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
exists() { nmcli -t -f NAME connection show | grep -x "$CON" >/dev/null; }

preflight() {
  [ "$(id -u)" -eq 0 ] || die "run it with sudo"
  command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager ||
    die "NetworkManager isn't running. On older Raspberry Pi OS: sudo raspi-config, Advanced Options, Network Config, NetworkManager, then reboot."
  nmcli -t -f DEVICE,TYPE device | grep -x "$IFACE:wifi" >/dev/null || die "no Wi-Fi interface called $IFACE (see: nmcli device)"
}

# While the hotspot is up, devices on it reach only this Pi and its Docker containers (SHARE=0).
install_hook() {
  cat > "$HOOK" <<'HOOK'
#!/bin/sh
# Installed by pi-hotspot.sh. While the hotspot is up, devices on it reach only this Pi and its
# Docker containers, not the networks behind it.
[ "$CONNECTION_ID" = "pi-hotspot" ] || exit 0
IF=$1
case $2 in
  up)
    if command -v nft >/dev/null; then
      nft delete table inet pi_hotspot 2>/dev/null
      nft -f - <<EOF
table inet pi_hotspot {
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "$IF" oifname "docker0" accept
    iifname "$IF" oifname "br-*" accept
    iifname "$IF" oifname "veth*" accept
    iifname "$IF" drop
    oifname "$IF" iifname "docker0" accept
    oifname "$IF" iifname "br-*" accept
    oifname "$IF" iifname "veth*" accept
    oifname "$IF" drop
  }
}
EOF
    elif command -v iptables >/dev/null; then
      iptables -N PI_HOTSPOT 2>/dev/null || iptables -F PI_HOTSPOT
      for br in docker0 br-+ veth+; do
        iptables -A PI_HOTSPOT -i "$IF" -o "$br" -j RETURN
        iptables -A PI_HOTSPOT -o "$IF" -i "$br" -j RETURN
      done
      iptables -A PI_HOTSPOT -i "$IF" -j DROP
      iptables -A PI_HOTSPOT -o "$IF" -j DROP
      iptables -C FORWARD -j PI_HOTSPOT 2>/dev/null || iptables -I FORWARD 1 -j PI_HOTSPOT
    fi
    ;;
  down)
    command -v nft >/dev/null && nft delete table inet pi_hotspot 2>/dev/null
    if command -v iptables >/dev/null; then
      iptables -D FORWARD -j PI_HOTSPOT 2>/dev/null
      iptables -F PI_HOTSPOT 2>/dev/null
      iptables -X PI_HOTSPOT 2>/dev/null
    fi
    ;;
esac
exit 0
HOOK
  chown root:root "$HOOK"
  chmod 755 "$HOOK"
}

start() {
  preflight
  [ ${#SSID} -le 32 ] || die "SSID is longer than 32 characters"

  # Is Wi-Fi this Pi's only way onto the network? Then the hotspot would cut it off.
  local client others
  client=$(nmcli -t -f DEVICE,STATE,CONNECTION device | awk -F: -v i="$IFACE" -v c="$CON" '$1 == i && $2 == "connected" && $3 != c { print $3 }')
  others=$(ip route show default | grep -v "dev $IFACE " || true)
  if [ -n "$client" ]; then
    if [ -z "$others" ] && [ "${FORCE:-0}" != 1 ]; then
      die "$IFACE is this Pi's only network connection (\"$client\"). The hotspot would replace it and cut the Pi off from the network and the internet. Plug in Ethernet first, or run with FORCE=1 to go ahead anyway."
    fi
    echo "$IFACE leaves \"$client\" for the hotspot."
  fi

  if [ -n "${COUNTRY:-}" ]; then
    if command -v raspi-config >/dev/null; then raspi-config nonint do_wifi_country "$COUNTRY"; else iw reg set "$COUNTRY"; fi
  fi
  rfkill unblock wifi 2>/dev/null || true
  nmcli radio wifi on

  if [ -z "${PASSWORD:-}" ] && exists; then   # keep the password phones already know
    PASSWORD=$(nmcli -s -g 802-11-wireless-security.psk connection show "$CON" 2>/dev/null | sed 's/\\\(.\)/\1/g' || true)
  fi
  if [ -z "${PASSWORD:-}" ]; then              # easy to type: no 0/o, 1/l/i
    PASSWORD=$(LC_ALL=C tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' </dev/urandom | head -c 12 || true)
  fi
  [ ${#PASSWORD} -ge 8 ] && [ ${#PASSWORD} -le 63 ] || die "PASSWORD must be 8 to 63 characters"

  if [ "$SHARE" = 1 ]; then
    rm -f "$HOOK"
  else
    command -v nft >/dev/null || command -v iptables >/dev/null ||
      echo "Warning: neither nft nor iptables is installed, so phones could reach the network behind the Pi. sudo apt install nftables" >&2
    install_hook
  fi

  # (Re)create it with the current settings.
  if exists; then nmcli connection delete "$CON" >/dev/null; fi
  nmcli connection add type wifi ifname "$IFACE" con-name "$CON" ssid "$SSID" \
    connection.autoconnect "$([ "$AUTOSTART" = 1 ] && echo yes || echo no)" \
    connection.autoconnect-priority 100 \
    802-11-wireless.mode ap 802-11-wireless.band "$BAND" 802-11-wireless.channel "$CHANNEL" \
    802-11-wireless-security.key-mgmt wpa-psk 802-11-wireless-security.proto rsn \
    802-11-wireless-security.pairwise ccmp 802-11-wireless-security.group ccmp \
    802-11-wireless-security.pmf disable 802-11-wireless-security.psk "$PASSWORD" \
    ipv4.method shared ipv4.addresses "$ADDRESS" ipv6.method disabled >/dev/null
  nmcli connection up "$CON" >/dev/null ||
    die "the hotspot didn't start. Try BAND=bg CHANNEL=1, set COUNTRY, and check: journalctl -u NetworkManager -n 50 (if it mentions dnsmasq: sudo apt install dnsmasq-base)"

  show
}

show() {
  local addr=${ADDRESS%/*}
  echo
  echo "Hotspot \"$SSID\" is on."
  echo "  Password:     $PASSWORD"
  echo "  This Pi:      $addr   (ssh ${SUDO_USER:-pi}@$addr)"
  echo "  Its pages:    http://$addr:<port>, e.g. http://$addr:8765"
  if [ "$SHARE" = 1 ]; then
    echo "  Phones can also use this Pi's other network connections."
  else
    echo "  Phones reach only this Pi and its containers, so a phone may say \"No internet\": stay connected."
  fi
  [ "$AUTOSTART" = 1 ] && echo "  It starts again after a reboot (sudo $0 off to stop it)."
  esc() { printf '%s' "$1" | sed 's/[\\;,:"]/\\&/g'; }
  local qr="WIFI:T:WPA;S:$(esc "$SSID");P:$(esc "$PASSWORD");;"
  if command -v qrencode >/dev/null; then
    echo
    echo "Point the phone's camera at this to join:"
    qrencode -t ANSIUTF8 "$qr"
  else
    echo "  (sudo apt install qrencode for a QR code to scan instead of typing the password)"
  fi
}

off() {
  preflight
  exists || die "there's no hotspot set up"
  nmcli connection modify "$CON" connection.autoconnect no
  nmcli connection down "$CON" >/dev/null 2>&1 || true
  echo "Hotspot off; it won't start after a reboot. $IFACE goes back to its usual Wi-Fi networks."
}

status() {
  preflight
  if ! exists; then echo "No hotspot set up (sudo $0 starts one)."; return; fi
  local ssid state n
  ssid=$(nmcli -g 802-11-wireless.ssid connection show "$CON")
  state=$(nmcli -g GENERAL.STATE connection show "$CON" 2>/dev/null || true)
  if [ "$state" = activated ]; then
    n=$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station' || true)
    echo "Hotspot \"$ssid\" is on; ${n:-0} device(s) joined. The Pi is $(nmcli -g ipv4.addresses connection show "$CON" | cut -d/ -f1)."
  else
    echo "Hotspot \"$ssid\" is set up but off (sudo $0 starts it)."
  fi
}

remove() {
  preflight
  if exists; then nmcli connection delete "$CON" >/dev/null; fi
  rm -f "$HOOK"
  echo "Hotspot removed."
}

case ${1:-on} in
  on | start) start ;;
  off | stop) off ;;
  status) status ;;
  remove) remove ;;
  -h | --help | help) usage ;;
  *) usage; exit 2 ;;
esac
