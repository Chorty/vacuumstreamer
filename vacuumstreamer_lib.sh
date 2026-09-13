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
