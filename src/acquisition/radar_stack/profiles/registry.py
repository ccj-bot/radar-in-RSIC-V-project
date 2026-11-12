from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
from typing import Any

from radar_stack.profiles.plan import FormError, build_capture_plan
from radar_stack.profiles.sync import sync_profile as _sync_generated_profile


def _validate_name(name: str) -> str:
    value = name.strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", value):
        raise FormError("name must use 1-80 ASCII letters, digits, dot, underscore, or dash")
    return value


def saved_dir(root: Path) -> Path:
    return root / "config" / "profiles" / "saved"


def profile_path(root: Path, name: str) -> Path:
    return saved_dir(root) / f"{_validate_name(name)}.json"


def _atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".part")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def create_profile(root: Path, name: str, source: Path) -> Path:
    destination = profile_path(root, name)
    if destination.exists():
        raise FormError(f"saved profile already exists: {name}")
    source = source.resolve()
    form = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(form.get("fields"), dict):
        raise FormError("source form has no fields object")
    form["fields"]["profile_name"]["value"] = name
    _atomic_json(destination, form)
    try:
        _sync_generated_profile(root, name)
    except Exception:
        destination.unlink(missing_ok=True)
        raise
    return destination


def update_profile_field(root: Path, name: str, field: str, json_value: str) -> Path:
    path = profile_path(root, name)
    form = json.loads(path.read_text(encoding="utf-8"))
    if field not in form.get("fields", {}):
        raise FormError(f"unknown form field: {field}")
    original = json.loads(json.dumps(form))
    try:
        value = json.loads(json_value)
    except json.JSONDecodeError:
        value = json_value
    form["fields"][field]["value"] = value
    _atomic_json(path, form)
    try:
        _sync_generated_profile(root, name)
    except Exception:
        # Do not leave a selected profile in a state that cannot generate its
        # corresponding executable radar/DCA files.
        _atomic_json(path, original)
        raise
    return path


def sync_profile(root: Path, name: str) -> dict[str, Any] | None:
    """Regenerate all derived config files for a saved profile without selecting it."""
    profile_path(root, name)  # validates name and stable location
    return _sync_generated_profile(root, name)


