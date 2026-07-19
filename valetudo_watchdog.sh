#!/bin/sh
# Valetudo watchdog - restarts valetudo if it exits
while true; do
    VALETUDO_CONFIG_PATH=/data/valetudo_config.json /data/valetudo
    echo "$(date) Valetudo exited, restarting in 5s..." >> /tmp/valetudo_watchdog.log
    sleep 5
done
