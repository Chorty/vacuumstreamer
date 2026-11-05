#!/bin/bash
# Install the pinned official Caddy v2.11.4 Linux ARM64 binary. This does not
# enable HTTPS or reboot the robot; HTTPS_PROXY stays off until certs are ready.
# Usage: tools/install_caddy.sh PATH_TO_CADDY DEPLOY_ID
set -u
. "$(dirname "$0")/lib.sh"

ARTIFACT="${1:?usage: install_caddy.sh PATH_TO_CADDY DEPLOY_ID}"
DEPLOY="${2:?usage: install_caddy.sh PATH_TO_CADDY DEPLOY_ID}"
check_id "$DEPLOY"
EXPECTED=e1f904038fc11ca897ac5a12fdacfb2a7add02a8720c426d562a37f6fdad2afe
[ -f "$ARTIFACT" ] && [ "$(sha256 "$ARTIFACT")" = "$EXPECTED" ] || fail "Caddy binary differs from pinned v2.11.4 release"
valetudo_auth_preflight || fail "Valetudo authentication preflight failed; Caddy not installed"
robot_docked_idle_cached || fail "robot is not docked with an idle dock"

DEST=/data/vacuumstreamer/caddy
CURRENT=$(remote_sha256 "$DEST" 2>/dev/null)
if [ "$CURRENT" = "$EXPECTED" ]; then
    say "pinned Caddy already installed"
    exit 0
fi
if [ -n "$CURRENT" ]; then
    rsh_n "[ -e '$DEST.predeploy_$DEPLOY' ] || cp -p '$DEST' '$DEST.predeploy_$DEPLOY'" || fail "could not preserve existing Caddy"
    [ "$(remote_sha256 "$DEST.predeploy_$DEPLOY")" = "$CURRENT" ] || fail "Caddy backup hash mismatch"
fi

rsh "umask 077; cat > '$DEST.new_$DEPLOY' && chmod 755 '$DEST.new_$DEPLOY'" < "$ARTIFACT" || fail "Caddy upload failed"
[ "$(remote_sha256 "$DEST.new_$DEPLOY")" = "$EXPECTED" ] || fail "Caddy candidate hash mismatch"
rsh_n "mv -f '$DEST.new_$DEPLOY' '$DEST'" || fail "Caddy activation failed"
[ "$(remote_sha256 "$DEST")" = "$EXPECTED" ] || fail "installed Caddy hash mismatch"
say "installed pinned Caddy v2.11.4 ($EXPECTED); HTTPS_PROXY remains off"
