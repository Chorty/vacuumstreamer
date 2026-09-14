#!/bin/bash
# Archive /data, /mnt/private and /mnt/misc and verify every file against an
# on-robot SHA-256 manifest, then image the decrypted /dev/mapper/private view.
# The mounted /mnt/private is VacuumStreamer's bind-mounted copy, whose
# certificate.bin is a placeholder; the image keeps the original.
#
# Usage: tools/backup_robot.sh PACKAGE_DIR
set -u
. "$(dirname "$0")/lib.sh"

PKG="${1:?usage: backup_robot.sh PACKAGE_DIR}"
TS=$(date +%Y%m%d_%H%M%S)
RB="$PKG/robot_backup_$TS"
mkdir -p "$RB" && chmod 700 "$PKG" "$RB"
say "backup directory $RB"

rsh_n 'find /data /mnt/private /mnt/misc -xdev -type f ! -path /data/ava_reboot_cnt -exec sha256sum {} +' > "$RB/robot_files.sha256"
say "manifest files: $(wc -l < "$RB/robot_files.sha256" | tr -d ' ')"

A="$RB/vacuum_predeploy_$TS.tar.gz"
rsh_n 'tar -czf - --exclude=data/ava_reboot_cnt /data /mnt/private /mnt/misc 2>/dev/null' > "$A"
say "archive $(stat -f %z "$A") bytes"
gzip -t "$A" || fail "gzip test failed"
say "archive entries: $(tar -tzf "$A" | wc -l | tr -d ' ')"

V=$(mktemp -d)
trap 'rm -rf "$V"' EXIT
tar -xzf "$A" -C "$V" 2>>"$TOOL_LOG" || fail "archive extraction failed (disk space?)"
: > "$WORK_DIR/robot_files.check" || fail "cannot write $WORK_DIR/robot_files.check"
# shasum -c exits non-zero for unreadable files, which are re-checked below, so
# judge completeness by the number of result lines instead of its exit status.
(cd "$V" && sed 's#  /#  #' "$RB/robot_files.sha256" | shasum -a 256 -c 2>/dev/null) > "$WORK_DIR/robot_files.check"
[ "$(wc -l < "$WORK_DIR/robot_files.check" | tr -d ' ')" = "$(wc -l < "$RB/robot_files.sha256" | tr -d ' ')" ] || fail "extraction check incomplete (disk space?)"

# Files without read permission (for example /data/valetudo.bak, mode 0111)
# cannot be opened after extraction; verify them from the archive stream.
# Firmware counters that are rewritten while the robot runs may legitimately
# differ between the manifest and the archive; they must still be archived.
VOLATILE="/mnt/misc/totalruntime"
EMPTY_SHA256=$(printf '' | shasum -a 256 | cut -d' ' -f1)
is_volatile() {
    local v
    for v in $VOLATILE; do [ "$1" = "$v" ] && return 0; done
    return 1
}
not_ok=0
while IFS= read -r line; do
    name="${line%%: *}"
    want=$(awk -v p="/$name" '$2 == p {print $1}' "$RB/robot_files.sha256")
    got=$(tar -xOzf "$A" "$name" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
        say "verified from archive stream: /$name"
    elif [ -n "$got" ] && [ "$got" != "$EMPTY_SHA256" ] && is_volatile "/$name"; then
        say "changed during backup (live counter, archived as read): /$name"
    else
        say "MISMATCH /$name"
        not_ok=$((not_ok + 1))
    fi
done < <(grep -v ': OK$' "$WORK_DIR/robot_files.check")
say "files verified: $(grep -c ': OK$' "$WORK_DIR/robot_files.check") by extraction, mismatches: $not_ok"
[ "$not_ok" -eq 0 ] || fail "archive does not match the on-robot manifest"

for req in data/valetudo data/_root_postboot.sh data/valetudo_watchdog.sh data/valetudo_config.json data/vacuumstreamer/go2rtc.yaml data/vacuumstreamer/tts_handler.sh data/config/ava/mult_map.json mnt/misc/authorized_keys mnt/private; do
    [ -e "$V/$req" ] || fail "required path missing from archive: $req"
done
say "required paths present; archive SHA-256 $(sha256 "$A")"

SECTORS=$(rsh_n 'for d in /sys/block/dm-*; do [ "$(cat $d/dm/name 2>/dev/null)" = private ] && cat $d/size; done')
if [ -n "$SECTORS" ] && [ "$SECTORS" -gt 0 ] && [ "$SECTORS" -le 524288 ]; then
    R=$(rsh_n 'dd if=/dev/mapper/private bs=65536 2>/dev/null | sha256sum' | cut -d' ' -f1)
    rsh_n 'dd if=/dev/mapper/private bs=65536 2>/dev/null' > "$RB/private_partition.img"
    [ "$(sha256 "$RB/private_partition.img")" = "$R" ] || fail "private partition image hash mismatch"
    say "private partition image $(stat -f %z "$RB/private_partition.img") bytes, SHA-256 $R (matches the robot)"
else
    say "private partition image skipped (size ${SECTORS:-unknown} sectors)"
fi

chmod 600 "$RB"/*
touch "$RB/.ok"
say "DONE $RB"
