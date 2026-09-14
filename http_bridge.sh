#!/bin/sh
# HTTP bridge on port 6971, started at boot when HTTP_BRIDGE=on. Runs
# tts_handler.sh for each connection and restarts tcpsvd if it exits.
#
# tcpsvd runs without -E so it passes the client address to tts_handler.sh as
# TCPREMOTEADDR, which the handler checks against HTTP_BRIDGE_ALLOW.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

VS_BRIDGE_PORT="${VS_BRIDGE_PORT:-6971}"

mkdir -p "$VS_RUN_DIR"
exec 9> "$VS_RUN_DIR/http_bridge.lock"

if ! flock -n 9; then
    exit 0
fi

vs_log "http bridge: started on port $VS_BRIDGE_PORT (HTTP_BRIDGE_ALLOW=$(vs_conf_get HTTP_BRIDGE_ALLOW any))"

while true; do
    tcpsvd -v 0.0.0.0 "$VS_BRIDGE_PORT" "$VS_DIR/tts_handler.sh" > /dev/null 2>&1 9>&-
    # Tests run a single iteration
    [ -n "${VS_BRIDGE_ONCE:-}" ] && break
    sleep 2
done
