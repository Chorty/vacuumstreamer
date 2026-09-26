#!/bin/bash
# Stage 3: reboot and require 12 consecutive health checks. On failure, restore
# the binary, boot script and go2rtc.yaml from the .predeploy copies, reboot
# again and check the previous setup.
#
# Usage: tools/deploy_reboot_gate.sh ARTIFACT_SHA256 VALETUDO_COMMIT DEPLOY_ID
set -u
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/reboot_gate_functions.sh"

EXPECTED="${1:?usage: deploy_reboot_gate.sh ARTIFACT_SHA256 VALETUDO_COMMIT DEPLOY_ID}"
COMMIT="${2:?usage: deploy_reboot_gate.sh ARTIFACT_SHA256 VALETUDO_COMMIT DEPLOY_ID}"
DEPLOY="${3:?usage: deploy_reboot_gate.sh ARTIFACT_SHA256 VALETUDO_COMMIT DEPLOY_ID}"
check_id "$DEPLOY"
MARK="$WORK_DIR/deploy_$DEPLOY"
[ -f "$MARK.native_installed" ] || fail "native stage for $DEPLOY has not run (tools/deploy_native.sh)"
PREVIOUS_SHA=$(cat "$MARK.previous_sha" 2>/dev/null)
[ -n "$PREVIOUS_SHA" ] || fail "previous binary hash for $DEPLOY unknown"
valetudo_auth_preflight || fail "Valetudo authentication preflight failed; reboot not attempted"
robot_docked_idle_cached || fail "robot is not docked with an idle dock"

if reboot_and_wait && gate new_healthy &&
   [ "$(remote_sha256 /data/valetudo)" = "$EXPECTED" ] &&
   vcurl_cached -s -m 5 "http://$VACUUM_IP/api/v2/valetudo/version" | grep -q "$COMMIT"; then
    say "runtime version: $(vcurl_cached -s -m 5 "http://$VACUUM_IP/api/v2/valetudo/version")"
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
