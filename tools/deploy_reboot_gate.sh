#!/bin/bash
# Stage 3: reboot and require 12 consecutive health checks. On failure, restore
# the binary, boot script and go2rtc.yaml from the .predeploy copies, reboot
# again and check the previous setup.
#
# Usage: tools/deploy_reboot_gate.sh ARTIFACT_SHA256 VALETUDO_COMMIT DEPLOY_ID
set -u
. "$(dirname "$0")/lib.sh"

EXPECTED="${1:?usage: deploy_reboot_gate.sh ARTIFACT_SHA256 VALETUDO_COMMIT DEPLOY_ID}"
COMMIT="${2:?usage: deploy_reboot_gate.sh ARTIFACT_SHA256 VALETUDO_COMMIT DEPLOY_ID}"
DEPLOY="${3:?usage: deploy_reboot_gate.sh ARTIFACT_SHA256 VALETUDO_COMMIT DEPLOY_ID}"
check_id "$DEPLOY"
MARK="$WORK_DIR/deploy_$DEPLOY"
[ -f "$MARK.native_installed" ] || fail "native stage for $DEPLOY has not run (tools/deploy_native.sh)"
PREVIOUS_SHA=$(cat "$MARK.previous_sha" 2>/dev/null)
[ -n "$PREVIOUS_SHA" ] || fail "previous binary hash for $DEPLOY unknown"
robot_docked_idle || fail "robot is not docked with an idle dock"

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

# The HTTP bridge must be running exactly when vacuumstreamer.conf switches it
# on (HTTP_BRIDGE, default on); with it off, nothing may listen for it.
new_healthy() {
    valetudo_auth_config | rsh "$REMOTE_VCURL"'; . /data/vacuumstreamer/vacuumstreamer_lib.sh &&
           [ "$(vcode /)" = 200 ] && [ "$(vcode /api/v2/robot)" = 200 ] &&
           pidof valetudo > /dev/null && ps w | grep -q "[v]aletudo_watchdog" &&
           pidof go2rtc > /dev/null && ps w | grep -q "[c]amera_supervisor[.]sh" &&
           if [ "$(vs_switch HTTP_BRIDGE on)" = on ]; then
               ps w | grep -q "[h]ttp_bridge[.]sh" && pidof tcpsvd > /dev/null
           else
               ! pidof tcpsvd > /dev/null
           fi' 2>/dev/null
}

previous_healthy() {
    valetudo_auth_config | rsh "$REMOTE_VCURL"'; [ "$(vcode /)" = 200 ] && [ "$(vcode /api/v2/robot)" = 200 ] &&
           pidof valetudo > /dev/null' 2>/dev/null
}

# gate CHECK - 12 consecutive passing checks 5 s apart within 300 s
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

if reboot_and_wait && gate new_healthy &&
   [ "$(remote_sha256 /data/valetudo)" = "$EXPECTED" ] &&
   vcurl -s -m 5 "http://$VACUUM_IP/api/v2/valetudo/version" | grep -q "$COMMIT"; then
    say "runtime version: $(vcurl -s -m 5 "http://$VACUUM_IP/api/v2/valetudo/version")"
    say "boot log: $(rsh_n 'grep "boot:" /tmp/vacuumstreamer.log | tail -1')"
    say "camera: $(camera_status)"
    touch "$MARK.reboot_passed"
    say "DONE reboot gate passed"
    exit 0
fi

say "gate failed; rolling back the binary and every preserved native file"
PATHS=$(native_deployed_paths | tr '\n' ' ')
rsh_n "for p in $PATHS; do
           if [ -e \"\$p.predeploy_$DEPLOY\" ]; then
               cp -p \"\$p.predeploy_$DEPLOY\" \"\$p.rollback_tmp\" && mv -f \"\$p.rollback_tmp\" \"\$p\" || exit 1
           fi
       done
       cp -p /data/valetudo.predeploy_$DEPLOY /data/valetudo.rollback_tmp && mv -f /data/valetudo.rollback_tmp /data/valetudo && sync" ||
    fail "rollback copy failed; the robot needs manual attention"
if reboot_and_wait && gate previous_healthy && [ "$(remote_sha256 /data/valetudo)" = "$PREVIOUS_SHA" ]; then
    say "DONE rolled back to $PREVIOUS_SHA"
else
    say "DONE rollback unhealthy; the robot needs manual attention"
fi
exit 1
