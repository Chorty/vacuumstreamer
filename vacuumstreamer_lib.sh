#!/bin/sh
# Shared helpers for the VacuumStreamer runtime scripts. Source this file; do
# not run it.
#
# Switches live in vacuumstreamer.conf as KEY=value lines. The file is parsed,
# never sourced, so its contents cannot run commands. A missing file, missing
# key, empty value or invalid value falls back to the caller's default.

VS_DIR="${VS_DIR:-/data/vacuumstreamer}"
VS_CONF="${VS_CONF:-$VS_DIR/vacuumstreamer.conf}"
VS_CREDENTIALS_DIR="${VS_CREDENTIALS_DIR:-$VS_DIR/credentials}"
VS_LOG="${VS_LOG:-/tmp/vacuumstreamer.log}"
VS_RUN_DIR="${VS_RUN_DIR:-/tmp/vacuumstreamer}"
VS_CAMERA_PORT="${VS_CAMERA_PORT:-6969}"
VS_GO2RTC_API="${VS_GO2RTC_API:-http://127.0.0.1:1984}"
VS_UPTIME_FILE="${VS_UPTIME_FILE:-/proc/uptime}"

vs_log() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" >> "$VS_LOG" 2>/dev/null
}

# vs_conf_get KEY DEFAULT - print the last value set for KEY, or DEFAULT.
vs_conf_get() {
    local key="$1" default="$2" value=""

    case "$key" in
        "" | *[!A-Z0-9_]*)
            echo "$default"
            return 1
            ;;
    esac

    if [ -r "$VS_CONF" ]; then
        value=$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\([^#]*\).*/\1/p" "$VS_CONF" | tail -n 1 | sed 's/[[:space:]]*$//')
    fi

    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# vs_switch KEY DEFAULT - print "on" or "off".
vs_switch() {
    local key="$1" default="$2" value

    value=$(vs_conf_get "$key" "$default")

    case "$value" in
        on | off)
            echo "$value"
            ;;
        *)
            vs_log "invalid value for $key in $VS_CONF; using $default"
            echo "$default"
            ;;
    esac
}

# vs_enabled KEY DEFAULT - succeed when the switch is on.
vs_enabled() {
    [ "$(vs_switch "$1" "$2")" = "on" ]
}

# vs_number KEY DEFAULT MIN MAX - print an integer setting between MIN and MAX.
vs_number() {
    local key="$1" default="$2" min="$3" max="$4" value

    value=$(vs_conf_get "$key" "$default")

    case "$value" in
        "" | *[!0-9]*) ;;
        *)
            if [ "${#value}" -le 6 ] && [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
                echo "$value"
                return 0
            fi
            ;;
    esac

    vs_log "invalid value for $key in $VS_CONF; using $default"
    echo "$default"
}

# vs_camera_mode - print "on_demand" or "always".
vs_camera_mode() {
    local value

    value=$(vs_conf_get CAMERA_MODE on_demand)

    case "$value" in
        on_demand | always)
            echo "$value"
            ;;
        *)
            vs_log "invalid value for CAMERA_MODE in $VS_CONF; using on_demand"
            echo "on_demand"
            ;;
    esac
}

# vs_private_path PATH - succeed when PATH is not a symlink and grants no
# permissions to group or others.
vs_private_path() {
    local mode

    [ -L "$1" ] && return 1
    mode=$(ls -ld "$1" 2>/dev/null | cut -c5-10)
    [ "$mode" = "------" ]
}

vs_read_credential() {
    tr -d '\r\n' < "$VS_CREDENTIALS_DIR/$1" 2>/dev/null
}

# vs_camera_login_check - when CAMERA_LOGIN is on, print the first problem with
# the credentials and fail. Credential values are never printed.
vs_camera_login_check() {
    local name value

    vs_enabled CAMERA_LOGIN off || return 0

    if [ ! -d "$VS_CREDENTIALS_DIR" ] || ! vs_private_path "$VS_CREDENTIALS_DIR"; then
        echo "CAMERA_LOGIN=on requires the directory $VS_CREDENTIALS_DIR with no group or other access (chmod 700)"
        return 1
    fi

    for name in GO2RTC_USERNAME GO2RTC_PASSWORD; do
        if [ ! -f "$VS_CREDENTIALS_DIR/$name" ] || ! vs_private_path "$VS_CREDENTIALS_DIR/$name"; then
            echo "CAMERA_LOGIN=on requires the file $VS_CREDENTIALS_DIR/$name with no group or other access (chmod 600)"
            return 1
        fi

        value=$(vs_read_credential "$name")

        case "$value" in
            "" | *[!A-Za-z0-9._~-]*)
                echo "$name must be non-empty and contain only letters, digits, '.', '_', '~' or '-'"
                return 1
                ;;
        esac
    done

    value=$(vs_read_credential GO2RTC_PASSWORD)

    if [ "${#value}" -lt 16 ]; then
        echo "GO2RTC_PASSWORD must be at least 16 characters"
        return 1
    fi
}

# vs_now - print seconds since boot, which keeps increasing when the robot syncs
# its clock after boot. Runtime state lives in tmpfs, so it never outlives a
# boot. Falls back to wall-clock seconds without /proc/uptime. VS_FAKE_NOW
# overrides it (tests only).
vs_now() {
    local uptime

    if [ -n "${VS_FAKE_NOW:-}" ]; then
        echo "$VS_FAKE_NOW"
    elif [ -r "$VS_UPTIME_FILE" ]; then
        read -r uptime _ < "$VS_UPTIME_FILE"
        echo "${uptime%%.*}"
    else
        date +%s
    fi
}

