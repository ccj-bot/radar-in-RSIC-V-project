"""Run loss-protected capture and a display-only bin-tail preview together."""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
from typing import Any


# Display-only choice: raw physical bins are always written unchanged. CUDA
# supports bilinear remapping here; the spline path remains CPU-only.
PREVIEW_BACKEND = "cuda"
PREVIEW_INTERPOLATION_MODE = "bilinear"
PREVIEW_GRID_SPACING_M = 0.10


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def _bit_count(value: int) -> int:
    return bin(value).count("1")


def _preview_contract_from_plan(plan: dict[str, Any], session: str) -> dict[str, Any]:
    summary = plan["radar_profile_summary"]
    derived = plan["derived"]
    fields = plan["input_fields"]
    timing = derived["timing_model"]
    chirps_per_frame = int(summary["chirps_per_frame"])
    physical_segment_pulses = int(derived["physical_segment_pulses"])
    if chirps_per_frame != physical_segment_pulses:
        raise RuntimeError(
            "live preview requires one physical bin to equal one complete radar frame; "
            f"got frame={chirps_per_frame}, bin={physical_segment_pulses}")
    tx_sequence = list(summary["effective_tx_sequence"])
    if len(tx_sequence) != 1 or int(summary["tx_count_effective"]) != 1:
        raise RuntimeError(
            "live preview is blocked for multi-TX profiles until TX chirp demultiplexing and calibration are implemented")
    lanes = _bit_count(int(fields["radar_lvds_lane_mask"]["value"]))
    if lanes <= 0:
        raise RuntimeError("LVDS lane mask resolves to zero enabled lanes")
    return {
        "schema": "nx-radar-live-preview-contract/v1",
        "created_at": _now(),
        "preview_status": "engineering_preview_only_not_physical_localization",
        "profile_name": plan["profile_name"],
        "session": session,
        "chirps_per_frame": chirps_per_frame,
        "window_frames": 1,
        "step_frames": 1,
        "adc_samples": int(summary["adc_samples"]),
        "lvds_lanes": lanes,
        "effective_tx_sequence": tx_sequence,
        "frame_periodicity_ms": float(summary["frame_periodicity_ms"]),
        "frame_rate_hz": float(summary["frame_rate_hz"]),
        "within_frame_prf_hz": float(timing["within_frame_prf_hz"]),
        "frame_blank_time_ms": float(timing["frame_blank_time_ms"]),
        "center_frequency_hz": float(timing["center_frequency_hz"]),
        "adc_sample_rate_hz": float(timing["adc_sample_rate_hz"]),
        "max_unambiguous_range_m": float(timing["max_unambiguous_range_m"]),
        "range_resolution_m": float(timing["range_resolution_m"]),
        "render_backend": PREVIEW_BACKEND,
        "interpolation_mode": PREVIEW_INTERPOLATION_MODE,
        "grid_spacing_m": PREVIEW_GRID_SPACING_M,
        "config_warning": (
            "Preview uses exactly one physical radar frame so a uniform-PRF FFT never crosses a frame gap. "
            "Velocity/trajectory and array calibration are still not authoritative; output remains preview-only."
        ),
    }


def _preview_contract(session: Path) -> dict[str, Any]:
    plan = json.loads((session / "capture_plan.json").read_text(encoding="utf-8"))
    return _preview_contract_from_plan(plan, str(session))


