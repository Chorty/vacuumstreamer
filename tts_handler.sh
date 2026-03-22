#!/bin/sh
# TTS/Audio/Control HTTP handler for vacuum
# Endpoints:
#   POST /say            - Text-to-speech via Google TTS
#   POST /play           - Play raw PCM (S16_LE, 16kHz, mono)
#   POST /play_raw       - Alias for /play
#   POST /play_ogg       - Play OGG file by path
#   GET  /test           - Play locate sound
#   GET  /volume/N       - Set speaker volume (0-100)
#   GET  /volume         - Get current speaker volume
#   GET  /mic_volume/N   - Set microphone gain (0-100)
#   GET  /mic_volume     - Get current microphone gain
#   GET  /obstacle_photos         - List obstacle detection photos with metadata
#   GET  /obstacle_photos/FILE    - Get single obstacle photo as base64 JSON
#   GET  /floor_types             - Get floor material detection per room (JSON)
#   GET  /room_types              - Get room type classifications
#   GET  /status         - Get vacuum state (status, battery, mode, fan, water)
#   GET  /start          - Start cleaning
#   GET  /stop           - Stop cleaning
#   GET  /pause          - Pause cleaning
#   GET  /home           - Return to dock
#   GET  /mode           - Get current operation mode
#   GET  /mode/MODE      - Set operation mode (vacuum, mop, vacuum_and_mop)
#   GET  /fan_speed       - Get current fan speed
#   GET  /fan_speed/SPEED - Set fan speed (low, medium, high, max)
#   GET  /water_usage       - Get current water usage level
#   GET  /water_usage/LEVEL - Set water usage (min, low, medium, high, max)
#   GET  /drive/enable   - Enable manual driving mode
#   GET  /drive/disable  - Disable manual driving mode
#   POST /drive/move     - Move: JSON body {"velocity": -1..1, "angle": -180..180}
#   GET  /drive/speed          - Get current drive speed (0-100)
#   GET  /drive/speed/N        - Set drive speed 0-100 (maps to velocity 0.0-1.0)
#   GET  /video_quality         - Get current video quality profile
#   GET  /video_quality/PROFILE - Set video quality (low, high)
#   GET  /segments       - List map segments (rooms)
#   POST /segments/clean - Clean specific segments: JSON body {"segment_ids": ["1","2"]}
#   POST /goto           - Go to map coordinates: JSON body {"x": N, "y": N}
#   GET  /location       - Get current robot X,Y position on map
#   GET  /statistics     - Get total and current cleaning statistics
#   GET  /consumables    - Get consumable remaining life
#   GET  /dnd            - Get Do Not Disturb configuration
#   PUT  /dnd            - Set DND: JSON body {"enabled":true,"start":{"hour":22,"minute":0},"end":{"hour":8,"minute":0}}
#   GET  /carpet_mode         - Get carpet sensor mode
#   GET  /carpet_mode/MODE    - Set carpet sensor mode (off, avoid, lift)
#   GET  /obstacle_images      - Get obstacle image detection status (enabled/disabled)
#   GET  /obstacle_images/enable  - Enable obstacle images
#   GET  /obstacle_images/disable - Disable obstacle images
#   GET  /obstacle_avoidance      - Get obstacle avoidance status
#   GET  /obstacle_avoidance/enable  - Enable obstacle avoidance
#   GET  /obstacle_avoidance/disable - Disable obstacle avoidance
#   GET  /child_lock            - Get child lock (key lock) status
#   GET  /child_lock/enable     - Enable child lock
#   GET  /child_lock/disable    - Disable child lock
#   GET  /auto_empty_interval   - Get auto-empty dock interval
#   GET  /auto_empty_interval/INTERVAL - Set interval (normal, frequent, every_clean)
#   GET  /quirks          - List all quirks with current values
#   POST /quirks          - Set a quirk: JSON body {"id":"...","value":"..."}
#   GET  /quirk/ID        - Get a single quirk value by UUID
#
# Usage: tcpsvd -vE 0.0.0.0 6971 /data/vacuumstreamer/tts_handler.sh

FFMPEG="/data/vacuumstreamer/ffmpeg"
VALETUDO="http://127.0.0.1"
RECORDER_CFG="/data/vacuumstreamer/ava_conf_video_monitor/recorder.cfg"
DRIVE_SPEED_FILE="/tmp/drive_speed"

read -r REQUEST_LINE
METHOD=$(echo "$REQUEST_LINE" | cut -d" " -f1)
URI=$(echo "$REQUEST_LINE" | cut -d" " -f2)

