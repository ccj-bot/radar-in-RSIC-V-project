"""Experiment history and closeout helpers for human-operated radar sessions."""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import time
from typing import Any


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def resolve_session(root: Path, value: str | Path) -> Path:
    root = Path(root).resolve()
    candidate = Path(value)
    if candidate.is_absolute() and candidate.is_dir():
        return candidate.resolve()
    relative = root / candidate
    if relative.is_dir():
        return relative.resolve()
    matches = sorted((root / "sessions").glob(f"*__{candidate.name}"))
    if len(matches) == 1:
        return matches[0].resolve()
    if not matches:
        raise FileNotFoundError(f"session not found: {value}")
    raise RuntimeError(f"session name is ambiguous; provide a full path: {value}")


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def summarize_experiment(root: Path, session_value: str | Path) -> dict[str, Any]:
    session = resolve_session(root, session_value)
    manifest = _read_json(session / "session_manifest.json") or {}
    plan = _read_json(session / "capture_plan.json") or {}
    experiment = _read_json(session / "experiment.json") or {}
    capture_result = _read_json(session / "capture_result.json")
    quality = _read_json(session / "radar" / "radar_quality_summary.json")
    host_delta = _read_json(session / "logs" / "host_evidence_delta.json")
    preview_contract = _read_json(session / "reconstruction" / "live_preview" / "preview_contract.json")
    raw_segments = list((session / "radar" / "raw_segments").glob("*.bin"))
    raw_bytes = sum(path.stat().st_size for path in raw_segments)
    fault_fields = (
        "duplicate_packets", "out_of_order_packets", "short_packets", "oversized_packets",
        "source_ip_anomalies", "source_port_anomalies", "byte_gaps", "byte_stride_mismatches",
        "sequence_mismatches", "queue_overflows", "trailing_unresolved_packets",
    )
    quality_faults = {
        key: int((quality or {}).get(key, 0))
        for key in fault_fields
        if int((quality or {}).get(key, 0)) != 0
    }
    if capture_result and capture_result.get("error"):
        outcome = "failed"
    elif quality_faults or (host_delta and not host_delta.get("transport_clean", False)):
        outcome = "failed_quality_gate"
    elif capture_result:
        outcome = "completed"
    elif manifest.get("status") == "prepared_no_hardware_started":
        outcome = "prepared_not_started"
    else:
        outcome = str(manifest.get("status") or "unknown")
    return {
        "schema": "nx-radar-experiment-summary/v1",
        "summarized_at": _now(),
        "session": str(session),
        "session_name": manifest.get("session_name") or session.name,
        "profile": manifest.get("active_profile") or plan.get("profile_name"),
        "purpose": experiment.get("purpose"),
        "notes": experiment.get("notes"),
        "action": experiment.get("action"),
        "outcome": outcome,
        "manifest_status": manifest.get("status"),
        "raw_segment_count": len(raw_segments),
        "raw_bytes": raw_bytes,
        "quality_status": (quality or {}).get("status"),
        "quality_faults": quality_faults,
        "queue_peak_packets": (quality or {}).get("queue_peak_packets"),
        "boundary_discard_bytes": (quality or {}).get("boundary_discard_bytes"),
        "boundary_discard_packets": (quality or {}).get("boundary_discard_packets"),
        "host_transport_clean": host_delta.get("transport_clean") if host_delta else None,
        "host_transport_faults": host_delta.get("transport_faults") if host_delta else None,
        "max_temperature_after_c": host_delta.get("max_temperature_after_c") if host_delta else None,
        "preview_contract": preview_contract,
        "capture_error": capture_result.get("error") if capture_result else None,
    }


def list_experiments(root: Path, limit: int = 20) -> dict[str, Any]:
    root = Path(root).resolve()
    sessions = sorted((root / "sessions").glob("*__*"), reverse=True)
    items = []
    for session in sessions[: max(1, limit)]:
        try:
            items.append(summarize_experiment(root, session))
        except Exception as exc:
            items.append({"session": str(session), "outcome": "inspection_error", "error": repr(exc)})
    return {"schema": "nx-radar-experiment-history/v1", "items": items}


def finish_experiment(root: Path, session_value: str | Path, timeout_s: float = 35.0) -> dict[str, Any]:
    root = Path(root).resolve()
    session = resolve_session(root, session_value)
    from radar_stack.capture.manager import capture_status, stop_capture

    status = capture_status(root)
    stop_request = None
    if status.get("active") and Path(status["runtime"]["session"]).resolve() == session:
        stop_request = stop_capture(root, str(session))
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline and capture_status(root).get("active"):
            time.sleep(0.2)
        if capture_status(root).get("active"):
            raise RuntimeError("capture did not stop at a complete segment boundary before timeout")
    summary = summarize_experiment(root, session)
    summary["stop_request"] = stop_request
    destination = session / "experiment_summary.json"
    _atomic_json(destination, summary)
    summary["written_summary"] = str(destination)
    return summary
