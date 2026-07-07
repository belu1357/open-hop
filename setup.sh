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

# ---------- lockout guard ----------
render_guard_service() {
    cat <<'EOF'
[Unit]
Description=open-hop lockout guard: revert firewall to open
RefuseManualStart=no

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft flush ruleset
EOF
}

render_guard_timer() {
    local mins="$1"
    cat <<EOF
[Unit]
Description=open-hop lockout guard timer

[Timer]
OnActiveSec=${mins}min
Unit=open-hop-revert.service

[Install]
WantedBy=timers.target
EOF
}

arm_guard() {
    local mins="$1" nonint="$2"
    render_guard_service >/etc/systemd/system/open-hop-revert.service
    render_guard_timer "$mins" >/etc/systemd/system/open-hop-revert.timer
    systemctl daemon-reload
    systemctl start open-hop-revert.timer
    if ((nonint)); then
        return
    fi
    local ans=""
    if [[ -t 0 ]]; then
        read -r -p "Rules applied - SSH should still work. Keep them? [Y/n] " ans || true
    fi
    if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
        cmd_confirm
    fi
}

cmd_confirm() {
    systemctl stop open-hop-revert.timer 2>/dev/null || true
    systemctl disable open-hop-revert.timer 2>/dev/null || true
    rm -f /etc/systemd/system/open-hop-revert.service \
        /etc/systemd/system/open-hop-revert.timer
    systemctl daemon-reload
    echo "open-hop: lockout guard cancelled; rules kept."
}

# ---------- config persistence ----------
persist_config() {
    cat >/etc/open-hop.conf <<EOF
# Managed by open-hop setup.sh
MULLVAD_IP="$1"
LISTEN_PORT="$2"
MULLVAD_PORT="$3"
SSH_PORT="$4"
ALLOW_SOURCE="$5"
EOF
}

# ---------- subcommands ----------
cmd_show() {
    echo "=== /etc/open-hop.conf ==="
    cat /etc/open-hop.conf 2>/dev/null || echo "(none)"
    echo
    echo "=== active nft ruleset ==="
    nft list ruleset
}

cmd_uninstall() {
    require_root
    cmd_confirm >/dev/null 2>&1 || true
    nft flush ruleset 2>/dev/null || true
    systemctl disable --now nftables 2>/dev/null || true
    rm -f /etc/sysctl.d/99-open-hop.conf /etc/nftables.conf /etc/open-hop.conf
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    echo "open-hop removed. WARNING: firewall is now wide open; reinstall or apply your own rules."
}

usage() {
    cat <<'EOF'
open-hop: dumb nftables UDP relay to Mullvad.

Usage:
  sudo setup.sh --mullvad-ip <ip> [options]        install/apply the relay
  sudo setup.sh show                               print active config + ruleset
  sudo setup.sh confirm                            cancel the lockout guard
  sudo setup.sh uninstall                          remove open-hop (opens firewall)

Options:
      --mullvad-ip <ip>      Mullvad server IPv4 to relay to (required)
      --listen-port <port>   port on the VPS the client connects to (default 51820)
      --mullvad-port <port>  Mullvad UDP port (default 51820; also try 53 or 443)
      --ssh-port <port>      port kept open for admin (default 22)
      --allow-source <cidr>  restrict the relay to a source CIDR/IP (default: any)
      --guard-mins <n>       lockout-guard auto-revert window (default 10; 0 disables)
      --yes                  non-interactive (skip confirm prompt; for cloud-init)
      --check                render + nft -c syntax-check only; do not apply

Each flag also reads an env var of the upper-snake-case name (e.g. MULLVAD_IP).
EOF
}

