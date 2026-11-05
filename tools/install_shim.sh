#!/bin/bash
# Stage between deploy_native.sh and deploy_reboot_gate.sh: install the pinned
# build of the capture shim, vacuumstreamer.so. deploy_native.sh exports tracked
# files with git archive, and *.so is gitignored, so it never installs the shim.
#
# The active file is replaced with an atomic mv, so a running video_monitor
# keeps its mapping. The new shim is first used after the reboot gate's reboot.
# That gate does not wake the camera, so this stage checks that the robot's
# loader accepts the candidate, and a camera wake afterwards is still required.
#
# EXPECTED is the build of vacuumstreamer.c at this commit. See "Capture shim" in
# tools/README.md; change it only together with the source.
#
# Usage: tools/install_shim.sh PATH_TO_SO DEPLOY_ID
set -u
. "$(dirname "$0")/lib.sh"

ARTIFACT="${1:?usage: install_shim.sh PATH_TO_SO DEPLOY_ID}"
DEPLOY="${2:?usage: install_shim.sh PATH_TO_SO DEPLOY_ID}"
check_id "$DEPLOY"
MARK="$WORK_DIR/deploy_$DEPLOY"
EXPECTED=2c541c63071f81ea85fdc9b1f2d4a198bbc26d0449e79ad355a8515ac2f6646e
DEST=/data/vacuumstreamer/vacuumstreamer.so
PRESERVED="$DEST.predeploy_$DEPLOY"
CANDIDATE="$DEST.new_$DEPLOY"

[ -f "$ARTIFACT" ] && [ "$(sha256 "$ARTIFACT")" = "$EXPECTED" ] || fail "shim differs from the pinned build"
[ -f "$MARK.native_installed" ] || fail "native stage for $DEPLOY has not run (tools/deploy_native.sh)"
[ -e "$MARK.reboot_passed" ] && fail "deploy ID $DEPLOY already passed its reboot gate; use a new ID"
valetudo_auth_preflight || fail "Valetudo authentication preflight failed; shim not installed"
robot_docked_idle_cached || fail "robot is not docked with an idle dock"

CURRENT=$(remote_sha256 "$DEST" 2>/dev/null)
[ -n "$CURRENT" ] || fail "cannot read the active shim"

# deploy_native.sh has normally preserved it already; a repeat run keeps that copy.
rsh_n "[ -e '$PRESERVED' ] || cp -p '$DEST' '$PRESERVED'" || fail "could not preserve the active shim"
PREVIOUS=$(remote_sha256 "$PRESERVED")
[ -n "$PREVIOUS" ] || fail "cannot read $PRESERVED"
[ "$CURRENT" = "$EXPECTED" ] || [ "$PREVIOUS" = "$CURRENT" ] || fail "$PRESERVED does not hold the active shim"
say "preserved the active shim as $PRESERVED ($PREVIOUS)"

if [ "$CURRENT" = "$EXPECTED" ]; then
    say "pinned shim already installed"
else
    candidate_failed() {
        rsh_n "rm -f '$CANDIDATE'" > /dev/null 2>&1
        fail "$1"
    }
    rsh "umask 077; cat > '$CANDIDATE' && chmod 755 '$CANDIDATE'" < "$ARTIFACT" || candidate_failed "shim upload failed"
    [ "$(remote_sha256 "$CANDIDATE")" = "$EXPECTED" ] || candidate_failed "shim candidate hash mismatch"

    # ld.so reports a preload it cannot use and still exits 0, so any output
    # counts as a failure. The shim has no constructor, so this starts nothing.
    LOAD_OUTPUT=$(rsh_n "LD_PRELOAD='$CANDIDATE' /bin/true 2>&1")
    LOAD_STATUS=$?
    [ "$LOAD_STATUS" -eq 0 ] && [ -z "$LOAD_OUTPUT" ] ||
        candidate_failed "the robot's loader rejected the shim (status $LOAD_STATUS): $LOAD_OUTPUT"
    say "the robot's loader accepted the candidate"

    rsh_n "mv -f '$CANDIDATE' '$DEST' && sync" || candidate_failed "shim activation failed"
    [ "$(remote_sha256 "$DEST")" = "$EXPECTED" ] || fail "installed shim hash mismatch; restore $PRESERVED"
fi

echo "$EXPECTED" > "$MARK.shim_installed"
echo "$PREVIOUS" > "$MARK.shim_previous_sha"
say "DONE installed pinned shim $EXPECTED; run deploy_reboot_gate.sh, then wake the camera"
