#!/bin/sh
# Tests for the VacuumStreamer runtime scripts.
#
# Usage: sh test/run_tests.sh [shell]
# The optional shell (default: sh) runs the scripts under test. dash is a close
# stand-in for the robot's BusyBox ash. Robot commands such as pidof, netstat,
# killall, curl, flock and setsid are replaced by stubs that track state in
# files.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
TEST_SH="${1:-sh}"
TMP_ROOT=$(mktemp -d)
ORIGINAL_PATH="$PATH"
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

exists() {
    if [ -e "$1" ]; then echo yes; else echo no; fi
}

wait_for() {
    local i=0

    while [ ! -e "$1" ] && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
}

new_case() {
    CASE=$((CASE + 1))
    VS_DIR="$TMP_ROOT/case$CASE"
    VS_STATE="$VS_DIR/state"
    mkdir -p "$VS_DIR/bin" "$VS_STATE"

    for script in vacuumstreamer_lib.sh go2rtc_launch.sh video_monitor_launch.sh vacuumstreamer_boot.sh camera_wake.sh camera_supervisor.sh camera_ctl.sh; do
        cp "$REPO/$script" "$VS_DIR/$script"
        chmod 755 "$VS_DIR/$script"
    done

    cat > "$VS_DIR/go2rtc" <<'EOF'
#!/bin/sh
touch "$VS_STATE/running_go2rtc"
echo "go2rtc args=[$*] credentials=[${CREDENTIALS_DIRECTORY:-unset}] user=[${GO2RTC_USERNAME:-unset}]"
EOF
    cat > "$VS_DIR/video_monitor" <<'EOF'
#!/bin/sh
touch "$VS_STATE/running_video_monitor"
[ -e "$VS_STATE/never_listen" ] || touch "$VS_STATE/listening"
echo "video_monitor preload=[${LD_PRELOAD:-unset}]"
EOF
    cat > "$VS_DIR/bin/pidof" <<'EOF'
#!/bin/sh
echo "pidof $*" >> "$VS_STATE/calls"
[ -e "$VS_STATE/running_$1" ]
EOF
    cat > "$VS_DIR/bin/killall" <<'EOF'
#!/bin/sh
# BusyBox killall: optional -SIGNAL, fails when no process has the name
echo "killall $*" >> "$VS_STATE/calls"
signal=TERM
case "$1" in -*) signal="${1#-}"; shift ;; esac
[ -e "$VS_STATE/running_$1" ] || exit 1
# A hung process ignores TERM
[ "$signal" = TERM ] && [ -e "$VS_STATE/hung_$1" ] && exit 0
rm -f "$VS_STATE/running_$1"
[ "$1" = video_monitor ] && rm -f "$VS_STATE/listening"
exit 0
EOF
    cat > "$VS_DIR/bin/netstat" <<'EOF'
#!/bin/sh
case "$1" in
    -ltn) [ -e "$VS_STATE/listening" ] && echo "tcp        0      0 0.0.0.0:6969            0.0.0.0:*               LISTEN" ;;
    -tn) [ -e "$VS_STATE/connected" ] && echo "tcp        0      0 127.0.0.1:6969          127.0.0.1:50000         ESTABLISHED" ;;
esac
exit 0
EOF
    cat > "$VS_DIR/bin/curl" <<'EOF'
#!/bin/sh
cat "$VS_STATE/streams.json" 2>/dev/null
EOF
    cat > "$VS_DIR/bin/flock" <<'EOF'
#!/bin/sh
# BusyBox 1.36 flock: only -s -x -u -n -o are valid
nonblocking=no
while [ $# -gt 1 ]; do
    case "$1" in
        -n) nonblocking=yes ;;
        -s | -x | -u | -o) ;;
        -*) echo "flock: invalid option -- '${1#-}'" >&2; exit 1 ;;
    esac
    shift
done
if [ -e "$VS_STATE/lock_held" ]; then
    [ "$nonblocking" = yes ] && exit 1
    while [ -e "$VS_STATE/lock_held" ]; do sleep 0.1; done
