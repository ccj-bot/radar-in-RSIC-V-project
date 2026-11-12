"""Derive the physical FMCW and frame timeline from a generated TI config."""
from __future__ import annotations

import math
from pathlib import Path
import re
from typing import Any


_ASSIGNMENT = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;#\r\n]+)")
_C_MPS = 299_792_458.0
_START_FREQ_LSB_HZ = 3.6e9 / (2**26)
_SLOPE_LSB_HZ_PER_US = 3.6e9 * 900.0 / (2**26)
_DCA_THROUGHPUT_TABLE = ((5.0, 706.0), (10.0, 545.0), (25.0, 325.0), (50.0, 193.0))


class TimingError(ValueError):
    pass


def _parse_int(text: str) -> int:
    try:
        return int(float(text.strip()))
    except ValueError as exc:
        raise TimingError(f"TI timing field is not an integer: {text!r}") from exc


def _parse_sections(config_path: Path) -> tuple[list[dict[str, int]], dict[int, dict[str, int]], dict[str, int]]:
    profiles: list[dict[str, int]] = []
    chirps: dict[int, dict[str, int]] = {}
    frame: dict[str, int] = {}
    section = ""
    current: dict[str, int] | None = None

    for raw_line in config_path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = raw_line.strip()
        if stripped.startswith("#"):
            lower = stripped.lower()
            if "rlprofilecfg_t" in lower:
                section = "profile"
                current = {}
                profiles.append(current)
            elif "rlchirpcfg_t" in lower:
                section = "chirp"
                current = {}
            elif "rlframecfg_t" in lower:
                section = "frame"
                current = frame
            elif stripped.upper().startswith("#END"):
                if section == "chirp" and current is not None and "chirpStartIdx" in current:
                    chirps[current["chirpStartIdx"]] = dict(current)
                section = ""
                current = None
            continue
        match = _ASSIGNMENT.match(raw_line)
        if not match or current is None:
            continue
        current[match.group(1)] = _parse_int(match.group(2))

    return profiles, chirps, frame


def dca_theoretical_throughput_mbps(packet_delay_us: float) -> float:
    """Conservative interpolation of TI DCA1000EVM User Guide table 19."""
    delay = float(packet_delay_us)
    if not math.isfinite(delay) or delay < 5.0 or delay > 500.0:
        raise TimingError("DCA packet delay must remain in the TI-supported 5..500 us range")
    for known_delay, throughput in _DCA_THROUGHPUT_TABLE:
        if abs(delay - known_delay) < 1e-9:
            return throughput
    for (left_delay, left_rate), (right_delay, right_rate) in zip(
        _DCA_THROUGHPUT_TABLE, _DCA_THROUGHPUT_TABLE[1:]
    ):
        if left_delay < delay < right_delay:
            fraction = (delay - left_delay) / (right_delay - left_delay)
            return left_rate + fraction * (right_rate - left_rate)
    # Above 50 us, scale conservatively from the last published point.
    return _DCA_THROUGHPUT_TABLE[-1][1] * _DCA_THROUGHPUT_TABLE[-1][0] / delay