def _write_preview_config(session: Path, contract: dict[str, Any]) -> Path:
    preview_root = session / "reconstruction" / "live_preview"
    preview_root.mkdir(parents=True, exist_ok=True)
    config_path = preview_root / "preview_runtime.cfg"
    lines = [
        "# Generated per-session live preview. Do not reuse as a physical imaging config.",
        f"acquisition.num_lanes = {contract['lvds_lanes']}",
        "acquisition.num_adc_bits = 16",
        "acquisition.is_real = false",
        f"fft.nr = {contract['adc_samples']}",
        f"frame.chirps_per_frame = {contract['chirps_per_frame']}",
        f"frame.window_frames = {contract['window_frames']}",
        f"frame.step_frames = {contract['step_frames']}",
        "fft.zero_range_bins = 100",
        f"fft.circshift_range_bins = {contract['adc_samples'] // 2}",
        "fft.zero_head_after_shift = 20",
        "fft.zero_tail_after_shift = 20",
        "imaging.channel_mode = single",
        "imaging.channel_index = 0",
        f"imaging.interpolation_mode = {contract['interpolation_mode']}",
        f"imaging.backend = {contract['render_backend']}",
        f"imaging.scene.rmax_m = {contract['max_unambiguous_range_m']}",
        f"imaging.scene.prf_hz = {contract['within_frame_prf_hz']}",
        "imaging.scene.c_mps = 3e8",
        f"imaging.scene.fc_hz = {contract['center_frequency_hz']}",
        f"imaging.scene.fs_hz = {contract['adc_sample_rate_hz']}",
        "imaging.scene.beam_width_deg = 120",
        "imaging.scene.squint_angle_deg = 0",
        f"imaging.scene.grid_spacing_m = {contract['grid_spacing_m']}",
        f"stream.replay_rate_hz = {contract['within_frame_prf_hz']}",
        f"stream.ring_columns = {max(512, contract['chirps_per_frame'] * 4)}",
        "display.enabled = true",
        "display.save_every_n = 0",
        "render.jet_levels = 256",
        "render.apply_myorder = true",
        "render.output_gamma = 1",
    ]
    config_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return config_path


def run_live_preview(
    root: Path,
    session_name: str,
    *,
    velocity_mps: float,
    dry_run: bool = False,
    allow_experimental_profile: bool = False,
    session_metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Start capture, tail complete bins, and stop capture when preview exits."""
    root = Path(root).resolve()
    if not dry_run and not os.environ.get("DISPLAY"):
        raise RuntimeError("live preview needs an NX display session; run this from the connected monitor terminal")
    from radar_stack.capture.manager import capture_status, start_capture, stop_capture
    from radar_stack.profiles.plan import build_capture_plan
    from radar_stack.profiles.registry import active_profile_path

    # Block incompatible TX/frame geometry before start_capture can launch any
    # receiver or AWR worker. The prepared session will snapshot this same plan.
    _preview_contract_from_plan(
        build_capture_plan(active_profile_path(root), project_root=root),
        "<not-started>")

    capture = start_capture(
        root,
        session_name,
        dry_run=dry_run,
        allow_experimental_profile=allow_experimental_profile,
        session_metadata=session_metadata,
    )
    session = Path(capture["session"])
    contract = _preview_contract(session)
    config_path = _write_preview_config(session, contract)
    preview_root = config_path.parent
    _atomic_json(preview_root / "preview_contract.json", contract)
    executable = root / "imaging" / "fft_image_NX_live" / "build" / "fft_imaging_live"
    if not executable.is_file():
        raise RuntimeError(f"live preview executable is missing: {executable}")
    command = [
        str(executable), "--config", str(config_path),
        "--source-bin-tail", str(session / "radar" / "raw_segments"),
        "--tail-poll-ms", "50", "--preview-only",
        "--velocity-mps", str(velocity_mps), "--timestamp-overlay",
        "--metrics-log", str(preview_root / "preview_metrics.csv"),
    ]
    _atomic_json(preview_root / "preview_launch.json", {
        "schema": "nx-radar-live-preview-launch/v1", "created_at": _now(),
        "command": command, "capture": capture, "contract": contract,
    })
    if dry_run:
        return {"dry_run": True, "capture": capture, "preview_contract": contract, "preview_command": command}
    preview_log = preview_root / "preview_process.log"
    return_code = -1
    try:
        with preview_log.open("w", encoding="utf-8") as log_handle:
            return_code = subprocess.run(command, stdout=log_handle, stderr=subprocess.STDOUT, text=True).returncode
    finally:
        status = capture_status(root)
        if status.get("active") and Path(status["runtime"]["session"]).resolve() == session.resolve():
            try:
                stop_capture(root, str(session))
            except Exception as exc:
                _atomic_json(preview_root / "preview_stop_error.json", {"at": _now(), "error": repr(exc)})
    return {"session": str(session), "preview_return_code": return_code, "preview_log": str(preview_log), "preview_contract": str(preview_root / "preview_contract.json")}
