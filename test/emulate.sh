#!/usr/bin/env bash
# Integration test for the Openhop relay. Two modes:
#   ./emulate.sh --syntax-matrix   # nft -c on a port/allow-source matrix (no root)
#   ./emulate.sh                   # full netns round-trip + isolation test (root)
set -euo pipefail

# shellcheck source=/dev/null
source "$(dirname "$0")/../setup.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
LISTEN=51820
MPORT=51820
SSH_PORT=22
VPS_LAN=100.64.0.1
VPS_WAN=100.64.1.1
CLIENT_IP=100.64.0.2
UP_IP=100.64.1.2
NS_C=oh-client
NS_V=oh-vps
NS_U=oh-upstream
PASS=0
FAIL=0
FAKE_PID=""

ok() {
    echo "PASS: $*"
    PASS=$((PASS + 1))
}
bad() {
    echo "FAIL: $*"
    FAIL=$((FAIL + 1))
}

cleanup() {
    [[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" 2>/dev/null || true
    for ns in "$NS_C" "$NS_V" "$NS_U"; do
        ip netns del "$ns" 2>/dev/null || true
    done
}
trap cleanup EXIT

run_syntax_matrix() {
    local tmp
    tmp="$(mktemp)"
    for lp in 51820 53 443; do
        for mp in 51820 53 443; do
            for as in "" "203.0.113.5/32"; do
                if render_nftables 198.51.100.10 "$lp" "$mp" 22 "$as" >"$tmp" &&
                    nft -c -f "$tmp" >/dev/null 2>&1; then
                    ok "syntax listen=$lp mullvad=$mp allow=${as:-any}"
                else
                    bad "syntax listen=$lp mullvad=$mp allow=${as:-any}"
                fi
            done
        done
    done
    rm -f "$tmp"
}

if [[ "${1:-}" == "--syntax-matrix" ]]; then
    run_syntax_matrix
    echo
    echo "matrix: $PASS passed, $FAIL failed"
    [[ "$FAIL" -eq 0 ]]
    exit
fi

# ---------------- full netns test ----------------
[[ $EUID -eq 0 ]] || {
    echo "need root for netns test"
    exit 1
}
command -v nft >/dev/null || {
    echo "nft not installed"
    exit 1
}
command -v python3 >/dev/null || {
    echo "python3 not installed"
    exit 1
}
modprobe nf_conntrack 2>/dev/null || true
cleanup

for ns in "$NS_C" "$NS_V" "$NS_U"; do
    ip netns add "$ns"
    ip netns exec "$ns" ip link set lo up
done

ip link add oh-c type veth peer name oh-vps-lan
ip link add oh-vps-wan type veth peer name oh-up
ip link set oh-c netns "$NS_C"
ip link set oh-vps-lan netns "$NS_V"
ip link set oh-vps-wan netns "$NS_V"
ip link set oh-up netns "$NS_U"

ip netns exec "$NS_C" ip addr add "$CLIENT_IP/24" dev oh-c
ip netns exec "$NS_V" ip addr add "$VPS_LAN/24" dev oh-vps-lan
ip netns exec "$NS_V" ip addr add "$VPS_WAN/24" dev oh-vps-wan
ip netns exec "$NS_U" ip addr add "$UP_IP/24" dev oh-up
ip netns exec "$NS_C" ip link set oh-c up
ip netns exec "$NS_V" ip link set oh-vps-lan up
ip netns exec "$NS_V" ip link set oh-vps-wan up
ip netns exec "$NS_U" ip link set oh-up up

ip netns exec "$NS_C" ip route add default via "$VPS_LAN"
ip netns exec "$NS_U" ip route add default via "$VPS_WAN"

# Apply the relay in the VPS namespace (nftables tables are per-netns).
ip netns exec "$NS_V" sysctl -w net.ipv4.ip_forward=1 >/dev/null
render_nftables "$UP_IP" "$LISTEN" "$MPORT" "$SSH_PORT" "" | ip netns exec "$NS_V" nft -f -

# Confirm the host ruleset is untouched (rules are isolated to the ns).
if nft list ruleset 2>/dev/null | grep -qF "open-hop"; then
    bad "host ruleset contaminated by ns rules"
else
    ok "host ruleset clean (nft tables are per-network-namespace)"
fi

LOG="$(mktemp)"
ip netns exec "$NS_U" python3 "$HERE/fake-mullvad.py" "$MPORT" >"$LOG" 2>&1 &
FAKE_PID=$!
sleep 0.5

# (1) Client sends to VPS:LISTEN; assert reply arrives from VPS_LAN:LISTEN.
RES="$(
    ip netns exec "$NS_C" python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
try:
    s.sendto(b"HELLO", ("100.64.0.1", 51820))
    data, addr = s.recvfrom(65535)
    print(f"{addr[0]}:{addr[1]} {data!r}")
except Exception as e:
    print(f"ERR {e}")
PY
)"
sleep 0.2
if [[ "$RES" == "100.64.0.1:51820 b'REPLY'" ]]; then
    ok "client received REPLY from VPS (reverse-DNAT works)"
else
    bad "client result unexpected: $RES"
fi

# (2) Assert upstream saw the VPS as the source (masquerade worked).
if grep -q "RECV from 100.64.1.1:" "$LOG"; then
    ok "upstream saw VPS as source (masquerade works)"
else
    bad "upstream did not see VPS source; log: $(cat "$LOG")"
fi

# (3) Non-listen port must be dropped (no reply).
NR="$(
    ip netns exec "$NS_C" python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1)
try:
    s.sendto(b"X", ("100.64.0.1", 9999))
    s.recvfrom(65535)
    print("GOT")
except Exception:
    print("NO-REPLY")
PY
)"
if [[ "$NR" == "NO-REPLY" ]]; then
    ok "non-listen port (9999) dropped"
else
    bad "non-listen port unexpectedly replied"
fi

# (4) Forward chain must contain the relay allow rule.
FWD="$(ip netns exec "$NS_V" nft list chain inet filter forward 2>/dev/null || true)"
if echo "$FWD" | grep -qF 'open-hop: relay -> mullvad'; then
    ok "forward chain has relay allow rule"
else
    bad "forward chain missing relay allow rule"
fi

# (5) Non-relay forwarded traffic must be dropped (no exfil path).
#     Send upstream -> client on a NON-relay port (9999) so the prerouting DNAT
#     (which matches only the listen port) does not intercept it; VPS forward
#     must drop it, proving isolation and incrementing the drop counter.
ip netns exec "$NS_U" python3 - <<'PY' >/dev/null 2>&1
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"EXFIL", ("100.64.0.2", 9999))
PY
sleep 0.2
DROP="$(ip netns exec "$NS_V" nft list chain inet filter forward 2>/dev/null || true)"
if echo "$DROP" | grep -qE 'counter packets [1-9][0-9]* bytes [1-9]'; then
    ok "forward drop rule fired (no exfil path upstream->client)"
else
    bad "forward drop rule did not fire"
fi

echo
echo "result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
