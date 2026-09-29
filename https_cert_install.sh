#!/bin/sh
# Dedicated HA key: only `install`. Framed PEM bundle then HA commit on stdin.
# One bounded, locked transaction replaces the old three-call protocol.
set -u
DIR=/data/vacuumstreamer/credentials
HOST=mattjoslin-valetudo.duckdns.org
CADDY=/data/vacuumstreamer/caddy
CADDYFILE=/data/vacuumstreamer/https_proxy.Caddyfile
. /data/vacuumstreamer/https_cert_state.sh
umask 077
case "${SSH_CONNECTION:-}" in "192.168.1.106 "*) ;; *) exit 1 ;; esac
[ "${SSH_ORIGINAL_COMMAND:-}" = install ] || exit 1
mkdir -p "$DIR/https-generations" || exit 1
chmod 700 "$DIR" "$DIR/https-generations" || exit 1
exec 9> "$DIR/https-install.lock"
flock -n 9 || exit 1
https_recover || exit 1
candidate=$(mktemp -d "$DIR/https-generations/pair.XXXXXX") || exit 1
published=no
committed=no
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$published" = yes ] && [ "$committed" = no ]; then
        if ! https_recover; then
            echo 'certificate rollback failed; preserving candidate' >&2
            exit 1
        fi
        killall -USR1 caddy > /dev/null 2>&1 || :
    fi
    if [ "$committed" = no ]; then rm -rf "$candidate"; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# Framing keeps stdin open for the HA acknowledgement while bounding storage.
length=$(timeout -s KILL 3 dd bs=1 count=7 2>/dev/null) || exit 1
case "$length" in ??????) ;; *) exit 1 ;; esac
case "$length" in *[!0-9]*) exit 1 ;; esac
# Strip zero padding before POSIX shell arithmetic (no octal interpretation).
length=$(printf '%s' "$length" | sed 's/^0*//')
[ -n "$length" ] && [ "$length" -le 98304 ] || exit 1
timeout -s KILL 12 dd bs=1 count="$length" 2>/dev/null > "$candidate/bundle" || exit 1
[ "$(wc -c < "$candidate/bundle")" -eq "$length" ] || exit 1
acknowledge() {
    printf 'ready\n'
    acknowledgement=$(timeout -s KILL 10 dd bs=1 count=7 2>/dev/null) || return 1
    [ "$acknowledgement" = commit ]
}
awk -v cert="$candidate/fullchain.pem" -v key="$candidate/privkey.pem" '
    /^-----BEGIN CERTIFICATE-----$/ { if (part != "" || keys) exit 1; part="cert"; certs++ }
    /^-----BEGIN (RSA |EC )?PRIVATE KEY-----$/ { if (part != "" || keys++) exit 1; part="key" }
    { if (part == "cert") print > cert; else if (part == "key") print > key; else if ($0 !~ /^[[:space:]]*$/) exit 1 }
    /^-----END CERTIFICATE-----$/ { if (part != "cert") exit 1; part="" }
    /^-----END (RSA |EC )?PRIVATE KEY-----$/ { if (part != "key") exit 1; part="" }
    END { if (part != "" || !certs || keys != 1) exit 1 }
' "$candidate/bundle" || exit 1
rm -f "$candidate/bundle"
cert="$candidate/fullchain.pem"
key="$candidate/privkey.pem"
openssl x509 -in "$cert" -noout -checkend 1209600 > /dev/null 2>&1 || exit 1
openssl verify -purpose sslserver -verify_hostname "$HOST" -untrusted "$cert" "$cert" > /dev/null 2>&1 || exit 1
openssl x509 -in "$cert" -outform DER -out "$candidate/leaf.der" 2>/dev/null || exit 1
openssl x509 -in "$cert" -pubkey -noout > "$candidate/pub.pem" 2>/dev/null || exit 1
openssl pkey -pubin -in "$candidate/pub.pem" -outform DER -out "$candidate/cert.pub" 2>/dev/null || exit 1
openssl pkey -in "$key" -passin pass: -pubout -outform DER -out "$candidate/key.pub" 2>/dev/null || exit 1
cmp -s "$candidate/cert.pub" "$candidate/key.pub" || exit 1
[ -x "$CADDY" ] && [ -r "$CADDYFILE" ] || exit 1
served_pair() {
    # Trust + hostname AND exact leaf, including renewals reusing a key.
    timeout -s KILL 3 openssl s_client -connect 127.0.0.1:443 -servername "$HOST" \
        -verify_return_error -verify_hostname "$HOST" -showcerts < /dev/null > "$candidate/served.pem" 2>/dev/null || return 1
    openssl x509 -in "$candidate/served.pem" -outform DER -out "$candidate/served.der" 2>/dev/null || return 1
    cmp -s "$candidate/leaf.der" "$candidate/served.der" || return 1
    code=$(curl -q --noproxy '*' -s -m 3 --resolve "$HOST:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$HOST/api/v2/robot") || return 1
    case "$code" in 200|401) return 0 ;; *) return 1 ;; esac
}
# Unchanged pairs must still be served correctly, but never cause a reload.
if cmp -s "$cert" "$DIR/https-fullchain.pem" && cmp -s "$key" "$DIR/https-privkey.pem"; then
    served_pair && acknowledge || exit 1
    exit 0
fi
# Bootstrap legacy files without changing contents. Public filenames remain
# compatible with the existing Caddyfile and deployment rollback.
if [ ! -L "$DIR/https-current" ] && [ -s "$DIR/https-fullchain.pem" ] && [ -s "$DIR/https-privkey.pem" ]; then
    legacy=$(mktemp -d "$DIR/https-generations/pair.XXXXXX") || exit 1
    cp "$DIR/https-fullchain.pem" "$legacy/fullchain.pem" && cp "$DIR/https-privkey.pem" "$legacy/privkey.pem" || exit 1
    https_switch_pair "https-generations/${legacy##*/}" || exit 1
    sync
fi
previous=$(readlink "$DIR/https-current") || previous=none
if [ "$previous" != none ]; then https_pair_path "$previous" || exit 1; fi
for kind in fullchain privkey; do
    rm -f "$DIR/https-$kind.pem.next"
    ln -s "https-current/$kind.pem" "$DIR/https-$kind.pem.next" &&
        mv -fT "$DIR/https-$kind.pem.next" "$DIR/https-$kind.pem" || exit 1
done
printf '%s\n' "$previous" > "$DIR/https-pending.next" &&
    mv -f "$DIR/https-pending.next" "$DIR/https-pending" || exit 1
sync
published=yes
https_switch_pair "https-generations/${candidate##*/}" || exit 1
sync
timeout -s KILL 5 "$CADDY" validate --config "$CADDYFILE" --adapter caddyfile > /dev/null 2>&1 || exit 1
killall -USR1 caddy > /dev/null 2>&1 || :
attempt=0
while ! served_pair; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 4 ] || exit 1
    sleep 2
done
# HA must verify its own trust store and the exact served leaf before commit.
acknowledge || exit 1
committed=yes
rm -f "$DIR/https-pending" || exit 1
sync
# Retain the previous pair; remove only owned obsolete generations.
for generation in "$DIR"/https-generations/pair.*; do
    relative="https-generations/${generation##*/}"
    https_pair_path "$relative" || continue
    [ "$generation" = "$candidate" ] || [ "$relative" = "$previous" ] || rm -rf "$generation"
done
rm -f "$candidate/pub.pem" "$candidate/cert.pub" "$candidate/key.pub" "$candidate/served.pem" "$candidate/served.der" "$candidate/leaf.der"
