#!/bin/bash
# Stage 1 for a native-only deployment: keep the active Valetudo binary, but
# satisfy the same preconditions and leave the same rollback copy and markers
# as deploy_binary.sh, so deploy_native.sh and deploy_reboot_gate.sh run
# unchanged. /data/valetudo is never modified.
#
# Usage: tools/deploy_keep_binary.sh DEPLOY_ID PACKAGE_DIR
set -u
. "$(dirname "$0")/lib.sh"

DEPLOY="${1:?usage: deploy_keep_binary.sh DEPLOY_ID PACKAGE_DIR}"
PKG="${2:?usage: deploy_keep_binary.sh DEPLOY_ID PACKAGE_DIR}"
check_id "$DEPLOY"
MARK="$WORK_DIR/deploy_$DEPLOY"

[ -f "$PKG/SHA256SUMS.txt" ] || fail "backup package $PKG is not sealed (tools/seal_package.sh)"
[ -e "$MARK.binary_passed" ] && fail "deploy ID $DEPLOY already has a binary stage; use a new ID"
robot_docked_idle || fail "robot is not docked with an idle dock"
rsh_n '[ "$(curl -s -o /dev/null -m 4 -w "%{http_code}" http://127.0.0.1/)" = 200 ] &&
       [ "$(curl -s -o /dev/null -m 4 -w "%{http_code}" http://127.0.0.1/api/v2/robot)" = 200 ]' ||
    fail "Valetudo is not healthy"

ACTIVE_SHA=$(remote_sha256 /data/valetudo)
[ -n "$ACTIVE_SHA" ] || fail "cannot read the active binary"
say "preconditions ok: docked and idle, sealed package, Valetudo healthy, active $ACTIVE_SHA"

# The reboot gate's rollback restores /data/valetudo from this copy.
rsh_n "[ -e /data/valetudo.predeploy_$DEPLOY ] || cp -p /data/valetudo /data/valetudo.predeploy_$DEPLOY"
[ "$(remote_sha256 "/data/valetudo.predeploy_$DEPLOY")" = "$ACTIVE_SHA" ] || fail "/data/valetudo.predeploy_$DEPLOY does not hold the active binary"
say "preserved active binary as /data/valetudo.predeploy_$DEPLOY"

echo "$ACTIVE_SHA" > "$MARK.previous_sha"
echo "$ACTIVE_SHA" > "$MARK.binary_kept"
echo "$ACTIVE_SHA" > "$MARK.binary_passed"
say "DONE binary kept; run deploy_native.sh, then deploy_reboot_gate.sh $ACTIVE_SHA <running-valetudo-commit> $DEPLOY if a reboot is needed"
