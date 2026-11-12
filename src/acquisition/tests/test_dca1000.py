from __future__ import annotations

import struct
import tempfile
import unittest
from pathlib import Path

from radar_stack.protocol.dca1000 import (
    CONTROL_FOOTER,
    CONTROL_HEADER,
    PacketTracker,
    ProtocolError,
    build_control_command,
    _dca_capture_payloads,
    parse_control_response,
    parse_data_packet,
)


def datagram(sequence: int, byte_count: int, payload_bytes: int = 1456) -> bytes:
    return struct.pack("<I", sequence) + byte_count.to_bytes(6, "little") + b"x" * payload_bytes


class DcaDataPacketTests(unittest.TestCase):
    def test_normal_packet(self) -> None:
        packet = parse_data_packet(datagram(7, 1456))
        self.assertEqual((packet.sequence, packet.byte_count, packet.payload_bytes), (7, 1456, 1456))

    def test_short_packet(self) -> None:
        with self.assertRaises(ProtocolError):
            parse_data_packet(b"short")

    def test_missing_duplicate_reordered_and_wrap(self) -> None:
        tracker = PacketTracker()
        for packet in (datagram(0xFFFFFFFE, 0), datagram(0, 2912), datagram(1, 4368), datagram(1, 4368), datagram(0xFFFFFFFF, 1456)):
            tracker.observe(parse_data_packet(packet))
        self.assertGreaterEqual(tracker.quality.missing_packets, 1)
        self.assertEqual(tracker.quality.duplicate_packets, 1)
        self.assertGreaterEqual(tracker.quality.out_of_order_packets, 1)

    def test_byte_count_mismatch_and_short_payload(self) -> None:
        tracker = PacketTracker()
        tracker.observe(parse_data_packet(datagram(1, 0)))
        tracker.observe(parse_data_packet(datagram(2, 999, 10)))
        self.assertEqual(tracker.quality.short_packets, 1)
        self.assertEqual(tracker.quality.byte_count_mismatches, 1)


class DcaControlTests(unittest.TestCase):
    def test_control_round_trip(self) -> None:
        request = build_control_command(9)
        self.assertEqual(struct.unpack_from("<H", request, 0)[0], CONTROL_HEADER)
        response = struct.pack("<HHHH", CONTROL_HEADER, 9, 0, CONTROL_FOOTER)
        self.assertEqual(parse_control_response(response, expected_command=9).status, 0)

    def test_fpga_version_field_is_preserved(self) -> None:
        response = struct.pack("<HHHH", CONTROL_HEADER, 14, 0x0402, CONTROL_FOOTER)
        self.assertEqual(parse_control_response(response, expected_command=14).status, 0x0402)

    def test_dca_capture_payloads_match_known_legacy_contract(self) -> None:
        payload = '{"DCA1000Config":{"dataLoggingMode":"raw","dataTransferMode":"LVDSCapture","dataCaptureMode":"ethernetStream","lvdsMode":1,"dataFormatMode":3,"packetDelay_us":5}}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cf.json"
            path.write_text(payload, encoding="utf-8")
            fpga, record = _dca_capture_payloads(path)
        self.assertEqual(fpga, bytes.fromhex("01010102031e"))
        self.assertEqual(record, bytes.fromhex("be0571020000"))


if __name__ == "__main__":
    unittest.main()
