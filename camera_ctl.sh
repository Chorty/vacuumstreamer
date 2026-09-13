#!/bin/sh
# Camera control for the Valetudo plugin and for manual use.
#
# Usage: camera_ctl.sh start|stop|status
#   start   Resume the camera: start go2rtc and the supervisor, then wake
#           video_monitor
#   stop    Pause the camera: stop go2rtc and video_monitor and keep them
#           stopped until the next start or reboot
#   status  Print the camera state as key=value lines
#
# Exit codes: 1 video_monitor did not start, 64 usage, 75 camera switched off,
# 78 camera login misconfigured.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

action="${1:-}"

fail() {
    vs_log "camera_ctl $action failed: $2"
    echo "camera_ctl: $2" >&2
    exit "$1"
}

case "$action" in
    start)
        problem=$("$VS_DIR/go2rtc_launch.sh" --check 2>&1)
        result=$?
        [ "$result" -eq 0 ] || fail "$result" "${problem#go2rtc_launch: }"

        mkdir -p "$VS_RUN_DIR"
        rm -f "$VS_RUN_DIR/camera_paused"
        vs_log "camera resumed"

        vs_running go2rtc || vs_start_detached "$VS_DIR/go2rtc_launch.sh"
        vs_start_detached "$VS_DIR/camera_supervisor.sh"
        "$VS_DIR/camera_wake.sh" > /dev/null 2>&1 || fail 1 "video_monitor did not start; see $VS_LOG"
        ;;
    stop)
        mkdir -p "$VS_RUN_DIR"
        : > "$VS_RUN_DIR/camera_paused"
        vs_stop go2rtc
        vs_stop video_monitor
        vs_log "camera paused"
        ;;
    status)
        echo "camera=$(vs_switch CAMERA on)"
        echo "mode=$(vs_camera_mode)"
        if vs_camera_paused; then echo "paused=yes"; else echo "paused=no"; fi
        if vs_running go2rtc; then echo "go2rtc=running"; else echo "go2rtc=stopped"; fi
        if vs_running video_monitor; then echo "video_monitor=running"; else echo "video_monitor=stopped"; fi
        if vs_port_connected "$VS_CAMERA_PORT"; then echo "viewer=connected"; else echo "viewer=none"; fi
        ;;
    *)
        echo "usage: $0 start|stop|status" >&2
        exit 64
        ;;
esac
