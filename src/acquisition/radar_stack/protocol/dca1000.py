from __future__ import annotations

from dataclasses import asdict, dataclass, field
from ipaddress import IPv4Address
import json
from pathlib import Path
import socket
import struct
from typing import Iterable


DATA_HEADER_BYTES = 10
DEFAULT_PACKET_BYTES = 1466
CONTROL_HEADER = 0xA55A
CONTROL_FOOTER = 0xEEAA
SYSTEM_CONNECT = 0x0009
READ_FPGA_VERSION = 0x000E
RESET_FPGA = 0x0001
RESET_RADAR = 0x0002
CONFIG_FPGA = 0x0003
STREAM_START = 0x0005
STREAM_STOP = 0x0006
CONFIG_RECORD = 0x000B


class ProtocolError(ValueError):
    """The received datagram does not match the DCA1000 contract."""


@dataclass(frozen=True)
class DataPacket:
    sequence: int
    byte_count: int
    payload: bytes
    source_ip: str | None = None
    source_port: int | None = None

    @property
    def payload_bytes(self) -> int:
        return len(self.payload)


@dataclass
class PacketQuality:
    received_packets: int = 0
    expected_packets: int = 0
    missing_packets: int = 0
    duplicate_packets: int = 0
    out_of_order_packets: int = 0
    short_packets: int = 0
    source_anomalies: int = 0
    byte_count_mismatches: int = 0
    first_sequence: int | None = None
    last_sequence: int | None = None
    first_byte_count: int | None = None
    last_byte_count: int | None = None

    def to_dict(self) -> dict:
        return asdict(self)


def parse_data_packet(
    datagram: bytes,
    source: tuple[str, int] | None = None,
    *,
    expected_source: tuple[str, int] | None = None,
    expected_packet_bytes: int = DEFAULT_PACKET_BYTES,
) -> DataPacket:
    if len(datagram) < DATA_HEADER_BYTES:
        raise ProtocolError(f"short datagram: {len(datagram)} bytes, need at least {DATA_HEADER_BYTES}")
    if expected_source and source and source != expected_source:
        raise ProtocolError(f"unexpected source {source[0]}:{source[1]}; expected {expected_source[0]}:{expected_source[1]}")
    sequence = struct.unpack_from("<I", datagram, 0)[0]
    byte_count = int.from_bytes(datagram[4:10], byteorder="little", signed=False)
    return DataPacket(
        sequence=sequence,
        byte_count=byte_count,
        payload=datagram[DATA_HEADER_BYTES:],
        source_ip=source[0] if source else None,
        source_port=source[1] if source else None,
    )


class PacketTracker:
    """Tracks packet quality without materializing the ADC payload stream."""

    def __init__(self, *, expected_packet_bytes: int = DEFAULT_PACKET_BYTES, reorder_window: int = 64) -> None:
        self.expected_packet_bytes = expected_packet_bytes
        self.reorder_window = reorder_window
        self.quality = PacketQuality()
        self._next_sequence: int | None = None
        self._previous_byte_count: int | None = None
        self._previous_payload_bytes: int | None = None
        self._seen: set[int] = set()

    def observe(self, packet: DataPacket) -> PacketQuality:
        quality = self.quality
        quality.received_packets += 1
        if quality.first_sequence is None:
            quality.first_sequence = packet.sequence
            quality.first_byte_count = packet.byte_count
            self._next_sequence = (packet.sequence + 1) & 0xFFFFFFFF
        else:
            assert self._next_sequence is not None
            forward = (packet.sequence - self._next_sequence) & 0xFFFFFFFF
            backward = (self._next_sequence - packet.sequence) & 0xFFFFFFFF
            if packet.sequence in self._seen:
                quality.duplicate_packets += 1
            elif packet.sequence == self._next_sequence:
                self._next_sequence = (packet.sequence + 1) & 0xFFFFFFFF
            elif 0 < forward < 0x80000000:
                quality.missing_packets += forward
                quality.expected_packets += forward
                self._next_sequence = (packet.sequence + 1) & 0xFFFFFFFF
            elif 0 < backward <= self.reorder_window:
                quality.out_of_order_packets += 1
            else:
                quality.out_of_order_packets += 1
        if len(packet.payload) != self.expected_packet_bytes - DATA_HEADER_BYTES:
            quality.short_packets += 1
        if self._previous_byte_count is not None and self._previous_payload_bytes is not None:
            expected = self._previous_byte_count + self._previous_payload_bytes
            if packet.byte_count != expected:
                quality.byte_count_mismatches += 1
        self._seen.add(packet.sequence)
        if len(self._seen) > self.reorder_window * 4:
            self._seen = set(sorted(self._seen)[-self.reorder_window * 2 :])
        quality.last_sequence = packet.sequence
        quality.last_byte_count = packet.byte_count
        self._previous_byte_count = packet.byte_count
        self._previous_payload_bytes = packet.payload_bytes
        quality.expected_packets = max(quality.expected_packets, quality.received_packets + quality.missing_packets)
        return quality


