#!/bin/sh
# Microphone gain control for the Valetudo plugin and for manual use.
#
# Usage: mic_gain_ctl.sh get
#        mic_gain_ctl.sh set PERCENT
#
# GET prints {"mic_volume":PCT,"raw":RAW}: RAW is the ALSA control value
# (numid 5, range 0-31) and PCT is RAW scaled to 0-100.
# SET clamps PERCENT to 0-100, maps it to 0-31, and applies it to both mic
# controls (numid 5 and 6), mirroring the previous port-6971 /mic_volume
# handler this replaces.
#
# Exit codes: 64 usage, 65 invalid percentage

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

MIC_GAIN_RAW_MAX=31

mic_gain_read() {
    amixer cget numid=5 2>/dev/null | grep ': values=' | sed 's/.*values=//'
}

mic_gain_report() {
    local raw="$1" pct

    case "$raw" in
        '' | *[!0-9]*)
            raw=0
            ;;
    esac

    pct=$((raw * 100 / MIC_GAIN_RAW_MAX))
    echo "{\"mic_volume\":$pct,\"raw\":$raw}"
}

case "${1:-}" in
    get)
        mic_gain_report "$(mic_gain_read)"
        ;;
    set)
        pct="${2:-}"

        case "$pct" in
            '' | *[!0-9]*)
                echo "mic_gain_ctl: invalid percentage: $pct" >&2
                exit 65
                ;;
        esac

        [ "$pct" -gt 100 ] && pct=100

        raw=$((pct * MIC_GAIN_RAW_MAX / 100))
        [ "$raw" -gt "$MIC_GAIN_RAW_MAX" ] && raw=$MIC_GAIN_RAW_MAX

        amixer cset numid=5 "$raw" > /dev/null 2>&1
        amixer cset numid=6 "$raw" > /dev/null 2>&1
        vs_log "mic_gain_ctl: set to ${pct}% (raw $raw)"

        mic_gain_report "$(mic_gain_read)"
        ;;
    *)
        echo "usage: $0 get|set PERCENT" >&2
        exit 64
        ;;
esac
