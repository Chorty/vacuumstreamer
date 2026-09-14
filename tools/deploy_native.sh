#!/bin/bash
# Stage 2: install the native runtime files from a committed revision of this
# repository, keeping on-robot copies of the current boot script and
# go2rtc.yaml. New scripts go in first; go2rtc.yaml and the boot script last.
#
# Usage: tools/deploy_native.sh NATIVE_COMMIT DEPLOY_ID
set -u
. "$(dirname "$0")/lib.sh"

COMMIT_ARG="${1:?usage: deploy_native.sh NATIVE_COMMIT DEPLOY_ID}"
DEPLOY="${2:?usage: deploy_native.sh NATIVE_COMMIT DEPLOY_ID}"
check_id "$DEPLOY"
MARK="$WORK_DIR/deploy_$DEPLOY"
[ -f "$MARK.binary_passed" ] || fail "binary stage for $DEPLOY has not passed (tools/deploy_binary.sh)"

COMMIT=$(git -C "$NATIVE_REPO" rev-parse "$COMMIT_ARG^{commit}") || fail "unknown commit $COMMIT_ARG"
E=$(mktemp -d)
trap 'rm -rf "$E"' EXIT
git -C "$NATIVE_REPO" archive "$COMMIT" | tar -x -C "$E" || fail "export of $COMMIT failed"
say "exported native commit $COMMIT"

rsh_n "[ -e /data/_root_postboot.sh.predeploy_$DEPLOY ] || cp -p /data/_root_postboot.sh /data/_root_postboot.sh.predeploy_$DEPLOY
       [ -e /data/vacuumstreamer/go2rtc.yaml.predeploy_$DEPLOY ] || cp -p /data/vacuumstreamer/go2rtc.yaml /data/vacuumstreamer/go2rtc.yaml.predeploy_$DEPLOY
       [ -e /data/_root_postboot.sh.predeploy_$DEPLOY ] && [ -e /data/vacuumstreamer/go2rtc.yaml.predeploy_$DEPLOY ]" ||
    fail "could not preserve the boot script and go2rtc.yaml"
say "preserved _root_postboot.sh and go2rtc.yaml as .predeploy_$DEPLOY"

install_file() { # SRC DEST MODE
    local src="$E/$1" dest="$2" mode="$3" want got
    want=$(sha256 "$src")
    rsh "cat > '$dest.new_$DEPLOY' && chmod $mode '$dest.new_$DEPLOY'" < "$src" || fail "upload $1"
    got=$(remote_sha256 "$dest.new_$DEPLOY")
    [ "$got" = "$want" ] || fail "hash mismatch for $1"
    rsh_n "mv -f '$dest.new_$DEPLOY' '$dest'" || fail "activate $1"
    say "installed $dest ($mode) $want"
}

SCRIPTS="vacuumstreamer_lib.sh go2rtc_launch.sh video_monitor_launch.sh camera_wake.sh camera_supervisor.sh camera_ctl.sh vacuumstreamer_boot.sh"
for f in $SCRIPTS; do
    install_file "$f" "/data/vacuumstreamer/$f" 755
done
for f in $SCRIPTS; do
    rsh_n "sh -n /data/vacuumstreamer/$f" || fail "robot syntax check failed for $f"
done
say "robot syntax check passed for all scripts"

if rsh_n '[ -e /data/vacuumstreamer/vacuumstreamer.conf ]'; then
    say "vacuumstreamer.conf already present; kept"
else
    install_file vacuumstreamer.conf /data/vacuumstreamer/vacuumstreamer.conf 644
fi

rsh_n '/data/vacuumstreamer/go2rtc_launch.sh --check' || fail "go2rtc_launch.sh --check failed on the robot"
say "camera status: $(camera_status)"

POSTBOOT_MODE=$(rsh_n 'stat -c %a /data/_root_postboot.sh')
install_file go2rtc.yaml /data/vacuumstreamer/go2rtc.yaml 644
install_file _root_postboot.sh /data/_root_postboot.sh "$POSTBOOT_MODE"
rsh_n 'sh -n /data/_root_postboot.sh' || fail "robot syntax check failed for _root_postboot.sh"

echo "$COMMIT" > "$MARK.native_installed"
say "DONE native files installed from $COMMIT"