# Read headers
CONTENT_LENGTH=0
while read -r HEADER; do
    HEADER=$(echo "$HEADER" | tr -d "\r")
    [ -z "$HEADER" ] && break
    case "$HEADER" in
        Content-Length:*|content-length:*)
            CONTENT_LENGTH=$(echo "$HEADER" | cut -d: -f2 | tr -d " ")
            ;;
    esac
done

send_response() {
    CODE="$1"
    BODY="$2"
    LEN=$(echo -n "$BODY" | wc -c | tr -d ' ')
    printf 'HTTP/1.0 %s\r\n' "$CODE"
    printf 'Content-Type: text/plain\r\n'
    printf 'Content-Length: %s\r\n' "$LEN"
    printf 'Access-Control-Allow-Origin: *\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '%s' "$BODY"
}

send_json_response() {
    CODE="$1"
    BODY="$2"
    LEN=$(echo -n "$BODY" | wc -c | tr -d ' ')
    printf 'HTTP/1.0 %s\r\n' "$CODE"
    printf 'Content-Type: application/json\r\n'
    printf 'Content-Length: %s\r\n' "$LEN"
    printf 'Access-Control-Allow-Origin: *\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    printf '%s' "$BODY"
}

# URL-decode a string (e.g. %20 -> space, + -> space)
urldecode() {
    echo "$1" | sed 's/+/ /g' | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g' | xargs -0 printf "%b" 2>/dev/null
}

# Extract base path (before query string)
BASE_PATH=$(echo "$URI" | cut -d'?' -f1)
QUERY_STRING=$(echo "$URI" | grep -o '?.*' | cut -c2-)