# ---------- entrypoint ----------
main() {
    local mullvad_ip="" listen_port=51820 mullvad_port=51820 ssh_port=22
    local allow_source="" guard_mins=10 yes=0 check_only=0

    case "${1:-}" in
    show)
        cmd_show
        exit 0
        ;;
    confirm)
        require_root
        cmd_confirm
        exit 0
        ;;
    uninstall)
        cmd_uninstall
        exit 0
        ;;
    --help | -h)
        usage
        exit 0
        ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --mullvad-ip | --listen-port | --mullvad-port | --ssh-port | --allow-source | --guard-mins)
            [[ -n "${2:-}" ]] || {
                echo "error: $1 needs a value" >&2
                exit 2
            }
            case "$1" in
            --mullvad-ip) mullvad_ip="$2" ;;
            --listen-port) listen_port="$2" ;;
            --mullvad-port) mullvad_port="$2" ;;
            --ssh-port) ssh_port="$2" ;;
            --allow-source) allow_source="$2" ;;
            --guard-mins) guard_mins="$2" ;;
            esac
            shift 2
            ;;
        --yes)
            yes=1
            shift
            ;;
        --check)
            check_only=1
            shift
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage
            exit 2
            ;;
        esac
    done

    # env fallbacks
    mullvad_ip="${MULLVAD_IP:-$mullvad_ip}"
    listen_port="${LISTEN_PORT:-$listen_port}"
    mullvad_port="${MULLVAD_PORT:-$mullvad_port}"
    ssh_port="${SSH_PORT:-$ssh_port}"
    allow_source="${ALLOW_SOURCE:-$allow_source}"

    # validate
    [[ -n "$mullvad_ip" ]] || {
        echo "error: --mullvad-ip is required" >&2
        exit 2
    }
    is_valid_ipv4 "$mullvad_ip" || {
        echo "error: invalid --mullvad-ip: $mullvad_ip" >&2
        exit 2
    }
    is_valid_port "$listen_port" || {
        echo "error: invalid --listen-port: $listen_port" >&2
        exit 2
    }
    is_valid_port "$mullvad_port" || {
        echo "error: invalid --mullvad-port: $mullvad_port" >&2
        exit 2
    }
    is_valid_port "$ssh_port" || {
        echo "error: invalid --ssh-port: $ssh_port" >&2
        exit 2
    }
    if [[ -n "$allow_source" ]]; then
        is_valid_cidr "$allow_source" || {
            echo "error: invalid --allow-source: $allow_source" >&2
            exit 2
        }
    fi
    # guard_mins may be 0 (disables the guard), so allow any non-negative int.
    [[ "$guard_mins" =~ ^[0-9]+$ ]] || {
        echo "error: invalid --guard-mins: $guard_mins" >&2
        exit 2
    }

    if ((check_only)); then
        if render_nftables "$mullvad_ip" "$listen_port" "$mullvad_port" "$ssh_port" "$allow_source" |
            nft -c -f -; then
            echo "syntax OK (--check)"
        else
            echo "error: syntax check failed" >&2
            exit 1
        fi
        exit 0
    fi

    require_root
    ensure_nft

    echo "==> enabling IPv4 forwarding"
    render_sysctl >/etc/sysctl.d/99-open-hop.conf
    sysctl --system >/dev/null

    echo "==> writing /etc/nftables.conf"
    render_nftables "$mullvad_ip" "$listen_port" "$mullvad_port" "$ssh_port" "$allow_source" \
        >/etc/nftables.conf

    echo "==> applying nftables ruleset"
    apply_rules

    persist_config "$mullvad_ip" "$listen_port" "$mullvad_port" "$ssh_port" "$allow_source"

    if ((guard_mins > 0)); then
        arm_guard "$guard_mins" "$yes"
    fi

    local vps_ip
    vps_ip="$(detect_vps_ip)"
    echo
    echo "✓ open-hop relay up: udp/${listen_port} -> ${mullvad_ip}:${mullvad_port}"
    echo "  Set in your Mullvad WireGuard client:"
    echo "    Endpoint = ${vps_ip}:${listen_port}"
    if ((guard_mins > 0)); then
        echo "  Keep these rules:  sudo bash setup.sh confirm"
        echo "  (otherwise they auto-revert to open in ${guard_mins} min)"
    fi
}

# Run main() only when executed, not when sourced (lets tests import functions).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
