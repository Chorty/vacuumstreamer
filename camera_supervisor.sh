#!/bin/sh
# Keeps the VacuumStreamer camera healthy. Started at boot when CAMERA=on.
#
# Usage: camera_supervisor.sh [--once]
#   --once  Run one check and exit (used by the tests)
#
# Every CAMERA_SUPERVISE_SECONDS (default 5) it:
#   - restarts go2rtc if it exited, backing off after starts that do not last
#   - in on_demand mode, stops video_monitor after CAMERA_IDLE_SECONDS without
#     a viewer; go2rtc wakes it again through camera_wake.sh
#   - in always mode, keeps video_monitor running
#   - restarts video_monitor when a viewer is connected but no video has
#     arrived for CAMERA_STALL_SECONDS
#   - keeps both stopped while camera_ctl.sh has paused the camera
# It exits when CAMERA is switched off.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

supervise_once() {
    local now mode idle stall bytes since last wake

    if ! vs_enabled CAMERA on; then
        vs_log "supervisor: CAMERA=off in $VS_CONF; stopping the camera"
        vs_stop go2rtc
        vs_stop video_monitor
        return 1
    fi

    if vs_camera_paused; then
        vs_running go2rtc && vs_stop go2rtc
        vs_running video_monitor && vs_stop video_monitor
        return 0
    fi

    now=$(vs_now)
    mode=$(vs_camera_mode)
    idle=$(vs_number CAMERA_IDLE_SECONDS 180 30 86400)
    stall=$(vs_number CAMERA_STALL_SECONDS 20 10 600)

    vs_keep_running go2rtc "$VS_DIR/go2rtc_launch.sh" "$now"

    if vs_port_connected "$VS_CAMERA_PORT"; then
        vs_state_set camera_last_active "$now"
        bytes=$(vs_camera_bytes)

        if [ -n "$bytes" ]; then
            if [ "$bytes" != "$(vs_state_get camera_bytes "")" ]; then
                vs_state_set camera_bytes "$bytes"
                vs_state_set camera_bytes_since "$now"
            else
                since=$(vs_state_get camera_bytes_since "$now")

                if [ $((now - since)) -ge "$stall" ]; then
                    vs_log "supervisor: no video for ${stall}s while a viewer is connected; restarting video_monitor"
                    vs_stop video_monitor
                    vs_state_set camera_bytes ""
                fi
            fi
        fi
    else
        vs_state_set camera_bytes ""

        if [ "$mode" = "on_demand" ] && vs_running video_monitor; then
            last=$(vs_state_get camera_last_active 0)
            wake=$(vs_state_get camera_last_wake 0)

            if [ "$wake" -gt "$last" ]; then
                last="$wake"
            fi

            if [ $((now - last)) -ge "$idle" ]; then
                vs_log "supervisor: no viewer for ${idle}s; stopping video_monitor"
                vs_stop video_monitor
            fi
        fi
    fi

    if [ "$mode" = "always" ]; then
        vs_keep_running video_monitor "$VS_DIR/video_monitor_launch.sh" "$now"
    fi

    return 0
}

case "${1:-}" in
    "" | --once) ;;
    *)
        echo "usage: $0 [--once]" >&2
        exit 64
        ;;
esac

mkdir -p "$VS_RUN_DIR"

if [ "${1:-}" = "--once" ]; then
    supervise_once
    exit $?
fi

exec 8> "$VS_RUN_DIR/supervisor.lock"

if ! flock -n 8; then
    exit 0
fi

# A video_monitor already running at startup gets a full idle period
vs_state_set camera_last_active "$(vs_now)"
vs_log "supervisor: started (CAMERA_MODE=$(vs_camera_mode))"

while supervise_once; do
    sleep "$(vs_number CAMERA_SUPERVISE_SECONDS 5 1 300)"
done

vs_log "supervisor: stopped"