vs_running() {
    pidof "$1" > /dev/null 2>&1
}

# vs_stop NAME - ask NAME to exit, and kill it when it is still running after
# VS_STOP_GRACE_SECONDS (default 3), for example because it is hung.
vs_stop() {
    local waited=0 grace="${VS_STOP_GRACE_SECONDS:-3}"

    killall "$1" > /dev/null 2>&1 || return 0

    while vs_running "$1" && [ "$waited" -lt $((grace * 5)) ]; do
        sleep 0.2
        waited=$((waited + 1))
    done

    if vs_running "$1"; then
        vs_log "$1 did not exit within ${grace}s; killing it"
        killall -KILL "$1" > /dev/null 2>&1
    fi

    return 0
}

# vs_port_listening PORT - succeed when something listens on TCP PORT.
vs_port_listening() {
    netstat -ltn 2>/dev/null | awk -v port=":$1" '$4 ~ port "$" && $6 == "LISTEN" { found = 1 } END { exit !found }'
}

# vs_port_connected PORT - succeed when a client is connected to a local
# listener on TCP PORT.
vs_port_connected() {
    netstat -tn 2>/dev/null | awk -v port=":$1" '$4 ~ port "$" && $6 == "ESTABLISHED" { found = 1 } END { exit !found }'
}

# vs_camera_paused - succeed while camera_ctl.sh has paused the camera.
vs_camera_paused() {
    [ -e "$VS_RUN_DIR/camera_paused" ]
}

# vs_camera_bytes - print how many bytes go2rtc has received from the camera's
# video source, or nothing while it is not connected. go2rtc pretty-prints the
# stream with the video source as its first producer.
vs_camera_bytes() {
    curl -s -m 3 "$VS_GO2RTC_API/api/streams?src=vacuum" 2>/dev/null | awk '
        /^  "producers": [[][]]/ { exit }
        /^  "producers": [[]/ { in_producers = 1; next }
        in_producers && (/^  []]/ || /^  "consumers"/) { exit }
        in_producers && /^    [{]/ { producer++ }
        in_producers && producer == 1 && /^      "bytes_recv": [0-9]+/ {
            gsub(/[^0-9]/, "")
            print
            exit
        }
    '
}

# vs_state_get NAME DEFAULT - print a numeric runtime state value.
vs_state_get() {
    local value=""

    [ -r "$VS_RUN_DIR/$1" ] && value=$(cat "$VS_RUN_DIR/$1" 2>/dev/null)

    case "$value" in
        "" | *[!0-9]*) echo "$2" ;;
        *) echo "$value" ;;
    esac
}

# vs_state_set NAME VALUE - store a runtime state value.
vs_state_set() {
    mkdir -p "$VS_RUN_DIR" && echo "$2" > "$VS_RUN_DIR/$1"
}

# vs_backoff FAILURES - print seconds to wait before the next start attempt.
vs_backoff() {
    case "$1" in
        0 | 1) echo 5 ;;
        2) echo 10 ;;
        3) echo 30 ;;
        *) echo 60 ;;
    esac
}

# vs_run COMMAND... - run a command. With VS_DRY_RUN set to a file path (tests
# only), record the command there instead.
vs_run() {
    if [ -n "${VS_DRY_RUN:-}" ]; then
        echo "run: $*" >> "$VS_DRY_RUN"
        return 0
    fi

    "$@"
}

# vs_background COMMAND... - start a command in the background, discarding its
# output. Honors VS_DRY_RUN like vs_run.
vs_background() {
    if [ -n "${VS_DRY_RUN:-}" ]; then
        echo "background: $*" >> "$VS_DRY_RUN"
        return 0
    fi

    "$@" > /dev/null 2>&1 &
}

# vs_start_detached COMMAND... - start a command in its own session with no
# inherited output or lock descriptors, so it outlives the caller and never
# holds the caller's pipe or locks open.
vs_start_detached() {
    setsid "$@" < /dev/null > /dev/null 2>&1 8>&- 9>&- &
}

# vs_keep_running NAME LAUNCHER NOW - start NAME through LAUNCHER when it is not
# running. Starts that do not last a minute back off progressively.
vs_keep_running() {
    local name="$1" launcher="$2" now="$3" failures problem

    if vs_running "$name"; then
        if [ $((now - $(vs_state_get "${name}_started_at" 0))) -ge 60 ]; then
            vs_state_set "${name}_failures" 0
        fi

        return 0
    fi

    [ "$now" -ge "$(vs_state_get "${name}_next_try" 0)" ] || return 0

    if ! problem=$("$launcher" --check 2>&1); then
        vs_log "supervisor: $name not started: $problem"
        vs_state_set "${name}_next_try" $((now + 60))
        return 0
    fi

    failures=$(($(vs_state_get "${name}_failures" 0) + 1))
    vs_log "supervisor: starting $name (attempt $failures)"
    vs_start_detached "$launcher"
    vs_state_set "${name}_failures" "$failures"
    vs_state_set "${name}_started_at" "$now"
    vs_state_set "${name}_next_try" $((now + $(vs_backoff "$failures")))
}
