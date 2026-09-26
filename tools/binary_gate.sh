#!/bin/sh
# Detached stage-1 gate. The Mac uploads this into a private temporary
# directory along with a curl config that is removed by the EXIT trap.
set -u

DEPLOY="$1"
GATE_DIR="$2"
BASE="${3:-/data}"
RESULT="${4:-/tmp/vs_binary_gate.result}"
CAND="$BASE/valetudo.candidate_$DEPLOY"
PREV="$BASE/valetudo.predeploy_$DEPLOY"
ACTIVE="$BASE/valetudo"

trap 'rm -rf "$GATE_DIR"' EXIT
trap 'exit 1' HUP INT TERM

log() { echo "$(date -u +%T) $*"; }
healthy() {
    [ "$(curl -K "$GATE_DIR/auth" -s -o /dev/null -m 4 -w '%{http_code}' http://127.0.0.1/)" = 200 ] &&
    [ "$(curl -K "$GATE_DIR/auth" -s -o /dev/null -m 4 -w '%{http_code}' http://127.0.0.1/api/v2/robot)" = 200 ]
}
# 12 consecutive healthy checks 5 s apart (60 s) within 240 s.
gate() {
    ok=0; end=$(($(date +%s) + 240))
    while [ "$(date +%s)" -lt "$end" ]; do
        if healthy; then
            ok=$((ok + 1))
            log "healthy $ok/12"
            [ "$ok" -ge 12 ] && return 0
        else
            ok=0
            log "not healthy"
        fi
        sleep 5
    done
    return 1
}

echo running > "$RESULT"
log "activating candidate"
if ! mv -f "$CAND" "$ACTIVE"; then echo activation_failed > "$RESULT"; exit 1; fi
sync
killall valetudo || :
sleep 8
if gate; then
    echo "passed $(sha256sum "$ACTIVE" | cut -d' ' -f1)" > "$RESULT"
    log "gate passed"
    exit 0
fi

log "gate failed; rolling back"
if ! cp -p "$PREV" "$BASE/valetudo.rollback_tmp" ||
   ! mv -f "$BASE/valetudo.rollback_tmp" "$ACTIVE"; then
    echo rollback_copy_failed > "$RESULT"
    exit 1
fi
sync
killall valetudo || :
sleep 8
if gate; then
    echo "rolled_back $(sha256sum "$ACTIVE" | cut -d' ' -f1)" > "$RESULT"
else
    echo rollback_unhealthy > "$RESULT"
fi
