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

# ---------- nftables rendering (pure; unit-tested) ----------
render_nftables() {
    local mullvad_ip="$1" listen_port="$2" mullvad_port="$3" ssh_port="$4"
    local allow_source="${5:-}"
    local prerouting forward
    if [[ -n "$allow_source" ]]; then
        prerouting="        ip saddr $allow_source udp dport $listen_port dnat to $mullvad_ip:$mullvad_port"
        forward="        ip saddr $allow_source ip daddr $mullvad_ip udp dport $mullvad_port accept comment \"open-hop: relay -> mullvad\""
    else
        prerouting="        udp dport $listen_port dnat to $mullvad_ip:$mullvad_port"
        forward="        ip daddr $mullvad_ip udp dport $mullvad_port accept comment \"open-hop: relay -> mullvad\""
    fi
    cat <<EOF
#!/usr/sbin/nft -f
# Managed by open-hop setup.sh. Re-run setup.sh to change; do not edit by hand.
flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
$prerouting
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr $mullvad_ip udp dport $mullvad_port masquerade
    }
}

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        iif "lo" accept
        tcp dport $ssh_port accept comment "open-hop: SSH admin"
        # Relay inbound on $listen_port never reaches INPUT: prerouting DNAT
        # rewrites its destination to $mullvad_ip, so it is forwarded, not local.
        counter drop
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
$forward
        counter drop
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
}

# ---------- system layer (mutates the host; covered by integration test) ----------
require_root() {
    ((EUID == 0)) || {
        echo "error: must run as root (use sudo)" >&2
        exit 1
    }
}

ensure_nft() {
    if ! command -v nft >/dev/null 2>&1; then
        echo "nft not found; installing nftables..." >&2
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y nftables
    fi
}

detect_vps_ip() {
    ip -o -4 route get 1.1.1.1 2>/dev/null |
        awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

render_sysctl() {
    cat <<'EOF'
# Managed by open-hop setup.sh
net.ipv4.ip_forward=1
EOF
}

apply_rules() {
    nft -c -f /etc/nftables.conf || {
        echo "error: nft syntax check failed" >&2
        exit 1
    }
    systemctl enable --now nftables
    nft -f /etc/nftables.conf
}

# ---------- entrypoint ----------
main() {
    echo "open-hop: validators loaded; CLI added in a later task" >&2
}

# Run main() only when executed, not when sourced (lets tests import functions).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
