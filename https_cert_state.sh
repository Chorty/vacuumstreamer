#!/bin/sh
# Shared recovery. Caller holds https-install.lock; paths are never client input.
https_pair_path() {
    case "$1" in
        https-generations/pair.[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) return 0 ;;
        *) return 1 ;;
    esac
}
https_switch_pair() {
    https_pair_path "$1" || return 1
    [ -s "$DIR/$1/fullchain.pem" ] && [ -s "$DIR/$1/privkey.pem" ] || return 1
    rm -f "$DIR/https-current.next"
    ln -s "$1" "$DIR/https-current.next" && mv -fT "$DIR/https-current.next" "$DIR/https-current"
}
https_recover() {
    [ -f "$DIR/https-pending" ] || return 0
    previous=$(cat "$DIR/https-pending") || return 1
    if [ "$previous" = none ]; then
        rm -f "$DIR/https-current" || return 1
    else
        https_switch_pair "$previous" || return 1
    fi
    rm -f "$DIR/https-pending" || return 1
    sync
}
