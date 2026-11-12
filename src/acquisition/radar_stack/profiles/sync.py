"""Generate executable radar/DCA configs from one bilingual saved profile."""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
from typing import Any


class SyncError(ValueError):
    pass


def _value(form: dict[str, Any], key: str) -> Any:
    try:
        return form["fields"][key]["value"]
    except KeyError as exc:
        raise SyncError(f"missing fields.{key}.value") from exc


def _integer_value(form: dict[str, Any], key: str, *, minimum: int = 1, maximum: int | None = None) -> int:
    """Parse a form integer without silently accepting booleans or fractions."""
    raw = _value(form, key)
    if isinstance(raw, bool):
        raise SyncError(f"{key} must be an integer, not true/false")
    if isinstance(raw, float) and not raw.is_integer():
        raise SyncError(f"{key} must be an integer")
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise SyncError(f"{key} must be an integer") from exc
    if value < minimum or (maximum is not None and value > maximum):
        bounds = f"{minimum}..{maximum}" if maximum is not None else f">= {minimum}"
        raise SyncError(f"{key} must be in {bounds}")
    return value


def _positive_finite_float(form: dict[str, Any], key: str) -> float:
    raw = _value(form, key)
    if isinstance(raw, bool):
        raise SyncError(f"{key} must be a positive number, not true/false")
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise SyncError(f"{key} must be a positive number") from exc
    if not math.isfinite(value) or value <= 0:
        raise SyncError(f"{key} must be a finite positive number")
    return value


def _optional_positive_finite_float(form: dict[str, Any], key: str) -> float | None:
    if key not in form.get("fields", {}):
        return None
    return _positive_finite_float(form, key)


def _synchronize_frame_aligned_bin(fields: dict[str, Any], *, chirps_per_frame: int) -> tuple[int, int]:
    """Make physical bins an integer number of radar frames.

    Older forms stored only chirps-per-bin.  A legacy value is migrated only
    when it is already frame-aligned; otherwise refusing to guess is safer than
    silently making a cross-frame raw bin.
    """
    if chirps_per_frame <= 0:
        raise SyncError("chirps_per_frame must be positive before deriving a physical bin")
    frame_field = fields.get("physical_segment_frames")
    if frame_field is None:
        legacy = _integer_value({"fields": fields}, "physical_segment_pulses")
        if legacy % chirps_per_frame:
            raise SyncError(
                "legacy physical_segment_pulses is not an integer number of frames; "
                "choose physical_segment_frames instead of creating a cross-frame raw bin"
            )
        frames = legacy // chirps_per_frame
        fields["physical_segment_frames"] = {
            "zh": "每个物理 bin 的帧数（自动对齐）",
            "en": "Radar frames per physical bin (frame-aligned)",
            "value": frames,
        }
    else:
        frames = _integer_value({"fields": fields}, "physical_segment_frames")
    pulses = frames * chirps_per_frame
    fields["physical_segment_pulses"] = {
        "zh": "每个物理 bin 的 chirp 数（由帧数自动推导）",
        "en": "Chirps per physical bin (derived from whole frames)",
        "value": pulses,
    }
    return frames, pulses


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _replace_assignment(lines: list[str], section_marker: str, key: str, value: int) -> bool:
    """Replace a key only in the intended TI config section, never globally."""
    in_section = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("#") and section_marker in stripped:
            in_section = True
            continue
        if in_section and stripped.startswith("#rl") and section_marker not in stripped:
            in_section = False
        if in_section and stripped.startswith(f"{key}="):
            prefix = line[: len(line) - len(line.lstrip())]
            lines[index] = f"{prefix}{key}={value};\n"
            return True
    return False


def _replace_first_assignment(lines: list[str], key: str, value: int) -> bool:
    for index, line in enumerate(lines):
        if line.strip().startswith(f"{key}="):
            prefix = line[: len(line) - len(line.lstrip())]
            lines[index] = f"{prefix}{key}={value};\n"
            return True
    return False


def _first_assignment_int(lines: list[str], key: str) -> int | None:
    for line in lines:
        stripped = line.strip()
        if stripped.startswith(f"{key}="):
            try:
                return int(stripped.split("=", 1)[1].split(";", 1)[0])
            except ValueError as exc:
                raise SyncError(f"template field {key} must be an integer") from exc
    return None


