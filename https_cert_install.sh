#!/bin/sh
# Forced command for the dedicated Home Assistant certificate-deploy SSH key.
# authorized_keys must also disable forwarding and PTY allocation. Only the
# three literal commands below are accepted; PEM bytes arrive solely on stdin.

set -u
DIR=/data/vacuumstreamer/credentials
HOST=mattjoslin-valetudo.duckdns.org
CADDY=/data/vacuumstreamer/caddy
CADDYFILE=/data/vacuumstreamer/https_proxy.Caddyfile
umask 077

mkdir -p "$DIR" || exit 1
chmod 700 "$DIR" || exit 1

case "${SSH_ORIGINAL_COMMAND:-}" in
    cert)
        cat > "$DIR/https-fullchain.pem.new" || {
            rm -f "$DIR/https-fullchain.pem.new"
            exit 1
        }
        chmod 600 "$DIR/https-fullchain.pem.new"
        ;;
    key)
        cat > "$DIR/https-privkey.pem.new" || {
            rm -f "$DIR/https-privkey.pem.new"
            exit 1
        }
        chmod 600 "$DIR/https-privkey.pem.new"
        ;;
    activate)
        cert="$DIR/https-fullchain.pem.new"
        key="$DIR/https-privkey.pem.new"
        trap 'rm -f "$cert" "$key"' EXIT
        [ -s "$cert" ] && [ -s "$key" ] || exit 1
        openssl x509 -in "$cert" -noout -checkend 1209600 > /dev/null 2>&1 || exit 1
        openssl x509 -in "$cert" -noout -checkhost "$HOST" > /dev/null 2>&1 || exit 1
        cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) || exit 1
        key_pub=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) || exit 1
        [ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ] || exit 1
        [ -x "$CADDY" ] && [ -r "$CADDYFILE" ] || exit 1

        # Keep the previous pair until both replacements and Caddy validation
        # succeed. Restore both files if either move or validation fails.
        for f in https-fullchain.pem https-privkey.pem; do
            if [ -e "$DIR/$f" ]; then cp -p "$DIR/$f" "$DIR/$f.previous" || exit 1; fi
        done
        restore_pair() {
            for f in https-fullchain.pem https-privkey.pem; do
                if [ -e "$DIR/$f.previous" ]; then
                    mv -f "$DIR/$f.previous" "$DIR/$f" || return 1
                else
                    rm -f "$DIR/$f" || return 1
                fi
            done
        }
        if ! mv -f "$cert" "$DIR/https-fullchain.pem" ||
           ! mv -f "$key" "$DIR/https-privkey.pem" ||
           ! "$CADDY" validate --config "$CADDYFILE" --adapter caddyfile > /dev/null 2>&1; then
            restore_pair || echo 'certificate rollback failed' >&2
            exit 1
        fi
        rm -f "$DIR/https-fullchain.pem.previous" "$DIR/https-privkey.pem.previous"
        killall caddy > /dev/null 2>&1 || :
        ;;
    *) exit 1 ;;
esac
