#!/bin/sh
# Tests for the VacuumStreamer runtime scripts.
#
# Usage: sh test/run_tests.sh [shell]
# The optional shell (default: sh) runs the scripts under test. dash is a close
# stand-in for the robot's BusyBox ash.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
TEST_SH="${1:-sh}"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

PASS=0
FAIL=0
CASE=0

check() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
    fi
}

contains() {
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf 'FAIL: %s\n  expected to contain: [%s]\n  actual: [%s]\n' "$1" "$2" "$3"
            ;;
    esac
}

lacks() {
    case "$3" in
        *"$2"*)
            FAIL=$((FAIL + 1))
            printf 'FAIL: %s\n  expected not to contain: [%s]\n  actual: [%s]\n' "$1" "$2" "$3"
            ;;
        *) PASS=$((PASS + 1)) ;;
    esac
}

new_case() {
    CASE=$((CASE + 1))
    VS_DIR="$TMP_ROOT/case$CASE"
    mkdir -p "$VS_DIR"

    for script in vacuumstreamer_lib.sh go2rtc_launch.sh video_monitor_launch.sh vacuumstreamer_boot.sh; do
        cp "$REPO/$script" "$VS_DIR/$script"
        chmod 755 "$VS_DIR/$script"
    done

    printf '#!/bin/sh\necho "go2rtc args=[$*] credentials=[${CREDENTIALS_DIRECTORY:-unset}] user=[${GO2RTC_USERNAME:-unset}]"\n' > "$VS_DIR/go2rtc"
    printf '#!/bin/sh\necho "video_monitor preload=[${LD_PRELOAD:-unset}]"\n' > "$VS_DIR/video_monitor"
    chmod 755 "$VS_DIR/go2rtc" "$VS_DIR/video_monitor"

    VS_CONF="$VS_DIR/vacuumstreamer.conf"
    VS_CREDENTIALS_DIR="$VS_DIR/credentials"
    VS_LOG="$VS_DIR/vacuumstreamer.log"
    export VS_DIR VS_CONF VS_CREDENTIALS_DIR VS_LOG
}

set_conf() {
    printf '%s\n' "$@" > "$VS_CONF"
}

set_credentials() {
    mkdir -p "$VS_CREDENTIALS_DIR"
    chmod 700 "$VS_CREDENTIALS_DIR"
    printf '%s\n' "$1" > "$VS_CREDENTIALS_DIR/GO2RTC_USERNAME"
    printf '%s\n' "$2" > "$VS_CREDENTIALS_DIR/GO2RTC_PASSWORD"
    chmod 600 "$VS_CREDENTIALS_DIR/GO2RTC_USERNAME" "$VS_CREDENTIALS_DIR/GO2RTC_PASSWORD"
}

lib() {
    $TEST_SH -c '. "$VS_DIR/vacuumstreamer_lib.sh"; "$@"' lib "$@"
}

run_script() {
    OUT=$($TEST_SH "$@" 2>&1)
    STATUS=$?
}

boot_actions() {
    rm -f "$VS_DIR/actions"
    VS_DRY_RUN="$VS_DIR/actions" $TEST_SH "$VS_DIR/vacuumstreamer_boot.sh"
    cat "$VS_DIR/actions" 2>/dev/null
}

GOOD_PASSWORD="abcdefghijklmnop1234"

# --- Switch parsing ---

new_case
check "a missing config uses an on default" "on" "$(lib vs_switch CAMERA on)"
check "a missing config uses an off default" "off" "$(lib vs_switch CAMERA_LOGIN off)"

new_case
set_conf "# comment" "  CAMERA = off   # trailing comment"
check "whitespace and comments are ignored" "off" "$(lib vs_switch CAMERA on)"

new_case
set_conf "CAMERA_LOGIN=off"
check "CAMERA does not match CAMERA_LOGIN" "on" "$(lib vs_switch CAMERA on)"

new_case
set_conf "CAMERA=off" "CAMERA=on"
check "the last occurrence wins" "on" "$(lib vs_switch CAMERA off)"

new_case
set_conf "CAMERA=off" "CAMERA="
check "an empty last value falls back to the default" "on" "$(lib vs_switch CAMERA on)"