@dataclass(frozen=True)
class ControlResponse:
    command: int
    status: int
    payload: bytes


def build_control_command(command: int, payload: bytes = b"") -> bytes:
    if not 0 <= command <= 0xFFFF:
        raise ValueError("command must fit in uint16")
    if len(payload) > 0xFFFF:
        raise ValueError("control payload exceeds uint16 length")
    return struct.pack("<HHH", CONTROL_HEADER, command, len(payload)) + payload + struct.pack("<H", CONTROL_FOOTER)


def parse_control_response(data: bytes, *, expected_command: int | None = None) -> ControlResponse:
    if len(data) < 8:
        raise ProtocolError(f"short control response: {len(data)} bytes")
    header, command, status, footer = struct.unpack_from("<HHHH", data, 0)
    if header != CONTROL_HEADER or footer != CONTROL_FOOTER:
        raise ProtocolError(f"invalid control envelope header={header:#x} footer={footer:#x}")
    if expected_command is not None and command != expected_command:
        raise ProtocolError(f"control command mismatch: got {command:#x}, expected {expected_command:#x}")
    return ControlResponse(command=command, status=status, payload=data[8:])


def probe_dca(ip: str, port: int, timeout_s: float = 1.0, *, bind_ip: str = "0.0.0.0") -> dict:
    """Perform read-only DCA control probes; it never starts recording or resets hardware."""
    IPv4Address(ip)
    results: list[dict] = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout_s)
        sock.bind((bind_ip, port))
        for name, command in (("system_connect", SYSTEM_CONNECT), ("read_fpga_version", READ_FPGA_VERSION)):
            try:
                sock.sendto(build_control_command(command), (ip, port))
                data, source = sock.recvfrom(4096)
                if source[0] != ip:
                    raise ProtocolError(f"unexpected DCA control response source {source[0]}:{source[1]}; expected IP {ip}")
                response = parse_control_response(data, expected_command=command)
                result = {"name": name, "ok": response.status == 0, "source": f"{source[0]}:{source[1]}", "status": response.status, "payload_hex": response.payload.hex()}
                if command == READ_FPGA_VERSION:
                    result["ok"] = True
                    result["fpga_version"] = {
                        "major": (response.status & 0x7F00) >> 8,
                        "minor": response.status & 0x00FF,
                        "playback_bitfile": bool(response.status & 0x4000),
                    }
                results.append(result)
            except (OSError, ProtocolError) as exc:
                results.append({"name": name, "ok": False, "error": str(exc)})
    return {"target": f"{ip}:{port}", "bound_source": f"{bind_ip}:{port}", "read_only": True, "results": results}


def reset_dca_target(ip: str, port: int, target: str, timeout_s: float = 2.0, *, bind_ip: str = "0.0.0.0") -> dict:
    """Issue one documented DCA1000 reset command; it never records or starts a sensor."""
    commands = {"fpga": RESET_FPGA, "radar": RESET_RADAR}
    if target not in commands:
        raise ValueError(f"unsupported reset target: {target}")
    IPv4Address(ip)
    command = commands[target]
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout_s)
        sock.bind((bind_ip, port))
        sock.sendto(build_control_command(command), (ip, port))
        data, source = sock.recvfrom(4096)
    if source[0] != ip:
        raise ProtocolError(f"unexpected DCA control response source {source[0]}:{source[1]}; expected IP {ip}")
    response = parse_control_response(data, expected_command=command)
    return {
        "target": target,
        "dca_target": f"{ip}:{port}",
        "bound_source": f"{bind_ip}:{port}",
        "recording_started": False,
        "status": response.status,
        "ok": response.status == 0,
        "source": f"{source[0]}:{source[1]}",
    }


