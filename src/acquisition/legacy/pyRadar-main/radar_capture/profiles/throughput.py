from __future__ import annotations


def estimate_frame_bytes(chirps_per_frame: int, rx_count: int, adc_samples: int, iq_components: int = 2, bytes_per_sample: int = 2) -> int:
    return int(chirps_per_frame) * int(rx_count) * int(adc_samples) * int(iq_components) * int(bytes_per_sample)


def estimate_raw_rate_MBps(frame_bytes: int, frame_rate_hz: float) -> float:
    return float(frame_bytes) * float(frame_rate_hz) / 1_000_000.0


def classify_raw_rate(raw_rate_MBps: float | None) -> str:
    if raw_rate_MBps is None:
        return "unknown"
    if raw_rate_MBps <= 90:
        return "safe"
    if raw_rate_MBps <= 115:
        return "warning"
    return "unsafe"
