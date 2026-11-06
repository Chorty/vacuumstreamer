#!/bin/bash
# Make SSH key-only, with the firmware's own switch: /etc/rc.d/dropbear.sh starts
# dropbear -s at boot when /mnt/misc/ssh_disable_passwords exists. It takes effect
# at the next reboot. To undo it before then, remove that file.
#
# A failed key after that reboot would lock out SSH, so this first logs in with
# the key through a temporary key-only server on the robot's loopback. It doesn't
# touch the running server.
#
# Usage: tools/ssh_keys_only.sh
set -u
. "$(dirname "$0")/lib.sh"

SWITCH=/mnt/misc/ssh_disable_passwords
PID_FILE=/tmp/vs_ssh_check.pid
ROBOT_PORT=2222
LOCAL_PORT=18222
TUNNEL=""

stop_check() {
    [ -n "$TUNNEL" ] && kill "$TUNNEL" 2>/dev/null
    rsh_n "[ -f '$PID_FILE' ] && kill \"\$(cat '$PID_FILE')\"; rm -f '$PID_FILE'" > /dev/null 2>&1
}
trap stop_check EXIT

rsh_n "[ -s /mnt/misc/authorized_keys ]" || fail "the robot's authorized_keys is missing or empty; nothing changed"
rsh_n "dropbear -s -p 127.0.0.1:$ROBOT_PORT -P '$PID_FILE'" || fail "could not start the temporary server; nothing changed"

ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -L "127.0.0.1:$LOCAL_PORT:127.0.0.1:$ROBOT_PORT" "$VACUUM_SSH" &
TUNNEL=$!

# Known hosts lists the robot by its real address, not the tunnel's.
ROBOT_HOST=$(ssh -G "$VACUUM_SSH" | awk '$1 == "hostname" { print $2 }')
KEY_OK=no
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ssh -n -o BatchMode=yes -o PreferredAuthentications=publickey -o HostName=127.0.0.1 -o "Port=$LOCAL_PORT" \
        -o "HostKeyAlias=$ROBOT_HOST" "$VACUUM_SSH" true 2>/dev/null; then
        KEY_OK=yes
        break
    fi
    sleep 1
done
[ "$KEY_OK" = yes ] || fail "this key could not log in to a key-only server; nothing changed"
say "this key logged in to a temporary key-only server"

rsh_n "touch '$SWITCH' && sync" || fail "could not set $SWITCH"
say "DONE SSH becomes key-only at the next reboot; to undo it first, remove $SWITCH"
