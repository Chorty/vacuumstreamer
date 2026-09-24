#!/bin/sh
# Microphone gain control for the Valetudo plugin and for manual use.
#
# Usage: mic_gain_ctl.sh get
#        mic_gain_ctl.sh set PERCENT
#
# GET prints {"mic_volume":PCT,"raw":RAW}: RAW is the ALSA control value
# (numid 5, range 0-31) and PCT is RAW scaled to 0-100.
# SET rejects a PERCENT outside 0-100, maps a valid one to the nearest of
# 0-31, and applies it to both mic controls (numid 5 and 6), like the previous
# port-6971 /mic_volume handler this replaces (which instead clamped the value
# and truncated).
#
# GET truncates and SET rounds, so setting the percentage GET reported gives
# back the same raw value for all 32 raw values. Truncating on both sides
# lowered 30 of them by one step on every get-then-set, which is how a Home
# Assistant sync loop drained the mic to 0.
#
# Exit codes: 64 usage, 65 invalid percentage

VS_SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$VS_SCRIPT_DIR/vacuumstreamer_lib.sh"

MIC_GAIN_RAW_MAX=31

mic_gain_read() {
    amixer cget numid=5 2>/dev/null | grep ': values=' | sed 's/.*values=//'
}

# mic_gain_report RAW - print the {mic_volume, raw} JSON for an ALSA raw
# value. RAW's leading zeros are stripped even though it is already known to
# be all-digits, because shell arithmetic otherwise reads a leading-zero
# value such as "017" as octal.
mic_gain_report() {
    local raw="$1" pct

    case "$raw" in
        '' | *[!0-9]*)
            raw=0
            ;;
    esac
    raw=$(vs_strip_leading_zeros "$raw")

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
        pct=$(vs_strip_leading_zeros "$pct")

        if [ "$pct" -gt 100 ]; then
            echo "mic_gain_ctl: invalid percentage: $pct" >&2
            exit 65
        fi

        raw=$(((pct * MIC_GAIN_RAW_MAX + 50) / 100))

        amixer cset numid=5 "$raw" > /dev/null 2>&1
        amixer cset numid=6 "$raw" > /dev/null 2>&1
        vs_log "mic_gain_ctl: set to ${pct}% (raw $raw)"

        # cset targets a fixed numid deterministically, so $raw is already
        # what was just applied; no need to re-read the hardware for it.
        mic_gain_report "$raw"
        ;;
    *)
        echo "usage: $0 get|set PERCENT" >&2
        exit 64
        ;;
esac
