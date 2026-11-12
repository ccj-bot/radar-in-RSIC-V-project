"""Limited real-stream discovery for a new DCA1000/AWR2243 station.

This command intentionally produces *evidence*, not a formal raw-data session:
it discovers the DCA UDP source port and compares observed byte_count span with
the selected profile. A separate acceptance command must lock those findings
into station configuration before production capture is allowed.
"""
from __future__ import annotations

from contextlib import contextmanager
import ctypes
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from typing import Any

from radar_stack.capture.evidence import evidence_delta, snapshot_host, write_evidence
from radar_stack.protocol.dca1000 import (
    configure_dca_capture,
    reset_dca_target,
    start_dca_stream,
    stop_dca_stream,
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    temp = path.with_suffix(path.suffix + ".part")
    temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def _event(session: Path, name: str, **details: Any) -> None:
    item = {"timestamp": _now(), "event": name, **details}
    with (session / "events.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(item, ensure_ascii=False) + "\n")


def _ok(value: Any) -> bool:
    return value in (None, 0, True)


def _resolve(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


@contextmanager
def _native_output_log(path: Path):
    """Capture C/C++ library stdout/stderr without hiding the final CLI JSON."""
    path.parent.mkdir(parents=True, exist_ok=True)
    saved_stdout, saved_stderr = os.dup(1), os.dup(2)
    with path.open("a", encoding="utf-8") as handle:
        try:
            sys.stdout.flush()
            sys.stderr.flush()
            ctypes.CDLL(None).fflush(None)
            os.dup2(handle.fileno(), 1)
            os.dup2(handle.fileno(), 2)
            yield
        finally:
            sys.stdout.flush()
            sys.stderr.flush()
            ctypes.CDLL(None).fflush(None)
            os.dup2(saved_stdout, 1)
            os.dup2(saved_stderr, 2)
            os.close(saved_stdout)
            os.close(saved_stderr)


def discovery_plan(root: Path, session_path: str | Path, frames: int) -> dict[str, Any]:
    root = Path(root).resolve()
    session = Path(session_path).resolve()
    plan = json.loads((session / "capture_plan.json").read_text(encoding="utf-8"))
    station = json.loads((session / "station_config_snapshot.yaml").read_text(encoding="utf-8"))
    profile_form = json.loads((session / "profile_form_snapshot.json").read_text(encoding="utf-8"))
    if frames <= 0 or frames > 20:
        raise ValueError("discovery frames must be in 1..20")
    derived = plan["derived"]
    cap_bytes = (64 * 1024**2 // int(derived["physical_segment_full_bytes"])) * int(derived["physical_segment_full_bytes"])
    return {
        "schema": "nx-radar-stream-discovery/v1",
        "session": str(session),
        "mode": "limited_hardware_stream_discovery_not_formal_capture",
        "frames_requested": frames,
        "receiver_cap_bytes": cap_bytes,
        "planned_bytes_per_chirp": int(derived["bytes_per_chirp"]),
        "chirps_per_frame": int(derived["chirps_per_frame"]),
        "physical_segment_bytes": int(derived["physical_segment_full_bytes"]),
        "network": station["network"],
        "radar_config": plan["input_fields"]["radar_config"]["value"],
        "dca_config": profile_form.get("fields", {}).get("dca_config", {}).get("value") or station["network"].get("dca_config"),
        "hardware_actions_if_executed": [
            "reset DCA radar and FPGA",
            "AWR2243_init and finite frame configuration",
            "configure DCA FPGA and packet record",
            "start receiver, DCA stream, then AWR sensor",
            "wait finite-frame stop, stop DCA stream, drain receiver, power off AWR",
        ],
    }


def run_stream_discovery(root: Path, session_path: str | Path, frames: int) -> dict[str, Any]:
    """Execute the bounded discovery transaction with cleanup on every path."""
    root = Path(root).resolve()
    session = Path(session_path).resolve()
    payload = discovery_plan(root, session, frames)
    network = payload["network"]
    plan = json.loads((session / "capture_plan.json").read_text(encoding="utf-8"))
    manifest_path = session / "session_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("status") != "prepared_no_hardware_started":
        raise RuntimeError(f"discovery requires fresh prepared session, got {manifest.get('status')!r}")
    radar_config = _resolve(root, str(payload["radar_config"]))
    dca_config = _resolve(root, str(payload.get("dca_config") or "legacy/pyRadar-main/configFiles/cf.json"))
    if not radar_config.is_file() or not dca_config.is_file():
        raise FileNotFoundError({"radar_config": str(radar_config), "dca_config": str(dca_config)})

    derived = plan["derived"]
    receiver = root / "bin" / "dca_segment_receiver"
    receiver_log = session / "logs" / "stream_discovery_receiver.log"
    hardware_log = session / "logs" / "stream_discovery_hardware.log"
    receiver_command = [
        str(receiver), "--bind-ip", network["nx_ip"], "--source-ip", network["dca_ip"],
        "--port", str(network["data_port"]), "--source-port", "0", "--discover-source-port", "1",
        "--session", str(session), "--chirp-bytes", str(derived["bytes_per_chirp"]),
        "--segment-bytes", str(derived["physical_segment_full_bytes"]), "--max-bytes", str(payload["receiver_cap_bytes"]),
        "--queue-packets", "262144", "--reorder-window", "64", "--evidence-packets", "4096",
        "--boundary-stop-on-signal", "0",
    ]
    result: dict[str, Any] = {**payload, "started_at": _now(), "receiver_command": receiver_command, "sensor_start_sent": False}
    receiver_process: subprocess.Popen[str] | None = None
    dca_stream_started = False
    awr_initialized = False
    sensor_started = False
    evidence_before = snapshot_host(network["interface"])
    write_evidence(session / "logs" / "host_evidence_before.json", evidence_before)
    with _native_output_log(hardware_log):
        try:
            _event(session, "stream_discovery_started", frames=frames, formal_capture=False)
            for target in ("radar", "fpga"):
                reset = reset_dca_target(network["dca_ip"], int(network["config_port"]), target, bind_ip=network["nx_ip"])
                result[f"dca_reset_{target}"] = reset
                if not reset["ok"]:
                    raise RuntimeError(f"DCA {target} reset failed")
            time.sleep(1.0)

            import fpga_udp

            init = fpga_udp.AWR2243_init(str(radar_config))
            result["awr_init_return"] = init
            if not _ok(init):
                raise RuntimeError(f"AWR2243_init failed: {init!r}")
            awr_initialized = True
            set_frames = fpga_udp.AWR2243_setFrameCfg(frames)
            result["awr_set_frames_return"] = set_frames
            if not _ok(set_frames):
                raise RuntimeError(f"AWR2243_setFrameCfg failed: {set_frames!r}")

            result["dca_configure"] = configure_dca_capture(network["dca_ip"], int(network["config_port"]), dca_config, bind_ip=network["nx_ip"])
            with receiver_log.open("w", encoding="utf-8") as handle:
                receiver_process = subprocess.Popen(receiver_command, stdout=handle, stderr=subprocess.STDOUT, text=True)
            time.sleep(0.5)
            if receiver_process.poll() is not None:
                raise RuntimeError(f"receiver exited before DCA stream start; see {receiver_log}")
            _event(session, "receiver_bound", pid=receiver_process.pid)

            result["dca_stream_start"] = start_dca_stream(network["dca_ip"], int(network["config_port"]), bind_ip=network["nx_ip"])
            dca_stream_started = True
            sensor_start = fpga_udp.AWR2243_sensorStart()
            result["awr_sensor_start_return"] = sensor_start
            if not _ok(sensor_start):
                raise RuntimeError(f"AWR2243_sensorStart failed: {sensor_start!r}")
            sensor_started = True
            result["sensor_start_sent"] = True
            _event(session, "awr_sensor_started", frames=frames)
            wait_result = fpga_udp.AWR2243_waitSensorStop()
            result["awr_wait_sensor_stop_return"] = wait_result
            if not _ok(wait_result):
                raise RuntimeError(f"AWR2243_waitSensorStop failed: {wait_result!r}")
            sensor_started = False
            _event(session, "awr_sensor_finished")
        except Exception as exc:
            result["error"] = repr(exc)
            _event(session, "stream_discovery_error", error=repr(exc))
        finally:
            if sensor_started:
                try:
                    import fpga_udp
                    result["cleanup_sensor_stop_return"] = fpga_udp.AWR2243_sensorStop()
                except Exception as exc:
                    result["cleanup_sensor_stop_error"] = repr(exc)
            if dca_stream_started:
                try:
                    result["cleanup_dca_stream_stop"] = stop_dca_stream(network["dca_ip"], int(network["config_port"]), bind_ip=network["nx_ip"])
                except Exception as exc:
                    result["cleanup_dca_stream_stop_error"] = repr(exc)
            if receiver_process is not None:
                if receiver_process.poll() is None:
                    receiver_process.send_signal(signal.SIGINT)
                try:
                    result["receiver_returncode"] = receiver_process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    receiver_process.terminate()
                    result["receiver_returncode"] = receiver_process.wait(timeout=5)
                    result["receiver_forced_terminate"] = True
            if awr_initialized:
                try:
                    import fpga_udp
                    result["cleanup_poweroff_return"] = fpga_udp.AWR2243_poweroff()
                except Exception as exc:
                    result["cleanup_poweroff_error"] = repr(exc)

    quality_path = session / "radar" / "radar_quality_summary.json"
    quality = json.loads(quality_path.read_text(encoding="utf-8")) if quality_path.is_file() else None
    result["receiver_quality"] = quality
    if quality:
        first, last = int(quality["first_byte_count"]), int(quality["last_byte_end"])
        observed_bytes = max(0, last - first)
        result["observed_stream_bytes"] = observed_bytes
        if observed_bytes and observed_bytes % frames == 0:
            observed_frame = observed_bytes // frames
            result["observed_bytes_per_frame"] = observed_frame
            if observed_frame % int(derived["chirps_per_frame"]) == 0:
                result["observed_bytes_per_chirp"] = observed_frame // int(derived["chirps_per_frame"])
        result["quality_clean"] = all(int(quality[key]) == 0 for key in ("duplicate_packets", "out_of_order_packets", "short_packets", "oversized_packets", "source_ip_anomalies", "source_port_anomalies", "byte_gaps", "byte_stride_mismatches", "sequence_mismatches", "queue_overflows", "trailing_unresolved_packets"))
        result["port_discovered"] = quality.get("observed_source_port") is not None
    evidence_after = snapshot_host(network["interface"])
    write_evidence(session / "logs" / "host_evidence_after.json", evidence_after)
    host_delta = evidence_delta(evidence_before, evidence_after)
    write_evidence(session / "logs" / "host_evidence_delta.json", host_delta)
    result["host_evidence_delta"] = host_delta
    result["quality_clean"] = bool(result.get("quality_clean")) and host_delta["transport_clean"]
    result["completed_at"] = _now()
    result["formal_capture_accepted"] = False
    result_path = session / "radar" / "stream_discovery_result.json"
    _atomic_json(result_path, result)
    manifest["status"] = "stream_discovery_completed_not_formal_capture" if not result.get("error") else "stream_discovery_failed"
    manifest["sensor_start_sent"] = bool(result["sensor_start_sent"])
    manifest["stream_discovery_result"] = str(result_path)
    _atomic_json(manifest_path, manifest)
    _event(session, "stream_discovery_finished", status=manifest["status"], formal_capture_accepted=False)
    return result


def assess_stream_discovery(root: Path, session_path: str | Path) -> dict[str, Any]:
    """Assess existing discovery evidence without touching hardware."""
    root = Path(root).resolve()
    session = Path(session_path).resolve()
    result_path = session / "radar" / "stream_discovery_result.json"
    result = json.loads(result_path.read_text(encoding="utf-8"))
    quality = result.get("receiver_quality") or {}
    plan = json.loads((session / "capture_plan.json").read_text(encoding="utf-8"))
    derived = plan["derived"]
    frames = int(result["frames_requested"])
    observed_total = int(result.get("observed_stream_bytes", 0))
    total_chirps = frames * int(derived["chirps_per_frame"])
    # DCA drops at most one 1456 B payload remainder when finite streaming
    # stops.  Infer the exact transport bytes/chirp from that interval instead
    # of assuming enabled-RX count changes the LVDS wire layout.
    lower = math.ceil(observed_total / total_chirps) if total_chirps else 0
    upper = (observed_total + 1455) // total_chirps if total_chirps else -1
    transport_candidates = list(range(lower, upper + 1)) if lower <= upper else []
    observed_bytes_per_chirp = transport_candidates[0] if len(transport_candidates) == 1 else None
    expected_total = total_chirps * observed_bytes_per_chirp if observed_bytes_per_chirp else None
    terminal_tail = expected_total - observed_total if expected_total is not None else None
    quality_clean = bool(result.get("quality_clean"))
    port = quality.get("observed_source_port")
    # DCA1000 transports full 1456 B payload packets. A finite capture can end
    # with the sub-packet tail absent; it must be represented as .part, not zeros.
    terminal_tail_is_packetization = terminal_tail is not None and 0 <= terminal_tail < 1456
    geometry_confirmed = quality_clean and isinstance(port, int) and port > 0 and terminal_tail_is_packetization and observed_bytes_per_chirp is not None
    assessment = {
        "schema": "nx-radar-stream-discovery-assessment/v1",
        "session": str(session),
        "frames": frames,
        "planned_bytes_per_chirp": int(derived["bytes_per_chirp"]),
        "expected_total_bytes": expected_total,
        "observed_total_bytes": observed_total,
        "terminal_untransmitted_tail_bytes": terminal_tail,
        "terminal_tail_is_dca_packetization": terminal_tail_is_packetization,
        "transport_bytes_per_chirp_candidates": transport_candidates,
        "observed_bytes_per_chirp": observed_bytes_per_chirp,
        "quality_clean": quality_clean,
        "observed_source_port": port,
        "verified_bytes_per_chirp": observed_bytes_per_chirp,
        "verified_chirps_per_frame": int(derived["chirps_per_frame"]),
        "geometry_confirmed_for_complete_segments": geometry_confirmed,
        "formal_capture_accepted": False,
        "assessed_at": _now(),
    }
    _atomic_json(session / "radar" / "stream_discovery_assessment.json", assessment)
    return assessment


def accept_stream_discovery(root: Path, session_path: str | Path) -> dict[str, Any]:
    """Lock station facts and this exact radar+DCA configuration validation."""
    root = Path(root).resolve()
    session = Path(session_path).resolve()
    assessment = assess_stream_discovery(root, session)
    if not assessment["geometry_confirmed_for_complete_segments"]:
        raise RuntimeError("discovery evidence is insufficient to lock station configuration")
    station_path = root / "config" / "station.yaml"
    station = json.loads(station_path.read_text(encoding="utf-8"))
    network = station["network"]
    network["dca_data_source_port"] = assessment["observed_source_port"]
    network["dca_data_source_port_verified"] = True
    # Geometry is profile-specific.  Formal capture authorization reads the
    # exact radar+DCA fingerprint record written below, not this station audit.
    network["last_bounded_stream_validation"] = {
        "bytes_per_chirp": assessment["verified_bytes_per_chirp"],
        "chirps_per_frame": assessment["verified_chirps_per_frame"],
        "terminal_untransmitted_tail_bytes": assessment["terminal_untransmitted_tail_bytes"],
        "evidence_session": str(session),
        "verified_at": _now(),
    }
    _atomic_json(station_path, station)
    from radar_stack.profiles.validation import record_validated_stream
    profile_validation = record_validated_stream(root, session, assessment)
    _event(session, "stream_discovery_accepted", source_port=assessment["observed_source_port"], bytes_per_chirp=assessment["verified_bytes_per_chirp"])
    return {"station_config": str(station_path), "accepted": True, "assessment": assessment, "profile_validation": profile_validation}