def list_profiles(root: Path) -> list[dict[str, Any]]:
    active = active_profile_name(root)
    try:
        station = json.loads((root / "config" / "station.yaml").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        station = None
    result = []
    for path in sorted(saved_dir(root).glob("*.json")) if saved_dir(root).exists() else []:
        try:
            form = json.loads(path.read_text(encoding="utf-8"))
            fields = form["fields"]
            item: dict[str, Any] = {
                "name": path.stem,
                "active": path.stem == active,
                "capture_mode": fields.get("capture_mode", {}).get("value"),
                "profile_usage": fields.get("profile_usage", {}).get("value") or "formal",
                "target_frame_rate_hz": fields.get("radar_target_frame_rate_hz", {}).get("value"),
                "radar_config": fields.get("radar_config", {}).get("value"),
            }
            try:
                from radar_stack.profiles.validation import validation_status

                plan = build_capture_plan(path, project_root=root)
                status = validation_status(root, form, plan, station)
                item["actual_frame_rate_hz"] = plan["derived"].get("timing_model", {}).get("frame_rate_hz")
                item["dca_utilization"] = plan["derived"].get("transport_budget", {}).get("dca_utilization")
                action = status["next_action"]
                item["capture_readiness"] = action
                item["capture_readiness_zh"] = {
                    "ready_for_capture": "已验证可采",
                    "run_10_frame_validation": "需要10帧验证",
                    "fix_unsupported_mixed_geometry": "当前不支持",
                }.get(action, "配置需要检查")
                item["validation_blockers"] = status["compatibility"]["blockers"]
            except Exception as exc:
                item["capture_readiness"] = "configuration_error"
                item["capture_readiness_zh"] = "配置文件有误"
                item["validation_blockers"] = [str(exc)]
            result.append(item)
        except (OSError, json.JSONDecodeError, KeyError) as exc:
            result.append({"name": path.stem, "active": False, "error": str(exc)})
    return result


def active_profile_name(root: Path) -> str | None:
    path = root / "config" / "active_profile.json"
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8")).get("profile_name")


def select_profile(root: Path, name: str) -> Path:
    candidate = profile_path(root, name)
    if not candidate.is_file():
        raise FormError(f"saved profile does not exist: {name}")
    destination = root / "config" / "active_profile.json"
    _atomic_json(destination, {"profile_name": name, "profile_path": str(candidate), "selected_at": datetime.now(timezone.utc).isoformat()})
    return destination


def active_profile_path(root: Path) -> Path:
    name = active_profile_name(root)
    if not name:
        raise FormError("no active profile; run profile select first")
    path = profile_path(root, name)
    if not path.is_file():
        raise FormError(f"active profile is missing: {name}")
    return path


def prepare_session(root: Path, session_name: str, *, session_metadata: dict[str, Any] | None = None) -> Path:
    safe_name = _validate_name(session_name)
    source_form = active_profile_path(root)
    _sync_generated_profile(root, source_form.stem)
    source_form = active_profile_path(root)
    plan = build_capture_plan(source_form, project_root=root)
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S_%f")
    session = root / "sessions" / f"{timestamp}__{safe_name}"
    if session.exists():
        raise FormError(f"session path already exists: {session}")
    for relative in ("radar/raw_segments", "reconstruction/images", "logs"):
        (session / relative).mkdir(parents=True, exist_ok=True)
    shutil.copy2(root / "config" / "station.yaml", session / "station_config_snapshot.yaml")
    form = json.loads(source_form.read_text(encoding="utf-8"))
    radar_config = form.get("fields", {}).get("radar_config", {}).get("value")
    if not radar_config:
        raise FormError("profile has no generated radar_config to snapshot")
    radar_path = Path(str(radar_config))
    if not radar_path.is_absolute(): radar_path = root / radar_path
    if not radar_path.is_file(): raise FormError(f"generated radar_config is missing: {radar_path}")
    radar_snapshot = session / "radar_config_snapshot.cfg"
    shutil.copy2(radar_path, radar_snapshot)
    form["fields"]["radar_config"]["value"] = str(radar_snapshot)
    dca_config = form.get("fields", {}).get("dca_config", {}).get("value")
    if not dca_config:
        station_for_dca = json.loads((root / "config" / "station.yaml").read_text(encoding="utf-8"))
        dca_config = station_for_dca["network"].get("dca_config")
    if dca_config:
        dca_path = Path(str(dca_config))
        if not dca_path.is_absolute(): dca_path = root / dca_path
        if not dca_path.is_file(): raise FormError(f"generated dca_config is missing: {dca_path}")
        dca_snapshot = session / "dca_config_snapshot.json"
        shutil.copy2(dca_path, dca_snapshot)
        form.setdefault("fields", {}).setdefault("dca_config", {"zh": "会话冻结 DCA 配置", "en": "Session-frozen DCA configuration"})["value"] = str(dca_snapshot)
    _atomic_json(session / "profile_form_snapshot.json", form)
    _atomic_json(session / "capture_plan.json", plan)
    manifest = {
        "schema": "nx-radar-session/v1",
        "session_name": safe_name,
        "session_path": str(session),
        "status": "prepared_no_hardware_started",
        "active_profile": active_profile_name(root),
        "prepared_at": datetime.now(timezone.utc).isoformat(),
        "sensor_start_sent": False,
    }
    if session_metadata:
        metadata = {
            "schema": "nx-radar-experiment/v1",
            "created_at": datetime.now(timezone.utc).isoformat(),
            **session_metadata,
        }
        _atomic_json(session / "experiment.json", metadata)
        manifest["experiment_metadata"] = str(session / "experiment.json")
    _atomic_json(session / "session_manifest.json", manifest)
    (session / "events.jsonl").write_text(json.dumps({"event": "session_prepared", "monotonic_ns": None, "hardware_action": "none"}, ensure_ascii=False) + "\n", encoding="utf-8")
    from radar_stack.imaging.contract import write_contract
    write_contract(session)
    return session
