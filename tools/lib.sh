#!/bin/bash
# Shared settings and helpers for the VacuumStreamer maintenance tools.
# Source this file from a tool; do not run it.
#
# Settings (environment variables):
#   VACUUM_SSH     SSH host alias for the robot (default: vacuum)
#   VACUUM_IP      robot LAN address (default: 192.168.1.31)
#   VALETUDO_REPO  Valetudo fork checkout (default: ~/Documents/GitHub/Valetudo)
#   BACKUP_ROOT    backup packages (default: ~/Documents/ValetudoBackups)
#   PROFILE_ROOT   profiler output (default: ~/Documents/ValetudoProfiles)
#   WORK_DIR       logs, markers and build clones (default: ~/.cache/vacuumstreamer-tools)

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_REPO="$(cd "$TOOLS_DIR/.." && pwd)"
VACUUM_SSH="${VACUUM_SSH:-vacuum}"
VACUUM_IP="${VACUUM_IP:-192.168.1.31}"
VALETUDO_REPO="${VALETUDO_REPO:-$HOME/Documents/GitHub/Valetudo}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Documents/ValetudoBackups}"
PROFILE_ROOT="${PROFILE_ROOT:-$HOME/Documents/ValetudoProfiles}"
WORK_DIR="${WORK_DIR:-$HOME/.cache/vacuumstreamer-tools}"
mkdir -p "$WORK_DIR"
TOOL_LOG="$WORK_DIR/$(basename "$0" .sh).log"

say() {
    echo "$(date +%T) $*" | tee -a "$TOOL_LOG"
}

fail() {
    say "ABORT $*"
    exit 1
}

# rsh COMMAND - run a command on the robot; stdin passes through (for uploads)
rsh() {
    ssh -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 "$VACUUM_SSH" "$@"
}

# rsh_n COMMAND - run a command on the robot without reading stdin. Use it
# inside `while read` loops, where plain ssh would swallow the loop's input.
rsh_n() {
    ssh -n -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=15 "$VACUUM_SSH" "$@"
}

# check_id VALUE - refuse values that are unsafe inside remote commands
check_id() {
    case "$1" in
        "" | *[!A-Za-z0-9._-]*) fail "invalid identifier: '$1'" ;;
    esac
}

sha256() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

remote_sha256() {
    rsh_n "sha256sum '$1'" | cut -d' ' -f1
}

now_float() {
    python3 -c 'import time; print(time.time())'
}

# since START - seconds elapsed since a now_float value
since() {
    python3 -c "import time; print(round(time.time() - $1, 2))"
}

camera_status() {
    rsh_n '/data/vacuumstreamer/camera_ctl.sh status' 2>/dev/null | tr '\n' ' '
}

# wait_camera_status SECONDS PATTERN - wait until camera_ctl.sh status matches
wait_camera_status() {
    local end=$(($(date +%s) + $1))

    while [ "$(date +%s)" -lt "$end" ]; do
        camera_status | grep -q "$2" && return 0
        sleep 2
    done

    return 1
}

robot_docked_idle() {
    rsh_n 'curl -s -m 5 http://127.0.0.1/api/v2/robot/state/attributes' | python3 "$TOOLS_DIR/docked_idle.py"
}

robot_uptime() {
    rsh_n 'cut -d. -f1 /proc/uptime'
}
