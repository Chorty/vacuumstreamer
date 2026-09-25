#!/bin/sh
# Keep the robot's LAN-only HTTPS entry point running after boot. Certificate
# issuance happens on Home Assistant; this process never receives a DNS token.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

CADDY="$VS_DIR/caddy"
CADDYFILE="$VS_DIR/https_proxy.Caddyfile"
CERT="$VS_CREDENTIALS_DIR/https-fullchain.pem"
KEY="$VS_CREDENTIALS_DIR/https-privkey.pem"

while [ "$(vs_switch HTTPS_PROXY off)" = on ]; do
    if [ ! -x "$CADDY" ] || [ ! -r "$CADDYFILE" ] || [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
        vs_log "https proxy: binary, config, or certificate missing"
        sleep 30
        continue
    fi

    "$CADDY" run --config "$CADDYFILE" --adapter caddyfile > /dev/null 2>&1
    vs_log "https proxy: exited; restarting"
    sleep 5
done