def derive_radar_timing(config_path: str | Path) -> dict[str, Any]:
    path = Path(config_path).resolve()
    profiles, chirps, frame = _parse_sections(path)
    try:
        chirp_start = frame["chirpStartIdxFCF"]
        chirp_end = frame["chirpEndIdxFCF"]
        loop_count = frame["loopCount"]
        periodicity_ticks = frame["periodicity"]
    except KeyError as exc:
        raise TimingError(f"generated TI frame config is missing {exc.args[0]}") from exc
    if chirp_end < chirp_start or loop_count <= 0 or periodicity_ticks <= 0:
        raise TimingError("generated TI frame config has invalid chirp range, loop count, or period")

    selected = []
    profile_ids: set[int] = set()
    tx_masks: list[int] = []
    for chirp_index in range(chirp_start, chirp_end + 1):
        chirp = chirps.get(chirp_index)
        if chirp is None:
            raise TimingError(f"selected chirp {chirp_index} has no rlChirpCfg_t section")
        selected.append(chirp)
        profile_ids.add(chirp.get("profileIdCPCFG", -1))
        tx_masks.append(chirp.get("txEnable", 0))
    if len(profile_ids) != 1:
        raise TimingError(f"selected chirps use mixed profile IDs: {sorted(profile_ids)}")
    profile_id = next(iter(profile_ids))
    profile = next((item for item in profiles if item.get("profileId") == profile_id), None)
    if profile is None:
        raise TimingError(f"selected profileId={profile_id} has no rlProfileCfg_t section")

    required = (
        "idleTimeConst", "adcStartTimeConst", "rampEndTime", "freqSlopeConst",
        "startFreqConst", "numAdcSamples", "digOutSampleRate",
    )
    missing = [key for key in required if key not in profile]
    if missing:
        raise TimingError(f"selected rlProfileCfg_t is missing timing fields: {missing}")

    idle_time_us = profile["idleTimeConst"] * 0.01
    adc_start_time_us = profile["adcStartTimeConst"] * 0.01
    ramp_end_time_us = profile["rampEndTime"] * 0.01
    chirp_period_us = idle_time_us + ramp_end_time_us
    if chirp_period_us <= 0.0:
        raise TimingError("selected profile has a non-positive chirp period")
    chirps_per_frame = len(selected) * loop_count
    frame_period_ms = periodicity_ticks * 5e-6
    frame_on_time_ms = chirps_per_frame * chirp_period_us / 1000.0
    frame_blank_time_ms = frame_period_ms - frame_on_time_ms
    boundary_interval_us = chirp_period_us + frame_blank_time_ms * 1000.0
    sample_rate_hz = profile["digOutSampleRate"] * 1000.0
    adc_samples = profile["numAdcSamples"]
    if adc_samples <= 0 or sample_rate_hz <= 0.0:
        raise TimingError("selected profile has invalid ADC samples or sample rate")
    adc_capture_time_us = adc_samples / sample_rate_hz * 1e6
    if adc_start_time_us + adc_capture_time_us > ramp_end_time_us + 1e-9:
        raise TimingError(
            "ADC capture extends beyond ramp end: "
            f"{adc_start_time_us + adc_capture_time_us:.6f} us > {ramp_end_time_us:.6f} us"
        )
    slope_mhz_per_us = profile["freqSlopeConst"] * _SLOPE_LSB_HZ_PER_US / 1e6
    slope_hz_per_s = slope_mhz_per_us * 1e12
    if slope_hz_per_s <= 0.0:
        raise TimingError("selected profile must use a positive frequency slope")
    start_frequency_hz = profile["startFreqConst"] * _START_FREQ_LSB_HZ
    adc_bandwidth_hz = slope_hz_per_s * adc_capture_time_us * 1e-6
    center_frequency_hz = start_frequency_hz + slope_hz_per_s * (
        adc_start_time_us + adc_capture_time_us / 2.0
    ) * 1e-6
    range_resolution_m = _C_MPS / (2.0 * adc_bandwidth_hz)
    max_unambiguous_range_m = _C_MPS * sample_rate_hz / (2.0 * slope_hz_per_s)
    if center_frequency_hz <= 0.0 or adc_bandwidth_hz <= 0.0:
        raise TimingError("selected profile produced invalid RF center frequency or ADC bandwidth")

    return {
        "schema": "nx-radar-physical-timing/v1",
        "config_path": str(path),
        "profile_id": profile_id,
        "selected_chirp_indices": list(range(chirp_start, chirp_end + 1)),
        "selected_tx_masks": tx_masks,
        "unique_chirps_per_loop": len(selected),
        "loop_count": loop_count,
        "chirps_per_frame": chirps_per_frame,
        "idle_time_us": idle_time_us,
        "ramp_end_time_us": ramp_end_time_us,
        "chirp_period_us": chirp_period_us,
        "within_frame_prf_hz": 1e6 / chirp_period_us,
        "frame_period_ms": frame_period_ms,
        "frame_rate_hz": 1000.0 / frame_period_ms,
        "frame_on_time_ms": frame_on_time_ms,
        "frame_blank_time_ms": frame_blank_time_ms,
        "frame_boundary_interval_us": boundary_interval_us,
        "boundary_to_regular_interval_ratio": boundary_interval_us / chirp_period_us,
        "multi_frame_uniform_fft_safe": frame_blank_time_ms <= chirp_period_us * 0.0001,
        "adc_samples": adc_samples,
        "adc_sample_rate_hz": sample_rate_hz,
        "adc_capture_time_us": adc_capture_time_us,
        "start_frequency_hz": start_frequency_hz,
        "center_frequency_hz": center_frequency_hz,
        "wavelength_m": _C_MPS / center_frequency_hz,
        "frequency_slope_mhz_per_us": slope_mhz_per_us,
        "adc_bandwidth_hz": adc_bandwidth_hz,
        "range_resolution_m": range_resolution_m,
        "max_unambiguous_range_m": max_unambiguous_range_m,
        "ti_minimum_inter_frame_blank_ms": 0.3,
    }