fi
exit 0
EOF
    printf '#!/bin/sh\nexec "$@"\n' > "$VS_DIR/bin/setsid"
    chmod 755 "$VS_DIR/go2rtc" "$VS_DIR/video_monitor" "$VS_DIR/bin/"*

    VS_CONF="$VS_DIR/vacuumstreamer.conf"
    VS_CREDENTIALS_DIR="$VS_DIR/credentials"
    VS_LOG="$VS_DIR/vacuumstreamer.log"
    VS_RUN_DIR="$VS_DIR/run"
    # Most tests drive port state through the netstat stub
    VS_PROC_NET_TCP="$VS_STATE/no_proc_net_tcp"
    PATH="$VS_DIR/bin:$ORIGINAL_PATH"
    export VS_DIR VS_STATE VS_CONF VS_CREDENTIALS_DIR VS_LOG VS_RUN_DIR VS_PROC_NET_TCP PATH
}

set_conf() {
    printf '%s\n' "$@" > "$VS_CONF"
}

set_run_state() {
    mkdir -p "$VS_RUN_DIR"
    echo "$2" > "$VS_RUN_DIR/$1"
}

set_credentials() {
    mkdir -p "$VS_CREDENTIALS_DIR"
    chmod 700 "$VS_CREDENTIALS_DIR"
    printf '%s\n' "$1" > "$VS_CREDENTIALS_DIR/GO2RTC_USERNAME"
    printf '%s\n' "$2" > "$VS_CREDENTIALS_DIR/GO2RTC_PASSWORD"
    chmod 600 "$VS_CREDENTIALS_DIR/GO2RTC_USERNAME" "$VS_CREDENTIALS_DIR/GO2RTC_PASSWORD"
}

stub_supervisor() {
    printf '#!/bin/sh\ntouch "$VS_STATE/supervisor_started"\n' > "$VS_DIR/camera_supervisor.sh"
    chmod 755 "$VS_DIR/camera_supervisor.sh"
}

lib() {
    $TEST_SH -c '. "$VS_DIR/vacuumstreamer_lib.sh"; "$@"' lib "$@"
}

run_script() {
    OUT=$($TEST_SH "$@" 2>&1)
    STATUS=$?
}

supervise() {
    VS_FAKE_NOW="$1" $TEST_SH "$VS_DIR/camera_supervisor.sh" --once > /dev/null 2>&1
    STATUS=$?
}

calls() {
    cat "$VS_STATE/calls" 2>/dev/null
}

loaded() {
    $TEST_SH -c '. "$VS_DIR/vacuumstreamer_lib.sh"; vs_conf_load; vs_conf_value "$1" "$2"; echo "$VS_VAL"' loaded "$@"
}