new_case
printf 'CAMERA=off\r\n' > "$VS_CONF"
check "Windows line endings are accepted" "off" "$(lib vs_switch CAMERA on)"

new_case
set_conf "CAMERA=maybe"
check "an invalid value falls back to the default" "on" "$(lib vs_switch CAMERA on)"
contains "an invalid value is logged" "invalid value for CAMERA" "$(cat "$VS_LOG")"

new_case
set_conf 'CAMERA=$(touch "$VS_DIR/pwned")'
check "a command in a value is treated as an invalid value" "on" "$(lib vs_switch CAMERA on)"
check "a command in a value never runs" "absent" "$(if [ -e "$VS_DIR/pwned" ]; then echo present; else echo absent; fi)"

new_case
check "an invalid key is rejected" "fallback" "$(lib vs_conf_get 'CAMERA;x' fallback)"

# --- go2rtc launcher ---

new_case
run_script "$VS_DIR/go2rtc_launch.sh"
check "login off: go2rtc starts" "0" "$STATUS"
check "login off: go2rtc gets its config and no credentials" "go2rtc args=[-c $VS_DIR/go2rtc.yaml] credentials=[unset] user=[unset]" "$OUT"

new_case
OUT=$(GO2RTC_USERNAME=inherited CREDENTIALS_DIRECTORY=/elsewhere $TEST_SH "$VS_DIR/go2rtc_launch.sh" 2>&1)
check "login off: inherited credential settings are cleared" "go2rtc args=[-c $VS_DIR/go2rtc.yaml] credentials=[unset] user=[unset]" "$OUT"

new_case
set_conf "CAMERA_LOGIN=on"
set_credentials viewer "$GOOD_PASSWORD"
run_script "$VS_DIR/go2rtc_launch.sh"
check "login on: go2rtc starts" "0" "$STATUS"
check "login on: go2rtc reads credentials from the directory" "go2rtc args=[-c $VS_DIR/go2rtc.yaml] credentials=[$VS_CREDENTIALS_DIR] user=[unset]" "$OUT"

new_case
set_conf "CAMERA_LOGIN=on"
run_script "$VS_DIR/go2rtc_launch.sh"
check "login on without credentials: refused" "78" "$STATUS"
contains "login on without credentials: explains why" "requires the directory" "$OUT"
lacks "login on without credentials: go2rtc does not run" "go2rtc args" "$OUT"
contains "login on without credentials: logged" "go2rtc not started" "$(cat "$VS_LOG")"

new_case
set_conf "CAMERA_LOGIN=on"
set_credentials viewer "$GOOD_PASSWORD"
chmod 755 "$VS_CREDENTIALS_DIR"
run_script "$VS_DIR/go2rtc_launch.sh"
check "an accessible credentials directory is refused" "78" "$STATUS"

new_case
set_conf "CAMERA_LOGIN=on"
set_credentials viewer "$GOOD_PASSWORD"
chmod 644 "$VS_CREDENTIALS_DIR/GO2RTC_PASSWORD"
run_script "$VS_DIR/go2rtc_launch.sh"
check "a readable password file is refused" "78" "$STATUS"

new_case
set_conf "CAMERA_LOGIN=on"
set_credentials viewer "$GOOD_PASSWORD"
rm "$VS_CREDENTIALS_DIR/GO2RTC_PASSWORD"
ln -s "$VS_CREDENTIALS_DIR/GO2RTC_USERNAME" "$VS_CREDENTIALS_DIR/GO2RTC_PASSWORD"
run_script "$VS_DIR/go2rtc_launch.sh"
check "a symlinked credential is refused" "78" "$STATUS"

new_case
set_conf "CAMERA_LOGIN=on"
set_credentials viewer "short-password"
run_script "$VS_DIR/go2rtc_launch.sh"
check "a short password is refused" "78" "$STATUS"
contains "a short password: explains why" "at least 16 characters" "$OUT"
lacks "a short password: the value is not printed" "short-password" "$OUT"

new_case
set_conf "CAMERA_LOGIN=on"
set_credentials "bad user" "$GOOD_PASSWORD"
run_script "$VS_DIR/go2rtc_launch.sh"
check "a username with a space is refused" "78" "$STATUS"

