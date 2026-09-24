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
robot_docked_idle || fail "robot is not docked with an idle dock"

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

# The gate outlives this SSH session, so it reads the login from a private
# file (empty without one) and deletes it when it finishes.
valetudo_auth_config | rsh 'umask 077; cat > /tmp/vs_binary_gate.auth' || fail "could not stage the Valetudo login for the gate"
rsh 'cat > /tmp/vs_binary_gate.sh && chmod 700 /tmp/vs_binary_gate.sh' <<'GATE'
#!/bin/sh
DEPLOY="$1"
trap 'rm -f /tmp/vs_binary_gate.auth' EXIT
CAND=/data/valetudo.candidate_$DEPLOY
PREV=/data/valetudo.predeploy_$DEPLOY
RESULT=/tmp/vs_binary_gate.result
log() { echo "$(date -u +%T) $*"; }
healthy() {
    [ "$(curl -K /tmp/vs_binary_gate.auth -s -o /dev/null -m 4 -w '%{http_code}' http://127.0.0.1/)" = 200 ] &&
    [ "$(curl -K /tmp/vs_binary_gate.auth -s -o /dev/null -m 4 -w '%{http_code}' http://127.0.0.1/api/v2/robot)" = 200 ]
}
# 12 consecutive healthy checks 5 s apart (60 s) within 240 s
gate() {
    ok=0; end=$(($(date +%s) + 240))
    while [ "$(date +%s)" -lt "$end" ]; do
        if healthy; then ok=$((ok + 1)); log "healthy $ok/12"; [ "$ok" -ge 12 ] && return 0
        else ok=0; log "not healthy"; fi
        sleep 5
    done
    return 1
}
echo running > $RESULT
log "activating candidate"
mv -f "$CAND" /data/valetudo && sync
killall valetudo
sleep 8
if gate; then echo "passed $(sha256sum /data/valetudo | cut -d' ' -f1)" > $RESULT; log "gate passed"; exit 0; fi
log "gate failed; rolling back"
cp -p "$PREV" /data/valetudo.rollback_tmp && mv -f /data/valetudo.rollback_tmp /data/valetudo && sync
killall valetudo
sleep 8
if gate; then echo "rolled_back $(sha256sum /data/valetudo | cut -d' ' -f1)" > $RESULT; else echo "rollback_unhealthy" > $RESULT; fi
GATE
rsh_n "rm -f /tmp/vs_binary_gate.result; setsid nohup /tmp/vs_binary_gate.sh $DEPLOY > /tmp/vs_binary_gate.out 2>&1 < /dev/null &"
say "on-robot gate started"

R=""
end=$(($(date +%s) + 600))
while [ "$(date +%s)" -lt "$end" ]; do
    R=$(rsh_n 'cat /tmp/vs_binary_gate.result 2>/dev/null' 2>/dev/null)
    case "$R" in passed*|rolled_back*|rollback_unhealthy*) break ;; esac
    sleep 10
done
rsh_n 'cat /tmp/vs_binary_gate.out' >> "$TOOL_LOG" 2>&1
say "gate result: ${R:-timeout}"
[ "$R" = "passed $EXPECTED" ] || fail "binary gate did not pass"

say "runtime version: $(vcurl -s -m 5 "http://$VACUUM_IP/api/v2/valetudo/version")"
say "watchdog processes: $(rsh_n 'ps w | grep -c "[v]aletudo_watchdog"')"
echo "$EXPECTED" > "$MARK.binary_passed"
say "DONE binary gate passed"
