#!/bin/sh
# Run as a Home Assistant OS shell_command from /config. The separate Let's
# Encrypt app owns /ssl/valetudo-*.pem; this script installs only those files.
set -eu

CERT=/ssl/valetudo-fullchain.pem
KEY=/ssl/valetudo-privkey.pem
IDENTITY=/config/.ssh/valetudo_https_ed25519
KNOWN=/config/.ssh/known_hosts
TARGET=root@192.168.1.31

[ -s "$CERT" ] && [ -s "$KEY" ] && [ -r "$IDENTITY" ] && [ -r "$KNOWN" ] || exit 1
ssh -i "$IDENTITY" -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN" "$TARGET" cert < "$CERT"
ssh -i "$IDENTITY" -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN" "$TARGET" key < "$KEY"
ssh -i "$IDENTITY" -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN" "$TARGET" activate < /dev/null
