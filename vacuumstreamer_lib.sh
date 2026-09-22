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
VS_PROC_NET_TCP="${VS_PROC_NET_TCP:-/proc/net/tcp}"

# Space, tab and carriage return, for trimming with shell builtins
VS_BLANKS=" $(printf '\t\r')"

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

# --- Builtin helpers for the long-running supervisor -------------------------
# The supervisor checks the camera every few seconds. These helpers use shell
# builtins and return results in variables such as VS_VAL, so a check starts as
# few processes as possible.

# vs_trim VALUE - set VS_VAL to VALUE without surrounding spaces, tabs or CRs.
vs_trim() {
    VS_VAL="$1"
    VS_VAL="${VS_VAL#"${VS_VAL%%[!$VS_BLANKS]*}"}"
    VS_VAL="${VS_VAL%"${VS_VAL##*[!$VS_BLANKS]}"}"
}

# vs_strip_leading_zeros DIGITS - print DIGITS with any leading zeros removed
# (down to a single "0" for an all-zero input), for a value about to be used
# in shell arithmetic. Plain "$((...))" reads a leading-zero numeral such as
# "017" as octal, and the "10#" radix prefix some shells accept to force
# decimal is not supported by dash/BusyBox ash's arithmetic.
vs_strip_leading_zeros() {
    local value="$1"

    while [ "${#value}" -gt 1 ]; do
        case "$value" in
            0*) value="${value#0}" ;;
            *) break ;;
        esac
    done

    echo "$value"
}

# vs_conf_load - read VS_CONF into VS_C_<KEY> variables, following the same
# rules as vs_conf_get: "#" starts a comment, whitespace around keys and values
# is ignored, and the last occurrence of a key wins. Values are never executed.
vs_conf_load() {
    local line key value

    for key in $VS_C_KEYS; do
        unset "VS_C_$key"
    done
    VS_C_KEYS=""

    [ -r "$VS_CONF" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"

        case "$line" in
            *=*) ;;
            *) continue ;;
        esac

        vs_trim "${line%%=*}"
        key="$VS_VAL"

        case "$key" in
            "" | *[!A-Z0-9_]*) continue ;;
        esac

        vs_trim "${line#*=}"
        value="$VS_VAL"
        eval "VS_C_$key=\$value"
        VS_C_KEYS="$VS_C_KEYS $key"
    done < "$VS_CONF"
}

# vs_conf_value KEY DEFAULT - set VS_VAL to KEY from vs_conf_load, or DEFAULT.
vs_conf_value() {
    eval "VS_VAL=\${VS_C_$1:-}"
    [ -n "$VS_VAL" ] || VS_VAL="$2"
}

# vs_warn_once KEY VALUE DEFAULT - log an invalid setting once per distinct value.
vs_warn_once() {
    local seen

    eval "seen=\${VS_WARNED_$1:-}"
    [ "$seen" = "$2" ] && return 0
    eval "VS_WARNED_$1=\$2"
    vs_log "invalid value for $1 in $VS_CONF; using $3"
}

# vs_setting_switch KEY DEFAULT - set VS_VAL to "on" or "off".
vs_setting_switch() {
    vs_conf_value "$1" "$2"

    case "$VS_VAL" in
        on | off) ;;
        *)
            vs_warn_once "$1" "$VS_VAL" "$2"
            VS_VAL="$2"
            ;;
    esac
}

# vs_setting_number KEY DEFAULT MIN MAX - set VS_VAL to an integer in range.
vs_setting_number() {
    vs_conf_value "$1" "$2"

    case "$VS_VAL" in
        "" | *[!0-9]*) ;;
        *)
            if [ "${#VS_VAL}" -le 6 ] && [ "$VS_VAL" -ge "$3" ] && [ "$VS_VAL" -le "$4" ]; then
                return 0
            fi
            ;;
    esac

    vs_warn_once "$1" "$VS_VAL" "$2"
    VS_VAL="$2"
}

