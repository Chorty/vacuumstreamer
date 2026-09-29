#!/bin/sh
# Keep the robot's LAN-only HTTPS entry point running after boot. Certificate
# issuance happens on Home Assistant; this process never receives a DNS token.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

CADDY="$VS_DIR/caddy"
CADDYFILE="$VS_DIR/https_proxy.Caddyfile"
CERT="$VS_CREDENTIALS_DIR/https-fullchain.pem"
KEY="$VS_CREDENTIALS_DIR/https-privkey.pem"
DIR="$VS_CREDENTIALS_DIR"
. "$VS_SCRIPT_DIR/https_cert_state.sh"

while [ "$(vs_switch HTTPS_PROXY off)" = on ]; do
    # Recover interrupted publication before starting after a crash/reboot.
    (umask 077; mkdir -p "$DIR" && exec 9> "$DIR/https-install.lock" || exit 1
        flock -n 9 || exit 2
        https_recover)
    recovery=$?
    if [ "$recovery" -eq 1 ]; then
        sleep 5
        continue
    fi
    # A busy lock means the installer owns the provisional pair. Starting it
    # is safe: both the robot and HA must verify it before it is committed.
    if [ ! -x "$CADDY" ] || [ ! -r "$CADDYFILE" ] || [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
        vs_log "https proxy: binary, config, or certificate missing"
        sleep 5
        continue
    fi

    "$CADDY" run --config "$CADDYFILE" --adapter caddyfile > /dev/null 2>&1
    vs_log "https proxy: exited; restarting"
    sleep 5
done