new_case
set_conf "CAMERA_LOGIN=on"
set_credentials viewer 'pass"word#1234567890'
run_script "$VS_DIR/go2rtc_launch.sh"
check "a password with YAML-breaking characters is refused" "78" "$STATUS"
lacks "a rejected password is not printed" 'pass"word' "$OUT"

new_case
set_conf "CAMERA=off"
run_script "$VS_DIR/go2rtc_launch.sh"
check "camera off: go2rtc is refused" "75" "$STATUS"
lacks "camera off: go2rtc does not run" "go2rtc args" "$OUT"

new_case
set_conf "CAMERA_LOGIN=on"
set_credentials viewer "$GOOD_PASSWORD"
run_script "$VS_DIR/go2rtc_launch.sh" --check
check "--check with valid settings succeeds" "0" "$STATUS"
check "--check does not start go2rtc" "" "$OUT"

new_case
run_script "$VS_DIR/go2rtc_launch.sh" --bogus
check "an unknown argument is a usage error" "64" "$STATUS"

# --- video_monitor launcher ---

new_case
run_script "$VS_DIR/video_monitor_launch.sh"
check "video_monitor starts with the hook preloaded" "video_monitor preload=[$VS_DIR/vacuumstreamer.so]" "$OUT"

new_case
: > "$VS_DIR/libc.so.6"
run_script "$VS_DIR/video_monitor_launch.sh"
check "the bundled libc is preloaded when present" "video_monitor preload=[$VS_DIR/vacuumstreamer.so:$VS_DIR/libc.so.6]" "$OUT"

new_case
set_conf "CAMERA=off"
run_script "$VS_DIR/video_monitor_launch.sh"
check "camera off: video_monitor is refused" "75" "$STATUS"
lacks "camera off: video_monitor does not run" "video_monitor preload" "$OUT"

# --- Boot script ---

new_case
ACTIONS=$(boot_actions)
contains "boot mounts the video_monitor config" "run: mount --bind $VS_DIR/ava_conf_video_monitor /ava/conf/video_monitor" "$ACTIONS"
contains "boot mounts the private copy" "run: mount --bind $VS_DIR/mnt_private_copy /mnt/private" "$ACTIONS"
contains "boot sets the speaker mixer" "run: amixer cset numid=16 on" "$ACTIONS"
contains "boot starts video_monitor" "background: $VS_DIR/video_monitor_launch.sh" "$ACTIONS"
contains "boot starts go2rtc" "background: $VS_DIR/go2rtc_launch.sh" "$ACTIONS"
contains "boot starts the HTTP bridge" "background: vs_http_bridge_loop" "$ACTIONS"
contains "boot logs the switches" "boot: CAMERA=on CAMERA_LOGIN=off TTS=on MAP_MANAGEMENT=on HTTP_BRIDGE=on" "$(cat "$VS_LOG")"

new_case
set_conf "CAMERA=off"
ACTIONS=$(boot_actions)
lacks "camera off: boot does not start video_monitor" "video_monitor_launch" "$ACTIONS"
lacks "camera off: boot does not start go2rtc" "go2rtc_launch" "$ACTIONS"
contains "camera off: mounts still apply" "run: mount --bind" "$ACTIONS"
contains "camera off: the HTTP bridge still starts" "background: vs_http_bridge_loop" "$ACTIONS"

new_case
set_conf "HTTP_BRIDGE=off"
ACTIONS=$(boot_actions)
lacks "bridge off: boot does not start the bridge" "vs_http_bridge_loop" "$ACTIONS"
contains "bridge off: the camera still starts" "background: $VS_DIR/go2rtc_launch.sh" "$ACTIONS"

new_case
set_conf "CAMERA_LOGIN=on"
ACTIONS=$(boot_actions)
lacks "login misconfigured: boot starts no camera process" "_launch.sh" "$ACTIONS"
contains "login misconfigured: boot logs why" "camera not started" "$(cat "$VS_LOG")"

new_case
rm "$VS_DIR/video_monitor"
ACTIONS=$(boot_actions)
check "without video_monitor installed boot does nothing" "" "$ACTIONS"

printf '%s passed, %s failed (shell: %s)\n' "$PASS" "$FAIL" "$TEST_SH"
[ "$FAIL" -eq 0 ]