# vs_setting_camera_mode - set VS_VAL to "on_demand" or "always".
vs_setting_camera_mode() {
    vs_conf_value CAMERA_MODE on_demand

    case "$VS_VAL" in
        on_demand | always) ;;
        *)
            vs_warn_once CAMERA_MODE "$VS_VAL" on_demand
            VS_VAL="on_demand"
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

# vs_now_var - set VS_NOW to seconds since boot, which keeps increasing when the
# robot syncs its clock after boot. Runtime state lives in tmpfs, so it never
# outlives a boot. Falls back to wall-clock seconds without /proc/uptime.
# VS_FAKE_NOW overrides it (tests only).
vs_now_var() {
    if [ -n "${VS_FAKE_NOW:-}" ]; then
        VS_NOW="$VS_FAKE_NOW"
    elif [ -r "$VS_UPTIME_FILE" ]; then
        read -r VS_NOW _ < "$VS_UPTIME_FILE"
        VS_NOW="${VS_NOW%%.*}"
    else
        VS_NOW=$(date +%s)
    fi
}

# vs_now - print the time from vs_now_var.
vs_now() {
    vs_now_var
    echo "$VS_NOW"
}

vs_running() {
    pidof "$1" > /dev/null 2>&1
}

# vs_nice_get - print this process's current niceness, portably: /proc on
# the robot, `ps` as a fallback where /proc/self/stat is unavailable (used by
# the Mac-side test suite).
vs_nice_get() {
    if [ -r /proc/self/stat ]; then
        awk '{print $19}' /proc/self/stat
    else
        ps -o nice= -p $$ | tr -d "$VS_BLANKS"
    fi
}

# vs_exec_at_nice TARGET CMD [ARGS...] - exec CMD at absolute niceness
# TARGET, regardless of the caller's own current niceness. `nice -n ADJUST`
# applies ADJUST relative to the caller, so a fixed adjustment lands
# differently depending on what already niced this process -- for example
# go2rtc, itself niced, spawning camera_wake.sh, which spawns
# video_monitor_launch.sh. This computes the adjustment needed to reach
# TARGET regardless of that chain.
vs_exec_at_nice() {
    local target="$1" current delta
    shift
    current=$(vs_nice_get) || current=0
    delta=$((target - current))

    if [ "$delta" -eq 0 ]; then
        exec "$@"
    else
        exec nice -n "$delta" "$@"
    fi
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

# vs_tcp_port_state PORT - set VS_PORT_LISTENING and VS_PORT_CONNECTED to "yes"
# or "no" for a local TCP port. Reads /proc/net/tcp and /proc/net/tcp6 with
# builtins, and falls back to netstat where /proc/net/tcp is not available.
vs_tcp_port_state() {
    local hex idx local_address remote state rest table

    VS_PORT_LISTENING=no
    VS_PORT_CONNECTED=no

    if [ -r "$VS_PROC_NET_TCP" ]; then
        eval "hex=\${VS_PORT_HEX_$1:-}"

        if [ -z "$hex" ]; then
            hex=$(printf '%04X' "$1")
            eval "VS_PORT_HEX_$1=\$hex"
        fi

        for table in "$VS_PROC_NET_TCP" "${VS_PROC_NET_TCP}6"; do
            [ -r "$table" ] || continue

            while read -r idx local_address remote state rest; do
                [ "${local_address##*:}" = "$hex" ] || continue

                case "$state" in
                    0A) VS_PORT_LISTENING=yes ;;
                    01) VS_PORT_CONNECTED=yes ;;
                esac
            done < "$table"
        done

        return 0
    fi

    if netstat -ltn 2>/dev/null | awk -v port=":$1" '$4 ~ port "$" && $6 == "LISTEN" { found = 1 } END { exit !found }'; then
        VS_PORT_LISTENING=yes
    fi

    if netstat -tn 2>/dev/null | awk -v port=":$1" '$4 ~ port "$" && $6 == "ESTABLISHED" { found = 1 } END { exit !found }'; then
        VS_PORT_CONNECTED=yes
    fi
}

