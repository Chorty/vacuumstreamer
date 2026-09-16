#!/bin/bash
# Mac-only end-to-end test of this repository's camera scripts with a real
# go2rtc and ffmpeg standing in for video_monitor. Covers wake on first viewer,
# idle stop, crash and stall recovery, pause and resume, a single supervisor,
# and always mode. Robot commands (pidof, killall, netstat, flock, setsid) are
# emulated with shims. Takes about four minutes.
#
# Usage: GO2RTC_BIN=/path/to/go2rtc tools/integration_local.sh
set -u
. "$(dirname "$0")/lib.sh"

: "${GO2RTC_BIN:?set GO2RTC_BIN to a go2rtc binary for this Mac (for example built from the v1.9.9 tag)}"
[ -x "$GO2RTC_BIN" ] || fail "GO2RTC_BIN is not executable: $GO2RTC_BIN"
for c in ffmpeg ffprobe lsof pgrep pkill; do command -v "$c" >/dev/null || fail "$c is required"; done

T="$WORK_DIR/integration"
rm -rf "$T"; mkdir -p "$T/bin" "$T/run"
FAILS=0
result() { if [ "$2" = "$3" ]; then say "PASS $1"; else say "FAIL $1 (expected $2, got $3)"; FAILS=$((FAILS + 1)); fi; }

export VS_DIR="$T" VS_CONF="$T/vacuumstreamer.conf" VS_CREDENTIALS_DIR="$T/credentials" VS_LOG="$T/vacuumstreamer.log" VS_RUN_DIR="$T/run" VS_CAMERA_PORT=16969 VS_GO2RTC_API=http://127.0.0.1:11984 VS_PROC_NET_TCP="$T/no_proc_net_tcp"
for f in vacuumstreamer_lib.sh go2rtc_launch.sh video_monitor_launch.sh camera_wake.sh camera_supervisor.sh camera_ctl.sh; do
    cp "$NATIVE_REPO/$f" "$T/$f"; chmod 755 "$T/$f"
done
cp "$GO2RTC_BIN" "$T/go2rtc"
# go2rtc_launch.sh also reads GO2RTC_BIN; point it at the copy the shims recognize
export GO2RTC_BIN="$T/go2rtc"
cat > "$T/go2rtc.yaml" <<YAML
streams:
  vacuum:
    - echo:$T/camera_wake.sh
api:
  listen: "127.0.0.1:11984"
  username: "\${GO2RTC_USERNAME:}"
  password: "\${GO2RTC_PASSWORD:}"
rtsp:
  listen: "127.0.0.1:18554"
webrtc:
  listen: "127.0.0.1:18555"
YAML
cat > "$T/video_monitor" <<SH
#!/bin/sh
while true; do
    ffmpeg -hide_banner -loglevel error -re -f lavfi -i testsrc2=size=640x480:rate=15 -c:v libx264 -tune zerolatency -g 15 -bf 0 -f h264 "tcp://127.0.0.1:$VS_CAMERA_PORT?listen=1" < /dev/null
    sleep 0.2
done
SH
cat > "$T/bin/pidof" <<'SH'
#!/bin/sh
case "$1" in
    go2rtc) pgrep -f "$VS_DIR/go2rtc -c" > /dev/null ;;
    video_monitor) pgrep -f "$VS_DIR/video_monitor\$" > /dev/null ;;
    *) exit 1 ;;
esac
SH
cat > "$T/bin/killall" <<'SH'
#!/bin/sh
signal=""
case "$1" in -*) signal="$1"; shift ;; esac
case "$1" in
    go2rtc) pgrep -f "$VS_DIR/go2rtc -c" > /dev/null || exit 1; pkill $signal -f "$VS_DIR/go2rtc -c" ;;
    video_monitor)
        pgrep -f "$VS_DIR/video_monitor\$" > /dev/null || exit 1
        pkill $signal -f "$VS_DIR/video_monitor\$"
        pkill $signal -f "127.0.0.1:$VS_CAMERA_PORT.listen=1"
        # A stopped ffmpeg only receives the signal after it is continued
        pkill -CONT -f "127.0.0.1:$VS_CAMERA_PORT.listen=1"
        ;;
esac
exit 0
SH
cat > "$T/bin/netstat" <<'SH'
#!/bin/sh
case "$1" in
    -ltn) lsof -nP -iTCP:"$VS_CAMERA_PORT" -sTCP:LISTEN > /dev/null 2>&1 && echo "tcp 0 0 0.0.0.0:$VS_CAMERA_PORT 0.0.0.0:* LISTEN" ;;
    -tn) lsof -nP -a -c ffmpeg -iTCP:"$VS_CAMERA_PORT" -sTCP:ESTABLISHED > /dev/null 2>&1 && echo "tcp 0 0 127.0.0.1:$VS_CAMERA_PORT 127.0.0.1:1 ESTABLISHED" ;;