def _replace_profile0_assignment(lines: list[str], key: str, value: int) -> bool:
    current_profile: int | None = None
    in_profile = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("#rlProfileCfg_t"):
            in_profile = True
            current_profile = None
            continue
        if in_profile and stripped.startswith("#rl") and "rlProfileCfg_t" not in stripped:
            in_profile = False
        if in_profile and stripped.startswith("profileId="):
            current_profile = int(stripped.split("=", 1)[1].split(";", 1)[0])
        if in_profile and current_profile == 0 and stripped.startswith(f"{key}="):
            prefix = line[: len(line) - len(line.lstrip())]
            lines[index] = f"{prefix}{key}={value};\n"
            return True
    return False


def _rewrite_selected_chirp_sections(lines: list[str], tx_sequence: list[int]) -> bool:
    """Make the first N chirp sections a deterministic TX sequence 0..N-1.

    The form deliberately permits one profile/ADC/RX geometry per frame.  That
    keeps every chirp the same byte size, which is the contract of the raw-bin
    receiver.  More exotic mixed-profile schedules are rejected by validation.
    """
    section = ""
    chirp_index = -1
    changed = 0
    for index, line in enumerate(lines):
        stripped = line.strip()
        lower = stripped.lower()
        if stripped.startswith("#"):
            if "rlchirpcfg" in lower:
                section = "chirp"
                chirp_index += 1
            elif stripped.startswith("#rl"):
                section = "other"
            continue
        if section != "chirp" or chirp_index >= len(tx_sequence):
            continue
        replacements = {
            "chirpStartIdx": chirp_index,
            "chirpEndIdx": chirp_index,
            "profileIdCPCFG": 0,
            "txEnable": 1 << tx_sequence[chirp_index],
        }
        for key, value in replacements.items():
            if stripped.startswith(f"{key}="):
                prefix = line[: len(line) - len(line.lstrip())]
                lines[index] = f"{prefix}{key}={value};\n"
                changed += 1
                break
    return changed == len(tx_sequence) * 4


def generated_dir(root: Path, profile_name: str) -> Path:
    return root / "config" / "profiles" / "generated" / profile_name