# vs_port_listening PORT - succeed when something listens on TCP PORT.
vs_port_listening() {
    vs_tcp_port_state "$1"
    [ "$VS_PORT_LISTENING" = "yes" ]
}

# vs_port_connected PORT - succeed when a client is connected to a local
# listener on TCP PORT.
vs_port_connected() {
    vs_tcp_port_state "$1"
    [ "$VS_PORT_CONNECTED" = "yes" ]
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

# vs_state_read NAME DEFAULT - set VS_VAL to a numeric runtime state value.
vs_state_read() {
    VS_VAL=""

    if [ -r "$VS_RUN_DIR/$1" ]; then
        read -r VS_VAL < "$VS_RUN_DIR/$1"
    fi

    case "$VS_VAL" in
        "" | *[!0-9]*) VS_VAL="$2" ;;
    esac
}

# vs_state_get NAME DEFAULT - print a numeric runtime state value.
vs_state_get() {
    vs_state_read "$1" "$2"
    echo "$VS_VAL"
}

# vs_state_set NAME VALUE - store a runtime state value.
vs_state_set() {
    if ! { echo "$2" > "$VS_RUN_DIR/$1"; } 2>/dev/null; then
        mkdir -p "$VS_RUN_DIR" && echo "$2" > "$VS_RUN_DIR/$1"
    fi
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

# vs_bridge_client_ip ADDRESS - print the IP from tcpsvd's TCPREMOTEADDR, which
# is "ip:port" or "[ip]:port". An IPv4-mapped IPv6 address prints as IPv4.
vs_bridge_client_ip() {
    local addr="$1"

    case "$addr" in
        \[*\]:*)
            addr="${addr#\[}"
            addr="${addr%%\]:*}"
            ;;
        *:*:*) ;;
        *:*) addr="${addr%:*}" ;;
    esac

    case "$addr" in
        ::ffff:*.*.*.*) addr="${addr#::ffff:}" ;;
    esac

    echo "$addr"
}

# vs_bridge_client_allowed IP - succeed when IP may use the HTTP bridge. The
# robot itself always may. HTTP_BRIDGE_ALLOW lists the other allowed addresses,
# separated by spaces or commas; "any", the default, allows every client.
vs_bridge_client_allowed() {
    local ip="$1" entry

    case "$ip" in
        127.0.0.1 | ::1) return 0 ;;
    esac

    for entry in $(vs_conf_get HTTP_BRIDGE_ALLOW any | tr ',' ' '); do
        [ "$entry" = any ] && return 0
        [ -n "$ip" ] && [ "$entry" = "$ip" ] && return 0
    done

    return 1
}

# vs_keep_running NAME LAUNCHER NOW - start NAME through LAUNCHER when it is not
# running. Starts that do not last a minute back off progressively. While NAME
# runs, this starts only pidof.
vs_keep_running() {
    local name="$1" launcher="$2" now="$3" failures problem

    if vs_running "$name"; then
        vs_state_read "${name}_failures" 0

        if [ "$VS_VAL" != 0 ]; then
            vs_state_read "${name}_started_at" 0
            [ $((now - VS_VAL)) -ge 60 ] && vs_state_set "${name}_failures" 0
        fi

        return 0
    fi

    vs_state_read "${name}_next_try" 0
    [ "$now" -ge "$VS_VAL" ] || return 0

    if ! problem=$("$launcher" --check 2>&1); then
        vs_log "supervisor: $name not started: $problem"
        vs_state_set "${name}_next_try" $((now + 60))
        return 0
    fi

    vs_state_read "${name}_failures" 0
    failures=$((VS_VAL + 1))
    vs_log "supervisor: starting $name (attempt $failures)"
    vs_start_detached "$launcher"
    vs_state_set "${name}_failures" "$failures"
    vs_state_set "${name}_started_at" "$now"
    vs_state_set "${name}_next_try" $((now + $(vs_backoff "$failures")))
}
