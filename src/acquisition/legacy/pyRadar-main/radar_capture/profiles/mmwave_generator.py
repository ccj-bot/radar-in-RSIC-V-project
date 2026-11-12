from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from radar_capture.core.errors import ProfileGenerateError
from radar_capture.core.json_utils import write_json
from radar_capture.core.path_utils import resolve_project_path, timestamp_slug
from radar_capture.profiles.mmwave_diff import build_diff
from radar_capture.profiles.mmwave_parser import parse_mmwave_config, summary_to_dict
from radar_capture.profiles.mmwave_validator import validate_summary
from radar_capture.profiles.profile_schema import ConceptRadarProfile

_KEY_VALUE_RE = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)([^;#\r\n]+)(.*)$")


@dataclass
class GeneratedArtifacts:
    generated_config: Path
    summary_json: Path
    diff_txt: Path
    validation_json: Path
    warnings: list[str]


def _rx_mask(channels: list[int]) -> int:
    value = 0
    for ch in channels:
        value |= 1 << ch
    return value


def _tx_mask(tx: int) -> int:
    return 1 << tx


def _replace_value(line: str, value: int | float) -> str:
    newline = "\n" if line.endswith("\n") else ""
    body = line[:-1] if newline else line
    m = _KEY_VALUE_RE.match(body)
    if not m:
        return line
    return f"{m.group(1)}{m.group(2)}{m.group(3)}{value}{m.group(5)}{newline}"


def _unique_output_base(out_dir: Path, profile_name: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", profile_name).strip("_") or "generated_profile"
    return out_dir / f"{safe}__{timestamp_slug()}"


def generate_profile(profile: ConceptRadarProfile, out_dir: str | Path = "configFiles/generated") -> GeneratedArtifacts:
    template_path = resolve_project_path(profile.template_config)
    if not template_path.exists():
        raise ProfileGenerateError(f"template config not found: {template_path}")
    out_path = resolve_project_path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)
    base = _unique_output_base(out_path, profile.profile_name)
    generated_config = base.with_suffix(".txt")
    summary_json = Path(str(base) + "__summary.json")
    diff_txt = Path(str(base) + "__diff.txt")
    validation_json = Path(str(base) + "__validation.json")

    lines = template_path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    warnings: list[str] = []
    changed = {"channelRx": False, "txEnable": False, "numAdcSamples": False, "loopCount": False, "framePeriodicity": False}
    current_section = ""
    selected_chirp_start = 0
    selected_chirp_end = max(0, len(profile.tx_sequence) - 1)
    selected_chirp_count = selected_chirp_end - selected_chirp_start + 1
    if profile.chirps_per_frame % selected_chirp_count != 0:
        warnings.append("chirps_per_frame is not divisible by selected chirp count; loopCount rounded down")
    loop_count = max(1, profile.chirps_per_frame // selected_chirp_count)
    frame_periodicity_ms = 1000.0 / profile.frame_rate_hz
    subframe_periodicity_ns = int(round(frame_periodicity_ms * 1_000_000.0))
    output: list[str] = []
    chirp_index_active: int | None = None

    for line in lines:
        stripped = line.strip()
        lower = stripped.lower()
        if stripped.startswith("#"):
            if "rlprofilecfg" in lower:
                current_section = "profile"
            elif "rlchirpcfg" in lower:
                current_section = "chirp"
                chirp_index_active = None
            elif "rlframecfg" in lower:
                current_section = "frame"
            elif stripped.upper().startswith("#END"):
                current_section = ""
                chirp_index_active = None
            output.append(line)
            continue
        m = _KEY_VALUE_RE.match(line)
        if not m:
            output.append(line)
            continue
        key = m.group(2)
        value_text = m.group(4).strip()
        if key == "channelRx":
            output.append(_replace_value(line, _rx_mask(profile.rx_channels)))
            changed["channelRx"] = True
            continue
        if current_section == "chirp" and key == "chirpStartIdx":
            try:
                chirp_index_active = int(float(value_text))
            except ValueError:
                warnings.append(f"could not parse chirpStartIdx line: {line.strip()}")
            output.append(line)
            continue
        if current_section == "chirp" and key == "txEnable" and chirp_index_active is not None:
            if selected_chirp_start <= chirp_index_active <= selected_chirp_end:
                tx_pos = chirp_index_active - selected_chirp_start
                tx = profile.tx_sequence[min(tx_pos, len(profile.tx_sequence) - 1)]
                output.append(_replace_value(line, _tx_mask(tx)))
                changed["txEnable"] = True
            else:
                output.append(line)
            continue
        if key == "numAdcSamples" and current_section in ("profile", "frame"):
            output.append(_replace_value(line, profile.adc_samples))
            changed["numAdcSamples"] = True
            continue
        if current_section == "frame" and key == "chirpStartIdxFCF":
            output.append(_replace_value(line, selected_chirp_start))
            continue
        if current_section == "frame" and key == "chirpEndIdxFCF":
            output.append(_replace_value(line, selected_chirp_end))
            continue
        if current_section == "frame" and key == "loopCount":
            output.append(_replace_value(line, loop_count))
            changed["loopCount"] = True
            continue
        if current_section == "frame" and key == "framePeriodicity":
            output.append(_replace_value(line, frame_periodicity_ms))
            changed["framePeriodicity"] = True
            continue
        if key == "subFramePeriodicity":
            output.append(_replace_value(line, subframe_periodicity_ns))
            changed["framePeriodicity"] = True
            continue
        if key == "numAdcSamplesAF":
            output.append(_replace_value(line, profile.adc_samples))
            continue
        output.append(line)

    for field, did_change in changed.items():
        if not did_change:
            warnings.append(f"whitelist field {field} was not found or not changed in template")

    generated_config.write_text("".join(output), encoding="utf-8")
    summary = parse_mmwave_config(generated_config)
    validation = validate_summary(summary, profile)
    diff = build_diff(template_path, generated_config)
    summary_payload: dict[str, Any] = summary_to_dict(summary)
    summary_payload.update({
        "profile_name": profile.profile_name,
        "template_config": str(template_path),
        "generated_config": str(generated_config),
        "segment_pulses": profile.segment_pulses,
        "segment_bytes": summary.frame_bytes if profile.segment_pulses == summary.chirps_per_frame else None,
        "generator_warnings": warnings,
    })
    write_json(summary_json, summary_payload)
    diff_txt.write_text(diff.diff_text, encoding="utf-8")
    validation_payload = validation.to_dict()
    validation_payload["generator_warnings"] = warnings
    validation_payload["changed_lines"] = diff.changed_lines
    write_json(validation_json, validation_payload)
    return GeneratedArtifacts(generated_config, summary_json, diff_txt, validation_json, warnings)
