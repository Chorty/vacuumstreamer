#!/bin/bash
# Functional camera checks on the robot with an RTSP viewer on this Mac:
# idle stop, cold wake latency, pause and resume through the Valetudo API,
# recovery from a video_monitor crash, and recovery from a frozen video_monitor.
# Leaves the camera resumed. Never moves the robot.
#
# Usage: tools/camera_checks.sh
set -u
. "$(dirname "$0")/lib.sh"

API="http://$VACUUM_IP/api/v2/robot/capabilities/VideoStreamCapability"
RTSP="rtsp://$VACUUM_IP:8554/vacuum"
FAILED=0
VIEWER=""
FROZEN=""

pass() { say "PASS $*"; }
bad() { say "FAIL $*"; FAILED=$((FAILED + 1)); }

cleanup() {
    [ -n "$VIEWER" ] && kill "$VIEWER" 2>/dev/null
    [ -n "$FROZEN" ] && rsh_n "kill -CONT $FROZEN 2>/dev/null; [ -d /proc/$FROZEN ] && kill -KILL $FROZEN 2>/dev/null"
}
trap cleanup EXIT

probe() {
    ffprobe -v error -rtsp_transport tcp -timeout "${1:-30000000}" -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$RTSP" 2>/dev/null | head -1
}

start_viewer() {
    ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$RTSP" -c copy -t 150 -f null - > "$WORK_DIR/camera_checks_viewer.log" 2>&1 &
    VIEWER=$!
    wait_camera_status 40 "viewer=connected"
}

# recovered_from OLD_PID SECONDS - print the new video_monitor PID once a viewer is reconnected
recovered_from() {
    local end=$(($(date +%s) + $2)) new
    while [ "$(date +%s)" -lt "$end" ]; do
        new=$(rsh_n 'pidof video_monitor' 2>/dev/null)
        if [ -n "$new" ] && [ "$new" != "$1" ] && camera_status | grep -q "viewer=connected"; then
            echo "$new"
            return 0
        fi
        sleep 2
    done
    return 1
}

say "supervisors: $(rsh_n 'ps w | grep -c "[c]amera_supervisor[.]sh"'); camera: $(camera_status)"

say "--- idle stop ---"
if wait_camera_status 300 "video_monitor=stopped"; then pass "video_monitor idle"; else bad "video_monitor still running after 300 s"; fi

say "--- cold wake ---"
t0=$(now_float); codec=$(probe)
[ "$codec" = h264 ] && pass "cold wake: H.264 stream info after $(since "$t0")s" || bad "cold wake returned ${codec:-nothing}"

say "--- pause and resume through Valetudo ---"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 40 -X PUT -H 'Content-Type: application/json' -d '{"action":"stop"}' "$API")
[ "$code" = 200 ] && pass "pause returned 200" || bad "pause returned $code"
sleep 6
camera_status | grep -q "paused=yes" && pass "camera paused: $(camera_status)" || bad "camera not paused: $(camera_status)"
[ -z "$(probe 8000000)" ] && pass "RTSP refused while paused" || bad "RTSP served while paused"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 40 -X PUT -H 'Content-Type: application/json' -d '{"action":"start"}' "$API")
[ "$code" = 200 ] && pass "resume returned 200" || bad "resume returned $code"
[ "$(probe)" = h264 ] && pass "RTSP serves H.264 after resume" || bad "RTSP did not serve H.264 after resume"

say "--- crash while watched ---"
start_viewer || bad "viewer did not connect"
sleep 5
old=$(rsh_n 'pidof video_monitor'); t0=$(now_float)
rsh_n 'killall video_monitor'
if new=$(recovered_from "$old" 60); then pass "crash: new video_monitor $new, viewer reconnected after $(since "$t0")s"; else bad "crash: no recovery within 60 s"; fi
sleep 8

say "--- stall while watched ---"
kill -0 "$VIEWER" 2>/dev/null || start_viewer
old=$(rsh_n 'pidof video_monitor'); t0=$(now_float)
FROZEN="$old"
rsh_n "kill -STOP $old"
if new=$(recovered_from "$old" 75); then pass "stall: new video_monitor $new, viewer reconnected after $(since "$t0")s"; else bad "stall: no recovery within 75 s"; fi
rsh_n "[ -d /proc/$old ]" && bad "frozen video_monitor $old still present" || FROZEN=""
say "log: $(rsh_n 'grep -E "no video for|did not exit|camera wake: starting" /tmp/vacuumstreamer.log | tail -4' | tr '\n' '|')"
kill -0 "$VIEWER" 2>/dev/null && pass "viewer survived crash and stall" || say "INFO viewer exited"

say "supervisors: $(rsh_n 'ps w | grep -c "[c]amera_supervisor[.]sh"'); camera: $(camera_status)"
[ "$FAILED" -eq 0 ] || fail "$FAILED camera checks failed"
say "DONE all camera checks passed"
