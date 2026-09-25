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
#   VALETUDO_AUTH_SERVICE  Mac keychain service holding the Valetudo Basic Auth
#                  login (default: valetudo-basic-auth; account = username).
#                  Without that entry the tools send no login. A deploy
#                  preflight verifies that unauthenticated requests work.

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

# Runtime scripts deploy_native.sh installs in /data/vacuumstreamer, in install
# order: the boot script last, after everything it starts. mic_gain_ctl.sh and
# recorder_quality_ctl.sh are called by the Valetudo plugin's
# MicrophoneGainCapability and RecorderQualityCapability; a script missing
# from this list is never installed, and the capability then fails with ENOENT.
NATIVE_SCRIPTS="vacuumstreamer_lib.sh go2rtc_launch.sh video_monitor_launch.sh camera_wake.sh camera_supervisor.sh camera_ctl.sh mic_gain_ctl.sh recorder_quality_ctl.sh http_bridge.sh tts_handler.sh https_proxy.sh https_cert_install.sh vacuumstreamer_boot.sh"

# native_deployed_paths - every robot file a native deployment may replace or
# edit. Each existing one is preserved as <path>.predeploy_<id> and restored by
# the reboot gate's rollback.
native_deployed_paths() {
    local f
    for f in $NATIVE_SCRIPTS go2rtc.yaml vacuumstreamer.conf https_proxy.Caddyfile; do
        echo "/data/vacuumstreamer/$f"
    done
    echo /data/_root_postboot.sh
}

VALETUDO_AUTH_SERVICE="${VALETUDO_AUTH_SERVICE:-valetudo-basic-auth}"

# valetudo_auth_config - print a curl config line carrying the Valetudo Basic
# Auth login from the Mac keychain, or nothing when none is stored. It is only
# ever fed to curl on stdin (curl -K -), so the login never appears in process
# arguments on the Mac or the robot.
valetudo_auth_config() {
    local details status user pass

    details=$(security find-generic-password -s "$VALETUDO_AUTH_SERVICE" 2>/dev/null)
    status=$?
    if [ "$status" -eq 44 ]; then
        return 0
    fi
    if [ "$status" -ne 0 ]; then
        echo "cannot read the Valetudo login from the keychain" >&2
        return 1
    fi
    user=$(printf '%s\n' "$details" | sed -n 's/^ *"acct"<blob>="\(.*\)"$/\1/p')
    if [ -z "$user" ]; then
        echo "the Valetudo keychain entry has no account" >&2
        return 1
    fi
    pass=$(security find-generic-password -s "$VALETUDO_AUTH_SERVICE" -w 2>/dev/null) || {
        echo "cannot read the Valetudo password from the keychain" >&2
        return 1
    }
    case "$user:$pass" in
        *[!A-Za-z0-9._~:-]* | :* | *:)
            echo "the Valetudo login in the keychain is empty or has unsupported characters" >&2
            return 1
            ;;
    esac
    printf 'user = "%s:%s"\n' "$user" "$pass"
}

# vcurl ARGS... - curl on the Mac, sending the Valetudo login if one is stored
vcurl() {
    local config
    config=$(valetudo_auth_config) || return 1
    printf '%s\n' "$config" | curl -K - "$@"
}

# Read the login once per deploy stage. An absent entry is acceptable only
# when Valetudo itself answers without a login. Call before any robot writes.
valetudo_auth_preflight() {
    local codes
    VS_AUTH_CONFIG=$(valetudo_auth_config) || return 1
    codes=$(printf '%s\n' "$VS_AUTH_CONFIG" | rsh "$REMOTE_VCURL"'; vcode / && printf "\n" && vcode /api/v2/robot') || return 1
    if [ "$codes" != "$(printf '200\n200')" ]; then
        echo "Valetudo authentication preflight failed (missing or invalid login, or unhealthy HTTP service)" >&2
        return 1
    fi
}

# Send the cached login without putting it in an argument or fetching the
# keychain again after reboot. The remote command is a fixed shell fragment.
remote_vcurl_cached() {
    printf '%s\n' "$VS_AUTH_CONFIG" | rsh "$REMOTE_VCURL""; $1"
}

vcurl_cached() {
    printf '%s\n' "$VS_AUTH_CONFIG" | curl -K - "$@"
}

# REMOTE_VCURL - prefix for a robot command whose stdin is
# valetudo_auth_config: it reads the login once into a shell variable, then
# "vcurl ARGS" runs curl with it (printf is a shell builtin, so the login is
# not in any process's arguments) and "vcode PATH" prints Valetudo's HTTP
# status for PATH. Use it with rsh, not rsh_n:
#   valetudo_auth_config | rsh "$REMOTE_VCURL"'; [ "$(vcode /)" = 200 ]'
REMOTE_VCURL='VS_AUTH=$(cat) || exit 1; vcurl() { printf "%s\n" "$VS_AUTH" | curl -K - -s -m 5 "$@"; }; vcode() { vcurl -o /dev/null -w "%{http_code}" "http://127.0.0.1$1"; }'

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
    local config response
    config=$(valetudo_auth_config) || return 1
    response=$(printf '%s\n' "$config" | rsh "$REMOTE_VCURL"'; vcurl http://127.0.0.1/api/v2/robot/state/attributes') || return 1
    printf '%s\n' "$response" | python3 "$TOOLS_DIR/docked_idle.py"
}

robot_docked_idle_cached() {
    local response
    response=$(remote_vcurl_cached 'vcurl http://127.0.0.1/api/v2/robot/state/attributes') || return 1
    printf '%s\n' "$response" | python3 "$TOOLS_DIR/docked_idle.py"
}

robot_uptime() {
    rsh_n 'cut -d. -f1 /proc/uptime'
}
