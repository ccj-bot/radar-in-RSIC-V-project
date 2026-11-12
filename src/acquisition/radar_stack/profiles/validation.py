"""Configuration identity and bounded-stream validation for capture profiles.

The receiver has a fixed bytes-per-chirp contract.  This module makes that
contract explicit: a change to the radar or DCA file gets a new fingerprint and
cannot reuse validation evidence collected for an older configuration.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
from typing import Any


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _resolve(root: Path, value: object) -> Path:
    path = Path(str(value))
    return path if path.is_absolute() else root / path


def _config_paths(root: Path, form: dict[str, Any], station: dict[str, Any] | None = None) -> tuple[Path, Path]:
    fields = form.get("fields", {})
    radar_value = fields.get("radar_config", {}).get("value")
    dca_value = fields.get("dca_config", {}).get("value")
    if not dca_value and station:
        dca_value = station.get("network", {}).get("dca_config")
    if not radar_value or not dca_value:
        raise ValueError("profile must contain radar_config and dca_config before validation")
    radar, dca = _resolve(root, radar_value), _resolve(root, dca_value)
    if not radar.is_file() or not dca.is_file():
        raise FileNotFoundError({"radar_config": str(radar), "dca_config": str(dca)})
    return radar, dca


def configuration_identity(root: Path, form: dict[str, Any], station: dict[str, Any] | None = None) -> dict[str, Any]:
    """Return an identity based only on files that can alter the byte stream.

    Bin size, reconstruction windows and the session data cap are intentionally
    excluded: they change file layout, not the radar/DCA wire format.
    """
    root = Path(root).resolve()
    radar, dca = _config_paths(root, form, station)
    identity = {
        "schema": "nx-radar-configuration-identity/v1",
        "radar_config_sha256": _sha256(radar),
        "dca_config_sha256": _sha256(dca),
    }
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
    identity["fingerprint"] = hashlib.sha256(encoded).hexdigest()
    identity["radar_config"] = str(radar)
    identity["dca_config"] = str(dca)
    return identity


def validation_path(root: Path, fingerprint: str) -> Path:
    return Path(root) / "config" / "profiles" / "validated" / f"{fingerprint}.json"


def compatibility_from_plan(plan: dict[str, Any]) -> dict[str, Any]:
    """Decide whether the fixed-size receiver can safely represent this config."""
    summary = plan.get("radar_profile_summary", {})
    warnings = [str(item) for item in summary.get("warnings", [])]
    blocking_warning_markers = (
        "multiple selected profile ids",
        "selected chirp ",
        "txEnable missing",
        "chirps_per_frame could not be computed",
        "frame_bytes could not be computed",
        "channelRx not found",
        "numAdcSamples not found",
    )
    blockers = [warning for warning in warnings if any(marker in warning for marker in blocking_warning_markers)]
    derived = plan.get("derived", {})
    bytes_per_chirp = int(derived.get("bytes_per_chirp", 0))
    chirps_per_frame = int(derived.get("chirps_per_frame", 0))
    rx_count = int(summary.get("rx_count") or 0)
    adc_samples = int(summary.get("adc_samples") or 0)
    expected = rx_count * adc_samples * 4 if rx_count and adc_samples else 0
    transport = plan.get("transport_geometry", {})
    transport_override = bool(transport.get("validated_override"))
    if expected and expected != bytes_per_chirp and not transport_override:
        blockers.append(f"parsed payload geometry {expected} B/chirp differs from plan {bytes_per_chirp} B/chirp")
    if not (1 <= rx_count <= 4):
        blockers.append(f"RX count {rx_count} is outside AWR2243 supported range 1..4")
    if chirps_per_frame <= 0 or bytes_per_chirp <= 0:
        blockers.append("non-positive chirps_per_frame or bytes_per_chirp")
    return {
        "fixed_geometry_supported": not blockers,
        "blockers": blockers,
        "advisory_warnings": [warning for warning in warnings if warning not in blockers],
        "parsed_rx_count": rx_count,
        "parsed_tx_count_effective": int(summary.get("tx_count_effective") or 0),
        "parsed_adc_samples": adc_samples,
        "planned_bytes_per_chirp": bytes_per_chirp,
        "planned_chirps_per_frame": chirps_per_frame,
        "validated_transport_override": transport_override,
    }


def validation_status(root: Path, form: dict[str, Any], plan: dict[str, Any], station: dict[str, Any] | None = None) -> dict[str, Any]:
    identity = configuration_identity(root, form, station)
    compatibility = compatibility_from_plan(plan)
    path = validation_path(root, identity["fingerprint"])
    record: dict[str, Any] | None = None
    if path.is_file():
        record = json.loads(path.read_text(encoding="utf-8"))
    geometry_matches = bool(record) and int(record.get("verified_bytes_per_chirp", -1)) == compatibility["planned_bytes_per_chirp"] and int(record.get("verified_chirps_per_frame", -1)) == compatibility["planned_chirps_per_frame"]
    return {
        "identity": identity,
        "compatibility": compatibility,
        "stream_validation_record": record,
        "stream_validation_current": geometry_matches,
        "stream_validation_path": str(path),
        "next_action": "ready_for_capture" if compatibility["fixed_geometry_supported"] and geometry_matches else ("run_10_frame_validation" if compatibility["fixed_geometry_supported"] else "fix_unsupported_mixed_geometry"),
    }


def validation_status_for_session(root: Path, session: Path) -> dict[str, Any]:
    session = Path(session).resolve()
    plan = json.loads((session / "capture_plan.json").read_text(encoding="utf-8"))
    form = json.loads((session / "profile_form_snapshot.json").read_text(encoding="utf-8"))
    station = json.loads((session / "station_config_snapshot.yaml").read_text(encoding="utf-8"))
    return validation_status(Path(root), form, plan, station)


def record_validated_stream(root: Path, session: Path, assessment: dict[str, Any]) -> dict[str, Any]:
    """Persist evidence that exactly this radar+DCA fingerprint passed a bounded run."""
    root, session = Path(root).resolve(), Path(session).resolve()
    plan = json.loads((session / "capture_plan.json").read_text(encoding="utf-8"))
    form = json.loads((session / "profile_form_snapshot.json").read_text(encoding="utf-8"))
    station = json.loads((session / "station_config_snapshot.yaml").read_text(encoding="utf-8"))
    compatibility = compatibility_from_plan(plan)
    if not compatibility["fixed_geometry_supported"]:
        raise RuntimeError({"message": "configuration is not safe for the fixed-size receiver", "compatibility": compatibility})
    if not assessment.get("geometry_confirmed_for_complete_segments"):
        raise RuntimeError("bounded stream evidence did not confirm this configuration")
    identity = configuration_identity(root, form, station)
    record = {
        "schema": "nx-radar-profile-stream-validation/v1",
        "accepted_at": datetime.now(timezone.utc).isoformat(),
        "fingerprint": identity["fingerprint"],
        "radar_config_sha256": identity["radar_config_sha256"],
        "dca_config_sha256": identity["dca_config_sha256"],
        "evidence_session": str(session),
        "verified_bytes_per_chirp": int(assessment["verified_bytes_per_chirp"]),
        "verified_chirps_per_frame": int(assessment["verified_chirps_per_frame"]),
        "observed_source_port": int(assessment["observed_source_port"]),
        "assessment": assessment,
    }
    destination = validation_path(root, identity["fingerprint"])
    _atomic_json(destination, record)
    return {"validation_record": str(destination), "record": record}


def validate_active_profile(root: Path, *, frames: int = 10, lock_fd=None) -> dict[str, Any]:
    from radar_stack.capture.manager import capture_lock
    if lock_fd is not None:
        return _validate_active_profile_locked(root, frames=frames)
    with capture_lock(root):
        return _validate_active_profile_locked(root, frames=frames)


def _validate_active_profile_locked(root: Path, *, frames: int = 10) -> dict[str, Any]:
    """Run the one bounded hardware transaction needed after stream-format changes."""
    if frames < 1 or frames > 20:
        raise ValueError("profile validation frames must be in 1..20")
    root = Path(root).resolve()
    from radar_stack.profiles.registry import active_profile_name, prepare_session
    from radar_stack.capture.discovery import accept_stream_discovery, run_stream_discovery

    runtime_path = root / "runtime" / "active_capture.json"
    if runtime_path.is_file():
        runtime = json.loads(runtime_path.read_text(encoding="utf-8"))
        pid = int(runtime.get("worker_pid", -1))
        if pid <= 0:
            runtime_path.unlink(missing_ok=True)
        else:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                runtime_path.unlink(missing_ok=True)
            except PermissionError:
                raise RuntimeError("an existing capture worker is active; profile validation is blocked")
            else:
                raise RuntimeError("an existing capture worker is active; stop it before profile validation")

    name = active_profile_name(root)
    if not name:
        raise RuntimeError("select a profile before validating it")
    session = prepare_session(root, f"validate-{name}")
    plan = json.loads((session / "capture_plan.json").read_text(encoding="utf-8"))
    compatibility = compatibility_from_plan(plan)
    if not compatibility["fixed_geometry_supported"]:
        manifest_path = session / "session_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["status"] = "validation_blocked_before_hardware"
        manifest["validation_blockers"] = compatibility["blockers"]
        _atomic_json(manifest_path, manifest)
        raise RuntimeError({
            "session": str(session),
            "message": "profile is unsupported by the fixed-geometry receiver; no hardware action was taken",
            "compatibility": compatibility,
        })
    discovery = run_stream_discovery(root, session, frames)
    if discovery.get("error"):
        raise RuntimeError({"session": str(session), "discovery_error": discovery["error"]})
    accepted = accept_stream_discovery(root, session)
    return {
        "profile": name,
        "session": str(session),
        "frames": frames,
        "hardware_action": "bounded finite-frame validation completed; no formal capture session created",
        "accepted": accepted,
    }
