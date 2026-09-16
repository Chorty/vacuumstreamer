#!/bin/bash
# Seal a backup package: write BACKUP_INFO.txt and SHA256SUMS.txt, then
# re-verify every file. Requires the backup and build tools to have finished.
#
# Usage: tools/seal_package.sh PACKAGE_DIR
set -u
. "$(dirname "$0")/lib.sh"

PKG="${1:?usage: seal_package.sh PACKAGE_DIR}"
[ -f "$PKG/ssh_credentials/.ok" ] || fail "SSH backup not finished (tools/backup_ssh.sh)"
[ -f "$PKG/hardware_identity/.ok" ] || fail "hardware backup not finished (tools/backup_hardware.sh)"
RB=$(ls -d "$PKG"/robot_backup_* 2>/dev/null | tail -1)
[ -n "$RB" ] && [ -f "$RB/.ok" ] || fail "robot backup not finished (tools/backup_robot.sh)"
ARCH=$(ls "$RB"/vacuum_predeploy_*.tar.gz)
ART=$(ls "$PKG"/artifact_*/valetudo-aarch64 2>/dev/null | tail -1)

{
    echo "VacuumStreamer / Valetudo deployment backup"
    echo "Sealed: $(date '+%F %T %Z')"
    echo "Robot: $VACUUM_IP ($VACUUM_SSH), active Valetudo SHA-256 $(remote_sha256 /data/valetudo)"
    echo
    echo "Robot file backup: ${RB#$PKG/}/$(basename "$ARCH")"
    echo "  SHA-256 $(sha256 "$ARCH"), $(stat -f %z "$ARCH") bytes"
    echo "  /data, /mnt/private (bind-mounted copy) and /mnt/misc, verified file by file against robot_files.sha256"
    [ -f "$RB/private_partition.img" ] && echo "  private_partition.img: decrypted /dev/mapper/private, SHA-256 $(sha256 "$RB/private_partition.img")"
    echo
    echo "Hardware identity and firmware: hardware_identity/ (see HARDWARE_SHA256SUMS.txt)"
    echo "  Encrypted private partition and misc/tee storage restore only to this SoC."
    echo
    echo "SSH access: ssh_credentials/ (Mac key, ssh config block, known_hosts, robot host keys and authorized_keys)"
    if [ -n "$ART" ]; then
        echo
        echo "Deployment artifact: ${ART#$PKG/}"
        echo "  SHA-256 $(sha256 "$ART"), $(stat -f %z "$ART") bytes; see BUILD_RECORD.txt"
    fi
    echo
    echo "This package contains device secrets and SSH keys. Keep it private."
} > "$PKG/BACKUP_INFO.txt"
chmod 600 "$PKG/BACKUP_INFO.txt"

(cd "$PKG" && find . -type f ! -name SHA256SUMS.txt ! -name .DS_Store ! -name DEPLOY_RECORD.txt ! -name .ok | sed 's#^\./##' | sort | while IFS= read -r f; do shasum -a 256 "$f"; done > SHA256SUMS.txt && chmod 600 SHA256SUMS.txt)
bad=$(cd "$PKG" && shasum -a 256 -c SHA256SUMS.txt 2>&1 | grep -vc ': OK$')
[ "$bad" -eq 0 ] || fail "$bad files failed re-verification"
say "DONE sealed $(wc -l < "$PKG/SHA256SUMS.txt" | tr -d ' ') files, all re-verified"
