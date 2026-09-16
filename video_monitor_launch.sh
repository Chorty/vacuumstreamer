#!/bin/sh
# Starts the vendor video_monitor with the VacuumStreamer capture hook.
#
# Usage: video_monitor_launch.sh [--check]
#   --check  Validate the switches, then exit.
#
# Exit codes: 64 usage, 75 camera switched off.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

VIDEO_MONITOR_BIN="${VIDEO_MONITOR_BIN:-$VS_DIR/video_monitor}"
VACUUMSTREAMER_SO="${VACUUMSTREAMER_SO:-$VS_DIR/vacuumstreamer.so}"
VS_LIBC="${VS_LIBC:-$VS_DIR/libc.so.6}"

case "${1:-}" in
    "" | --check) ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 64
        ;;
esac

if ! vs_enabled CAMERA on; then
    vs_log "video_monitor not started: CAMERA=off in $VS_CONF"
    echo "video_monitor_launch: CAMERA=off in $VS_CONF" >&2
    exit 75
fi

[ "${1:-}" = "--check" ] && exit 0

LD_PRELOAD="$VACUUMSTREAMER_SO"

# Older firmware needs the bundled libc alongside the hook
if [ -f "$VS_LIBC" ]; then
    LD_PRELOAD="$LD_PRELOAD:$VS_LIBC"
fi

export LD_PRELOAD
vs_log "starting video_monitor"
exec "$VIDEO_MONITOR_BIN"
