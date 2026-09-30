import importlib.util
import pathlib
import socket
import struct
import threading
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "raknet-ping.py"
MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")


def load_module():
    spec = importlib.util.spec_from_file_location("raknet_ping", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeServer(threading.Thread):
    def __init__(self, motd):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.motd = motd.encode()
        self.received = None

    def run(self):
        data, addr = self.sock.recvfrom(2048)
        self.received = data
        ping_time = data[1:9]
        pong = b"\x1c" + ping_time + struct.pack(">Q", 42) + MAGIC
        pong += struct.pack(">H", len(self.motd)) + self.motd
        self.sock.sendto(pong, addr)


class RaknetPingTest(unittest.TestCase):
    def test_ping_returns_motd(self):
        server = FakeServer("MCPE;Daan;800;1.26.0;0;10;123;Daan;Adventure;1;19132;19133;")
        server.start()
        result = load_module().ping("127.0.0.1", server.port, timeout=2)
        server.join(2)
        self.assertEqual(result, "MCPE;Daan;800;1.26.0;0;10;123;Daan;Adventure;1;19132;19133;")

    def test_ping_packet_is_unconnected_ping(self):
        server = FakeServer("MCPE;x;")
        server.start()
        load_module().ping("127.0.0.1", server.port, timeout=2)
        server.join(2)
        self.assertEqual(server.received[0], 0x01)
        self.assertEqual(server.received[9:25], MAGIC)
        self.assertEqual(len(server.received), 33)

    def test_timeout_raises(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        try:
            with self.assertRaises(TimeoutError):
                load_module().ping("127.0.0.1", port, timeout=0.3)
        finally:
            sock.close()


if __name__ == "__main__":
    unittest.main()