def send_dca_control(
    ip: str,
    port: int,
    command: int,
    payload: bytes = b"",
    *,
    timeout_s: float = 2.0,
    bind_ip: str = "0.0.0.0",
) -> dict:
    """Send one DCA control command and require a reply from the configured DCA IP."""
    IPv4Address(ip)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(timeout_s)
        sock.bind((bind_ip, port))
        sock.sendto(build_control_command(command, payload), (ip, port))
        data, source = sock.recvfrom(4096)
    if source[0] != ip:
        raise ProtocolError(f"unexpected DCA control response source {source[0]}:{source[1]}; expected IP {ip}")
    response = parse_control_response(data, expected_command=command)
    if response.status != 0:
        raise ProtocolError(f"DCA command {command:#x} failed with status {response.status:#x}")
    return {
        "command": command,
        "ok": True,
        "status": response.status,
        "source": f"{source[0]}:{source[1]}",
        "payload_hex": response.payload.hex(),
        "bound_source": f"{bind_ip}:{port}",
    }


def _dca_capture_payloads(config_path: str | Path) -> tuple[bytes, bytes]:
    """Build the documented DCA1000 FPGA and packet-record payloads from cf.json."""
    config = json.loads(Path(config_path).read_text(encoding="utf-8"))["DCA1000Config"]
    try:
        fpga = bytes((
            {"raw": 1, "multi": 2}[config["dataLoggingMode"]],
            {1: 1, 2: 2}[int(config["lvdsMode"])],
            {"LVDSCapture": 1, "playback": 2}[config["dataTransferMode"]],
            {"SDCardStorage": 1, "ethernetStream": 2}[config["dataCaptureMode"]],
            {1: 1, 2: 2, 3: 3}[int(config["dataFormatMode"])],
            0x1E,  # timer mode; the legacy tested implementation uses this fixed value
        ))
        # TI legacy DCA code programs max UDP data packet = 1470 B and converts
        # microseconds to 8 ns FPGA ticks.
        record = struct.pack("<HHH", 1470, int(float(config["packetDelay_us"]) * 1000 / 8), 0)
    except (KeyError, TypeError, ValueError) as exc:
        raise ProtocolError(f"invalid DCA1000Config in {config_path}: {exc}") from exc
    return fpga, record


def configure_dca_capture(ip: str, port: int, config_path: str | Path, *, timeout_s: float = 2.0, bind_ip: str = "0.0.0.0") -> dict:
    """Configure FPGA and record packet delay; this does not start streaming."""
    fpga_payload, record_payload = _dca_capture_payloads(config_path)
    return {
        "config_path": str(Path(config_path).resolve()),
        "fpga": send_dca_control(ip, port, CONFIG_FPGA, fpga_payload, timeout_s=timeout_s, bind_ip=bind_ip),
        "record": send_dca_control(ip, port, CONFIG_RECORD, record_payload, timeout_s=timeout_s, bind_ip=bind_ip),
        "recording_started": False,
    }


def start_dca_stream(ip: str, port: int, *, timeout_s: float = 2.0, bind_ip: str = "0.0.0.0") -> dict:
    return send_dca_control(ip, port, STREAM_START, timeout_s=timeout_s, bind_ip=bind_ip)


def stop_dca_stream(ip: str, port: int, *, timeout_s: float = 2.0, bind_ip: str = "0.0.0.0") -> dict:
    return send_dca_control(ip, port, STREAM_STOP, timeout_s=timeout_s, bind_ip=bind_ip)


def inspect_raw_datagrams(chunks: Iterable[bytes], *, packet_bytes: int = DEFAULT_PACKET_BYTES) -> PacketQuality:
    tracker = PacketTracker(expected_packet_bytes=packet_bytes)
    for chunk in chunks:
        try:
            packet = parse_data_packet(chunk, expected_packet_bytes=packet_bytes)
        except ProtocolError:
            tracker.quality.short_packets += 1
            continue
        tracker.observe(packet)
    return tracker.quality