esac
exit 0
SH
# macOS has no flock: emulate the supervisor's single-instance lock; the wake lock always succeeds
cat > "$T/bin/flock" <<'SH'
#!/bin/sh
if [ "$1" = "-n" ] && [ "${2:-}" = 8 ]; then
    others=$(pgrep -f "$VS_DIR/camera_supervisor.sh" | grep -v "^$PPID\$" | wc -l)
    [ "$others" -eq 0 ]
    exit $?
fi
exit 0
SH
printf '#!/bin/sh\nexec "$@"\n' > "$T/bin/setsid"
chmod 755 "$T/video_monitor" "$T/bin/"*
export PATH="$T/bin:$PATH"
printf 'CAMERA_MODE=on_demand\nCAMERA_IDLE_SECONDS=30\nCAMERA_STALL_SECONDS=10\nCAMERA_SUPERVISE_SECONDS=1\nCAMERA_WAKE_TIMEOUT_SECONDS=15\n' > "$VS_CONF"

cleanup() {
    pkill -f "$T/camera_supervisor.sh"; pkill -f "$T/go2rtc.yaml"; pkill -f "$T/video_monitor"
    pkill -CONT -f "127.0.0.1:$VS_CAMERA_PORT.listen=1"; pkill -f "127.0.0.1:$VS_CAMERA_PORT.listen=1"; pkill -f "rtsp://127.0.0.1:18554/vacuum"
}
trap cleanup EXIT
yesno() { if "$@"; then echo yes; else echo no; fi; }
wait_until() { local end=$(($(date +%s) + $1)); shift; while [ "$(date +%s)" -lt "$end" ]; do "$@" && return 0; sleep 0.5; done; return 1; }
api_up() { curl -s -o /dev/null -m 1 "$VS_GO2RTC_API/api"; }
vm_running() { pidof video_monitor; }
vm_stopped() { ! pidof video_monitor; }
connected() { netstat -tn | grep -q ESTABLISHED; }
probe() { ffprobe -v error -rtsp_transport tcp -timeout 25000000 -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 rtsp://127.0.0.1:18554/vacuum 2>/dev/null | head -1; }
viewer() { ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i rtsp://127.0.0.1:18554/vacuum -t "$1" -f null - > /dev/null 2>&1 & VIEWER=$!; }

say "--- supervisor start (on_demand) ---"
"$T/camera_supervisor.sh" > /dev/null 2>&1 &
result "supervisor starts go2rtc" yes "$(yesno wait_until 15 api_up)"
sleep 3
result "on_demand: no capture before a viewer" no "$(yesno vm_running)"

say "--- first viewer wakes the camera ---"
t0=$(now_float); CODEC=$(probe)
result "first viewer receives H.264" h264 "$CODEC"
say "first-viewer latency $(since "$t0")s"
result "viewer woke video_monitor" yes "$(yesno vm_running)"

say "--- idle stop ---"
result "video_monitor stops after 30 s without a viewer" yes "$(yesno wait_until 50 vm_stopped)"

say "--- crash while watching ---"
viewer 90
result "long viewer connects" yes "$(yesno wait_until 25 connected)"
killall video_monitor
sleep 1
result "go2rtc re-wakes video_monitor after a crash" yes "$(yesno wait_until 30 connected)"

say "--- stall while watching ---"
kill -0 "$VIEWER" 2>/dev/null || viewer 90
wait_until 20 connected
pkill -STOP -f "127.0.0.1:$VS_CAMERA_PORT.listen=1"
result "stall is detected and video_monitor restarted" yes "$(yesno wait_until 40 grep -q 'no video for 10s' "$VS_LOG")"
kill -0 "$VIEWER" 2>/dev/null || viewer 60
result "video recovers after the stall" yes "$(yesno wait_until 30 connected)"
kill "$VIEWER" 2>/dev/null

say "--- pause and resume ---"
"$T/camera_ctl.sh" stop; result "camera_ctl stop succeeds" 0 "$?"
sleep 4
result "paused: go2rtc stays stopped" no "$(yesno pidof go2rtc)"
result "paused: video_monitor stays stopped" no "$(yesno vm_running)"
"$T/camera_ctl.sh" start; result "camera_ctl start succeeds" 0 "$?"
result "resumed: go2rtc runs" yes "$(yesno wait_until 10 pidof go2rtc)"
result "resumed: a viewer receives H.264" h264 "$(probe)"
result "a single supervisor runs" 1 "$(pgrep -f "$T/camera_supervisor.sh" | wc -l | tr -d ' ')"

say "--- always mode ---"
sed -i '' 's/^CAMERA_MODE=.*/CAMERA_MODE=always/' "$VS_CONF"
killall video_monitor
result "always: supervisor restarts video_monitor" yes "$(yesno wait_until 20 vm_running)"
sleep 35
result "always: video_monitor is not idled" yes "$(yesno vm_running)"

[ "$FAILS" -eq 0 ] || fail "$FAILS integration checks failed"
say "DONE all integration checks passed"
