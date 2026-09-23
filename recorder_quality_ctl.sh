#!/bin/sh
# Recorder (video encoder) quality control for the Valetudo plugin and for
# manual use. Edits the vendor video_monitor's recorder.cfg, then restarts
# video_monitor -- through video_monitor_launch.sh, so it lands at the
# absolute nice level the rest of the pipeline uses (see the video-priority
# fix) -- but only if it is already running. Otherwise the next on-demand
# wake through camera_wake.sh reads the new recorder.cfg on its own.
#
# This replaces the previous port-6971 /video_quality handler, which
# restarted video_monitor by hand at the default nice level, undoing the
# video-priority fix whenever quality was changed while a viewer was
# connected.
#
# Usage: recorder_quality_ctl.sh get
#        recorder_quality_ctl.sh set PROFILE
#
# PROFILE is "low" (864x480/15fps/600kbps) or "high" (640x480/25fps/2Mbps).
#
# Exit codes: 64 usage, 65 invalid profile, 66 recorder.cfg not accessible,
# 67 failed to write recorder.cfg

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

RECORDER_CFG="${RECORDER_CFG:-$VS_DIR/ava_conf_video_monitor/recorder.cfg}"

# recorder_quality_field KEY - print KEY's first-occurrence value from
# RECORDER_CFG as a clean base-10 integer, or 0 if missing or not numeric
# (e.g. a stray CRLF line ending, or KEY absent), so recorder_quality_read's
# JSON is always well-formed and never misread as octal.
recorder_quality_field() {
    local value

    value=$(grep "^$1" "$RECORDER_CFG" 2>/dev/null | head -1 | sed 's/.*= *//' | tr -d '\r')

    case "$value" in
        '' | *[!0-9]*)
            echo 0
            ;;
        *)
            vs_strip_leading_zeros "$value"
            ;;
    esac
}

recorder_quality_read() {
    local w h f b profile

    w=$(recorder_quality_field encoder_voutput_width)
    h=$(recorder_quality_field encoder_voutput_height)
    f=$(recorder_quality_field encoder_voutput_framerate)
    b=$(recorder_quality_field encoder_voutput_bitrate)

    if [ "$b" = "600000" ] && [ "$f" = "15" ]; then
        profile="low"
    else
        profile="high"
    fi

    echo "{\"profile\":\"$profile\",\"width\":$w,\"height\":$h,\"framerate\":$f,\"bitrate\":$b}"
}

# recorder_quality_restart - restart video_monitor at the intended nice
# level, through the same camera.lock camera_wake.sh uses. Without that
# lock, a viewer's TCP connection breaking when video_monitor is killed makes
# go2rtc immediately retry through camera_wake.sh, which (finding
# video_monitor not running, and holding no competing lock) starts its own
# instance concurrently with this one; in CAMERA_MODE=always the supervisor's
# own periodic restart can race the same way with no viewer involved at all.
# Best-effort: a failure here is logged, not fatal -- recorder.cfg is already
# correct, and the next wake or supervisor tick will pick it up.
recorder_quality_restart() {
    local timeout deadline

    timeout=$(vs_number CAMERA_WAKE_TIMEOUT_SECONDS 15 1 120)
    mkdir -p "$VS_RUN_DIR"

    (
        deadline=$(($(vs_now) + timeout))

        until flock -n 9; do
            [ "$(vs_now)" -lt "$deadline" ] || exit 3
            sleep 0.2
        done

        vs_stop video_monitor
        # A brief settle so the capture device is released before the new
        # instance opens it, matching the handler this replaces.
        sleep 1
        vs_start_detached "$VS_DIR/video_monitor_launch.sh"

        deadline=$(($(vs_now) + timeout))

        until vs_port_listening "$VS_CAMERA_PORT"; do
            [ "$(vs_now)" -lt "$deadline" ] || exit 2
            sleep 0.2
        done
    ) 9> "$VS_RUN_DIR/camera.lock"

    case $? in
        0) ;;
        3) vs_log "recorder_quality_ctl: timed out waiting for the camera lock" ;;
        *) vs_log "recorder_quality_ctl: video_monitor did not start listening within ${timeout}s" ;;
    esac
}

case "${1:-}" in
    get)
        [ -r "$RECORDER_CFG" ] || {
            echo "recorder_quality_ctl: $RECORDER_CFG not found" >&2
            exit 66
        }
        recorder_quality_read
        ;;
    set)
        profile="${2:-}"

        case "$profile" in
            low)
                vw=864; vh=480; vf=15; vb=600000
                ;;
            high)
                vw=640; vh=480; vf=25; vb=2000000
                ;;
            *)
                echo "recorder_quality_ctl: invalid profile: $profile (use: low, high)" >&2
                exit 65
                ;;
        esac

        [ -w "$RECORDER_CFG" ] || {
            echo "recorder_quality_ctl: $RECORDER_CFG not writable" >&2
            exit 66
        }

        # Camera 0's settings only (first occurrence, lines 1-70), matching
        # the handler this replaces. Written via a temp file and mv rather
        # than "sed -i", whose flag takes an argument on BSD sed (macOS, used
        # by the test suite) and none on GNU/BusyBox sed (the robot) -- there
        # is no spelling of "-i" that is correct on both.
        RQ_TMP="$RECORDER_CFG.recorder_quality_ctl.tmp"
        if ! sed "1,70 {
            s/^video_width = .*/video_width = $vw/
            s/^video_height = .*/video_height = $vh/
            s/^video_framerate = .*/video_framerate = $vf/
            s/^encoder_voutput_width = .*/encoder_voutput_width = $vw/
            s/^encoder_voutput_height = .*/encoder_voutput_height = $vh/
            s/^encoder_voutput_framerate = .*/encoder_voutput_framerate = $vf/
            s/^encoder_voutput_bitrate = .*/encoder_voutput_bitrate = $vb/
        }" "$RECORDER_CFG" > "$RQ_TMP"; then
            rm -f "$RQ_TMP"
            echo "recorder_quality_ctl: failed to write $RECORDER_CFG" >&2
            exit 67
        fi
        mv "$RQ_TMP" "$RECORDER_CFG"
        vs_log "recorder_quality_ctl: set profile $profile"

        if vs_running video_monitor; then
            vs_log "recorder_quality_ctl: video_monitor running, restarting at the intended nice level"
            recorder_quality_restart
        fi

        recorder_quality_read
        ;;
    *)
        echo "usage: $0 get|set PROFILE" >&2
        exit 64
        ;;
esac
