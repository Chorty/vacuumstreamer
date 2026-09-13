#!/bin/sh
# Boot-time startup for VacuumStreamer, called from /data/_root_postboot.sh.
#
# Honors the switches in vacuumstreamer.conf. The bind mounts and mixer
# settings always apply, so the AVA and audio environment stays the same
# whichever features are switched on.

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

[ -f "$VS_DIR/video_monitor" ] || exit 0

vs_http_bridge_loop() {
    while true; do
        tcpsvd -vE 0.0.0.0 6971 "$VS_DIR/tts_handler.sh" > /dev/null 2>&1
        sleep 2
    done
}

camera=$(vs_switch CAMERA on)
http_bridge=$(vs_switch HTTP_BRIDGE on)

vs_log "boot: CAMERA=$camera CAMERA_LOGIN=$(vs_switch CAMERA_LOGIN off) TTS=$(vs_switch TTS on) MAP_MANAGEMENT=$(vs_switch MAP_MANAGEMENT on) HTTP_BRIDGE=$http_bridge"

vs_run mount --bind "$VS_DIR/ava_conf_video_monitor" /ava/conf/video_monitor
vs_run mount --bind "$VS_DIR/mnt_private_copy" /mnt/private

# Enable microphone for audio capture
vs_run amixer cset numid=12 on > /dev/null 2>&1
vs_run amixer cset numid=13 on > /dev/null 2>&1
vs_run amixer cset numid=5 19 > /dev/null 2>&1
vs_run amixer cset numid=6 19 > /dev/null 2>&1
# Enable speaker output for two-way audio / TTS
vs_run amixer cset numid=16 on > /dev/null 2>&1      # LINEOUT switch on
vs_run amixer cset numid=15 on > /dev/null 2>&1      # HpSpeaker switch on
vs_run amixer cset numid=14 on > /dev/null 2>&1      # Headphone switch on

if [ "$camera" = "on" ]; then
    if problem=$("$VS_DIR/go2rtc_launch.sh" --check 2>&1); then
        vs_background "$VS_DIR/video_monitor_launch.sh"
        vs_background "$VS_DIR/go2rtc_launch.sh"
    else
        vs_log "camera not started: $problem"
    fi
fi

# TTS/HTTP bridge watchdog — respawns tcpsvd if it dies
if [ "$http_bridge" = "on" ]; then
    vs_background vs_http_bridge_loop
fi
