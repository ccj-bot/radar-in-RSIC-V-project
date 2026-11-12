from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from radar_capture.profiles.throughput import estimate_frame_bytes, estimate_raw_rate_MBps

_KEY_VALUE_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;#\r\n]+)")


@dataclass
class MmwaveConfigSummary:
    config_path: str
    channel_tx_mask: int | None
    channel_rx_mask: int | None
    effective_tx_sequence: list[int]
    effective_rx_channels: list[int]
    adc_samples: int | None
    adc_samples_source: str | None
    chirp_start: int | None
    chirp_end: int | None
    loop_count: int | None
    chirps_per_frame: int | None
    frame_periodicity_ms: float | None
    frame_periodicity_source: str | None
    frame_rate_hz: float | None
    rx_count: int
    tx_count_effective: int
    frame_bytes: int | None
    estimated_raw_rate_MBps: float | None
    risk_level: str
    warnings: list[str]
    raw_commands_count: int


def _parse_int(value: str) -> int | None:
    try:
        return int(float(value.strip()))
    except ValueError:
        return None


def decode_tx_mask(mask: int) -> list[int]:
    return [idx for idx, bit in enumerate([1, 2, 4]) if mask & bit]


def decode_rx_mask(mask: int) -> list[int]:
    return [idx for idx, bit in enumerate([1, 2, 4, 8]) if mask & bit]


def _risk(rate: float | None) -> str:
    from radar_capture.profiles.throughput import classify_raw_rate
    return classify_raw_rate(rate)


