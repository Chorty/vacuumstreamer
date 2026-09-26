#!/bin/bash
# Stage 1: upload a Valetudo binary as a candidate and activate it through an
# on-robot 60-second health gate that rolls back automatically. The gate runs
# on the robot, so a dropped SSH session cannot interrupt it.
#
# Usage: tools/deploy_binary.sh ARTIFACT DEPLOY_ID PACKAGE_DIR
set -u
. "$(dirname "$0")/lib.sh"

ARTIFACT="${1:?usage: deploy_binary.sh ARTIFACT DEPLOY_ID PACKAGE_DIR}"
DEPLOY="${2:?usage: deploy_binary.sh ARTIFACT DEPLOY_ID PACKAGE_DIR}"
PKG="${3:?usage: deploy_binary.sh ARTIFACT DEPLOY_ID PACKAGE_DIR}"
check_id "$DEPLOY"
MARK="$WORK_DIR/deploy_$DEPLOY"

[ -f "$ARTIFACT" ] || fail "artifact $ARTIFACT not found"
EXPECTED=$(sha256 "$ARTIFACT")
[ -f "$PKG/SHA256SUMS.txt" ] || fail "backup package $PKG is not sealed (tools/seal_package.sh)"
grep -q " $(basename "$(dirname "$ARTIFACT")")/$(basename "$ARTIFACT")$" "$PKG/SHA256SUMS.txt" && ! grep -q "^$EXPECTED " "$PKG/SHA256SUMS.txt" && fail "artifact differs from the sealed copy"
valetudo_auth_preflight || fail "Valetudo authentication preflight failed; nothing activated"
robot_docked_idle_cached || fail "robot is not docked with an idle dock"

ACTIVE_SHA=$(remote_sha256 /data/valetudo)
[ -n "$ACTIVE_SHA" ] || fail "cannot read the active binary"
[ "$ACTIVE_SHA" != "$EXPECTED" ] || fail "the artifact is already active"
say "preconditions ok: docked and idle, sealed package, active $ACTIVE_SHA, candidate $EXPECTED"

rsh_n "[ -e /data/valetudo.predeploy_$DEPLOY ] || cp -p /data/valetudo /data/valetudo.predeploy_$DEPLOY"
[ "$(remote_sha256 "/data/valetudo.predeploy_$DEPLOY")" = "$ACTIVE_SHA" ] || fail "/data/valetudo.predeploy_$DEPLOY does not hold the active binary"
echo "$ACTIVE_SHA" > "$MARK.previous_sha"
say "preserved active binary as /data/valetudo.predeploy_$DEPLOY"

rsh "cat > /data/valetudo.candidate_$DEPLOY && chmod 755 /data/valetudo.candidate_$DEPLOY" < "$ARTIFACT" || fail "upload failed"
[ "$(remote_sha256 "/data/valetudo.candidate_$DEPLOY")" = "$EXPECTED" ] || fail "candidate upload hash mismatch"
say "candidate uploaded and verified"

# The gate outlives SSH. Keep its curl config in a unique, root-only directory
# and make either this script or the detached gate remove it on every failure.
GATE_DIR=$(rsh_n 'umask 077; mktemp -d /tmp/vs_binary_gate.XXXXXX') || fail "could not create the gate directory"
case "$GATE_DIR" in /tmp/vs_binary_gate.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) ;; *) fail "unexpected gate directory" ;; esac
gate_upload_failed() {
    rsh_n "rm -rf '$GATE_DIR'" > /dev/null 2>&1
    fail "$1"
}
printf '%s\n' "$VS_AUTH_CONFIG" | rsh "umask 077; cat > '$GATE_DIR/auth' && chmod 600 '$GATE_DIR/auth'" ||
    gate_upload_failed "could not stage the Valetudo login for the gate"
rsh "umask 077; cat > '$GATE_DIR/gate.sh' && chmod 700 '$GATE_DIR/gate.sh'" < "$TOOLS_DIR/binary_gate.sh" ||
    gate_upload_failed "could not upload the binary gate"
rsh_n "sh -n '$GATE_DIR/gate.sh'" || gate_upload_failed "binary gate syntax check failed"
rsh_n "rm -f /tmp/vs_binary_gate.result; setsid nohup '$GATE_DIR/gate.sh' '$DEPLOY' '$GATE_DIR' > /tmp/vs_binary_gate.out 2>&1 < /dev/null & gate_pid=\$!; sleep 1; kill -0 \$gate_pid" ||
    gate_upload_failed "could not launch the binary gate"
say "on-robot gate started"

R=""
end=$(($(date +%s) + 600))
while [ "$(date +%s)" -lt "$end" ]; do
    R=$(rsh_n 'cat /tmp/vs_binary_gate.result 2>/dev/null' 2>/dev/null)
    case "$R" in passed*|rolled_back*|rollback_unhealthy*|activation_failed*|rollback_copy_failed*) break ;; esac
    sleep 10
done
rsh_n 'cat /tmp/vs_binary_gate.out' >> "$TOOL_LOG" 2>&1
say "gate result: ${R:-timeout}"
[ "$R" = "passed $EXPECTED" ] || fail "binary gate did not pass"

say "runtime version: $(vcurl_cached -s -m 5 "http://$VACUUM_IP/api/v2/valetudo/version")"
say "watchdog processes: $(rsh_n 'ps w | grep -c "[v]aletudo_watchdog"')"
echo "$EXPECTED" > "$MARK.binary_passed"
say "DONE binary gate passed"
