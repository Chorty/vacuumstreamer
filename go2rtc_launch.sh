#!/bin/sh
# Starts go2rtc for the VacuumStreamer camera.
#
# Usage: go2rtc_launch.sh [--check]
#   --check  Validate the switches and camera login, then exit.
#
# With CAMERA_LOGIN=on, go2rtc reads GO2RTC_USERNAME and GO2RTC_PASSWORD from
# the credentials directory through its CREDENTIALS_DIRECTORY support, so the
# secrets are never written into go2rtc.yaml, the environment or arguments.
#
# Exit codes: 64 usage, 75 camera switched off, 78 camera login misconfigured.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

GO2RTC_BIN="${GO2RTC_BIN:-$VS_DIR/go2rtc}"
GO2RTC_CONFIG="${GO2RTC_CONFIG:-$VS_DIR/go2rtc.yaml}"

fail() {
    vs_log "go2rtc not started: $1"
    echo "go2rtc_launch: $1" >&2
    exit "$2"
}

case "${1:-}" in
    "" | --check) ;;
    *)
        echo "usage: $0 [--check]" >&2
        exit 64
        ;;
esac

vs_enabled CAMERA on || fail "CAMERA=off in $VS_CONF" 75
problem=$(vs_camera_login_check) || fail "$problem" 78

[ "${1:-}" = "--check" ] && exit 0

unset GO2RTC_USERNAME GO2RTC_PASSWORD

if vs_enabled CAMERA_LOGIN off; then
    CREDENTIALS_DIRECTORY="$VS_CREDENTIALS_DIR"
    export CREDENTIALS_DIRECTORY
    vs_log "starting go2rtc with camera login"
else
    unset CREDENTIALS_DIRECTORY
    vs_log "starting go2rtc without camera login"
fi

# Valetudo deliberately runs at nice 10 (os.setPriority in Valetudo.js) so the
# API/GUI never competes with AVA's real-time control loop for CPU. go2rtc
# and video_monitor previously ran at the default nice 0, tied with AVA and
# ahead of Valetudo -- on this 4-core SoC, cleaning alone can push load past
# 14-20, and at that point scheduling order decides who gets the CPU. Video
# is best-effort; it should never outrank the API/GUI for it, so it matches
# Valetudo's own nice level instead of the default.
vs_exec_at_nice 10 "$GO2RTC_BIN" -c "$GO2RTC_CONFIG"
