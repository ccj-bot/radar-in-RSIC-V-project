"""Read-only capture gate: report why a prepared session may or may not start.

This module deliberately has no DCA reset, record-start, or sensor-start calls.
It is safe to run before every capture and leaves an immutable JSON report in the
prepared session's logs directory.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import socket
import subprocess
from typing import Any

from radar_stack.protocol.dca1000 import probe_dca


def _command(command: list[str]) -> dict[str, Any]:
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    return {
        "command": command,
        "returncode": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def _link_state(ethtool_output: str) -> dict[str, Any]:
    state: dict[str, Any] = {"speed_mbps": None, "duplex": None, "link_detected": None}
    for line in ethtool_output.splitlines():
        stripped = line.strip()
        if stripped.startswith("Speed:") and stripped.endswith("Mb/s"):
            try:
                state["speed_mbps"] = int(stripped.split(":", 1)[1].strip()[:-4])
            except ValueError:
                pass
        elif stripped.startswith("Duplex:"):
            state["duplex"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("Link detected:"):
            state["link_detected"] = stripped.split(":", 1)[1].strip().lower() == "yes"
    return state


def _effective_udp_receive_buffer(bind_ip: str, port: int, requested_bytes: int) -> dict[str, Any]:
    """Bind the real data endpoint briefly and report the kernel-granted buffer."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, requested_bytes)
            sock.bind((bind_ip, port))
            return {
                "ok": True,
                "bind": f"{bind_ip}:{port}",
                "requested_bytes": requested_bytes,
                # Linux commonly reports twice the internally capped SO_RCVBUF.
                "SO_RCVBUF_reported_bytes": sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF),
            }
    except OSError as exc:
        return {"ok": False, "bind": f"{bind_ip}:{port}", "error": str(exc)}


def _write_report(session: Path, report: dict[str, Any]) -> Path:
    logs = session / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = logs / f"capture_preflight_{stamp}.json"
    temporary = destination.with_suffix(".json.part")
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(destination)
    return destination


