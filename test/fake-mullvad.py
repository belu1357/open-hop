#!/usr/bin/env python3
"""Fake Mullvad: a UDP responder that stands in for a Mullvad server.

It exists only for the network-namespace integration test. On any inbound
datagram it logs the source (so emulate.sh can assert DNAT+masquerade rewrote
the source to the VPS) and replies, so emulate.sh can assert the client sees
the reply coming from the VPS (reverse-DNAT).
"""
import socket
import sys


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 51820
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    sys.stderr.write(f"fake-mullvad listening on udp/{port}\n")
    sys.stderr.flush()
    while True:
        data, addr = sock.recvfrom(65535)
        print(f"RECV from {addr[0]}:{addr[1]} {len(data)}B", flush=True)
        sock.sendto(b"REPLY", addr)


if __name__ == "__main__":
    main()