def parse_mmwave_config(path: str | Path) -> MmwaveConfigSummary:
    p = Path(path)
    warnings: list[str] = []
    current_section = ""
    profiles: list[dict[str, Any]] = []
    chirps: dict[int, dict[str, Any]] = {}
    frame: dict[str, Any] = {}
    top: dict[str, Any] = {}
    raw_commands_count = 0
    current_profile: dict[str, Any] | None = None
    current_chirp: dict[str, Any] | None = None

    for raw_line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = raw_line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            lower = stripped.lower()
            if "rlprofilecfg" in lower:
                current_section = "profile"
                current_profile = {"raw_line": raw_line}
                profiles.append(current_profile)
                current_chirp = None
            elif "rlchirpcfg" in lower:
                current_section = "chirp"
                current_chirp = {"raw_line": raw_line}
                current_profile = None
            elif "rlframecfg" in lower:
                current_section = "frame"
                current_profile = None
                current_chirp = None
            elif stripped.upper().startswith("#END"):
                if current_section == "chirp" and current_chirp is not None:
                    idx = current_chirp.get("chirpStartIdx")
                    if isinstance(idx, int):
                        chirps[idx] = dict(current_chirp)
                current_section = ""
                current_profile = None
                current_chirp = None
            continue
        m = _KEY_VALUE_RE.match(raw_line)
        if not m:
            warnings.append(f"unparsed line retained: {raw_line[:80]}")
            continue
        raw_commands_count += 1
        key, value_text = m.group(1), m.group(2).strip()
        value = _parse_int(value_text)
        if value is None:
            warnings.append(f"could not parse integer field {key}={value_text}")
            continue
        if key in ("channelTx", "channelRx"):
            top[key] = value
        if current_section == "profile" and current_profile is not None:
            current_profile[key] = value
        elif current_section == "chirp" and current_chirp is not None:
            current_chirp[key] = value
        elif current_section == "frame" or key in ("chirpStartIdxFCF", "chirpEndIdxFCF", "loopCount", "framePeriodicity", "subFramePeriodicity"):
            frame[key] = value

    channel_tx_mask = top.get("channelTx")
    channel_rx_mask = top.get("channelRx")
    effective_rx_channels = decode_rx_mask(channel_rx_mask) if isinstance(channel_rx_mask, int) else []
    if channel_rx_mask is None:
        warnings.append("channelRx not found")

    chirp_start = frame.get("chirpStartIdxFCF")
    chirp_end = frame.get("chirpEndIdxFCF")
    loop_count = frame.get("loopCount")
    selected_chirps = list(range(chirp_start, chirp_end + 1)) if isinstance(chirp_start, int) and isinstance(chirp_end, int) else []
    if not selected_chirps:
        warnings.append("frame chirpStartIdxFCF/chirpEndIdxFCF not found")

    effective_tx_sequence: list[int] = []
    for chirp_idx in selected_chirps:
        chirp = chirps.get(chirp_idx)
        if not chirp:
            warnings.append(f"selected chirp {chirp_idx} not found")
            continue
        tx_enable = chirp.get("txEnable")
        if isinstance(tx_enable, int):
            effective_tx_sequence.extend(decode_tx_mask(tx_enable))
        else:
            warnings.append(f"txEnable missing for selected chirp {chirp_idx}")

    chirps_per_frame = len(selected_chirps) * loop_count if selected_chirps and isinstance(loop_count, int) else None
    if chirps_per_frame is None:
        warnings.append("chirps_per_frame could not be computed")

    profile_by_id = {prof.get("profileId"): prof for prof in profiles if isinstance(prof.get("profileId"), int)}
    selected_profile_ids: list[int] = []
    for chirp_idx in selected_chirps:
        chirp = chirps.get(chirp_idx)
        if chirp and isinstance(chirp.get("profileIdCPCFG"), int):
            profile_id = chirp["profileIdCPCFG"]
            if profile_id not in selected_profile_ids:
                selected_profile_ids.append(profile_id)

    adc_samples = None
    adc_samples_source = None
    if len(selected_profile_ids) == 1:
        selected_profile = profile_by_id.get(selected_profile_ids[0])
        if selected_profile and isinstance(selected_profile.get("numAdcSamples"), int):
            adc_samples = selected_profile["numAdcSamples"]
            adc_samples_source = f"profileId={selected_profile_ids[0]}"
    elif len(selected_profile_ids) > 1:
        warnings.append(f"multiple selected profile ids {selected_profile_ids}; adc_samples needs manual review")

    if adc_samples is None and profiles:
        for prof in profiles:
            if isinstance(prof.get("numAdcSamples"), int):
                adc_samples = prof["numAdcSamples"]
                adc_samples_source = f"first profileId={prof.get('profileId')}"
                warnings.append("using first profile numAdcSamples because selected chirp profile could not be resolved")
                break
    if adc_samples is None and isinstance(frame.get("numAdcSamples"), int):
        adc_samples = frame["numAdcSamples"]
        adc_samples_source = "frame"
        warnings.append("using frame numAdcSamples because profile numAdcSamples was not found")
    if adc_samples is None:
        warnings.append("numAdcSamples not found")
    elif isinstance(frame.get("numAdcSamples"), int) and frame["numAdcSamples"] != adc_samples:
        warnings.append(
            f"frame numAdcSamples={frame['numAdcSamples']} differs from selected {adc_samples_source} numAdcSamples={adc_samples}"
        )

    frame_periodicity_ms = None
    frame_periodicity_source = None
    if isinstance(frame.get("framePeriodicity"), int):
        frame_periodicity_ms = float(frame["framePeriodicity"])
        frame_periodicity_source = "framePeriodicity_ms"
    elif isinstance(frame.get("periodicity"), int):
        frame_periodicity_ms = float(frame["periodicity"]) * 5e-6
        frame_periodicity_source = "periodicity_5ns_ticks"
        warnings.append("framePeriodicity not found; derived frame_periodicity_ms from legacy periodicity using 5 ns ticks")
    elif isinstance(frame.get("subFramePeriodicity"), int):
        frame_periodicity_ms = float(frame["subFramePeriodicity"]) / 1_000_000.0
        frame_periodicity_source = "subFramePeriodicity_ns"
        warnings.append("framePeriodicity/periodicity not found; derived frame_periodicity_ms from subFramePeriodicity assuming ns")
    else:
        warnings.append("framePeriodicity/periodicity/subFramePeriodicity not found")

    frame_rate_hz = (1000.0 / frame_periodicity_ms) if frame_periodicity_ms and frame_periodicity_ms > 0 else None
    frame_bytes = None
    raw_rate = None
    if chirps_per_frame and effective_rx_channels and adc_samples:
        frame_bytes = estimate_frame_bytes(chirps_per_frame, len(effective_rx_channels), adc_samples)
        if frame_rate_hz:
            raw_rate = estimate_raw_rate_MBps(frame_bytes, frame_rate_hz)
    else:
        warnings.append("frame_bytes could not be computed from parsed fields")

    unique_tx = []
    for tx in effective_tx_sequence:
        if tx not in unique_tx:
            unique_tx.append(tx)

    return MmwaveConfigSummary(
        config_path=str(p),
        channel_tx_mask=channel_tx_mask,
        channel_rx_mask=channel_rx_mask,
        effective_tx_sequence=effective_tx_sequence,
        effective_rx_channels=effective_rx_channels,
        adc_samples=adc_samples,
        adc_samples_source=adc_samples_source,
        chirp_start=chirp_start,
        chirp_end=chirp_end,
        loop_count=loop_count,
        chirps_per_frame=chirps_per_frame,
        frame_periodicity_ms=frame_periodicity_ms,
        frame_periodicity_source=frame_periodicity_source,
        frame_rate_hz=frame_rate_hz,
        rx_count=len(effective_rx_channels),
        tx_count_effective=len(unique_tx),
        frame_bytes=frame_bytes,
        estimated_raw_rate_MBps=raw_rate,
        risk_level=_risk(raw_rate),
        warnings=warnings,
        raw_commands_count=raw_commands_count,
    )


def summary_to_dict(summary: MmwaveConfigSummary) -> dict[str, Any]:
    return asdict(summary)
