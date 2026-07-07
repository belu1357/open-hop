#!/usr/bin/env bats
# shellcheck source=/dev/null
source "$BATS_TEST_DIRNAME/../../setup.sh"

@test "is_valid_ipv4 accepts 192.168.1.1" {
    run is_valid_ipv4 192.168.1.1
    [ "$status" -eq 0 ]
}
@test "is_valid_ipv4 accepts 8.8.8.8" {
    run is_valid_ipv4 8.8.8.8
    [ "$status" -eq 0 ]
}
@test "is_valid_ipv4 rejects 999.1.1.1" {
    run is_valid_ipv4 999.1.1.1
    [ "$status" -ne 0 ]
}
@test "is_valid_ipv4 rejects 1.2.3" {
    run is_valid_ipv4 1.2.3
    [ "$status" -ne 0 ]
}
@test "is_valid_ipv4 rejects empty" {
    run is_valid_ipv4 ""
    [ "$status" -ne 0 ]
}
@test "is_valid_port accepts 51820" {
    run is_valid_port 51820
    [ "$status" -eq 0 ]
}
@test "is_valid_port accepts 1 and 65535" {
    run is_valid_port 1
    [ "$status" -eq 0 ]
    run is_valid_port 65535
    [ "$status" -eq 0 ]
}
@test "is_valid_port rejects 0 and 65536" {
    run is_valid_port 0
    [ "$status" -ne 0 ]
    run is_valid_port 65536
    [ "$status" -ne 0 ]
}
@test "is_valid_port rejects non-numeric" {
    run is_valid_port abc
    [ "$status" -ne 0 ]
}
@test "is_valid_cidr accepts 203.0.113.5/32" {
    run is_valid_cidr 203.0.113.5/32
    [ "$status" -eq 0 ]
}
@test "is_valid_cidr accepts 10.0.0.0/8" {
    run is_valid_cidr 10.0.0.0/8
    [ "$status" -eq 0 ]
}
@test "is_valid_cidr rejects 203.0.113.5/33" {
    run is_valid_cidr 203.0.113.5/33
    [ "$status" -ne 0 ]
}
@test "is_valid_cidr rejects bare ip" {
    run is_valid_cidr 203.0.113.5
    [ "$status" -ne 0 ]
}
