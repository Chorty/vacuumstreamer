#!/bin/bash
# Back up SSH access to the robot into PACKAGE_DIR/ssh_credentials: the Mac
# identity file, its ssh config block and known_hosts entry, and the robot's
# dropbear host keys and authorized_keys, verified against on-robot hashes.
#
# Usage: tools/backup_ssh.sh PACKAGE_DIR
set -u
. "$(dirname "$0")/lib.sh"

PKG="${1:?usage: backup_ssh.sh PACKAGE_DIR}"
C="$PKG/ssh_credentials"
mkdir -p "$C" && chmod 700 "$PKG" "$C"

KEY=$(ssh -G "$VACUUM_SSH" | awk '/^identityfile /{print $2; exit}' | sed "s#^~#$HOME#")
[ -f "$KEY" ] || fail "identity file $KEY not found"
KEY_COPY="$C/$(basename "$KEY")"
cp -p "$KEY" "$KEY_COPY"
cmp -s "$KEY" "$KEY_COPY" || fail "key copy differs"

awk -v host="$VACUUM_SSH" '/^Host /{show=0; for (i = 2; i <= NF; i++) if ($i == host) show=1} show' ~/.ssh/config > "$C/ssh_config_block.txt"
ssh-keygen -F "$VACUUM_IP" > "$C/known_hosts_entries.txt" || true

rsh_n 'tar -czf - /etc/dropbear /authorized_keys /mnt/misc/authorized_keys 2>/dev/null' > "$C/robot_ssh_keys.tar.gz"
rsh_n 'sha256sum /etc/dropbear/* /authorized_keys /mnt/misc/authorized_keys' > "$C/robot_ssh_keys.sha256"
chmod 600 "$C/ssh_config_block.txt" "$C/known_hosts_entries.txt" "$C/robot_ssh_keys.tar.gz" "$C/robot_ssh_keys.sha256"

V=$(mktemp -d)
trap 'rm -rf "$V"' EXIT
tar -xzf "$C/robot_ssh_keys.tar.gz" -C "$V"
(cd "$V" && sed 's#  /#  #' "$C/robot_ssh_keys.sha256" | shasum -a 256 -c) > "$WORK_DIR/robot_ssh_keys.check" 2>&1
grep -v ': OK$' "$WORK_DIR/robot_ssh_keys.check" && fail "robot key files do not match their on-robot hashes"
say "robot key files match on-robot hashes: $(grep -c ': OK$' "$WORK_DIR/robot_ssh_keys.check")"

PUB=$(ssh-keygen -y -f "$KEY_COPY" | cut -d' ' -f2)
for f in authorized_keys mnt/misc/authorized_keys; do
    grep -q "$PUB" "$V/$f" || fail "/$f does not contain the backed-up key"
done
say "key $(ssh-keygen -y -f "$KEY_COPY" | ssh-keygen -lf - | cut -d' ' -f2) is authorized in both authorized_keys files"

touch "$C/.ok"
say "DONE $C"
