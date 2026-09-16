#!/bin/bash
# Docked 10-minute profiles of the camera: nobody watching, an RTSP viewer on
# this Mac, and CAMERA_MODE=always. Measures cold wake latency between the
# first two. Restores the robot's original CAMERA_MODE at the end.
#
# Usage: tools/profiles.sh LABEL_PREFIX [DURATION_SECONDS]
# Environment: MIN_UPTIME (default 1440 s, to match baselines captured 24-38
# minutes after boot). Writes WORK_DIR/profiles_<prefix>.txt for
# compare_profiles.py.
set -u
. "$(dirname "$0")/lib.sh"

PREFIX="${1:?usage: profiles.sh LABEL_PREFIX [DURATION_SECONDS]}"
DURATION="${2:-600}"
check_id "$PREFIX"
MIN_UPTIME="${MIN_UPTIME:-1440}"
RTSP="rtsp://$VACUUM_IP:8554/vacuum"
RUNS="$WORK_DIR/profiles_$PREFIX.txt"
VIEWER=""
ORIGINAL_MODE=""

set_mode() {
    rsh_n "sed -i 's/^CAMERA_MODE=.*/CAMERA_MODE=$1/' /data/vacuumstreamer/vacuumstreamer.conf && grep '^CAMERA_MODE=' /data/vacuumstreamer/vacuumstreamer.conf" >> "$TOOL_LOG"
}

cleanup() {
    [ -n "$VIEWER" ] && kill "$VIEWER" 2>/dev/null
    [ -n "$ORIGINAL_MODE" ] && set_mode "$ORIGINAL_MODE"
}
trap cleanup EXIT

run_profile() { # SCENARIO
    local label="$PREFIX-docked-camera-$1" dir
    robot_docked_idle || fail "robot not docked and idle before $1"
    say "START $label uptime=$(robot_uptime)s camera: $(camera_status)"
    (cd "$VALETUDO_REPO" && npm run profile_vacuum_resources -- --label "$label" --duration "$DURATION") >> "$TOOL_LOG" 2>&1
    dir=$(ls -dt "$PROFILE_ROOT"/*_"$label"_* 2>/dev/null | head -1)
    say "END $label dir=$dir camera: $(camera_status)"
    robot_docked_idle && say "$label: still docked and idle" || say "$label: NOT docked and idle at the end"
    echo "$1 $dir" >> "$RUNS"
}

ORIGINAL_MODE=$(rsh_n "sed -n 's/^CAMERA_MODE=//p' /data/vacuumstreamer/vacuumstreamer.conf | tail -1")
ORIGINAL_MODE="${ORIGINAL_MODE:-on_demand}"
check_id "$ORIGINAL_MODE"
: > "$RUNS"

until [ "$(robot_uptime)" -ge "$MIN_UPTIME" ]; do sleep 30; done
say "uptime reached ${MIN_UPTIME}s; original CAMERA_MODE=$ORIGINAL_MODE"

# Nobody watching, on demand
set_mode on_demand
wait_camera_status 400 "video_monitor=stopped" || say "WARN video_monitor still running before the idle profile"
wait_camera_status 60 "viewer=none" || say "WARN a viewer is connected before the idle profile"
run_profile idle

if camera_status | grep -q "video_monitor=stopped"; then
    t0=$(now_float)
    codec=$(ffprobe -v error -rtsp_transport tcp -timeout 30000000 -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$RTSP" 2>/dev/null | head -1)
    say "cold wake: codec=${codec:-none} stream info after $(since "$t0")s"
else
    say "cold wake skipped: video_monitor was not idle"
fi

# An RTSP viewer on this Mac
ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$RTSP" -c copy -t $((DURATION + 120)) -f null - > "$WORK_DIR/profile_viewer.log" 2>&1 &
VIEWER=$!
wait_camera_status 60 "viewer=connected" && say "viewer connected" || say "WARN viewer did not connect"
run_profile watched
kill -0 "$VIEWER" 2>/dev/null && say "viewer still running at the end" || say "WARN viewer exited early"
kill "$VIEWER" 2>/dev/null
VIEWER=""
sleep 10

# Always mode, nobody watching
set_mode always
wait_camera_status 60 "video_monitor=running" && say "always mode capturing" || say "WARN always mode did not start video_monitor"
run_profile always

say "runs listed in $RUNS; compare with: python3 $TOOLS_DIR/compare_profiles.py $RUNS"
say "DONE"
