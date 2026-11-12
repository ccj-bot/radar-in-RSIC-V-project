"""Small public control surface for background manual capture."""
from __future__ import annotations

from datetime import datetime, timezone
import json
import fcntl
from contextlib import contextmanager
import os
from pathlib import Path
import signal
import subprocess
import sys
from typing import Any

from radar_stack.capture.preflight import run_capture_preflight
from radar_stack.profiles.registry import prepare_session


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".part")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def _runtime_path(root: Path) -> Path:
    return root / "runtime" / "active_capture.json"


def _pid_is_running(pid: int) -> bool:
    """True only while the registered worker process still exists."""
    if pid <= 0:
        return False
    try:
        command = Path(f"/proc/{pid}/cmdline").read_bytes()
        if b"radar_stack.capture.worker" not in command:
            return False
        os.kill(pid, 0)
    except (ProcessLookupError, FileNotFoundError):
        return False
    except PermissionError:
        return True
    return True


@contextmanager
def capture_lock(root: Path):
    path = Path(root) / "runtime" / "capture.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("已有采集或设备验证正在运行") from None
        yield lock.fileno()


def start_capture(root, session_name, *, dry_run=False, allow_experimental_profile=False,
                  session_metadata=None, lock_fd=None):
    options = dict(dry_run=dry_run, allow_experimental_profile=allow_experimental_profile,
                   session_metadata=session_metadata)
    if lock_fd is not None:
        return _start_capture_locked(root, session_name, lock_fd=lock_fd, **options)
    with capture_lock(root) as fd:
        return _start_capture_locked(root, session_name, lock_fd=fd, **options)


def _start_capture_locked(
    root: Path,
    session_name: str,
    *,
    lock_fd: int,
    dry_run: bool = False,
    allow_experimental_profile: bool = False,
    session_metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    root = Path(root).resolve()
    runtime = _runtime_path(root)
    if runtime.exists():
        stale = json.loads(runtime.read_text(encoding="utf-8"))
        if _pid_is_running(int(stale.get("worker_pid", -1))):
            raise RuntimeError(f"a capture is already registered: {runtime}")
        runtime.unlink()
    # Gate before preparing a formal session: an unsupported or unvalidated
    # stream format must not create a misleading empty capture directory.
    from radar_stack.profiles.plan import build_capture_plan
    from radar_stack.profiles.registry import active_profile_path
    from radar_stack.profiles.validation import validation_status

    form_path = active_profile_path(root)
    form = json.loads(form_path.read_text(encoding="utf-8"))
    station = json.loads((root / "config" / "station.yaml").read_text(encoding="utf-8"))
    selected_plan = build_capture_plan(form_path, project_root=root)
    usage = selected_plan["derived"].get("profile_usage", "formal")
    if usage != "formal" and not allow_experimental_profile:
        raise RuntimeError(
            f"profile usage is {usage!r}; use the stress/experimental workflow so the exception is explicit"
        )
    readiness = validation_status(root, form, selected_plan, station)
    if readiness["next_action"] != "ready_for_capture":
        raise RuntimeError({
            "message": "capture is blocked before session preparation: stream format is not currently verified",
            "profile": form_path.stem,
            "next_action": readiness["next_action"],
            "validation_blockers": readiness["compatibility"]["blockers"],
        })
    session = prepare_session(root, session_name, session_metadata=session_metadata)
    preflight = run_capture_preflight(root, session)
    if preflight["summary_status"] != "preflight_passed_not_capture_authorized":
        manifest_path = session / "session_manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["status"] = "preflight_blocked"
        manifest["preflight_report"] = preflight["written_report"]
        _atomic_json(manifest_path, manifest)
        blockers = [item["blocker"] for item in preflight["checks"] if not item["ok"]]
        raise RuntimeError("采集预检未通过：" + "; ".join(blockers))
    plan = json.loads((session / "capture_plan.json").read_text(encoding="utf-8"))
    if plan["derived"]["capture_mode"] not in {"manual_stop_with_data_cap", "manual_until_disk_reserve"}:
        raise RuntimeError("capture start currently supports manual_stop_with_data_cap profiles only")
    command = [sys.executable, "-m", "radar_stack.capture.worker", "--root", str(root), "--session", str(session), "--lock-fd", str(lock_fd)]
    if dry_run:
        return {"session": str(session), "preflight": preflight, "worker_command": command, "hardware_action": "none"}
    log_path = session / "logs" / "capture_worker.log"
    with log_path.open("w", encoding="utf-8") as handle:
        process = subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT, text=True, start_new_session=True, pass_fds=(lock_fd,))
    _atomic_json(runtime, {"schema": "nx-radar-active-capture/v1", "worker_pid": process.pid, "session": str(session), "state": "launching", "requested_at": _now()})
    return {"session": str(session), "worker_pid": process.pid, "preflight_report": preflight["written_report"], "stop_command": "radarctl capture stop", "hardware_action": "worker started; it will control DCA/AWR"}


def stop_capture(root: Path, session: str | None = None) -> dict[str, Any]:
    root = Path(root).resolve()
    runtime = _runtime_path(root)
    if not runtime.is_file():
        raise RuntimeError("no active capture runtime record")
    state = json.loads(runtime.read_text(encoding="utf-8"))
    if session and Path(session).resolve() != Path(state["session"]).resolve():
        raise RuntimeError("requested session does not match active capture")
    pid = int(state["worker_pid"])
    if not _pid_is_running(pid):
        runtime.unlink(missing_ok=True)
        raise RuntimeError("registered capture worker is no longer running; stale runtime record removed")
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError as exc:
        raise RuntimeError("registered capture worker is no longer running; inspect its session result") from exc
    state["state"] = "manual_stop_requested"
    state["stop_requested_at"] = _now()
    _atomic_json(runtime, state)
    return {"session": state["session"], "worker_pid": pid, "stop_requested": True, "note": "receiver will finish the current complete physical bin before the worker stops DCA/radar"}


def capture_status(root: Path) -> dict[str, Any]:
    root = Path(root).resolve()
    runtime = _runtime_path(root)
    if not runtime.is_file():
        return {"active": False}
    state = json.loads(runtime.read_text(encoding="utf-8"))
    if not _pid_is_running(int(state.get("worker_pid", -1))):
        runtime.unlink(missing_ok=True)
        return {"active": False, "stale_runtime_removed": True, "last_runtime": state}
    session = Path(state["session"])
    quality_path = session / "radar" / "radar_quality_summary.json"
    return {"active": True, "runtime": state, "quality": json.loads(quality_path.read_text(encoding="utf-8")) if quality_path.is_file() else None}
