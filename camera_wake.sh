#!/bin/sh
# Video source for go2rtc's camera stream, used through an echo: source.
#
# go2rtc runs this whenever the stream needs video, including its retries after
# video_monitor exits. It starts video_monitor when needed, waits for its stream
# port and prints the address go2rtc should read.
#
# Exit code 1 means the camera is unavailable; the reason goes to stderr and
# the VacuumStreamer log.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

refuse() {
    vs_log "camera wake refused: $1"
    echo "camera_wake: $1" >&2
    exit 1
}

vs_enabled CAMERA on || refuse "CAMERA=off in $VS_CONF"
vs_camera_paused && refuse "camera paused"

timeout=$(vs_number CAMERA_WAKE_TIMEOUT_SECONDS 15 1 120)
mkdir -p "$VS_RUN_DIR"

# Serialize wakes so viewers arriving together start a single video_monitor
(
    flock -w "$timeout" 9 || exit 3

    if ! vs_running video_monitor; then
        vs_log "camera wake: starting video_monitor"
        vs_start_detached "$VS_DIR/video_monitor_launch.sh"
    fi

    deadline=$(($(vs_now) + timeout))

    until vs_port_listening "$VS_CAMERA_PORT"; do
        [ "$(vs_now)" -lt "$deadline" ] || exit 2
        sleep 0.2
    done
) 9> "$VS_RUN_DIR/camera.lock"

case $? in
    0) ;;
    3) refuse "timed out waiting for another camera wake" ;;
    *) refuse "video_monitor did not open port $VS_CAMERA_PORT within ${timeout}s" ;;
esac

vs_state_set camera_last_wake "$(vs_now)"
echo "tcp://127.0.0.1:$VS_CAMERA_PORT"
