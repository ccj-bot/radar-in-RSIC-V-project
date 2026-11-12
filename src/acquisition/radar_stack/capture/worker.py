"""Background manual-capture worker; launched only by `radarctl capture start`."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import time
from typing import Any

from radar_stack.capture.evidence import evidence_delta, snapshot_host, write_evidence
from radar_stack.protocol.dca1000 import configure_dca_capture, probe_dca, reset_dca_target, start_dca_stream, stop_dca_stream

STOP_REQUESTED = False


def _signal(_: int, __: Any) -> None:
    global STOP_REQUESTED
    STOP_REQUESTED = True


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".part")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def _event(session: Path, name: str, **details: Any) -> None:
    with (session / "events.jsonl").open("a", encoding="utf-8") as output:
        output.write(json.dumps({"timestamp": _now(), "monotonic_ns": time.monotonic_ns(), "unix_ns": time.time_ns(), "source": "radar", "event": name, **details}, ensure_ascii=False) + "\n")


def _ok(value: Any) -> bool:
    return value in (None, 0, True)


def _resolve(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def run(root: Path, session: Path) -> int:
    root, session = root.resolve(), session.resolve()
    plan = json.loads((session / "capture_plan.json").read_text(encoding="utf-8"))
    station = json.loads((session / "station_config_snapshot.yaml").read_text(encoding="utf-8"))
    profile = json.loads((session / "profile_form_snapshot.json").read_text(encoding="utf-8"))
    manifest_path = session / "session_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    derived, network = plan["derived"], station["network"]
    if derived["capture_mode"] not in {"manual_stop_with_data_cap", "manual_until_disk_reserve"}:
        raise RuntimeError("background worker currently supports manual_stop_with_data_cap only")
    source_port = int(network["dca_data_source_port"])
    if not network.get("dca_data_source_port_verified") or source_port <= 0:
        raise RuntimeError("station snapshot has no verified DCA data source port")
    radar_config = _resolve(root, str(profile["fields"]["radar_config"]["value"]))
    dca_config = _resolve(root, str(profile["fields"].get("dca_config", {}).get("value") or network["dca_config"]))
    if not radar_config.is_file() or not dca_config.is_file():
        raise FileNotFoundError({"radar_config": str(radar_config), "dca_config": str(dca_config)})

    runtime_path = root / "runtime" / "active_capture.json"
    evidence_before = snapshot_host(network["interface"])
    write_evidence(session / "logs" / "host_evidence_before.json", evidence_before)
    receiver_log = session / "logs" / "capture_receiver.log"
    boundary_ready_path = session / "radar" / "boundary_stop_ready.json"
    receiver_command = [
        str(root / "bin" / "dca_segment_receiver"), "--bind-ip", network["nx_ip"], "--source-ip", network["dca_ip"],
        "--port", str(network["data_port"]), "--source-port", str(source_port), "--session", str(session),
        "--chirp-bytes", str(derived["bytes_per_chirp"]), "--segment-bytes", str(derived["physical_segment_full_bytes"]),
        "--max-bytes", str(derived.get("receiver_max_bytes", derived["total_expected_bytes"])), "--queue-packets", "262144", "--reorder-window", "64", "--evidence-packets", "4096",
        "--reserve-bytes", str(int(float(derived["reserve_disk_gib"]) * 1024**3)),
        "--disk-guard-bytes", str(derived.get("disk_stop_guard_bytes", 1024**3)),
        "--idle-timeout-ms", "10000",
        "--boundary-stop-on-signal", "1",
        "--boundary-ready-file", str(boundary_ready_path),
    ]
    receiver: subprocess.Popen[str] | None = None
    dca_stream_started = awr_initialized = sensor_started = False
    stop_reason = "unknown"
    ever_started = False
    disk_stop = False
    result: dict[str, Any] = {"session": str(session), "worker_pid": os.getpid(), "started_at": _now(), "receiver_command": receiver_command}
    try:
        manifest["status"] = "capture_starting"
        _atomic_json(manifest_path, manifest)
        _event(session, "capture_worker_started", worker_pid=os.getpid())
        for target in ("radar", "fpga"):
            reply = reset_dca_target(network["dca_ip"], int(network["config_port"]), target, bind_ip=network["nx_ip"])
            result[f"reset_{target}"] = reply
            if not reply["ok"]: raise RuntimeError(f"DCA {target} reset failed")
            if STOP_REQUESTED:
                result["startup_stop_phase"] = f"after_dca_reset_{target}"
                stop_reason = "manual_stop_before_sensor_start"
                _event(session, "manual_stop_before_sensor_start", phase=result["startup_stop_phase"])
                return 0
        time.sleep(1.0)
        if STOP_REQUESTED:
            result["startup_stop_phase"] = "before_awr_init"
            stop_reason = "manual_stop_before_sensor_start"
            _event(session, "manual_stop_before_sensor_start", phase=result["startup_stop_phase"])
            return 0
        import fpga_udp
        value = fpga_udp.AWR2243_init(str(radar_config))
        if not _ok(value): raise RuntimeError(f"AWR2243_init failed: {value!r}")
        awr_initialized = True
        if STOP_REQUESTED:
            result["startup_stop_phase"] = "after_awr_init"
            stop_reason = "manual_stop_before_sensor_start"
            _event(session, "manual_stop_before_sensor_start", phase=result["startup_stop_phase"])
            return 0
        value = fpga_udp.AWR2243_setFrameCfg(0)
        if not _ok(value): raise RuntimeError(f"AWR2243_setFrameCfg(0) failed: {value!r}")
        if STOP_REQUESTED:
            result["startup_stop_phase"] = "after_frame_config"
            stop_reason = "manual_stop_before_sensor_start"
            _event(session, "manual_stop_before_sensor_start", phase=result["startup_stop_phase"])
            return 0
        result["dca_configure"] = configure_dca_capture(network["dca_ip"], int(network["config_port"]), dca_config, bind_ip=network["nx_ip"])
        with receiver_log.open("w", encoding="utf-8") as handle:
            receiver = subprocess.Popen(receiver_command, stdout=handle, stderr=subprocess.STDOUT, text=True)
        time.sleep(0.5)
        if receiver.poll() is not None: raise RuntimeError("receiver exited before stream start")
        result["receiver_pid"] = receiver.pid
        _atomic_json(runtime_path, {"schema": "nx-radar-active-capture/v1", "worker_pid": os.getpid(), "receiver_pid": receiver.pid, "session": str(session), "state": "ready_to_start_sensor", "started_at": _now()})
        if STOP_REQUESTED:
            result["startup_stop_phase"] = "receiver_ready_before_dca_stream"
            stop_reason = "manual_stop_before_sensor_start"
            _event(session, "manual_stop_before_sensor_start", phase=result["startup_stop_phase"])
            return 0
        result["dca_stream_start"] = start_dca_stream(network["dca_ip"], int(network["config_port"]), bind_ip=network["nx_ip"])
        dca_stream_started = True
        if STOP_REQUESTED:
            result["startup_stop_phase"] = "dca_stream_started_before_sensor_start"
            stop_reason = "manual_stop_before_sensor_start"
            _event(session, "manual_stop_before_sensor_start", phase=result["startup_stop_phase"])
            return 0
        value = fpga_udp.AWR2243_sensorStart()
        if not _ok(value): raise RuntimeError(f"AWR2243_sensorStart failed: {value!r}")
        sensor_started = True
        ever_started = True
        start_monotonic = time.monotonic()
        manifest["status"] = "capturing"
        manifest["sensor_start_sent"] = True
        _atomic_json(manifest_path, manifest)
        _atomic_json(runtime_path, {"schema": "nx-radar-active-capture/v1", "worker_pid": os.getpid(), "receiver_pid": receiver.pid, "session": str(session), "state": "capturing", "started_at": _now(), "manual_stop_rule": "receiver exits only after closing its current complete physical bin"})
        _event(session, "capture_started", stop_after_gib=derived["stop_after_gib_requested"])
        while receiver.poll() is None and not STOP_REQUESTED:
            free = shutil.disk_usage(session).free
            threshold = int(float(derived["reserve_disk_gib"]) * 1024**3) + int(derived.get("disk_stop_guard_bytes", 1024**3))
            if free <= threshold:
                disk_stop = True
                break
            if boundary_ready_path.is_file():
                disk_stop = json.loads(boundary_ready_path.read_text()).get("stop_reason") == "disk_reserve"
                break
            time.sleep(0.2)
        if receiver.poll() is not None:
            stop_reason = "receiver_capacity_or_failure"
            result["receiver_returncode"] = receiver.returncode
        else:
            stop_reason = "disk_reserve" if disk_stop else "manual_stop_requested"
            _event(session, "manual_stop_receiver_boundary_requested", rule="finish current complete physical bin before sensor/DCA stop")
            receiver.send_signal(signal.SIGINT)
            boundary_deadline = time.monotonic() + 5.0
            while time.monotonic() < boundary_deadline and receiver.poll() is None and not boundary_ready_path.is_file():
                time.sleep(0.01)
            if boundary_ready_path.is_file():
                result["boundary_stop_ready"] = json.loads(boundary_ready_path.read_text(encoding="utf-8"))
                _event(session, "manual_stop_boundary_closed", **result["boundary_stop_ready"])
            else:
                result["boundary_stop_ready_timeout"] = True
                result["error"] = "receiver did not finish a complete segment before stop timeout"
            if sensor_started:
                value = fpga_udp.AWR2243_sensorStop()
                result["sensor_stop_after_boundary"] = value
                if _ok(value):
                    sensor_started = False
            if dca_stream_started:
                result["dca_stream_stop_after_boundary"] = stop_dca_stream(
                    network["dca_ip"], int(network["config_port"]), bind_ip=network["nx_ip"])
                if result["dca_stream_stop_after_boundary"].get("ok"):
                    dca_stream_started = False
            if receiver.poll() is None:
                receiver.send_signal(signal.SIGINT)
            try:
                result["receiver_returncode"] = receiver.wait(timeout=20)
            except subprocess.TimeoutExpired:
                receiver.terminate()
                result["receiver_returncode"] = receiver.wait(timeout=5)
                result["receiver_forced_terminate"] = True
    except Exception as exc:
        result["error"] = repr(exc)
        stop_reason = "worker_error"
        _event(session, "capture_worker_error", error=repr(exc))
    finally:
        if sensor_started:
            try:
                import fpga_udp
                result["sensor_stop"] = fpga_udp.AWR2243_sensorStop()
            except Exception as exc: result["sensor_stop_error"] = repr(exc)
        if dca_stream_started:
            try: result["dca_stream_stop"] = stop_dca_stream(network["dca_ip"], int(network["config_port"]), bind_ip=network["nx_ip"])
            except Exception as exc: result["dca_stream_stop_error"] = repr(exc)
        if receiver is not None:
            if receiver.poll() is None: receiver.send_signal(signal.SIGINT)
            try: result["receiver_returncode"] = receiver.wait(timeout=20)
            except subprocess.TimeoutExpired:
                receiver.terminate(); result["receiver_returncode"] = receiver.wait(timeout=5); result["receiver_forced_terminate"] = True
        if awr_initialized:
            try:
                import fpga_udp
                result["poweroff"] = fpga_udp.AWR2243_poweroff()
            except Exception as exc: result["poweroff_error"] = repr(exc)
        try:
            result["post_capture_dca_probe"] = probe_dca(
                network["dca_ip"], int(network["config_port"]), 1.0, bind_ip=network["nx_ip"])
        except Exception as exc:
            result["post_capture_dca_probe_error"] = repr(exc)
        quality_path = session / "radar" / "radar_quality_summary.json"
        result["quality"] = json.loads(quality_path.read_text(encoding="utf-8")) if quality_path.is_file() else None
        evidence_after = snapshot_host(network["interface"])
        write_evidence(session / "logs" / "host_evidence_after.json", evidence_after)
        host_delta = evidence_delta(evidence_before, evidence_after)
        write_evidence(session / "logs" / "host_evidence_delta.json", host_delta)
        result["host_evidence_delta"] = host_delta
        receiver_rc = result.get("receiver_returncode")
        if ever_started and receiver_rc not in (None, 0) and "error" not in result:
            result["error"] = f"receiver exited with status {receiver_rc}"
        quality_fault_fields = (
            "duplicate_packets", "out_of_order_packets", "short_packets", "oversized_packets",
            "source_ip_anomalies", "source_port_anomalies", "byte_gaps", "byte_stride_mismatches",
            "sequence_mismatches", "queue_overflows", "trailing_unresolved_packets",
        )
        if ever_started and result["quality"] is None and "error" not in result:
            result["error"] = "receiver quality summary is missing after a started stream"
        elif result["quality"]:
            nonzero_quality = {
                key: int(result["quality"].get(key, 0))
                for key in quality_fault_fields
                if int(result["quality"].get(key, 0)) != 0
            }
            result["quality_gate"] = {
                "passed": not nonzero_quality,
                "nonzero_fault_counters": nonzero_quality,
                "boundary_discard_bytes": int(result["quality"].get("boundary_discard_bytes", 0)),
                "boundary_discard_packets": int(result["quality"].get("boundary_discard_packets", 0)),
            }
            if nonzero_quality and "error" not in result:
                result["error"] = f"receiver quality gate failed: {nonzero_quality}"
        if not host_delta["transport_clean"] and "error" not in result:
            result["error"] = f"host transport counters increased: {host_delta['transport_faults']}"
        if ever_started and result["quality"] and result["quality"].get("status") == "disk_reserve_stop":
            stop_reason = "disk_reserve"
        if any(key in result for key in ("sensor_stop_error", "dca_stream_stop_error", "poweroff_error")):
            result.setdefault("error", "hardware cleanup reported an error; inspect capture result")
        result["stop_reason"] = stop_reason
        result["finished_at"] = _now()
        _atomic_json(session / "capture_result.json", result)
        manifest["status"] = "capture_failed" if result.get("error") else "capture_stopped"
        manifest["capture_result"] = str(session / "capture_result.json")
        _atomic_json(manifest_path, manifest)
        try:
            runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
            if int(runtime.get("worker_pid", -1)) == os.getpid():
                runtime_path.unlink()
        except FileNotFoundError:
            pass
        _event(session, "capture_finished", stop_reason=stop_reason, status=manifest["status"])
    return 2 if result.get("error") else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock-fd", type=int)
    parser.add_argument("--root", required=True)
    parser.add_argument("--session", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, _signal)
    signal.signal(signal.SIGINT, _signal)
    return run(Path(args.root), Path(args.session))


if __name__ == "__main__":
    raise SystemExit(main())
