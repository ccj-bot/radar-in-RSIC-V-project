from __future__ import annotations

import json
import math
from pathlib import Path
import shutil
from typing import Any


class FormError(ValueError):
    """The bilingual profile form is incomplete or inconsistent."""


def _value(form: dict[str, Any], key: str) -> Any:
    try:
        return form["fields"][key]["value"]
    except (KeyError, TypeError) as exc:
        raise FormError(f"missing fields.{key}.value") from exc


def build_capture_plan(form_path: str | Path, *, project_root: str | Path) -> dict[str, Any]:
    form_path = Path(form_path).resolve()
    root = Path(project_root).resolve()
    try:
        form = json.loads(form_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise FormError(f"form must be valid JSON: {exc}") from exc

    profile_name = str(_value(form, "profile_name")).strip()
    radar_config_text = str(_value(form, "radar_config")).strip()
    capture_mode = str(_value(form, "capture_mode")).strip()
    raw_frames = _value(form, "frames")
    frames = int(raw_frames) if raw_frames not in (None, "") else 0
    segment_pulses = int(_value(form, "physical_segment_pulses"))
    raw_segment_frames = form.get("fields", {}).get("physical_segment_frames", {}).get("value")
    segment_frames = int(raw_segment_frames) if raw_segment_frames not in (None, "") else None
    window_pulses = [int(item) for item in _value(form, "reconstruction_windows")]
    stop_after_gib = float(_value(form, "stop_after_gib"))
    reserve_disk_gib = float(_value(form, "reserve_disk_gib"))
    profile_usage = str(form.get("fields", {}).get("profile_usage", {}).get("value") or "formal").strip()
    if not profile_name or not radar_config_text:
        raise FormError("profile_name and radar_config must not be empty")
    if capture_mode not in {"finite_frames", "continuous_until_data_budget", "manual_stop_with_data_cap", "manual_until_disk_reserve"}:
        raise FormError("capture_mode must be finite_frames, continuous_until_data_budget, or manual_stop_with_data_cap")
    if segment_pulses <= 0 or not window_pulses or min(window_pulses) <= 0:
        raise FormError("physical_segment_pulses and reconstruction_windows must be positive")
    if capture_mode == "finite_frames" and frames <= 0:
        raise FormError("frames must be positive in finite_frames mode")
    if capture_mode in {"continuous_until_data_budget", "manual_stop_with_data_cap"} and stop_after_gib <= 0:
        raise FormError("stop_after_gib must be positive in data-budget modes")
    if not math.isfinite(reserve_disk_gib) or reserve_disk_gib < 0:
        raise FormError("reserve_disk_gib must not be negative")
    if capture_mode == "manual_until_disk_reserve" and reserve_disk_gib < 1:
        raise FormError("continuous capture must reserve at least 1 GiB")
    if profile_usage not in {"formal", "stress_only", "mimo_experimental"}:
        raise FormError("profile_usage must be formal, stress_only, or mimo_experimental")

    config_path = Path(radar_config_text)
    if not config_path.is_absolute():
        config_path = root / config_path
    if not config_path.is_file():
        raise FormError(f"radar_config does not exist: {config_path}")

    from radar_capture.profiles.mmwave_parser import parse_mmwave_config, summary_to_dict

    summary = parse_mmwave_config(config_path)
    if summary.chirps_per_frame <= 0 or summary.frame_bytes <= 0:
        raise FormError("parsed configuration has no usable frame geometry")
    if summary.frame_bytes % summary.chirps_per_frame:
        raise FormError("frame_bytes is not divisible by chirps_per_frame; per-chirp segmentation is unsafe")

    parsed_bytes_per_chirp = summary.frame_bytes // summary.chirps_per_frame
    if segment_frames is not None:
        if segment_frames <= 0:
            raise FormError("physical_segment_frames must be positive")
        expected_segment_pulses = segment_frames * summary.chirps_per_frame
        if segment_pulses != expected_segment_pulses:
            raise FormError(
                "physical_segment_pulses must be derived from physical_segment_frames "
                f"({segment_frames} × {summary.chirps_per_frame} = {expected_segment_pulses})"
            )
    # A short real-stream validation is authoritative for the transport layout.
    # In particular, disabling an RX channel may still leave a fixed-width LVDS
    # slot on the wire.  Reuse an override only when its radar+DCA file hashes
    # match this exact saved profile.
    transport_geometry: dict[str, Any] = {
        "source": "parser",
        "parsed_bytes_per_chirp": parsed_bytes_per_chirp,
        "validated_override": False,
    }
    try:
        from radar_stack.profiles.validation import configuration_identity, validation_path
        identity = configuration_identity(root, form)
        record_path = validation_path(root, identity["fingerprint"])
        if record_path.is_file():
            record = json.loads(record_path.read_text(encoding="utf-8"))
            observed = int(record.get("verified_bytes_per_chirp", 0))
            if observed > 0:
                transport_geometry.update({
                    "source": "bounded_stream_validation",
                    "validated_override": observed != parsed_bytes_per_chirp,
                    "validation_record": str(record_path),
                    "validated_bytes_per_chirp": observed,
                })
                bytes_per_chirp = observed
            else:
                bytes_per_chirp = parsed_bytes_per_chirp
        else:
            bytes_per_chirp = parsed_bytes_per_chirp
    except (OSError, ValueError, json.JSONDecodeError):
        bytes_per_chirp = parsed_bytes_per_chirp
    segment_bytes = segment_pulses * bytes_per_chirp
    disk = shutil.disk_usage(root / "sessions")
    reserve_bytes = int(reserve_disk_gib * 1024**3)
    usable_bytes = max(0, disk.free - reserve_bytes)
    if capture_mode == "finite_frames":
        total_pulses = frames * summary.chirps_per_frame
        full_segments, tail_pulses = divmod(total_pulses, segment_pulses)
        segment_count = full_segments + (1 if tail_pulses else 0)
        planned_bytes = total_pulses * bytes_per_chirp
    else:
        requested_bytes = usable_bytes if capture_mode == "manual_until_disk_reserve" else int(stop_after_gib * 1024**3)
        if requested_bytes > usable_bytes:
            raise FormError(f"requested {stop_after_gib:.2f} GiB exceeds usable disk budget {usable_bytes / 1024**3:.2f} GiB after reserve")
        segment_count = requested_bytes // segment_bytes
        if segment_count == 0:
            raise FormError("stop_after_gib is smaller than one physical segment")
        total_pulses = segment_count * segment_pulses
        tail_pulses = 0
        planned_bytes = segment_count * segment_bytes
        frames = total_pulses / summary.chirps_per_frame
    raw_rate_mibps = summary.estimated_raw_rate_MBps
    if summary.frame_periodicity_ms and summary.frame_periodicity_ms > 0:
        raw_rate_mibps = bytes_per_chirp * summary.chirps_per_frame / (summary.frame_periodicity_ms / 1000.0) / 1024**2
    from radar_stack.profiles.timing import dca_theoretical_throughput_mbps, derive_radar_timing

    timing_model = derive_radar_timing(config_path)
    if timing_model["frame_blank_time_ms"] + 1e-9 < timing_model["ti_minimum_inter_frame_blank_ms"]:
        raise FormError(
            "frame timing violates TI minimum inter-frame blank time: "
            f"{timing_model['frame_blank_time_ms']:.6f} ms < "
            f"{timing_model['ti_minimum_inter_frame_blank_ms']:.3f} ms"
        )
    packet_delay_us = float(_value(form, "dca_packet_delay_us"))
    dca_capacity_mbps = dca_theoretical_throughput_mbps(packet_delay_us)
    payload_mbps = raw_rate_mibps * 1024**2 * 8.0 / 1e6
    dca_utilization = payload_mbps / dca_capacity_mbps
    conservative_wire_overhead_factor = 1.06
    estimated_wire_mbps = payload_mbps * conservative_wire_overhead_factor
    link_utilization = estimated_wire_mbps / 1000.0
    frame_bytes = bytes_per_chirp * summary.chirps_per_frame
    dca_formal_payload_limit_mbps = dca_capacity_mbps * 0.90
    link_formal_payload_limit_mbps = 1000.0 * 0.80 / conservative_wire_overhead_factor
    max_formal_fps_by_dca = dca_formal_payload_limit_mbps * 1e6 / (frame_bytes * 8.0)
    max_formal_fps_by_link = link_formal_payload_limit_mbps * 1e6 / (frame_bytes * 8.0)
    if dca_utilization >= 0.90:
        raise FormError(
            "planned ADC payload is too close to the DCA1000 packet-delay limit: "
            f"{payload_mbps:.2f} / {dca_capacity_mbps:.2f} Mb/s = {dca_utilization:.1%}; "
            "keep formal profiles below 90%"
        )
    window_plan = []
    for pulses in window_pulses:
        full_bins, tail = divmod(pulses, segment_pulses)
        window_plan.append({
            "window_pulses": pulses,
            "window_bytes": pulses * bytes_per_chirp,
            "full_segment_count": full_bins,
            "tail_pulses_from_next_segment": tail,
        })

    labels = {key: {"zh": item.get("zh"), "en": item.get("en"), "value": item.get("value")} for key, item in form["fields"].items()}
    return {
        "schema": "nx-radar-capture-plan/v1",
        "profile_name": profile_name,
        "source_form": str(form_path),
        "input_fields": labels,
        "radar_profile_summary": summary_to_dict(summary),
        "transport_geometry": transport_geometry,
        "derived": {
            "bytes_per_chirp": bytes_per_chirp,
            "chirps_per_frame": summary.chirps_per_frame,
            "capture_mode": capture_mode,
            "profile_usage": profile_usage,
            "frames": frames,
            "total_pulses": total_pulses,
            "total_expected_bytes": planned_bytes,
            "receiver_max_bytes": ((2**63 - 1) // segment_bytes * segment_bytes) if capture_mode == "manual_until_disk_reserve" else planned_bytes,
            "stop_policy": "manual_or_disk_reserve" if capture_mode == "manual_until_disk_reserve" else "manual_or_data_cap",
            "disk_stop_guard_bytes": max(1024**3, 2 * segment_bytes, int(raw_rate_mibps * 1024**2 * 5)),
            "physical_segment_pulses": segment_pulses,
            "physical_segment_frames": segment_frames,
            "physical_segment_full_bytes": segment_bytes,
            "physical_segment_count": segment_count,
            "last_segment_pulses": tail_pulses or segment_pulses,
            "segment_matches_frame_boundary": segment_pulses % summary.chirps_per_frame == 0,
            "segment_interval_ms": segment_pulses / summary.chirps_per_frame * summary.frame_periodicity_ms,
            "estimated_raw_rate_MiBps": raw_rate_mibps,
            "timing_model": timing_model,
            "transport_budget": {
                "dca_packet_delay_us": packet_delay_us,
                "dca_theoretical_payload_capacity_mbps": dca_capacity_mbps,
                "planned_adc_payload_mbps": payload_mbps,
                "conservative_wire_overhead_factor": conservative_wire_overhead_factor,
                "estimated_ethernet_wire_mbps": estimated_wire_mbps,
                "gigabit_link_utilization": link_utilization,
                "dca_utilization": dca_utilization,
                "dca_headroom_fraction": 1.0 - dca_utilization,
                "formal_profile_utilization_limit": 0.90,
                "formal_link_utilization_limit": 0.80,
                "max_formal_fps_by_dca_packet_delay": max_formal_fps_by_dca,
                "max_formal_fps_by_gigabit_link": max_formal_fps_by_link,
                "max_formal_fps_combined": min(max_formal_fps_by_dca, max_formal_fps_by_link),
            },
            "stop_after_gib_requested": stop_after_gib if capture_mode not in {"finite_frames", "manual_until_disk_reserve"} else None,
            "disk_free_gib_at_plan_time": round(disk.free / 1024**3, 3),
            "reserve_disk_gib": reserve_disk_gib,
            "usable_disk_gib_at_plan_time": round(usable_bytes / 1024**3, 3),
            "reconstruction_windows": window_plan,
        },
        "integrity_rules": {
            "position_source": "DCA1000 6-byte cumulative byte_count; sequence is a cross-check",
            "zero_fill_allowed": False,
            "finalize_rule": "write .bin.part, verify, flush/close, then atomically rename to .bin",
            "continuous_stop_rule": "stop only after a complete segment closes at or below the approved data budget",
            "manual_stop_rule": "finish current physical segment, then stop sensor and DCA; disk reserve is monitored during capture",
        },
    }
