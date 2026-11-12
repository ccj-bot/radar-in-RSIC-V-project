from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from radar_capture.core.json_utils import write_json
from radar_capture.core.path_utils import resolve_project_path
from radar_capture.profiles.mmwave_parser import parse_mmwave_config, summary_to_dict


def discover_config_files(root: str | Path = "configFiles") -> list[Path]:
    base = resolve_project_path(root)
    if not base.exists():
        return []
    return sorted(p for p in base.glob("*.txt") if p.is_file())


def classify_config(path: Path) -> str:
    name = path.name.lower()
    if "30f128_safe" in name:
        return "stable_current"
    if "safe" in name:
        return "stable_candidate"
    if "debug" in name or "nofw" in name or "neg" in name:
        return "debug_or_experimental"
    if "desktop" in name or "20260409" in name:
        return "historical"
    if "test" in name:
        return "test_candidate"
    return "unknown_review"


def build_matrix(config_root: str | Path = "configFiles") -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    for path in discover_config_files(config_root):
        try:
            summary = parse_mmwave_config(path)
            data = summary_to_dict(summary)
            row = {
                "path": str(path),
                "name": path.name,
                "classification": classify_config(path),
                "parse_status": "ok",
                "effective_tx_sequence": data.get("effective_tx_sequence"),
                "effective_rx_channels": data.get("effective_rx_channels"),
                "adc_samples": data.get("adc_samples"),
                "chirps_per_frame": data.get("chirps_per_frame"),
                "frame_periodicity_ms": data.get("frame_periodicity_ms"),
                "frame_rate_hz": data.get("frame_rate_hz"),
                "frame_bytes": data.get("frame_bytes"),
                "estimated_raw_rate_MBps": data.get("estimated_raw_rate_MBps"),
                "risk_level": data.get("risk_level"),
                "warnings": data.get("warnings", []),
                "raw_commands_count": data.get("raw_commands_count"),
            }
        except Exception as exc:
            row = {
                "path": str(path),
                "name": path.name,
                "classification": classify_config(path),
                "parse_status": "error",
                "error": repr(exc),
            }
        rows.append(row)
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "config_root": str(resolve_project_path(config_root)),
        "count": len(rows),
        "rows": rows,
    }


def write_matrix_reports(matrix: dict[str, Any], json_out: str | Path, md_out: str | Path) -> None:
    write_json(resolve_project_path(json_out), matrix)
    md_path = resolve_project_path(md_out)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# mmWave Config Decode Matrix",
        "",
        f"Generated at: {matrix['generated_at']}",
        f"Config root: `{matrix['config_root']}`",
        f"Count: {matrix['count']}",
        "",
        "| name | class | parse | TX | RX | samples | chirps/frame | frame Hz | frame bytes | raw MB/s | risk | warnings |",
        "|---|---|---:|---|---|---:|---:|---:|---:|---:|---|---|",
    ]
    for row in matrix["rows"]:
        warnings = row.get("warnings") or []
        warning_text = "<br>".join(str(w) for w in warnings[:3])
        if len(warnings) > 3:
            warning_text += f"<br>... {len(warnings)-3} more"
        if row.get("parse_status") != "ok":
            warning_text = row.get("error", warning_text)
        lines.append(
            "| {name} | {classification} | {parse_status} | {tx} | {rx} | {samples} | {chirps} | {hz} | {bytes} | {rate} | {risk} | {warnings} |".format(
                name=row.get("name"),
                classification=row.get("classification"),
                parse_status=row.get("parse_status"),
                tx=row.get("effective_tx_sequence", ""),
                rx=row.get("effective_rx_channels", ""),
                samples=row.get("adc_samples", ""),
                chirps=row.get("chirps_per_frame", ""),
                hz=(f"{row.get('frame_rate_hz'):.3f}" if isinstance(row.get("frame_rate_hz"), (int, float)) else ""),
                bytes=row.get("frame_bytes", ""),
                rate=(f"{row.get('estimated_raw_rate_MBps'):.3f}" if isinstance(row.get("estimated_raw_rate_MBps"), (int, float)) else ""),
                risk=row.get("risk_level", ""),
                warnings=warning_text.replace("|", "\\|"),
            )
        )
    lines.extend([
        "",
        "## Notes",
        "",
        "This matrix is offline parser output only. It does not prove hardware readiness and does not run capture.",
        "Risk levels use conservative DCA1000 long-run thresholds from `radar_capture.profiles.throughput`.",
        "Frame-rate values may require calibration against real session metadata, especially for configs using `periodicity` or `subFramePeriodicity`.",
    ])
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
