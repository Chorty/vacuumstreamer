#!/bin/bash
# Build the ARM64 Valetudo binary the way manual_build.yml does, from a clean
# clone checked out detached at COMMIT, so the binary embeds the commit and the
# OpenAPI schema. Optionally store the artifact in a backup package.
#
# Usage: tools/build_valetudo.sh COMMIT [PACKAGE_DIR]
set -u
. "$(dirname "$0")/lib.sh"

COMMIT_ARG="${1:?usage: build_valetudo.sh COMMIT [PACKAGE_DIR]}"
PKG="${2:-}"
COMMIT=$(git -C "$VALETUDO_REPO" rev-parse "$COMMIT_ARG^{commit}") || fail "unknown commit $COMMIT_ARG"
SHORT="${COMMIT:0:8}"
C="$WORK_DIR/build-$SHORT"
PLUGIN_GITDIR="$VALETUDO_REPO/.git/modules/vacuumstreamer-plugin"

step() {
    local name="$1"; shift
    say "step $name"
    ( "$@" ) >> "$TOOL_LOG" 2>&1 || fail "step $name failed; see $TOOL_LOG"
}

rm -rf "$C"
step clone git clone -q --no-checkout "$VALETUDO_REPO" "$C"
cd "$C" || fail "cd $C"
step checkout git -c advice.detachedHead=false checkout -q --detach "$COMMIT"
step submodule_init git submodule init
git config submodule.vacuumstreamer-plugin.url "$PLUGIN_GITDIR"
step submodule_update git -c protocol.file.allow=always submodule update
say "source: parent $(git rev-parse HEAD) (HEAD file: $(cat .git/HEAD)), plugin $(git -C vacuumstreamer-plugin rev-parse HEAD)"
step pkg_cache rsync -a "$VALETUDO_REPO/build_dependencies/pkg/" build_dependencies/pkg/
step npm_ci npm ci
step openapi npm run build_openapi_schema
step generate_code npm run generate_code --workspace=backend
step lint npm run lint_all
step ts_check npm run ts-check_all
step test npm test --workspace=backend
step frontend npm run build --workspace=frontend
BEFORE=$(wc -l < "$TOOL_LOG")
step aarch64 npm run build_aarch64 --workspace=backend

A="$C/build/aarch64/valetudo"
META=$(cat backend/lib/res/build_metadata.json)
echo "$META" | grep -q "\"commit\":\"$COMMIT\"" || fail "build metadata does not name $COMMIT: $META"
[ -s backend/lib/res/valetudo.openapi.schema.json ] || fail "OpenAPI schema missing"
WARNINGS=$(tail -n +"$BEFORE" "$TOOL_LOG" | grep -c '> Warning')
[ "$WARNINGS" -eq 0 ] || fail "pkg printed $WARNINGS warnings"
SHA=$(sha256 "$A")
say "artifact $A"
say "SHA-256 $SHA, $(stat -f %z "$A") bytes, $(file -b "$A")"
say "metadata $META"

if [ -n "$PKG" ]; then
    AD="$PKG/artifact_$SHORT"
    mkdir -p "$AD" && chmod 700 "$PKG" "$AD"
    cp "$A" "$AD/valetudo-aarch64"
    cp backend/lib/res/build_metadata.json "$AD/build_metadata.json"
    {
        echo "Built: $(date '+%F %T %Z') by tools/build_valetudo.sh"
        echo "Source: clean clone detached at $COMMIT"
        echo "Plugin: $(git -C vacuumstreamer-plugin rev-parse HEAD)"
        echo "Steps: npm ci; build_openapi_schema; generate_code; lint_all; ts-check_all; backend tests; frontend build; build_aarch64"
        echo "Embedded metadata: $META"
        echo "Artifact SHA-256: $SHA"
        echo "Architecture: $(file -b "$A")"
    } > "$AD/BUILD_RECORD.txt"
    chmod 600 "$AD"/*
    [ "$(sha256 "$AD/valetudo-aarch64")" = "$SHA" ] || fail "package copy hash mismatch"
    say "stored in $AD"
fi
say "DONE $SHA"