def run_capture_preflight(
    root: Path,
    session_path: str | Path,
    *,
    min_udp_receive_buffer_bytes: int = 128 * 1024 * 1024,
    requested_udp_receive_buffer_bytes: int = 256 * 1024 * 1024,
    dca_timeout_s: float = 1.0,
) -> dict[str, Any]:
    """Validate a prepared session without changing radar/DCA capture state."""
    root = Path(root).resolve()
    session = Path(session_path).resolve()
    if not session.is_dir():
        raise ValueError(f"session does not exist: {session}")
    plan_path, manifest_path = session / "capture_plan.json", session / "session_manifest.json"
    if not plan_path.is_file() or not manifest_path.is_file():
        raise ValueError("session is missing capture_plan.json or session_manifest.json")
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    station_snapshot = session / "station_config_snapshot.yaml"
    if not station_snapshot.is_file():
        raise ValueError("session is missing station_config_snapshot.yaml")
    station = json.loads(station_snapshot.read_text(encoding="utf-8"))
    network, paths, derived = station["network"], station["paths"], plan["derived"]
    checks: list[dict[str, Any]] = []

    def check(name: str, ok: bool, detail: Any, blocker: str) -> None:
        checks.append({"name": name, "ok": ok, "detail": detail, "blocker": None if ok else blocker})

    check("session_prepared", manifest.get("status") == "prepared_no_hardware_started", {"status": manifest.get("status")}, "session is not a fresh prepared session")
    bytes_per_chirp = int(derived["bytes_per_chirp"])
    check("segment_geometry", int(derived["physical_segment_full_bytes"]) % bytes_per_chirp == 0, {"segment_bytes": derived["physical_segment_full_bytes"], "bytes_per_chirp": bytes_per_chirp}, "segment does not end on a planned chirp boundary")
    check("data_cap_complete_segments", int(derived["total_expected_bytes"]) % int(derived["physical_segment_full_bytes"]) == 0, {"planned_bytes": derived["total_expected_bytes"]}, "planned cap would stop inside a physical segment")

    disk = shutil.disk_usage(paths["session_root"])
    reserve = int(float(derived["reserve_disk_gib"]) * 1024**3)
    required = (int(derived.get("disk_stop_guard_bytes", 1024**3)) + int(derived["physical_segment_full_bytes"]) if derived["capture_mode"] == "manual_until_disk_reserve" else int(derived["total_expected_bytes"])) + reserve
    check("disk_headroom", disk.free >= required, {"free_bytes": disk.free, "required_bytes": required, "reserve_bytes": reserve}, "free disk is below planned data plus reserve")

    address = _command(["ip", "-br", "addr", "show", network["interface"]])
    check("radar_nic_address", address["returncode"] == 0 and network["nx_ip"] in address["stdout"], address, "radar NIC does not have the configured NX address")
    link = _command(["ethtool", network["interface"]])
    link_state = _link_state(link["stdout"])
    transport_budget = derived.get("transport_budget", {})
    # Prefer the plan's packet/PHY estimate so the displayed budget and the
    # preflight gate are the same contract.
    estimated_wire_mbps = float(
        transport_budget.get(
            "estimated_ethernet_wire_mbps",
            float(derived["estimated_raw_rate_MiBps"]) * 8.388608 * 1.10,
        )
    )
    speed = link_state["speed_mbps"]
    link_limit = float(transport_budget.get("formal_link_utilization_limit", 0.80))
    check("link_budget", speed is not None and speed >= 1000 and link_state["duplex"] == "Full" and link_state["link_detected"] is True and estimated_wire_mbps < speed * link_limit, {"link": link_state, "estimated_wire_mbps_conservative": round(estimated_wire_mbps, 2), "formal_link_utilization_limit": link_limit, "command": link}, "link is not detected 1Gb/s full duplex with adequate sustained headroom")
    dca_utilization = float(transport_budget.get("dca_utilization", 1.0))
    check(
        "dca_packet_delay_budget",
        dca_utilization < float(transport_budget.get("formal_profile_utilization_limit", 0.90)),
        transport_budget,
        "DCA1000 payload rate is too close to the packet-delay throughput limit",
    )
    timing_model = derived.get("timing_model", {})
    check(
        "ti_frame_timing",
        float(timing_model.get("frame_blank_time_ms", -1.0)) >= float(timing_model.get("ti_minimum_inter_frame_blank_ms", 0.3)),
        timing_model,
        "frame-on time leaves less than the TI minimum inter-frame blank time",
    )

    socket_buffer = _effective_udp_receive_buffer(network["nx_ip"], int(network["data_port"]), requested_udp_receive_buffer_bytes)
    check("udp_data_port_bindable", bool(socket_buffer.get("ok")), socket_buffer, "UDP data port cannot be bound; another receiver may still be running")
    reported = int(socket_buffer.get("SO_RCVBUF_reported_bytes", 0))
    check("udp_kernel_receive_buffer", reported >= min_udp_receive_buffer_bytes, {**socket_buffer, "minimum_reported_bytes": min_udp_receive_buffer_bytes, "linux_note": "SO_RCVBUF may be reported as twice the internally capped value"}, "kernel UDP receive buffer is below the configured safety minimum")

    source_port = network.get("dca_data_source_port")
    source_port_verified = network.get("dca_data_source_port_verified") is True
    check("dca_data_source_port_verified", isinstance(source_port, int) and 0 < source_port < 65536 and source_port_verified, {"dca_data_source_port": source_port, "verified": source_port_verified}, "DCA ADC data source UDP port has not been observed and locked into this session snapshot")
    from radar_stack.profiles.validation import validation_status_for_session
    profile_validation = validation_status_for_session(root, session)
    compatibility = profile_validation["compatibility"]
    check(
        "profile_fixed_geometry_supported",
        bool(compatibility["fixed_geometry_supported"]),
        compatibility,
        "this profile mixes or omits chirp geometry; use a fixed ADC/RX geometry or add a variable-geometry receiver before capture",
    )
    check(
        "profile_stream_validation_current",
        bool(profile_validation["stream_validation_current"]),
        {key: profile_validation[key] for key in ("identity", "stream_validation_path", "stream_validation_record", "next_action")},
        "radar or DCA configuration changed since its last bounded stream validation; run the 10-frame profile validation",
    )
    parser_warnings = plan.get("radar_profile_summary", {}).get("warnings", [])
    geometry_warnings = [item for item in parser_warnings if "numAdcSamples" in str(item) or "frame_bytes" in str(item)]
    geometry_evidence = network.get("verified_stream_geometry", {})
    evidence_matches_plan = bool(profile_validation["stream_validation_current"])
    check("parsed_geometry_unambiguous", not geometry_warnings or evidence_matches_plan, {"parser_warnings": geometry_warnings, "planned_bytes_per_chirp": bytes_per_chirp, "verified_stream_geometry": geometry_evidence, "matching_profile_validation": evidence_matches_plan}, "profile parser reports unresolved ADC geometry and no matching validation for this exact configuration exists")

    dca = probe_dca(network["dca_ip"], int(network["config_port"]), dca_timeout_s, bind_ip=network["nx_ip"])
    dca_ok = all(item.get("ok") for item in dca.get("results", []))
    check("dca_read_only_probe", dca_ok, dca, "DCA1000 did not pass read-only control probe")

    report = {
        "schema": "nx-radar-capture-preflight/v1",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "session": str(session),
        "mode": "read-only-no-reset-no-record-start-no-sensor-start",
        "minimum_udp_receive_buffer_reported_bytes": min_udp_receive_buffer_bytes,
        "checks": checks,
        "profile_validation": profile_validation,
        "summary_status": "preflight_passed_not_capture_authorized" if all(item["ok"] for item in checks) else "blocked",
        "capture_authorized": False,
        "not_verified_by_preflight": ["actual ADC data source port and byte_count semantics", "AWR initialized stream geometry", "receiver/DCA/AWR start order", "finite-frame stop and cleanup"],
        "sensor_start_sent": False,
    }
    report["written_report"] = str(_write_report(session, report))
    return report
