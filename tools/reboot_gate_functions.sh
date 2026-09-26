#!/bin/bash
# Sourced by deploy_reboot_gate.sh. Kept separate so the actual reboot/gate
# functions can be exercised with stubbed SSH and time in test/run_tests.sh.

reboot_and_wait() {
    local before now end
    before=$(rsh_n 'cat /proc/sys/kernel/random/boot_id')
    rsh_n 'sync; (sleep 2; reboot) > /dev/null 2>&1 &'
    say "reboot requested (boot_id $before)"
    end=$(($(date +%s) + 600))
    while [ "$(date +%s)" -lt "$end" ]; do
        sleep 10
        now=$(rsh_n 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)
        if [ -n "$now" ] && [ "$now" != "$before" ]; then
            say "robot back (boot_id $now)"
            return 0
        fi
    done
    return 1
}

new_healthy() {
    remote_vcurl_cached '. /data/vacuumstreamer/vacuumstreamer_lib.sh &&
           [ "$(vcode /)" = 200 ] && [ "$(vcode /api/v2/robot)" = 200 ] &&
           pidof valetudo > /dev/null && ps w | grep -q "[v]aletudo_watchdog" &&
           pidof go2rtc > /dev/null && ps w | grep -q "[c]amera_supervisor[.]sh" &&
           vs_bridge_healthy &&
           if [ "$(vs_switch HTTPS_PROXY off)" = on ]; then
               pidof caddy > /dev/null && vs_port_listening 443 &&
               [ "$(vcurl -o /dev/null -w "%{http_code}" --resolve mattjoslin-valetudo.duckdns.org:443:127.0.0.1 https://mattjoslin-valetudo.duckdns.org/api/v2/robot)" = 200 ]
           else
               true
           fi' 2>/dev/null
}

previous_healthy() {
    remote_vcurl_cached '[ "$(vcode /)" = 200 ] && [ "$(vcode /api/v2/robot)" = 200 ] &&
           pidof valetudo > /dev/null' 2>/dev/null
}

# gate CHECK - 12 consecutive passing checks 5 s apart within 300 s.
gate() {
    local check="$1" ok=0 end=$(($(date +%s) + 300))
    while [ "$(date +%s)" -lt "$end" ]; do
        if $check; then
            ok=$((ok + 1)); say "$check $ok/12"
            [ "$ok" -ge 12 ] && return 0
        else
            ok=0; say "$check failing"
        fi
        sleep 5
    done
    return 1
}
