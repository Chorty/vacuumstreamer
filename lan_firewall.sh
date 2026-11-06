#!/bin/sh
# Keep the inbound LAN drops in place while LAN_FIREWALL=on, and IPv6 off on wlan0,
# because this kernel can't filter IPv6. iptables rules don't survive a reboot, and
# the firmware's wifi_start.sh flushes them when it changes networks, so this checks
# every 30 s. Only wlan0 is covered, so loopback users are unaffected: Caddy, SSH
# tunnels and Valetudo's firmware link.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

# Without Caddy, port 80 is the only way in from another device, so it stays open.
block_http=$(vs_switch HTTPS_PROXY off)

while :; do
    vs_lan_ipv6_off
    vs_lan_firewall_apply "$block_http"
    sleep 30
done
