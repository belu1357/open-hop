#!/usr/bin/env bash
# open-hop setup.sh: manage a dumb nftables UDP relay to Mullvad.
# Sourceable: functions only run via main() when executed directly.
set -euo pipefail

# ---------- input validation ----------
is_valid_ipv4() {
    local s="$1"
    [[ "$s" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do
        ((10#$o >= 0 && 10#$o <= 255)) || return 1
    done
    return 0
}

is_valid_port() {
    local s="$1"
    [[ "$s" =~ ^[0-9]+$ ]] || return 1
    ((10#$s >= 1 && 10#$s <= 65535)) || return 1
    return 0
}

is_valid_cidr() {
    local s="$1" ip prefix
    [[ "$s" == */* ]] || return 1
    ip="${s%%/*}"
    prefix="${s##*/}"
    is_valid_ipv4 "$ip" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    ((10#$prefix >= 0 && 10#$prefix <= 32)) || return 1
    return 0
}

# ---------- entrypoint ----------
main() {
    echo "open-hop: validators loaded; CLI added in a later task" >&2
}

# Run main() only when executed, not when sourced (lets tests import functions).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
