#!/bin/bash
# Raw, read-only images of every named partition except UDISK, plus the U-Boot
# environment, sunxi chip information and the dm-crypt mapping, each checked
# against the robot. The encrypted private partition and misc/tee storage only
# restore to the same SoC. rootfs and boot images hold the rooted firmware,
# including its authorized_keys and dropbear host keys.
#
# Usage: tools/backup_hardware.sh PACKAGE_DIR
set -u
. "$(dirname "$0")/lib.sh"

PKG="${1:?usage: backup_hardware.sh PACKAGE_DIR}"
HW="$PKG/hardware_identity"
mkdir -p "$HW" && chmod 700 "$PKG" "$HW"

PARTS=$(rsh_n 'for l in /dev/by-name/*; do n=$(basename $l); [ "$n" = UDISK ] || echo "$n $(( $(cat /sys/class/block/$(basename $(readlink -f $l))/size) * 512 ))"; done')
[ -n "$PARTS" ] || fail "no partitions listed"
mismatch=0

while read -r part bytes; do
    check_id "$part"
    if [ "$bytes" -le 16777216 ]; then
        # Small partitions: stage one read on the robot so the hash covers exactly what is copied
        R=$(rsh_n "dd if=/dev/by-name/$part of=/tmp/vs_part.img bs=65536 2>/dev/null && sha256sum /tmp/vs_part.img" | cut -d' ' -f1)
        rsh_n 'cat /tmp/vs_part.img' > "$HW/$part.img"
        rsh_n 'rm -f /tmp/vs_part.img'
    else
        # Large partitions are not mounted read-write, so two reads are identical
        R=$(rsh_n "dd if=/dev/by-name/$part bs=1048576 2>/dev/null | sha256sum" | cut -d' ' -f1)
        rsh_n "dd if=/dev/by-name/$part bs=1048576 2>/dev/null" > "$HW/$part.img"
    fi
    L=$(sha256 "$HW/$part.img"); got=$(stat -f %z "$HW/$part.img")
    if [ "$R" = "$L" ] && [ "$got" = "$bytes" ]; then
        say "PART ok $part $got bytes $L"
    else
        say "PART MISMATCH $part bytes=$got/$bytes remote=$R local=$L"
        mismatch=$((mismatch + 1))
    fi
done <<< "$PARTS"

rsh_n 'fw_printenv 2>/dev/null' > "$HW/uboot_env.txt"
say "U-Boot variables: $(grep -c = "$HW/uboot_env.txt"); boot slot: $(grep -E '^(boot_partition|root_partition)=' "$HW/uboot_env.txt" | tr '\n' ' ')"
rsh_n 'cat /sys/class/sunxi_info/sys_info 2>/dev/null' > "$HW/sunxi_sys_info.txt"
rsh_n 'cat /sys/class/sunxi_info/key_info 2>/dev/null' > "$HW/sunxi_key_info.txt"
rsh_n 'cat /sys/block/dm-0/dm/name /sys/block/dm-0/dm/uuid 2>/dev/null; ls /sys/block/dm-0/slaves' > "$HW/private_dm_mapping.txt"
chmod 600 "$HW"/*
(cd "$HW" && shasum -a 256 *.img *.txt > HARDWARE_SHA256SUMS.txt && chmod 600 HARDWARE_SHA256SUMS.txt)

[ "$mismatch" -eq 0 ] || fail "$mismatch partition images did not match the robot"
touch "$HW/.ok"
say "DONE $HW ($(du -sh "$HW" | cut -f1))"
