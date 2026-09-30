#!/usr/bin/env python3
"""Send a RakNet unconnected ping to a Bedrock server and print its status."""
import argparse
import os
import socket
import struct
import sys
import time

MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")
UNCONNECTED_PING = 0x01
UNCONNECTED_PONG = 0x1C


def ping(host: str, port: int, timeout: float) -> str:
    """Return the pong string, or raise TimeoutError if the server does not answer."""
    packet = (
        bytes([UNCONNECTED_PING])
        + struct.pack(">Q", int(time.time() * 1000))
        + MAGIC
        + os.urandom(8)
    )
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout)
        sock.sendto(packet, (host, port))
        try:
            data, _ = sock.recvfrom(2048)
        except socket.timeout as exc:
            raise TimeoutError(f"no response from {host}:{port}") from exc
    if not data or data[0] != UNCONNECTED_PONG:
        raise ValueError(f"unexpected packet id {data[:1].hex()}")
    (length,) = struct.unpack(">H", data[33:35])
    return data[35 : 35 + length].decode("utf-8", errors="replace")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("--timeout", type=float, default=3.0)
    args = parser.parse_args()
    try:
        pong = ping(args.host, args.port, args.timeout)
    except TimeoutError:
        print("no response")
        return 1
    fields = pong.split(";")
    labels = ["edition", "motd", "protocol", "version", "players", "max players", "server id", "level", "gamemode"]
    for label, value in zip(labels, fields):
        print(f"{label}: {value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
