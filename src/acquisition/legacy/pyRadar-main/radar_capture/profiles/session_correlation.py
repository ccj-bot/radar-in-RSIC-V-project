from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from radar_capture.core.json_utils import write_json
from radar_capture.core.path_utils import resolve_project_path
from radar_capture.profiles.mmwave_parser import parse_mmwave_config, summary_to_dict


def _load_json(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _session_dirs(root: Path, limit: int | None) -> list[Path]:
    sessions = sorted([p for p in root.iterdir() if p.is_dir()], key=lambda p: p.stat().st_mtime_ns)
    return sessions[-limit:] if limit else sessions


def _extract_session(session: Path) -> dict[str, Any] | None:
    manifest = _load_json(session / "session_manifest.json") or {}
    metadata = _load_json(session / "session_metadata.json") or {}
    mode_summary = _load_json(session / "radar/radar_mode_summary.json") or metadata.get("radar_mode_summary") or {}
    radar = manifest.get("radar") or {}
    adc = radar.get("adc_params") or {}
    if not mode_summary and not radar:
        return None
    config_path = mode_summary.get("config_path") or metadata.get("radar_config_path") or radar.get("radar_config")
    if not config_path:
        return None
    actual_frames = mode_summary.get("actual_radar_frames") or metadata.get("actual_radar_frames") or radar.get("num_frames")
    actual_bytes = mode_summary.get("actual_raw_bytes") or metadata.get("actual_raw_bytes") or radar.get("raw_bytes")
    requested_duration = metadata.get("requested_duration_sec") or (manifest.get("requested_capture") or {}).get("duration_seconds_requested")
    active_duration = (manifest.get("timing") or {}).get("radar_active_duration_seconds")
    observed_fps_by_duration = None
    if actual_frames and active_duration:
        try:
            observed_fps_by_duration = float(actual_frames) / float(active_duration)
        except Exception:
            pass
    return {
        "session": str(session),
        "session_name": session.name,
        "config_path": str(config_path),
        "config_name": Path(str(config_path)).name,
        "radar_mode": metadata.get("radar_mode") or mode_summary.get("mode"),
        "requested_duration_sec": requested_duration,
        "radar_active_duration_seconds": active_duration,
        "actual_radar_frames": actual_frames,
        "actual_raw_bytes": actual_bytes,
        "file_size_matches": mode_summary.get("file_size_matches") or metadata.get("file_size_matches"),
        "quality_status": (metadata.get("radar_quality") or radar.get("quality") or {}).get("capture_quality_status"),
        "observed_adc_samples": mode_summary.get("adc_samples") or adc.get("samples"),
        "observed_chirps_per_frame": mode_summary.get("chirps_per_frame") or adc.get("chirps"),
        "observed_rx_count": mode_summary.get("rx_count") or adc.get("rx"),
        "observed_tx_count": adc.get("tx") or len(mode_summary.get("txEnable") or []),
        "observed_frame_period_ms": mode_summary.get("frame_period_ms") or adc.get("frame_periodicity"),
        "observed_fps": mode_summary.get("fps") or mode_summary.get("expected_fps") or observed_fps_by_duration,
        "observed_frame_bytes": mode_summary.get("bytes_per_frame") or adc.get("frame_bytes"),
        "configured_frame_period_ns": radar.get("configured_frame_period_ns"),
    }


def build_session_correlation(session_root: str | Path = "/home/radar/capture_sessions", limit: int | None = None) -> dict[str, Any]:
    root = Path(session_root)
    rows: list[dict[str, Any]] = []
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for session in _session_dirs(root, limit) if root.exists() else []:
        extracted = _extract_session(session)
        if extracted:
            grouped[extracted["config_name"]].append(extracted)
    for config_name, sessions in sorted(grouped.items()):
        config_path = sessions[-1]["config_path"]
        parser = None
        parser_error = None
        try:
            p = Path(config_path)
            if not p.exists():
                p = resolve_project_path("configFiles") / config_name
            parser = summary_to_dict(parse_mmwave_config(p)) if p.exists() else None
        except Exception as exc:
            parser_error = repr(exc)
        latest = sessions[-1]
        mismatches: list[str] = []
        if parser:
            comparisons = [
                ("adc_samples", parser.get("adc_samples"), latest.get("observed_adc_samples")),
                ("chirps_per_frame", parser.get("chirps_per_frame"), latest.get("observed_chirps_per_frame")),
                ("rx_count", parser.get("rx_count"), latest.get("observed_rx_count")),
                ("frame_bytes", parser.get("frame_bytes"), latest.get("observed_frame_bytes")),
            ]
            for name, parsed, observed in comparisons:
                if parsed is not None and observed is not None and parsed != observed:
                    mismatches.append(f"{name}: parser={parsed}, observed={observed}")
            parsed_fps = parser.get("frame_rate_hz")
            obs_fps = latest.get("observed_fps")
            if isinstance(parsed_fps, (int, float)) and isinstance(obs_fps, (int, float)) and abs(float(parsed_fps) - float(obs_fps)) > 1.0:
                mismatches.append(f"fps: parser={parsed_fps:.3f}, observed={obs_fps:.3f}")
        rows.append({
            "config_name": config_name,
            "config_path": config_path,
            "session_count": len(sessions),
            "latest_session": latest,
            "parser_summary": parser,
            "parser_error": parser_error,
            "mismatches": mismatches,
        })
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "session_root": str(root),
        "config_count": len(rows),
        "rows": rows,
    }


def write_session_correlation_reports(report: dict[str, Any], json_out: str | Path, md_out: str | Path) -> None:
    write_json(resolve_project_path(json_out), report)
    md_path = resolve_project_path(md_out)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Session Config Correlation",
        "",
        f"Generated at: {report['generated_at']}",
        f"Session root: `{report['session_root']}`",
        f"Config count: {report['config_count']}",
        "",
        "| config | sessions | latest session | observed samples/chirps/fps/frame bytes | parser samples/chirps/fps/frame bytes | mismatches |",
        "|---|---:|---|---|---|---|",
    ]
    for row in report["rows"]:
        latest = row["latest_session"]
        parser = row.get("parser_summary") or {}
        obs = f"{latest.get('observed_adc_samples')}/{latest.get('observed_chirps_per_frame')}/{latest.get('observed_fps')}/{latest.get('observed_frame_bytes')}"
        par = f"{parser.get('adc_samples')}/{parser.get('chirps_per_frame')}/{parser.get('frame_rate_hz')}/{parser.get('frame_bytes')}" if parser else row.get("parser_error")
        mismatches = "<br>".join(row.get("mismatches") or []) or ""
        lines.append(f"| {row['config_name']} | {row['session_count']} | {latest.get('session_name')} | {obs} | {par} | {mismatches} |")
    lines.extend([
        "",
        "## Interpretation",
        "",
        "Observed values come from historical session manifests and radar mode summaries. Parser values come from offline txt parsing only.",
        "Mismatches indicate places where the offline parser needs calibration against the existing capture code and metadata.",
    ])
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