def sync_profile(root: Path, profile_name: str) -> dict[str, Any] | None:
    """Synchronize a configurable profile; returns None for legacy static forms."""
    root = Path(root).resolve()
    profile_path = root / "config" / "profiles" / "saved" / f"{profile_name}.json"
    form = json.loads(profile_path.read_text(encoding="utf-8"))
    fields = form.get("fields", {})
    if "radar_config_template" not in fields:
        return None

    radar_template = root / str(_value(form, "radar_config_template"))
    dca_template = root / str(_value(form, "dca_config_template"))
    if not radar_template.is_file() or not dca_template.is_file():
        raise SyncError(f"missing configuration template: radar={radar_template}, dca={dca_template}")
    # These are format-level checks, not a substitute for the later real-stream
    # validation.  We restrict only facts known from the AWR2243/DCA bit layout
    # and keep TI-specific rate/profile acceptance under the 10-frame gate.
    adc_samples = _integer_value(form, "radar_profile0_adc_samples", maximum=65535)
    loop_count = _integer_value(form, "radar_frame_loop_count")
    periodicity = _integer_value(form, "radar_frame_periodicity_ticks")
    rx_mask = _integer_value(form, "radar_channel_rx_mask", maximum=15)
    if "radar_channel_tx_mask" not in fields:
        fields["radar_channel_tx_mask"] = {
            "zh": "可用发射天线掩码",
            "en": "Enabled TX antenna mask",
            "value": 7,
        }
    tx_mask = _integer_value(form, "radar_channel_tx_mask", maximum=7)
    lane_mask = _integer_value(form, "radar_lvds_lane_mask", maximum=15)
    data_rate = _integer_value(form, "radar_lvds_data_rate_code")
    packet_delay = _positive_finite_float(form, "dca_packet_delay_us")
    if not 5.0 <= packet_delay <= 500.0:
        raise SyncError("dca_packet_delay_us must remain in the TI-supported 5..500 us range")
    idle_time = (
        _integer_value(form, "radar_profile0_idle_time_ticks", minimum=0, maximum=524287)
        if "radar_profile0_idle_time_ticks" in fields else None
    )
    ramp_end_time = (
        _integer_value(form, "radar_profile0_ramp_end_time_ticks", minimum=1, maximum=500000)
        if "radar_profile0_ramp_end_time_ticks" in fields else None
    )
    if "radar_chirp_tx_sequence" not in fields:
        fields["radar_chirp_tx_sequence"] = {
            "zh": "一个 chirp 循环内的 TX 天线顺序（0/1/2）",
            "en": "TX antenna sequence within one chirp cycle (0/1/2)",
            "value": [0],
        }
    raw_tx_sequence = fields["radar_chirp_tx_sequence"].get("value", [0])
    if not isinstance(raw_tx_sequence, list) or not 1 <= len(raw_tx_sequence) <= 3:
        raise SyncError("radar_chirp_tx_sequence must be a JSON list of 1..3 TX indices, such as [0, 1, 2]")
    if any(isinstance(item, bool) for item in raw_tx_sequence):
        raise SyncError("radar_chirp_tx_sequence entries must be integer TX indices, not true/false")
    try:
        tx_sequence = [int(item) for item in raw_tx_sequence]
    except (TypeError, ValueError) as exc:
        raise SyncError("radar_chirp_tx_sequence entries must be integer TX indices") from exc
    if any(isinstance(item, float) and not item.is_integer() for item in raw_tx_sequence):
        raise SyncError("radar_chirp_tx_sequence entries must be integer TX indices")
    if any(item not in (0, 1, 2) for item in tx_sequence):
        raise SyncError("radar_chirp_tx_sequence may use TX antenna indices 0, 1, 2 only")
    required_tx_mask = sum(1 << item for item in set(tx_sequence))
    if tx_mask & required_tx_mask != required_tx_mask:
        raise SyncError("radar_channel_tx_mask must enable every TX antenna used by radar_chirp_tx_sequence")
    chirps_per_frame = loop_count * len(tx_sequence)

    # Human-facing profiles may specify frame rate and desired blanking directly.
    # The low-level TI ticks remain in the saved form as generated evidence, but
    # are not something an experiment operator needs to calculate by hand.
    target_fps = _optional_positive_finite_float(form, "radar_target_frame_rate_hz")
    target_blank_ms = _optional_positive_finite_float(form, "radar_target_frame_blank_time_ms")
    if (target_fps is None) != (target_blank_ms is None):
        raise SyncError(
            "radar_target_frame_rate_hz and radar_target_frame_blank_time_ms must be provided together"
        )
    if target_fps is not None and target_blank_ms is not None:
        if ramp_end_time is None:
            raise SyncError(
                "radar_profile0_ramp_end_time_ticks is required when deriving timing from target frame rate"
            )
        if target_blank_ms < 0.3:
            raise SyncError("target inter-frame blank time must be at least the TI 0.3 ms minimum")
        periodicity = int(round(200_000_000.0 / target_fps))
        frame_period_ms = periodicity * 5e-6
        available_chirp_time_us = (frame_period_ms - target_blank_ms) * 1000.0 / chirps_per_frame
        ramp_end_us = ramp_end_time * 0.01
        derived_idle_us = available_chirp_time_us - ramp_end_us
        if derived_idle_us < 0:
            raise SyncError(
                "target frame rate is impossible: ramp time alone exceeds the frame-on budget"
            )
        idle_time = int(math.floor(derived_idle_us / 0.01 + 1e-9))
        if idle_time > 524287:
            raise SyncError("derived radar_profile0_idle_time_ticks exceeds the AWR2243 field limit")
        fields["radar_frame_periodicity_ticks"]["value"] = periodicity
        if "radar_profile0_idle_time_ticks" not in fields:
            fields["radar_profile0_idle_time_ticks"] = {
                "zh": "Profile 0 空闲时间 tick（由目标帧率自动推导）",
                "en": "Profile 0 idle-time ticks (derived from target frame rate)",
                "value": idle_time,
            }
        else:
            fields["radar_profile0_idle_time_ticks"]["value"] = idle_time
    physical_segment_frames, physical_segment_pulses = _synchronize_frame_aligned_bin(
        fields,
        chirps_per_frame=chirps_per_frame,
    )

    lines = radar_template.read_text(encoding="utf-8").splitlines(keepends=True)
    adc_format = _first_assignment_int(lines, "adcFormat")
    if adc_format not in (0, 1, 2):
        raise SyncError("radar template adcFormat must be 0 (real), 1 (complex 1x), or 2 (complex 2x)")
    frame_adc_samples = adc_samples * (1 if adc_format == 0 else 2)
    if frame_adc_samples > 65535:
        raise SyncError("derived frame numAdcSamples exceeds the 16-bit field limit")
    updates = {
        "profile0_numAdcSamples": _replace_profile0_assignment(lines, "numAdcSamples", adc_samples),
        "frame_numAdcSamples": _replace_assignment(lines, "rlFrameCfg_t", "numAdcSamples", frame_adc_samples),
        "frame_loopCount": _replace_assignment(lines, "rlFrameCfg_t", "loopCount", loop_count),
        "frame_periodicity": _replace_assignment(lines, "rlFrameCfg_t", "periodicity", periodicity),
        "channelRx": _replace_first_assignment(lines, "channelRx", rx_mask),
        "channelTx": _replace_first_assignment(lines, "channelTx", tx_mask),
        "laneEn": _replace_first_assignment(lines, "laneEn", lane_mask),
        "dataRate": _replace_first_assignment(lines, "dataRate", data_rate),
        "chirp_tx_sequence": _rewrite_selected_chirp_sections(lines, tx_sequence),
        "frame_chirp_start": _replace_assignment(lines, "rlFrameCfg_t", "chirpStartIdxFCF", 0),
        "frame_chirp_end": _replace_assignment(lines, "rlFrameCfg_t", "chirpEndIdxFCF", len(tx_sequence) - 1),
    }
    if idle_time is not None:
        updates["profile0_idleTimeConst"] = _replace_profile0_assignment(lines, "idleTimeConst", idle_time)
    if ramp_end_time is not None:
        updates["profile0_rampEndTime"] = _replace_profile0_assignment(lines, "rampEndTime", ramp_end_time)
    if not all(updates.values()):
        missing = [name for name, found in updates.items() if not found]
        raise SyncError(f"radar template sections missing expected parameters: {missing}")

    dca = json.loads(dca_template.read_text(encoding="utf-8"))
    dca["DCA1000Config"]["packetDelay_us"] = packet_delay
    output = generated_dir(root, profile_name)
    output.mkdir(parents=True, exist_ok=True)
    radar_path = output / "mmwave.cfg"
    dca_path = output / "dca1000.json"
    radar_temp = radar_path.with_suffix(radar_path.suffix + ".part")
    dca_temp = dca_path.with_suffix(dca_path.suffix + ".part")
    radar_temp.write_text("".join(lines), encoding="utf-8")
    dca_temp.write_text(json.dumps(dca, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    from radar_stack.profiles.timing import derive_radar_timing

    timing = derive_radar_timing(radar_temp)
    if timing["frame_blank_time_ms"] + 1e-9 < timing["ti_minimum_inter_frame_blank_ms"]:
        radar_temp.unlink(missing_ok=True)
        dca_temp.unlink(missing_ok=True)
        raise SyncError(
            "generated frame timing violates TI minimum blank time: "
            f"{timing['frame_blank_time_ms']:.6f} ms"
        )
    radar_temp.replace(radar_path)
    dca_temp.replace(dca_path)

    form["fields"]["radar_config"]["value"] = str(radar_path.relative_to(root))
    form["fields"]["dca_config"]["value"] = str(dca_path.relative_to(root))
    manifest = {
        "schema": "nx-radar-generated-profile/v1",
        "profile_name": profile_name,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "radar_template": str(radar_template),
        "dca_template": str(dca_template),
        "generated_radar_config": str(radar_path),
        "generated_dca_config": str(dca_path),
        "applied_values": {key: _value(form, key) for key in ("radar_profile0_adc_samples", "radar_frame_loop_count", "radar_frame_periodicity_ticks", "radar_channel_rx_mask", "radar_channel_tx_mask", "radar_lvds_lane_mask", "radar_lvds_data_rate_code", "dca_packet_delay_us")},
        "sha256": {"radar": _sha256(radar_path), "dca": _sha256(dca_path)},
    }
    manifest["applied_values"]["radar_chirp_tx_sequence"] = tx_sequence
    manifest["applied_values"]["radar_adc_format"] = adc_format
    manifest["applied_values"]["radar_frame_numAdcSamples"] = frame_adc_samples
    manifest["applied_values"]["physical_segment_frames"] = physical_segment_frames
    manifest["applied_values"]["physical_segment_pulses"] = physical_segment_pulses
    if idle_time is not None:
        manifest["applied_values"]["radar_profile0_idle_time_ticks"] = idle_time
    if ramp_end_time is not None:
        manifest["applied_values"]["radar_profile0_ramp_end_time_ticks"] = ramp_end_time
    if target_fps is not None and target_blank_ms is not None:
        manifest["applied_values"]["radar_target_frame_rate_hz"] = target_fps
        manifest["applied_values"]["radar_target_frame_blank_time_ms"] = target_blank_ms
    manifest["physical_timing"] = timing
    (output / "generation_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp = profile_path.with_suffix(".json.part")
    temp.write_text(json.dumps(form, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(profile_path)
    return manifest
