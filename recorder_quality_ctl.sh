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
# Exit codes: 64 usage, 65 invalid profile, 66 recorder.cfg not accessible

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

RECORDER_CFG="${RECORDER_CFG:-$VS_DIR/ava_conf_video_monitor/recorder.cfg}"

recorder_quality_read() {
    local w h f b profile

    w=$(grep "^encoder_voutput_width" "$RECORDER_CFG" 2>/dev/null | head -1 | sed 's/.*= *//')
    h=$(grep "^encoder_voutput_height" "$RECORDER_CFG" 2>/dev/null | head -1 | sed 's/.*= *//')
    f=$(grep "^encoder_voutput_framerate" "$RECORDER_CFG" 2>/dev/null | head -1 | sed 's/.*= *//')
    b=$(grep "^encoder_voutput_bitrate" "$RECORDER_CFG" 2>/dev/null | head -1 | sed 's/.*= *//')

    if [ "$b" = "600000" ] && [ "$f" = "15" ]; then
        profile="low"
    else
        profile="high"
    fi

    echo "{\"profile\":\"$profile\",\"width\":${w:-0},\"height\":${h:-0},\"framerate\":${f:-0},\"bitrate\":${b:-0}}"
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
        sed "1,70 {
            s/^video_width = .*/video_width = $vw/
            s/^video_height = .*/video_height = $vh/
            s/^video_framerate = .*/video_framerate = $vf/
            s/^encoder_voutput_width = .*/encoder_voutput_width = $vw/
            s/^encoder_voutput_height = .*/encoder_voutput_height = $vh/
            s/^encoder_voutput_framerate = .*/encoder_voutput_framerate = $vf/
            s/^encoder_voutput_bitrate = .*/encoder_voutput_bitrate = $vb/
        }" "$RECORDER_CFG" > "$RQ_TMP" && mv "$RQ_TMP" "$RECORDER_CFG"
        vs_log "recorder_quality_ctl: set profile $profile"

        if vs_running video_monitor; then
            vs_log "recorder_quality_ctl: video_monitor running, restarting at the intended nice level"
            vs_stop video_monitor
            vs_start_detached "$VS_DIR/video_monitor_launch.sh"
        fi

        recorder_quality_read
        ;;
    *)
        echo "usage: $0 get|set PROFILE" >&2
        exit 64
        ;;
esac