count_commands() {
    local c real

    mkdir -p "$VS_DIR/counting"

    for c in sed tail cut awk netstat cat mkdir date tr ls grep curl; do
        real=$(PATH="$ORIGINAL_PATH" command -v "$c") || continue
        printf '#!/bin/sh\necho "exec %s" >> "$VS_STATE/calls"\nexec %s "$@"\n' "$c" "$real" > "$VS_DIR/counting/$c"
        chmod 755 "$VS_DIR/counting/$c"
    done

    PATH="$VS_DIR/counting:$PATH"
    export PATH
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
check "a command in a value never runs" "no" "$(exists "$VS_DIR/pwned")"

new_case
check "an invalid key is rejected" "fallback" "$(lib vs_conf_get 'CAMERA;x' fallback)"

# --- Builtin config reader matches vs_conf_get ---

new_case
printf '%s\n' "# comment" "  CAMERA = off   # trailing" "CAMERA_LOGIN=on" "TTS=off" "TTS=on" \
    "MAP_MANAGEMENT=off" "MAP_MANAGEMENT=" "HTTP_BRIDGE==weird" "CA#MERA=off" "camera=off" \
    "	CAMERA_MODE	=	always	" "CAMERA_IDLE_SECONDS=1 2" 'CAMERA_STALL_SECONDS=$(touch "$VS_DIR/pwned")' > "$VS_CONF"
printf 'CAMERA_WAKE_TIMEOUT_SECONDS=9\r' >> "$VS_CONF"
for key in CAMERA CAMERA_LOGIN TTS MAP_MANAGEMENT HTTP_BRIDGE CAMERA_MODE CAMERA_IDLE_SECONDS CAMERA_STALL_SECONDS CAMERA_WAKE_TIMEOUT_SECONDS MISSING; do
    check "builtin reader matches vs_conf_get for $key" "$(lib vs_conf_get "$key" fallback)" "$(loaded "$key" fallback)"
done
check "the builtin reader never runs a value" "no" "$(exists "$VS_DIR/pwned")"

new_case
check "the builtin reader handles a missing config" "fallback" "$(loaded CAMERA fallback)"

new_case
set_conf "CAMERA=maybe" "CAMERA_IDLE_SECONDS=5" "CAMERA_MODE=sometimes"
OUT=$($TEST_SH -c '. "$VS_DIR/vacuumstreamer_lib.sh"; vs_conf_load
    vs_setting_switch CAMERA on; a="$VS_VAL"; vs_setting_switch CAMERA on
    vs_setting_number CAMERA_IDLE_SECONDS 180 30 86400; b="$VS_VAL"
    vs_setting_camera_mode; echo "$a $VS_VAL $b"')
check "invalid settings fall back to their defaults" "on on_demand 180" "$OUT"
check "an invalid setting is logged once" "1" "$(grep -c 'invalid value for CAMERA in' "$VS_LOG")"

# --- Port state from /proc/net/tcp ---

new_case
cat > "$VS_STATE/tcp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:1B39 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 101
   1: 0100007F:1B39 0100007F:C350 01 00000000:00000000 00:00000000 00000000     0        0 102
   2: 0100007F:C350 0100007F:1B39 01 00000000:00000000 00:00000000 00000000     0        0 103
   3: 00000000:07C0 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 104
EOF
OUT=$(VS_PROC_NET_TCP="$VS_STATE/tcp" $TEST_SH -c '. "$VS_DIR/vacuumstreamer_lib.sh"; vs_tcp_port_state 6969; echo "$VS_PORT_LISTENING $VS_PORT_CONNECTED"')
check "a listener and a connected viewer are read from /proc/net/tcp" "yes yes" "$OUT"

new_case
cat > "$VS_STATE/tcp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:C350 0100007F:1B39 01 00000000:00000000 00:00000000 00000000     0        0 103
   1: 00000000:1B3A 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 104
EOF
OUT=$(VS_PROC_NET_TCP="$VS_STATE/tcp" $TEST_SH -c '. "$VS_DIR/vacuumstreamer_lib.sh"; vs_tcp_port_state 6969; echo "$VS_PORT_LISTENING $VS_PORT_CONNECTED"')
check "a client-side connection or another port is not the camera" "no no" "$OUT"

# --- Runtime state helpers ---

new_case
check "a missing state value uses the default" "7" "$(lib vs_state_get missing 7)"
set_run_state junk "abc"
check "a non-numeric state value uses the default" "7" "$(lib vs_state_get junk 7)"
rm -rf "$VS_RUN_DIR"
lib vs_state_set created 42
check "storing state creates the runtime directory" "42" "$(lib vs_state_get created 0)"

# --- Supervisor idle loop starts few processes ---

new_case
printf '  sl  local_address rem_address   st\n   0: 00000000:07C0 00000000:0000 0A 0 0 0 0 0 0 0\n' > "$VS_STATE/tcp"
touch "$VS_STATE/running_go2rtc"
set_run_state go2rtc_started_at 0
count_commands
VS_PROC_NET_TCP="$VS_STATE/tcp" supervise 1000
PATH="$VS_DIR/bin:$ORIGINAL_PATH"; export PATH
check "an idle supervisor check only runs pidof" "$(printf 'pidof go2rtc\npidof video_monitor')" "$(calls)"

# --- Numeric settings and camera mode ---

new_case
set_conf "CAMERA_IDLE_SECONDS=300" "CAMERA_STALL_SECONDS=abc" "CAMERA_WAKE_TIMEOUT_SECONDS=999"
check "a valid number is used" "300" "$(lib vs_number CAMERA_IDLE_SECONDS 180 30 86400)"
check "a non-numeric value falls back" "20" "$(lib vs_number CAMERA_STALL_SECONDS 20 10 600)"
check "an out-of-range value falls back" "15" "$(lib vs_number CAMERA_WAKE_TIMEOUT_SECONDS 15 1 120)"

new_case
printf '123.45 678.90\n' > "$VS_DIR/uptime"
check "the clock counts seconds since boot" "123" "$(VS_UPTIME_FILE="$VS_DIR/uptime" lib vs_now)"
check "the clock falls back to wall time without an uptime file" "yes" "$(n=$(VS_UPTIME_FILE="$VS_DIR/missing" lib vs_now); [ "$n" -gt 1700000000 ] && echo yes || echo no)"

new_case
check "camera mode defaults to on_demand" "on_demand" "$(lib vs_camera_mode)"
set_conf "CAMERA_MODE=always"
check "camera mode can be always" "always" "$(lib vs_camera_mode)"
set_conf "CAMERA_MODE=sometimes"
check "an invalid camera mode falls back to on_demand" "on_demand" "$(lib vs_camera_mode)"

# --- Stopping processes ---

new_case
touch "$VS_STATE/running_video_monitor"
lib vs_stop video_monitor
check "stop ends a process that exits" "no" "$(exists "$VS_STATE/running_video_monitor")"
lacks "stop does not kill a process that exits" "killall -KILL" "$(calls)"

new_case
touch "$VS_STATE/running_video_monitor" "$VS_STATE/hung_video_monitor"
VS_STOP_GRACE_SECONDS=1 lib vs_stop video_monitor
contains "stop kills a hung process after the grace period" "killall -KILL video_monitor" "$(calls)"
check "a hung process is gone after stop" "no" "$(exists "$VS_STATE/running_video_monitor")"
contains "killing a hung process is logged" "video_monitor did not exit within 1s; killing it" "$(cat "$VS_LOG")"

new_case
lib vs_stop video_monitor
STATUS=$?
check "stopping a process that is not running succeeds" "0" "$STATUS"
lacks "stopping a process that is not running does not kill" "killall -KILL" "$(calls)"

# --- go2rtc stream info ---

new_case
cat > "$VS_STATE/streams.json" <<'EOF'
{
  "producers": [
    {
      "id": 7,
      "format_name": "bitstream",
      "receivers": [
        {
          "id": 8,
          "bytes_recv": 5
        }
      ],
      "bytes_recv": 123456
    },
    {
      "url": "exec:arecord",
      "bytes_recv": 999999
    }
  ],
  "consumers": [
    {
      "bytes_recv": 777
    }
  ]
}
EOF
check "video bytes come from the first producer" "123456" "$(lib vs_camera_bytes)"

new_case
printf '{\n  "producers": [\n    {\n      "url": "echo:/data/vacuumstreamer/camera_wake.sh"\n    }\n  ],\n  "consumers": [\n    {\n      "bytes_recv": 777\n    }\n  ]\n}\n' > "$VS_STATE/streams.json"
check "a disconnected video source reports no bytes" "" "$(lib vs_camera_bytes)"

new_case
printf '{\n  "producers": [],\n  "consumers": [\n    {\n      "bytes_recv": 777\n    }\n  ]\n}\n' > "$VS_STATE/streams.json"
check "an empty producer list reports no bytes" "" "$(lib vs_camera_bytes)"

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

# --- Camera wake ---

new_case
OUT=$($TEST_SH "$VS_DIR/camera_wake.sh" 2>/dev/null)
STATUS=$?
check "wake: succeeds" "0" "$STATUS"
check "wake: prints only the stream address" "tcp://127.0.0.1:6969" "$OUT"
check "wake: starts video_monitor" "yes" "$(exists "$VS_STATE/running_video_monitor")"
check "wake: records the wake time" "yes" "$(exists "$VS_RUN_DIR/camera_last_wake")"

new_case
touch "$VS_STATE/running_video_monitor" "$VS_STATE/listening"
OUT=$($TEST_SH "$VS_DIR/camera_wake.sh" 2>/dev/null)
check "wake with video_monitor running: prints the address" "tcp://127.0.0.1:6969" "$OUT"
lacks "wake with video_monitor running: does not start another" "starting video_monitor" "$(cat "$VS_LOG" 2>/dev/null)"

new_case
set_conf "CAMERA=off"
run_script "$VS_DIR/camera_wake.sh"
check "wake: refused while the camera is off" "1" "$STATUS"
lacks "wake: no address while the camera is off" "tcp://" "$OUT"
check "wake: nothing started while the camera is off" "no" "$(exists "$VS_STATE/running_video_monitor")"

new_case
set_run_state camera_paused ""
run_script "$VS_DIR/camera_wake.sh"
check "wake: refused while paused" "1" "$STATUS"
contains "wake: explains the pause" "camera paused" "$OUT"

new_case
set_conf "CAMERA_WAKE_TIMEOUT_SECONDS=1"
touch "$VS_STATE/never_listen"
run_script "$VS_DIR/camera_wake.sh"
check "wake: refused when video_monitor never listens" "1" "$STATUS"
contains "wake: explains the timeout" "did not open port 6969 within 1s" "$OUT"

new_case
set_conf "CAMERA_WAKE_TIMEOUT_SECONDS=1"
touch "$VS_STATE/lock_held"
run_script "$VS_DIR/camera_wake.sh"
check "wake: gives up when another wake holds the lock" "1" "$STATUS"
contains "wake: explains the held lock" "timed out waiting for another camera wake" "$OUT"
check "wake: starts nothing while another wake holds the lock" "no" "$(exists "$VS_STATE/running_video_monitor")"

new_case
set_conf "CAMERA_WAKE_TIMEOUT_SECONDS=5"
touch "$VS_STATE/lock_held"
( sleep 1; rm -f "$VS_STATE/lock_held" ) &
OUT=$($TEST_SH "$VS_DIR/camera_wake.sh" 2>/dev/null)
STATUS=$?
wait
check "wake: proceeds once the other wake releases the lock" "0" "$STATUS"
check "wake: prints the address after waiting for the lock" "tcp://127.0.0.1:6969" "$OUT"

# --- Supervisor ---

new_case
supervise 1000
wait_for "$VS_STATE/running_go2rtc"
check "supervisor starts go2rtc when it is not running" "yes" "$(exists "$VS_STATE/running_go2rtc")"
check "supervisor backs off after starting go2rtc" "1005" "$(cat "$VS_RUN_DIR/go2rtc_next_try")"

new_case
set_run_state go2rtc_failures 3
set_run_state go2rtc_next_try 900
supervise 1000
check "repeated go2rtc failures back off longer" "1060" "$(cat "$VS_RUN_DIR/go2rtc_next_try")"

new_case
set_run_state go2rtc_next_try 2000
supervise 1000
sleep 0.3
check "supervisor waits for the backoff before restarting go2rtc" "no" "$(exists "$VS_STATE/running_go2rtc")"

new_case
touch "$VS_STATE/running_go2rtc"
set_run_state go2rtc_failures 4
set_run_state go2rtc_started_at 900
supervise 1000
check "a go2rtc that stays up for a minute resets its failures" "0" "$(cat "$VS_RUN_DIR/go2rtc_failures")"

new_case
set_conf "CAMERA_LOGIN=on"
supervise 1000
sleep 0.3
check "supervisor does not start go2rtc with a misconfigured login" "no" "$(exists "$VS_STATE/running_go2rtc")"
contains "supervisor logs the login problem" "supervisor: go2rtc not started" "$(cat "$VS_LOG")"
check "supervisor rechecks a misconfigured login after a minute" "1060" "$(cat "$VS_RUN_DIR/go2rtc_next_try")"

new_case
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor" "$VS_STATE/listening"
set_run_state camera_last_active 800
supervise 1000
contains "on demand: an idle video_monitor is stopped" "killall video_monitor" "$(calls)"

new_case
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor" "$VS_STATE/listening"
set_run_state camera_last_active 900
supervise 1000
lacks "on demand: a recently watched video_monitor keeps running" "killall video_monitor" "$(calls)"

new_case
set_conf "CAMERA_IDLE_SECONDS=60"
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor" "$VS_STATE/listening"
set_run_state camera_last_active 900
supervise 1000
contains "on demand: CAMERA_IDLE_SECONDS sets the idle period" "killall video_monitor" "$(calls)"

new_case
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor" "$VS_STATE/listening"
set_run_state camera_last_active 100
set_run_state camera_last_wake 950
supervise 1000
lacks "on demand: a recent wake counts as activity" "killall video_monitor" "$(calls)"

new_case
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor" "$VS_STATE/listening" "$VS_STATE/connected"
set_run_state camera_last_active 100
supervise 1000
lacks "a connected viewer keeps video_monitor running" "killall video_monitor" "$(calls)"
check "a connected viewer updates the activity time" "1000" "$(cat "$VS_RUN_DIR/camera_last_active")"

new_case
set_conf "CAMERA_MODE=always"
touch "$VS_STATE/running_go2rtc"
supervise 1000
wait_for "$VS_STATE/running_video_monitor"
check "always: video_monitor is started" "yes" "$(exists "$VS_STATE/running_video_monitor")"

new_case
set_conf "CAMERA_MODE=always"
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor" "$VS_STATE/listening"
set_run_state camera_last_active 0
supervise 1000
lacks "always: an unwatched video_monitor keeps running" "killall video_monitor" "$(calls)"

new_case
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor" "$VS_STATE/listening" "$VS_STATE/connected"
printf '{\n  "producers": [\n    {\n      "bytes_recv": 5000\n    }\n  ],\n  "consumers": []\n}\n' > "$VS_STATE/streams.json"
set_run_state camera_bytes 5000
set_run_state camera_bytes_since 970
supervise 1000
contains "stall: video_monitor restarts when no video arrives" "killall video_monitor" "$(calls)"

new_case
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor" "$VS_STATE/listening" "$VS_STATE/connected" "$VS_STATE/hung_video_monitor"
printf '{\n  "producers": [\n    {\n      "bytes_recv": 5000\n    }\n  ],\n  "consumers": []\n}\n' > "$VS_STATE/streams.json"
set_run_state camera_bytes 5000
set_run_state camera_bytes_since 970
VS_STOP_GRACE_SECONDS=1 supervise 1000
contains "stall: a hung video_monitor is killed" "killall -KILL video_monitor" "$(calls)"
check "stall: the hung video_monitor is gone" "no" "$(exists "$VS_STATE/running_video_monitor")"

new_case
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor" "$VS_STATE/listening" "$VS_STATE/connected"
printf '{\n  "producers": [\n    {\n      "bytes_recv": 5000\n    }\n  ],\n  "consumers": []\n}\n' > "$VS_STATE/streams.json"
set_run_state camera_bytes 4000
set_run_state camera_bytes_since 900
supervise 1000
lacks "flowing video is not treated as a stall" "killall video_monitor" "$(calls)"
check "flowing video updates the byte count" "5000" "$(cat "$VS_RUN_DIR/camera_bytes")"
check "flowing video resets the stall timer" "1000" "$(cat "$VS_RUN_DIR/camera_bytes_since")"

new_case
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor"
set_run_state camera_paused ""
supervise 1000
contains "paused: go2rtc is kept stopped" "killall go2rtc" "$(calls)"
contains "paused: video_monitor is kept stopped" "killall video_monitor" "$(calls)"

new_case
set_run_state camera_paused ""
supervise 1000
sleep 0.3
check "paused: go2rtc is not restarted" "no" "$(exists "$VS_STATE/running_go2rtc")"

new_case
set_conf "CAMERA=off"
touch "$VS_STATE/running_go2rtc"
supervise 1000
check "camera off: the supervisor exits its loop" "1" "$STATUS"
contains "camera off: the supervisor stops go2rtc" "killall go2rtc" "$(calls)"

# --- Camera control ---

new_case
stub_supervisor
set_run_state camera_paused ""
run_script "$VS_DIR/camera_ctl.sh" start
check "start: succeeds" "0" "$STATUS"
check "start: clears the pause" "no" "$(exists "$VS_RUN_DIR/camera_paused")"
wait_for "$VS_STATE/running_go2rtc"
check "start: go2rtc is running" "yes" "$(exists "$VS_STATE/running_go2rtc")"
check "start: video_monitor is awake" "yes" "$(exists "$VS_STATE/running_video_monitor")"
wait_for "$VS_STATE/supervisor_started"
check "start: the supervisor is started" "yes" "$(exists "$VS_STATE/supervisor_started")"

new_case
stub_supervisor
set_conf "CAMERA=off"
run_script "$VS_DIR/camera_ctl.sh" start
check "start: refused while the camera is off" "75" "$STATUS"

new_case
stub_supervisor
set_conf "CAMERA_LOGIN=on"
set_run_state camera_paused ""
run_script "$VS_DIR/camera_ctl.sh" start
check "start: refused with a misconfigured login" "78" "$STATUS"
contains "start: explains the login problem" "camera_ctl: CAMERA_LOGIN=on requires" "$OUT"
check "start: a refused start stays paused" "yes" "$(exists "$VS_RUN_DIR/camera_paused")"

new_case
stub_supervisor
set_conf "CAMERA_WAKE_TIMEOUT_SECONDS=1"
touch "$VS_STATE/never_listen"
run_script "$VS_DIR/camera_ctl.sh" start
check "start: fails when video_monitor never listens" "1" "$STATUS"
contains "start: points to the log" "video_monitor did not start" "$OUT"

new_case
touch "$VS_STATE/running_go2rtc" "$VS_STATE/running_video_monitor"
run_script "$VS_DIR/camera_ctl.sh" stop
check "stop: succeeds" "0" "$STATUS"
check "stop: pauses the camera" "yes" "$(exists "$VS_RUN_DIR/camera_paused")"
contains "stop: stops go2rtc" "killall go2rtc" "$(calls)"
contains "stop: stops video_monitor" "killall video_monitor" "$(calls)"

new_case
set_conf "CAMERA_MODE=always"
touch "$VS_STATE/running_go2rtc" "$VS_STATE/connected"
run_script "$VS_DIR/camera_ctl.sh" status
check "status: reports the camera state" "$(printf 'camera=on\nmode=always\npaused=no\ngo2rtc=running\nvideo_monitor=stopped\nviewer=connected')" "$OUT"

new_case
run_script "$VS_DIR/camera_ctl.sh" restart
check "ctl: an unknown action is a usage error" "64" "$STATUS"

# --- Boot script ---

new_case
ACTIONS=$(boot_actions)
contains "boot mounts the video_monitor config" "run: mount --bind $VS_DIR/ava_conf_video_monitor /ava/conf/video_monitor" "$ACTIONS"
contains "boot mounts the private copy" "run: mount --bind $VS_DIR/mnt_private_copy /mnt/private" "$ACTIONS"
contains "boot sets the speaker mixer" "run: amixer cset numid=16 on" "$ACTIONS"
contains "boot starts the camera supervisor" "background: $VS_DIR/camera_supervisor.sh" "$ACTIONS"
lacks "boot leaves video_monitor to the supervisor" "video_monitor_launch" "$ACTIONS"
contains "boot starts the HTTP bridge" "background: vs_http_bridge_loop" "$ACTIONS"
contains "boot logs the switches" "boot: CAMERA=on CAMERA_MODE=on_demand CAMERA_LOGIN=off TTS=on MAP_MANAGEMENT=on HTTP_BRIDGE=on" "$(cat "$VS_LOG")"

new_case
set_conf "CAMERA=off"
ACTIONS=$(boot_actions)
lacks "camera off: boot does not start the supervisor" "camera_supervisor" "$ACTIONS"
contains "camera off: mounts still apply" "run: mount --bind" "$ACTIONS"
contains "camera off: the HTTP bridge still starts" "background: vs_http_bridge_loop" "$ACTIONS"

new_case
set_conf "HTTP_BRIDGE=off"
ACTIONS=$(boot_actions)
lacks "bridge off: boot does not start the bridge" "vs_http_bridge_loop" "$ACTIONS"
contains "bridge off: the camera supervisor still starts" "background: $VS_DIR/camera_supervisor.sh" "$ACTIONS"

new_case
rm "$VS_DIR/video_monitor"
ACTIONS=$(boot_actions)
check "without video_monitor installed boot does nothing" "" "$ACTIONS"

printf '%s passed, %s failed (shell: %s)\n' "$PASS" "$FAIL" "$TEST_SH"
[ "$FAIL" -eq 0 ]
