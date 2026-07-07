#!/usr/bin/env bats
# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/../../setup.sh"

@test "default render contains DNAT, masquerade, forward allow, no source qualifier" {
    run render_nftables 198.51.100.10 51820 51820 22 ""
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF "udp dport 51820 dnat to 198.51.100.10:51820"
    echo "$output" | grep -qF "ip daddr 198.51.100.10 udp dport 51820 masquerade"
    echo "$output" | grep -qF "ip daddr 198.51.100.10 udp dport 51820 accept"
    ! echo "$output" | grep -qF "ip saddr"
}

@test "render keeps SSH port open and drops the rest in input" {
    run render_nftables 198.51.100.10 51820 51820 2222 ""
    echo "$output" | grep -qF "tcp dport 2222 accept"
}

@test "render with allow-source qualifies prerouting and forward" {
    run render_nftables 198.51.100.10 53 51820 22 203.0.113.5/32
    echo "$output" | grep -qF "ip saddr 203.0.113.5/32 udp dport 53 dnat to 198.51.100.10:51820"
    echo "$output" | grep -qF "ip saddr 203.0.113.5/32 ip daddr 198.51.100.10 udp dport 51820 accept"
}

@test "render marks the file as managed and flushes ruleset" {
    run render_nftables 198.51.100.10 51820 51820 22 ""
    echo "$output" | head -2 | grep -qF "Managed by open-hop"
    echo "$output" | grep -qF "flush ruleset"
}
