#!/bin/sh

# Interestingly, the iw command does not always have the same effect as these module parameters
# It is expected that some of these will fail as the robot has only one of those modules
echo 0 > /sys/module/8189fs/parameters/rtw_power_mgnt
echo 0 > /sys/module/8188fu/parameters/rtw_power_mgnt
echo 0 > /sys/module/8723ds/parameters/rtw_power_mgnt

iw dev wlan0 set power_save off

if [[ -f /data/config/ava/iot.flag ]] && grep -q "dmiot" /data/config/ava/iot.flag; then
        rm /data/config/ava/iot.flag
fi

if [ ! "$(readlink /data/config/system/localtime)" -ef "/usr/share/zoneinfo/UTC" ]; then
        rm /data/config/system/localtime
        ln -s /usr/share/zoneinfo/UTC /data/config/system/localtime
fi

if [[ -f /data/valetudo ]]; then
        /data/valetudo_watchdog.sh > /dev/null 2>&1 &
        VALETUDO_CONFIG_PATH=/data/valetudo_config.json /data/maploader-binary > /dev/null 2>&1 &
fi

if [[ -f /data/vacuumstreamer/video_monitor ]]; then
    mount --bind /data/vacuumstreamer/ava_conf_video_monitor /ava/conf/video_monitor
    mount --bind /data/vacuumstreamer/mnt_private_copy /mnt/private

    # Enable microphone for audio capture
    amixer cset numid=12 on > /dev/null 2>&1
    amixer cset numid=13 on > /dev/null 2>&1
    amixer cset numid=5 19 > /dev/null 2>&1
    amixer cset numid=6 19 > /dev/null 2>&1

    # Enable speaker output for two-way audio / TTS
    amixer cset numid=16 on > /dev/null 2>&1      # LINEOUT switch on
    amixer cset numid=15 on > /dev/null 2>&1      # HpSpeaker switch on
    amixer cset numid=14 on > /dev/null 2>&1      # Headphone switch on

    LD_PRELOAD=/data/vacuumstreamer/vacuumstreamer.so /data/vacuumstreamer/video_monitor > /dev/null 2>&1 &
    /data/vacuumstreamer/go2rtc -c /data/vacuumstreamer/go2rtc.yaml > /dev/null 2>&1 &

    # TTS/HTTP bridge watchdog — respawns tcpsvd if it dies
    ( while true; do
        tcpsvd -vE 0.0.0.0 6971 /data/vacuumstreamer/tts_handler.sh > /dev/null 2>&1
        sleep 2
    done ) &
fi
