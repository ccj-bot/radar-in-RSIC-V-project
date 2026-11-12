"""Bounded, stop-on-first-fault frame-rate ladder for the NX radar station."""
from __future__ import annotations

import csv
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import time
from typing import Any

from radar_stack.capture.evidence import evidence_delta, snapshot_host


_RATE_TEMPLATE = "awr2243_rate_optimized_fill_form.json"
_SPECS = (
    ("s30-uniform", 30.0, "formal"),
    ("s32-uniform", 32.0, "formal"),
    ("s34-uniform", 34.0, "formal"),
    ("s35-uniform", 35.0, "formal"),
    ("s36-uniform-lab", 36.0, "stress_only"),
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def prepare_rate_profiles(root: Path) -> dict[str, Any]:
    """Create the managed 30/32/34/35/36 fps profiles if they are absent."""
    root = Path(root).resolve()
    template_path = root / "config" / "profiles" / "templates" / _RATE_TEMPLATE
    template = json.loads(template_path.read_text(encoding="utf-8"))
    from radar_stack.profiles.registry import profile_path, sync_profile

    prepared: list[dict[str, Any]] = []
    for name, fps, usage in _SPECS:
        destination = profile_path(root, name)
        if destination.exists():
            prepared.append({"profile": name, "status": "already_exists_not_modified"})
            continue
        form = json.loads(json.dumps(template))
        fields = form["fields"]
        fields["profile_name"]["value"] = name
        fields["profile_usage"]["value"] = usage
        fields["radar_target_frame_rate_hz"]["value"] = fps
        fields["radar_config"]["value"] = f"config/profiles/generated/{name}/mmwave.cfg"
        fields["dca_config"]["value"] = f"config/profiles/generated/{name}/dca1000.json"
        # Stress sessions are intentionally small; operators can clone a
        # validated formal profile later if they need a larger data cap.
        fields["stop_after_gib"]["value"] = 5
        _atomic_json(destination, form)
        try:
            manifest = sync_profile(root, name)
        except Exception:
            destination.unlink(missing_ok=True)
            shutil.rmtree(root / "config" / "profiles" / "generated" / name, ignore_errors=True)
            raise
        prepared.append({"profile": name, "status": "created", "generation": manifest})
    return {"schema": "nx-radar-stress-profile-preparation/v1", "prepared_at": _now(), "profiles": prepared}


def stress_plan(root: Path) -> dict[str, Any]:
    root = Path(root).resolve()
    from radar_stack.profiles.plan import build_capture_plan
    from radar_stack.profiles.registry import profile_path

    rungs: list[dict[str, Any]] = []
    for name, target_fps, usage in _SPECS:
        path = profile_path(root, name)
        if not path.is_file():
            rungs.append({"profile": name, "target_fps": target_fps, "usage": usage, "status": "missing"})
            continue
        try:
            plan = build_capture_plan(path, project_root=root)
            timing = plan["derived"]["timing_model"]
            transport = plan["derived"]["transport_budget"]
            rungs.append({
                "profile": name,
                "target_fps": target_fps,
                "usage": plan["derived"].get("profile_usage", usage),
                "status": "ready_to_validate",
                "actual_fps": timing["frame_rate_hz"],
                "chirps_per_frame": timing["chirps_per_frame"],
                "frame_blank_time_ms": timing["frame_blank_time_ms"],
                "planned_adc_payload_mbps": transport["planned_adc_payload_mbps"],
                "estimated_ethernet_wire_mbps": transport["estimated_ethernet_wire_mbps"],
                "dca_capacity_mbps": transport["dca_theoretical_payload_capacity_mbps"],
                "dca_utilization": transport["dca_utilization"],
                "gigabit_link_utilization": transport["gigabit_link_utilization"],
            })
        except Exception as exc:
            rungs.append({"profile": name, "target_fps": target_fps, "usage": usage, "status": "invalid", "error": repr(exc)})
    return {
        "schema": "nx-radar-stress-plan/v1",
        "created_at": _now(),
        "stop_on_first_fault": True,
        "faults": [
            "receiver byte gap, sequence mismatch, duplicate/out-of-order packet, or queue overflow",
            "NIC missed/drop/error counter delta",
            "UDP InErrors or RcvbufErrors delta",
            "DCA/FPGA post-run probe failure",
            "Jetson thermal zone above the selected limit",
        ],
        "rungs": rungs,
    }


def _interval_faults(session: Path) -> dict[str, int]:
    path = session / "radar" / "radar_packet_intervals.csv"
    totals = {name: 0 for name in ("duplicate_packets", "out_of_order_packets", "byte_gaps", "sequence_mismatches")}
    if not path.is_file():
        return totals
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                for name in totals:
                    totals[name] += int(row.get(name) or 0)
    except (OSError, ValueError):
        totals["read_error"] = 1
    return {key: value for key, value in totals.items() if value}


def _probe_ok(result: dict[str, Any]) -> bool:
    probe = result.get("post_capture_dca_probe") or {}
    values = probe.get("results") or []
    return bool(values) and all(item.get("ok") for item in values)


def _wait_for_capture_state(root: Path, session: Path, timeout_s: float) -> tuple[bool, dict[str, Any]]:
    from radar_stack.capture.manager import capture_status

    deadline = time.monotonic() + timeout_s
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        last = capture_status(root)
        if not last.get("active"):
            return False, last
        if Path(last["runtime"]["session"]).resolve() == session.resolve() and last["runtime"].get("state") == "capturing":
            return True, last
        time.sleep(0.2)
    return False, last


def _wait_until_stopped(root: Path, timeout_s: float) -> bool:
    from radar_stack.capture.manager import capture_status

    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if not capture_status(root).get("active"):
            return True
        time.sleep(0.2)
    return False


def run_stress_ladder(
    root: Path,
    *,
    validation_frames: int = 10,
    soak_seconds: float = 0.0,
    maximum_temperature_c: float = 85.0,
    profile_names: list[str] | None = None,
) -> dict[str, Any]:
    if not 1 <= validation_frames <= 20:
        raise ValueError("validation_frames must be in 1..20")
    if soak_seconds < 0 or soak_seconds > 300:
        raise ValueError("soak_seconds must be in 0..300")
    root = Path(root).resolve()
    from radar_stack.capture.manager import capture_status, start_capture, stop_capture
    from radar_stack.profiles.registry import active_profile_name, select_profile
    from radar_stack.profiles.validation import validate_active_profile

    if capture_status(root).get("active"):
        raise RuntimeError("an existing capture is active; stop it before the stress ladder")
    plan = stress_plan(root)
    known_names = {item["profile"] for item in plan["rungs"]}
    selected_names = set(profile_names or known_names)
    unknown = sorted(selected_names - known_names)
    if unknown:
        raise ValueError(f"unknown stress profiles: {unknown}")
    selected_rungs = [item for item in plan["rungs"] if item["profile"] in selected_names]
    unavailable = [item for item in selected_rungs if item["status"] != "ready_to_validate"]
    if unavailable:
        raise RuntimeError({"message": "stress ladder profiles are not ready", "rungs": unavailable})

    original_profile = active_profile_name(root)
    report: dict[str, Any] = {
        "schema": "nx-radar-stress-result/v1",
        "started_at": _now(),
        "validation_frames": validation_frames,
        "soak_seconds": soak_seconds,
        "maximum_temperature_c": maximum_temperature_c,
        "selected_profiles": [item["profile"] for item in selected_rungs],
        "original_active_profile": original_profile,
        "rungs": [],
        "stopped_on_fault": False,
    }
    try:
        for rung_plan in selected_rungs:
            name = rung_plan["profile"]
            rung: dict[str, Any] = {"profile": name, "plan": rung_plan, "started_at": _now()}
            report["rungs"].append(rung)
            select_profile(root, name)
            try:
                validation = validate_active_profile(root, frames=validation_frames)
                rung["validation"] = validation
                validation_session = Path(validation["session"])
                discovery_result = json.loads((validation_session / "radar" / "stream_discovery_result.json").read_text(encoding="utf-8"))
                rung["validation_quality_clean"] = bool(discovery_result.get("quality_clean"))
                rung["validation_host_evidence_delta"] = discovery_result.get("host_evidence_delta")
                temperatures = list((discovery_result.get("host_evidence_delta") or {}).get("thermal_after_c", {}).values())
                validation_max_temp = max(temperatures) if temperatures else None
                rung["validation_max_temperature_c"] = validation_max_temp
                if not rung["validation_quality_clean"]:
                    raise RuntimeError("bounded validation reported transport faults")
                if validation_max_temp is not None and validation_max_temp > maximum_temperature_c:
                    raise RuntimeError(f"temperature {validation_max_temp:.1f} C exceeds limit")

                if soak_seconds > 0:
                    capture = start_capture(
                        root,
                        f"stress-{name}",
                        allow_experimental_profile=True,
                        session_metadata={
                            "purpose": "automatic frame-rate stress ladder",
                            "notes": f"{soak_seconds:g} second bounded soak",
                            "profile": name,
                            "action": "stress_soak",
                        },
                    )
                    rung["capture"] = capture
                    session = Path(capture["session"])
                    started, startup_state = _wait_for_capture_state(root, session, 30.0)
                    rung["capture_startup_state"] = startup_state
                    if not started:
                        raise RuntimeError("capture worker did not reach capturing state")
                    before_path = session / "logs" / "host_evidence_before.json"
                    before = json.loads(before_path.read_text(encoding="utf-8"))
                    deadline = time.monotonic() + soak_seconds
                    live_fault: dict[str, Any] | None = None
                    while time.monotonic() < deadline:
                        status = capture_status(root)
                        if not status.get("active"):
                            live_fault = {"worker": "capture ended before requested soak duration"}
                            break
                        interval_faults = _interval_faults(session)
                        current = snapshot_host(before["interface"])
                        delta = evidence_delta(before, current)
                        temperatures = list(current.get("thermal_c", {}).values())
                        max_temp = max(temperatures) if temperatures else None
                        if interval_faults:
                            live_fault = {"receiver_intervals": interval_faults}
                        elif not delta["transport_clean"]:
                            live_fault = {"host_transport": delta["transport_faults"]}
                        elif max_temp is not None and max_temp > maximum_temperature_c:
                            live_fault = {"temperature_c": max_temp}
                        if live_fault:
                            break
                        time.sleep(min(1.0, max(0.05, deadline - time.monotonic())))
                    if capture_status(root).get("active"):
                        rung["stop_request"] = stop_capture(root, str(session))
                    if not _wait_until_stopped(root, 35.0):
                        raise RuntimeError("capture worker did not stop at a complete physical-frame boundary")
                    result_path = session / "capture_result.json"
                    capture_result = json.loads(result_path.read_text(encoding="utf-8")) if result_path.is_file() else {}
                    rung["capture_result"] = capture_result
                    if live_fault:
                        raise RuntimeError({"live_fault": live_fault})
                    if capture_result.get("error"):
                        raise RuntimeError(capture_result["error"])
                    if not _probe_ok(capture_result):
                        raise RuntimeError("post-capture DCA/FPGA probe did not pass")
                rung["status"] = "passed"
            except Exception as exc:
                try:
                    active = capture_status(root)
                    if active.get("active"):
                        rung["emergency_stop_request"] = stop_capture(root)
                        rung["emergency_stop_completed"] = _wait_until_stopped(root, 35.0)
                except Exception as stop_exc:
                    rung["emergency_stop_error"] = repr(stop_exc)
                rung["status"] = "failed"
                rung["error"] = repr(exc)
                rung["finished_at"] = _now()
                report["stopped_on_fault"] = True
                report["stop_profile"] = name
                break
            rung["finished_at"] = _now()
    finally:
        restore_target = original_profile or _SPECS[0][0]
        select_profile(root, restore_target)
        report["restored_active_profile"] = active_profile_name(root)
        report["finished_at"] = _now()
        destination = root / "logs" / f"stress_{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}.json"
        _atomic_json(destination, report)
        report["written_report"] = str(destination)
    return report