case "$BASE_PATH" in
    /say)
        # Accept text via POST body or GET ?text=...
        if [ "$METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
            TEXT=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null | tr -d "\r\n")
        elif [ -n "$QUERY_STRING" ]; then
            TEXT=$(echo "$QUERY_STRING" | sed 's/^text=//;s/&.*//')
            TEXT=$(urldecode "$TEXT")
        else
            send_response "400 Bad Request" "POST text body or GET /say?text=hello"
            exit 0
        fi

        if [ -z "$TEXT" ]; then
            send_response "400 Bad Request" "empty text"
            exit 0
        fi

        # URL-encode text for Google TTS
        ENCODED=$(echo -n "$TEXT" | sed 's/ /+/g;s/[^a-zA-Z0-9_.+~-]/%&/g' | sed 's/%\(.\)/\1/g' | cat -v | sed 's/ /+/g')
        # Simple URL encoding: replace spaces with +
        ENCODED=$(echo -n "$TEXT" | sed 's/ /+/g')
        TMP_MP3="/tmp/tts_say_$$.mp3"

        # Download TTS audio from Google
        curl -s -A "Mozilla/5.0" \
            -o "$TMP_MP3" \
            "https://translate.google.com/translate_tts?ie=UTF-8&q=${ENCODED}&tl=en&client=tw-ob" 2>/dev/null

        if [ -s "$TMP_MP3" ]; then
            # Convert MP3 to PCM and play
            "$FFMPEG" -i "$TMP_MP3" -f s16le -ar 16000 -ac 1 -acodec pcm_s16le - 2>/dev/null | \
                aplay -D default -f S16_LE -r 16000 -c 1 -t raw - > /dev/null 2>&1
            rm -f "$TMP_MP3"
            send_response "200 OK" "said: $TEXT"
        else
            rm -f "$TMP_MP3"
            send_response "500 Internal Server Error" "TTS failed"
        fi
        ;;
    /play)
        if [ "$METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
            TMP_RAW=/tmp/tts_play_$$.raw
            TMP_OGG=/tmp/tts_play_$$.ogg
            dd bs=1 count=$CONTENT_LENGTH of=$TMP_RAW 2>/dev/null
            # Convert raw PCM to OGG, then play via dmr_player
            oggenc --raw --raw-bits=16 --raw-chan=1 --raw-rate=16000 \
                   --raw-endianness=0 -Q -o "$TMP_OGG" "$TMP_RAW" > /dev/null 2>&1
            ogg123 "$TMP_OGG" > /dev/null 2>&1
            rm -f "$TMP_RAW" "$TMP_OGG"
            send_response "200 OK" "played"
        else
            send_response "400 Bad Request" "POST with raw PCM body required"
        fi
        ;;
    /play_raw)
        if [ "$METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
            TMP_RAW=/tmp/tts_raw_$$.raw
            TMP_OGG=/tmp/tts_raw_$$.ogg
            dd bs=1 count=$CONTENT_LENGTH of=$TMP_RAW 2>/dev/null
            oggenc --raw --raw-bits=16 --raw-chan=1 --raw-rate=16000 \
                   --raw-endianness=0 -Q -o "$TMP_OGG" "$TMP_RAW" > /dev/null 2>&1
            ogg123 "$TMP_OGG" > /dev/null 2>&1
            rm -f "$TMP_RAW" "$TMP_OGG"
            send_response "200 OK" "played"
        else
            send_response "400 Bad Request" "POST with raw PCM body required"
        fi
        ;;
    /play_ogg)
        if [ "$METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
            OGG_PATH=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null | tr -d "\r\n")
            if [ -f "$OGG_PATH" ]; then
                ogg123 "$OGG_PATH" > /dev/null 2>&1
                send_response "200 OK" "played $OGG_PATH"
            else
                send_response "404 Not Found" "file not found: $OGG_PATH"
            fi
        else
            send_response "400 Bad Request" "POST with ogg filepath in body"
        fi
        ;;
    /test)
        ogg123 /audio/EN/45.ogg > /dev/null 2>&1
        send_response "200 OK" "test sound played"
        ;;
    /volume)
        # GET /volume - return current LINEOUT volume as percentage
        # LINEOUT range: 0-31, mapped from 0-100 via mediad_set_real_volume.sh
        # MR813: real = value * 0.16 + 16, so value = (real - 16) / 0.16
        RAW=$(amixer cget numid=7 2>/dev/null | grep ': values=' | sed 's/.*values=//')
        # Convert LINEOUT raw (0-31) back to percentage (0-100)
        if [ "$RAW" -le 16 ] 2>/dev/null; then
            PCT=0
        else
            PCT=$(( (RAW - 16) * 100 / 16 ))
            [ "$PCT" -gt 100 ] && PCT=100
        fi
        send_json_response "200 OK" "{\"volume\":$PCT,\"raw\":$RAW}"
        ;;
    /volume/*)
        VOL=$(echo "$BASE_PATH" | sed 's|/volume/||')
        /ava/script/mediad_set_real_volume.sh set "$VOL" > /dev/null 2>&1
        send_response "200 OK" "volume set to $VOL"
        ;;
    /mic_volume)
        # GET /mic_volume - return current mic gain as percentage
        # MIC gain range: 0-31
        RAW=$(amixer cget numid=5 2>/dev/null | grep ': values=' | sed 's/.*values=//')
        PCT=$(( RAW * 100 / 31 ))
        send_json_response "200 OK" "{\"mic_volume\":$PCT,\"raw\":$RAW}"
        ;;
    /mic_volume/*)
        # Set mic gain: 0-100 mapped to 0-31
        MIC_PCT=$(echo "$BASE_PATH" | sed 's|/mic_volume/||')
        MIC_RAW=$(( MIC_PCT * 31 / 100 ))
        [ "$MIC_RAW" -gt 31 ] && MIC_RAW=31
        [ "$MIC_RAW" -lt 0 ] && MIC_RAW=0
        amixer cset numid=5 "$MIC_RAW" > /dev/null 2>&1
        amixer cset numid=6 "$MIC_RAW" > /dev/null 2>&1
        send_response "200 OK" "mic volume set to $MIC_PCT (raw: $MIC_RAW)"
        ;;

    # ---- Vacuum Control (Valetudo API proxy) ----
    /status)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/state/attributes" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            send_json_response "200 OK" "$RESULT"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /start)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/BasicControlCapability" \
            -d '{"action":"start"}' 2>/dev/null)
        send_response "200 OK" "$RESULT"
        ;;
    /stop)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/BasicControlCapability" \
            -d '{"action":"stop"}' 2>/dev/null)
        send_response "200 OK" "$RESULT"
        ;;
    /pause)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/BasicControlCapability" \
            -d '{"action":"pause"}' 2>/dev/null)
        send_response "200 OK" "$RESULT"
        ;;
    /home)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/BasicControlCapability" \
            -d '{"action":"home"}' 2>/dev/null)
        send_response "200 OK" "$RESULT"
        ;;
    /mode)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/state/attributes" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            # Extract operation_mode from state attributes
            MODE=$(echo "$RESULT" | sed -n 's/.*"type":"operation_mode","value":"\([^"]*\)".*/\1/p')
            send_json_response "200 OK" "{\"mode\":\"$MODE\"}"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /mode/*)
        NEW_MODE=$(echo "$BASE_PATH" | sed 's|/mode/||')
        case "$NEW_MODE" in
            vacuum|mop|vacuum_and_mop)
                RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                    "$VALETUDO/api/v2/robot/capabilities/OperationModeControlCapability/preset" \
                    -d "{\"name\":\"$NEW_MODE\"}" 2>/dev/null)
                send_response "200 OK" "mode set to $NEW_MODE"
                ;;
            *)
                send_response "400 Bad Request" "invalid mode: $NEW_MODE (use: vacuum, mop, vacuum_and_mop)"
                ;;
        esac
        ;;
    /fan_speed)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/state/attributes" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            SPEED=$(echo "$RESULT" | sed -n 's/.*"type":"fan_speed","value":"\([^"]*\)".*/\1/p')
            send_json_response "200 OK" "{\"fan_speed\":\"$SPEED\"}"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /fan_speed/*)
        NEW_SPEED=$(echo "$BASE_PATH" | sed 's|/fan_speed/||')
        case "$NEW_SPEED" in
            low|medium|high|max)
                RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                    "$VALETUDO/api/v2/robot/capabilities/FanSpeedControlCapability/preset" \
                    -d "{\"name\":\"$NEW_SPEED\"}" 2>/dev/null)
                send_response "200 OK" "fan speed set to $NEW_SPEED"
                ;;
            *)
                send_response "400 Bad Request" "invalid fan speed: $NEW_SPEED (use: low, medium, high, max)"
                ;;
        esac
        ;;
    /water_usage)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/state/attributes" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            WATER=$(echo "$RESULT" | sed -n 's/.*"type":"water_grade","value":"\([^"]*\)".*/\1/p')
            send_json_response "200 OK" "{\"water_usage\":\"$WATER\"}"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /water_usage/*)
        NEW_WATER=$(echo "$BASE_PATH" | sed 's|/water_usage/||')
        case "$NEW_WATER" in
            min|low|medium|high|max)
                RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                    "$VALETUDO/api/v2/robot/capabilities/WaterUsageControlCapability/preset" \
                    -d "{\"name\":\"$NEW_WATER\"}" 2>/dev/null)
                send_response "200 OK" "water usage set to $NEW_WATER"
                ;;
            *)
                send_response "400 Bad Request" "invalid water usage: $NEW_WATER (use: min, low, medium, high, max)"
                ;;
        esac
        ;;
    /drive/enable)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/HighResolutionManualControlCapability" \
            -d '{"action":"enable"}' 2>/dev/null)
        send_response "200 OK" "manual control enabled"
        ;;
    /drive/disable)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/HighResolutionManualControlCapability" \
            -d '{"action":"disable"}' 2>/dev/null)
        send_response "200 OK" "manual control disabled"
        ;;
    /drive/move)
        if [ "$METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
            BODY=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
            # Extract velocity and angle from JSON body
            VELOCITY=$(echo "$BODY" | sed -n 's/.*"velocity" *: *\([0-9.eE+-]*\).*/\1/p')
            ANGLE=$(echo "$BODY" | sed -n 's/.*"angle" *: *\([0-9.eE+-]*\).*/\1/p')
            if [ -z "$VELOCITY" ] || [ -z "$ANGLE" ]; then
                send_response "400 Bad Request" "JSON body required: {\"velocity\": -1..1, \"angle\": -180..180}"
                exit 0
            fi
            RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                "$VALETUDO/api/v2/robot/capabilities/HighResolutionManualControlCapability" \
                -d "{\"action\":\"move\",\"vector\":{\"velocity\":$VELOCITY,\"angle\":$ANGLE}}" 2>/dev/null)
            send_response "200 OK" "$RESULT"
        else
            send_response "400 Bad Request" "POST JSON body required: {\"velocity\": -1..1, \"angle\": -180..180}"
        fi
        ;;
    /drive/speed)
        # Read stored drive speed percentage (default 50)
        if [ -f "$DRIVE_SPEED_FILE" ]; then
            SPD=$(cat "$DRIVE_SPEED_FILE")
        else
            SPD=50
        fi
        send_json_response "200 OK" "{\"speed\":$SPD}"
        ;;
    /drive/speed/*)
        NEW_SPD=$(echo "$BASE_PATH" | sed 's|/drive/speed/||')
        # Validate 0-100
        if [ "$NEW_SPD" -ge 0 ] 2>/dev/null && [ "$NEW_SPD" -le 100 ] 2>/dev/null; then
            echo "$NEW_SPD" > "$DRIVE_SPEED_FILE"
            send_json_response "200 OK" "{\"speed\":$NEW_SPD}"
        else
            send_response "400 Bad Request" "speed must be 0-100"
        fi
        ;;
    /segments)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/MapSegmentationCapability" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            send_json_response "200 OK" "$RESULT"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /segments/clean)
        if [ "$METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
            BODY=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
            RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                "$VALETUDO/api/v2/robot/capabilities/MapSegmentationCapability" \
                -d "$BODY" 2>/dev/null)
            send_response "200 OK" "$RESULT"
        else
            send_response "400 Bad Request" "POST JSON body: {\"segment_ids\": [\"1\",\"2\"], \"iterations\": 1}"
        fi
        ;;

    # ---- GoToLocation / Sentry ----
    /goto)
        if [ "$METHOD" = "POST" ] && [ "$CONTENT_LENGTH" -gt 0 ]; then
            BODY=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
            X=$(echo "$BODY" | grep -o '"x":[0-9-]*' | cut -d: -f2)
            Y=$(echo "$BODY" | grep -o '"y":[0-9-]*' | cut -d: -f2)
            if [ -n "$X" ] && [ -n "$Y" ]; then
                RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                    -d "{\"action\":\"goto\",\"coordinates\":{\"x\":$X,\"y\":$Y}}" \
                    "$VALETUDO/api/v2/robot/capabilities/GoToLocationCapability" 2>/dev/null)
                send_json_response "200 OK" "{\"x\":$X,\"y\":$Y,\"status\":\"ok\"}"
            else
                send_response "400 Bad Request" "POST JSON: {\"x\": N, \"y\": N}"
            fi
        else
            send_response "400 Bad Request" "POST JSON: {\"x\": N, \"y\": N}"
        fi
        ;;

    /location)
        # Return current robot X,Y from map state (useful for coordinate setup)
        MAP=$(curl -s -m 5 "$VALETUDO/api/v2/robot/state/map" 2>/dev/null)
        if [ -n "$MAP" ]; then
            # Robot entity is type "robot_position" in map entities
            X=$(echo "$MAP" | grep -o '"type":"robot_position"[^}]*"x":[0-9-]*' | grep -o '"x":[0-9-]*' | cut -d: -f2)
            Y=$(echo "$MAP" | grep -o '"type":"robot_position"[^}]*"y":[0-9-]*' | grep -o '"y":[0-9-]*' | cut -d: -f2)
            if [ -n "$X" ] && [ -n "$Y" ]; then
                send_json_response "200 OK" "{\"x\":$X,\"y\":$Y}"
            else
                send_json_response "200 OK" "{\"x\":null,\"y\":null,\"note\":\"position unavailable\"}"
            fi
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;

    # ---- Statistics ----
    /statistics)
        TOTAL=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/TotalStatisticsCapability" 2>/dev/null)
        CURRENT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/CurrentStatisticsCapability" 2>/dev/null)
        if [ -n "$TOTAL" ] && [ -n "$CURRENT" ]; then
            send_json_response "200 OK" "{\"total\":$TOTAL,\"current\":$CURRENT}"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;

    # ---- Consumables ----
    /consumables)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/ConsumableMonitoringCapability" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            send_json_response "200 OK" "$RESULT"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /consumables/reset/*)
        # /consumables/reset/TYPE or /consumables/reset/TYPE/SUBTYPE
        RESET_PATH=$(echo "$BASE_PATH" | sed 's|/consumables/reset/||')
        C_TYPE=$(echo "$RESET_PATH" | cut -d'/' -f1)
        C_SUBTYPE=$(echo "$RESET_PATH" | cut -d'/' -f2 -s)
        if [ -n "$C_SUBTYPE" ]; then
            RESET_URL="$VALETUDO/api/v2/robot/capabilities/ConsumableMonitoringCapability/$C_TYPE/$C_SUBTYPE"
        else
            RESET_URL="$VALETUDO/api/v2/robot/capabilities/ConsumableMonitoringCapability/$C_TYPE"
        fi
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$RESET_URL" -d '{"action":"reset"}' 2>/dev/null)
        send_response "200 OK" "consumable reset: $C_TYPE $C_SUBTYPE"
        ;;

    # ---- Do Not Disturb ----
    /dnd)
        if [ "$METHOD" = "PUT" ] || [ "$METHOD" = "POST" ]; then
            if [ "$CONTENT_LENGTH" -gt 0 ]; then
                BODY=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
                RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                    "$VALETUDO/api/v2/robot/capabilities/DoNotDisturbCapability" \
                    -d "$BODY" 2>/dev/null)
                send_response "200 OK" "DND updated"
            else
                send_response "400 Bad Request" "JSON body required: {\"enabled\":true,\"start\":{\"hour\":22,\"minute\":0},\"end\":{\"hour\":8,\"minute\":0}}"
            fi
        else
            RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/DoNotDisturbCapability" 2>/dev/null)
            if [ -n "$RESULT" ]; then
                send_json_response "200 OK" "$RESULT"
            else
                send_response "502 Bad Gateway" "valetudo unreachable"
            fi
        fi
        ;;

    # ---- Carpet Sensor Mode ----
    /carpet_mode)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/CarpetSensorModeControlCapability" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            send_json_response "200 OK" "$RESULT"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /carpet_mode/*)
        NEW_CARPET=$(echo "$BASE_PATH" | sed 's|/carpet_mode/||')
        case "$NEW_CARPET" in
            off|avoid|lift)
                RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                    "$VALETUDO/api/v2/robot/capabilities/CarpetSensorModeControlCapability" \
                    -d "{\"mode\":\"$NEW_CARPET\"}" 2>/dev/null)
                send_response "200 OK" "carpet mode set to $NEW_CARPET"
                ;;
            *)
                send_response "400 Bad Request" "invalid carpet mode: $NEW_CARPET (use: off, avoid, lift)"
                ;;
        esac
        ;;

    # ---- Obstacle Images ----
    /obstacle_images)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/ObstacleImagesCapability" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            send_json_response "200 OK" "$RESULT"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /obstacle_images/enable)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/ObstacleImagesCapability" \
            -d '{"action":"enable"}' 2>/dev/null)
        send_response "200 OK" "obstacle images enabled"
        ;;
    /obstacle_images/disable)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/ObstacleImagesCapability" \
            -d '{"action":"disable"}' 2>/dev/null)
        send_response "200 OK" "obstacle images disabled"
        ;;

    # ---- Obstacle Avoidance ----
    /obstacle_avoidance)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/ObstacleAvoidanceControlCapability" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            send_json_response "200 OK" "$RESULT"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /obstacle_avoidance/enable)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/ObstacleAvoidanceControlCapability" \
            -d '{"action":"enable"}' 2>/dev/null)
        send_response "200 OK" "obstacle avoidance enabled"
        ;;
    /obstacle_avoidance/disable)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/ObstacleAvoidanceControlCapability" \
            -d '{"action":"disable"}' 2>/dev/null)
        send_response "200 OK" "obstacle avoidance disabled"
        ;;

    # ---- Child Lock (Key Lock) ----
    /child_lock)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/KeyLockCapability" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            send_json_response "200 OK" "$RESULT"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /child_lock/enable)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/KeyLockCapability" \
            -d '{"action":"enable"}' 2>/dev/null)
        send_response "200 OK" "child lock enabled"
        ;;
    /child_lock/disable)
        RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
            "$VALETUDO/api/v2/robot/capabilities/KeyLockCapability" \
            -d '{"action":"disable"}' 2>/dev/null)
        send_response "200 OK" "child lock disabled"
        ;;

    # ---- Auto Empty Dock Interval ----
    /auto_empty_interval)
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/AutoEmptyDockAutoEmptyIntervalControlCapability" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            send_json_response "200 OK" "$RESULT"
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /auto_empty_interval/*)
        NEW_INTERVAL=$(echo "$BASE_PATH" | sed 's|/auto_empty_interval/||')
        case "$NEW_INTERVAL" in
            normal|frequent|every_clean)
                RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                    "$VALETUDO/api/v2/robot/capabilities/AutoEmptyDockAutoEmptyIntervalControlCapability" \
                    -d "{\"interval\":\"$NEW_INTERVAL\"}" 2>/dev/null)
                send_response "200 OK" "auto empty interval set to $NEW_INTERVAL"
                ;;
            *)
                send_response "400 Bad Request" "invalid interval: $NEW_INTERVAL (use: normal, frequent, every_clean)"
                ;;
        esac
        ;;

    # ---- Quirks ----
    /quirk/*)
        QUIRK_ID=$(echo "$BASE_PATH" | sed 's|/quirk/||')
        RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/QuirksCapability" 2>/dev/null)
        if [ -n "$RESULT" ]; then
            Q_VAL=$(echo "$RESULT" | sed -n 's/.*"id" *: *"'"$QUIRK_ID"'"[^}]*"value" *: *"\([^"]*\)".*/\1/p')
            if [ -z "$Q_VAL" ]; then
                Q_VAL=$(echo "$RESULT" | tr '{' '\n' | grep "$QUIRK_ID" | sed -n 's/.*"value" *: *"\([^"]*\)".*/\1/p')
            fi
            if [ -n "$Q_VAL" ]; then
                send_json_response "200 OK" "{\"id\":\"$QUIRK_ID\",\"value\":\"$Q_VAL\"}"
            else
                send_response "404 Not Found" "quirk not found: $QUIRK_ID"
            fi
        else
            send_response "502 Bad Gateway" "valetudo unreachable"
        fi
        ;;
    /quirks)
        if [ "$METHOD" = "POST" ] || [ "$METHOD" = "PUT" ]; then
            if [ "$CONTENT_LENGTH" -gt 0 ]; then
                BODY=$(dd bs=1 count=$CONTENT_LENGTH 2>/dev/null)
                Q_ID=$(echo "$BODY" | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p')
                Q_VAL=$(echo "$BODY" | sed -n 's/.*"value" *: *"\([^"]*\)".*/\1/p')
                if [ -z "$Q_ID" ] || [ -z "$Q_VAL" ]; then
                    send_response "400 Bad Request" "JSON body required: {\"id\":\"quirk-uuid\",\"value\":\"option\"}"
                    exit 0
                fi
                RESULT=$(curl -s -m 10 -X PUT -H "Content-Type: application/json" \
                    "$VALETUDO/api/v2/robot/capabilities/QuirksCapability" \
                    -d "{\"id\":\"$Q_ID\",\"value\":\"$Q_VAL\"}" 2>/dev/null)
                send_response "200 OK" "quirk updated"
            else
                send_response "400 Bad Request" "JSON body required: {\"id\":\"quirk-uuid\",\"value\":\"option\"}"
            fi
        else
            RESULT=$(curl -s -m 5 "$VALETUDO/api/v2/robot/capabilities/QuirksCapability" 2>/dev/null)
            if [ -n "$RESULT" ]; then
                send_json_response "200 OK" "$RESULT"
            else
                send_response "502 Bad Gateway" "valetudo unreachable"
            fi
        fi
        ;;
    /video_quality)
        # Read current encoder settings from recorder.cfg
        CUR_W=$(grep "^encoder_voutput_width" "$RECORDER_CFG" | head -1 | sed 's/.*= *//')
        CUR_H=$(grep "^encoder_voutput_height" "$RECORDER_CFG" | head -1 | sed 's/.*= *//')
        CUR_FPS=$(grep "^encoder_voutput_framerate" "$RECORDER_CFG" | head -1 | sed 's/.*= *//')
        CUR_BR=$(grep "^encoder_voutput_bitrate" "$RECORDER_CFG" | head -1 | sed 's/.*= *//')
        if [ "$CUR_BR" = "600000" ] && [ "$CUR_FPS" = "15" ]; then
            PROFILE="low"
        else
            PROFILE="high"
        fi
        send_json_response "200 OK" "{\"profile\":\"$PROFILE\",\"width\":$CUR_W,\"height\":$CUR_H,\"framerate\":$CUR_FPS,\"bitrate\":$CUR_BR}"
        ;;
    /video_quality/*)
        NEW_PROFILE=$(echo "$BASE_PATH" | sed 's|/video_quality/||')
        case "$NEW_PROFILE" in
            low)
                VW=864; VH=480; VF=15; VB=600000
                ;;
            high)
                VW=640; VH=480; VF=25; VB=2000000
                ;;
            *)
                send_response "400 Bad Request" "invalid profile: $NEW_PROFILE (use: low, high)"
                exit 0
                ;;
        esac
        # Update camera 0 settings (first occurrence only, lines 1-70)
        sed -i "1,70{/^video_width = /s/.*/video_width = $VW/}" "$RECORDER_CFG"
        sed -i "1,70{/^video_height = /s/.*/video_height = $VH/}" "$RECORDER_CFG"
        sed -i "1,70{/^video_framerate = /s/.*/video_framerate = $VF/}" "$RECORDER_CFG"
        sed -i "1,70{/^encoder_voutput_width = /s/.*/encoder_voutput_width = $VW/}" "$RECORDER_CFG"
        sed -i "1,70{/^encoder_voutput_height = /s/.*/encoder_voutput_height = $VH/}" "$RECORDER_CFG"
        sed -i "1,70{/^encoder_voutput_framerate = /s/.*/encoder_voutput_framerate = $VF/}" "$RECORDER_CFG"
        sed -i "1,70{/^encoder_voutput_bitrate = /s/.*/encoder_voutput_bitrate = $VB/}" "$RECORDER_CFG"
        # Restart video_monitor to apply changes
        killall video_monitor 2>/dev/null
        sleep 1
        LD_PRELOAD=/data/vacuumstreamer/vacuumstreamer.so /data/vacuumstreamer/video_monitor > /dev/null 2>&1 &
        send_json_response "200 OK" "{\"profile\":\"$NEW_PROFILE\",\"width\":$VW,\"height\":$VH,\"framerate\":$VF,\"bitrate\":$VB}"
        ;;

    # ---- Object Detection / AI Results ----
    /obstacle_photos)
        AI_DIR="/data/ai_offline_collection"
        if [ ! -d "$AI_DIR" ]; then
            send_json_response "200 OK" "[]"
            exit 0
        fi
        RESULT="["
        FIRST=1
        for IMGFILE in "$AI_DIR"/*.jpg "$AI_DIR"/*.JPG; do
            [ -f "$IMGFILE" ] || continue
            FNAME=$(basename "$IMGFILE")
            # Filename format: timestamp_angle_confidence.jpg
            TS=$(echo "$FNAME" | cut -d_ -f1)
            ANGLE=$(echo "$FNAME" | cut -d_ -f2)
            CONF=$(echo "$FNAME" | cut -d_ -f3 | sed 's/\.[Jj][Pp][Gg]$//')
            if [ "$FIRST" = "1" ]; then
                FIRST=0
            else
                RESULT="$RESULT,"
            fi
            RESULT="$RESULT{\"filename\":\"$FNAME\",\"timestamp\":$TS,\"angle\":$ANGLE,\"confidence\":$CONF}"
        done
        RESULT="$RESULT]"
        send_json_response "200 OK" "$RESULT"
        ;;
    /obstacle_photos/*)
        FNAME=$(echo "$BASE_PATH" | sed 's|/obstacle_photos/||')
        # Sanitize: no slashes or dots-dot allowed
        FNAME=$(echo "$FNAME" | sed 's|/||g; s|\.\.|.|g')
        IMGFILE="/data/ai_offline_collection/$FNAME"
        if [ ! -f "$IMGFILE" ]; then
            send_response "404 Not Found" "photo not found: $FNAME"
            exit 0
        fi
        B64=$(base64 "$IMGFILE" | tr -d '\n')
        send_json_response "200 OK" "{\"filename\":\"$FNAME\",\"data\":\"$B64\"}"
        ;;
    /floor_types)
        MAP_DIR="/data/DivideAI/ai_result"
        # DivideAI uses its own numeric map IDs independent of maploader slots
        ACTIVE_MAP=$(ls "$MAP_DIR" 2>/dev/null | sort -n | tail -1)
        FLOORS_FILE="$MAP_DIR/$ACTIVE_MAP/ai_floors_large.txt"
        if [ -f "$FLOORS_FILE" ]; then
            CONTENT=$(cat "$FLOORS_FILE")
            send_json_response "200 OK" "$CONTENT"
        else
            send_json_response "200 OK" "{\"ai_material\":[]}"
        fi
        ;;
    /room_types)
        MAP_DIR="/data/DivideAI/ai_result"
        # DivideAI uses its own numeric map IDs independent of maploader slots
        ACTIVE_MAP=$(ls "$MAP_DIR" 2>/dev/null | sort -n | tail -1)
        ROOMS_FILE="$MAP_DIR/$ACTIVE_MAP/ai_rooms_large.txt"
        if [ -f "$ROOMS_FILE" ]; then
            RESULT="["
            FIRST=1
            while IFS=' ' read -r ROOM_ID ROOM_TYPE LABEL; do
                [ -z "$ROOM_ID" ] && continue
                if [ "$FIRST" = "1" ]; then FIRST=0; else RESULT="$RESULT,"; fi
                RESULT="$RESULT{\"room_id\":$ROOM_ID,\"type\":$ROOM_TYPE,\"label\":$LABEL}"
            done < "$ROOMS_FILE"
            RESULT="$RESULT]"
            send_json_response "200 OK" "$RESULT"
        else
            send_json_response "200 OK" "[]"
        fi
        ;;
    *)
        send_response "404 Not Found" "endpoints: /say, /play, /play_ogg, /test, /volume[/N], /mic_volume[/N], /status, /start, /stop, /pause, /home, /mode[/MODE], /fan_speed[/SPEED], /water_usage[/LEVEL], /drive/enable, /drive/disable, /drive/move, /drive/speed[/N], /video_quality[/PROFILE], /segments, /segments/clean, /statistics, /consumables, /dnd, /carpet_mode[/MODE], /obstacle_images[/enable|disable], /obstacle_avoidance[/enable|disable], /child_lock[/enable|disable], /auto_empty_interval[/INTERVAL], /quirks, /quirk/ID, /obstacle_photos[/FILE], /floor_types, /room_types"
        ;;
esac
