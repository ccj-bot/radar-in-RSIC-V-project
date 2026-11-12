from __future__ import annotations

import argparse
import glob
import json
from pathlib import Path
import shutil
import subprocess
import sys

from radar_stack.protocol.dca1000 import DEFAULT_PACKET_BYTES, inspect_raw_datagrams, probe_dca, reset_dca_target


ROOT = Path(__file__).resolve().parents[2]
LEGACY = ROOT / "legacy" / "pyRadar-main"
if str(LEGACY) not in sys.path:
    sys.path.insert(0, str(LEGACY))


def _emit(value: object) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True, default=str))


def _legacy_profile(args: argparse.Namespace, validate: bool) -> int:
    from radar_capture.profiles.mmwave_parser import parse_mmwave_config, summary_to_dict
    from radar_capture.profiles.mmwave_validator import validate_summary

    summary = parse_mmwave_config(Path(args.config))
    payload = summary_to_dict(summary)
    if validate:
        payload["validation"] = validate_summary(summary).to_dict()
    _emit(payload)
    return 0 if not validate or payload["validation"]["passed"] else 2


def profile_plan(args: argparse.Namespace) -> int:
    from radar_stack.profiles.plan import build_capture_plan

    form = Path(args.form)
    if not form.is_absolute():
        form = ROOT / form
    plan = build_capture_plan(form, project_root=ROOT)
    if args.out:
        destination = Path(args.out)
        if not destination.is_absolute():
            destination = ROOT / destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        plan["written_plan"] = str(destination)
    _emit(plan)
    return 0


def profile_create(args: argparse.Namespace) -> int:
    from radar_stack.profiles.registry import create_profile
    source = Path(args.source)
    if not source.is_absolute(): source = ROOT / source
    _emit({"saved_profile": str(create_profile(ROOT, args.name, source))})
    return 0


def profile_set(args: argparse.Namespace) -> int:
    from radar_stack.profiles.registry import update_profile_field
    _emit({"saved_profile": str(update_profile_field(ROOT, args.name, args.field, args.value))})
    return 0


def profile_list(_: argparse.Namespace) -> int:
    from radar_stack.profiles.registry import list_profiles
    _emit({"profiles": list_profiles(ROOT)})
    return 0


def profile_show(args: argparse.Namespace) -> int:
    from radar_stack.profiles.registry import profile_path
    _emit(json.loads(profile_path(ROOT, args.name).read_text(encoding="utf-8")))
    return 0


def profile_select(args: argparse.Namespace) -> int:
    from radar_stack.profiles.registry import select_profile
    _emit({"active_profile_pointer": str(select_profile(ROOT, args.name)), "profile": args.name})
    return 0


def profile_sync(args: argparse.Namespace) -> int:
    from radar_stack.profiles.registry import sync_profile
    result = sync_profile(ROOT, args.name)
    _emit({"profile": args.name, "generated": result, "hardware_action": "none"})
    return 0


def profile_edit(args: argparse.Namespace) -> int:
    """Chinese-first terminal form editor; every confirmed edit triggers sync."""
    from radar_stack.profiles.registry import profile_path, update_profile_field

    path = profile_path(ROOT, args.name)
    form = json.loads(path.read_text(encoding="utf-8"))
    generated = {"profile_name", "radar_config_template", "dca_config_template", "radar_config", "dca_config", "physical_segment_pulses"}
    if "radar_target_frame_rate_hz" in form.get("fields", {}):
        generated.update({"radar_frame_periodicity_ticks", "radar_profile0_idle_time_ticks"})
    editable = [(key, item) for key, item in form.get("fields", {}).items() if key not in generated]
    while True:
        print(f"\n配置编辑 / Profile editor: {args.name}")
        for index, (key, item) in enumerate(editable, 1):
            print(f"[{index}] {item.get('zh', key)} / {item.get('en', key)} = {json.dumps(item.get('value'), ensure_ascii=False)}")
        choice = input("输入编号修改；输入 s 保存同步；输入 q 退出 / Number, s=sync, q=quit: ").strip().lower()
        if choice == "q":
            return 0
        if choice == "s":
            from radar_stack.profiles.registry import sync_profile
            _emit({"profile": args.name, "generated": sync_profile(ROOT, args.name), "hardware_action": "none"})
            return 0
        try:
            key, item = editable[int(choice) - 1]
        except (ValueError, IndexError):
            print("无效编号 / Invalid selection")
            continue
        raw = input(f"新值 / New value for {item.get('zh', key)} [{json.dumps(item.get('value'), ensure_ascii=False)}]: ").strip()
        if not raw:
            continue
        update_profile_field(ROOT, args.name, key, raw)
        form = json.loads(path.read_text(encoding="utf-8"))
        editable = [(name, value) for name, value in form.get("fields", {}).items() if name not in generated]
        print("已保存并自动同步 / Saved and synchronized")


def profile_validation_status(_: argparse.Namespace) -> int:
    """Show whether the selected radar+DCA file pair has current stream evidence."""
    from radar_stack.profiles.plan import build_capture_plan
    from radar_stack.profiles.registry import active_profile_path
    from radar_stack.profiles.validation import validation_status

    form = active_profile_path(ROOT)
    station = json.loads((ROOT / "config" / "station.yaml").read_text(encoding="utf-8"))
    _emit({"profile": form.stem, **validation_status(ROOT, json.loads(form.read_text(encoding="utf-8")), build_capture_plan(form, project_root=ROOT), station)})
    return 0


def profile_validate(args: argparse.Namespace) -> int:
    """Execute a bounded 1-20-frame validation for the currently selected profile."""
    from radar_stack.profiles.validation import validate_active_profile

    try:
        _emit(validate_active_profile(ROOT, frames=args.frames))
        return 0
    except Exception as exc:
        _emit({"error": repr(exc), "hardware_action": "validation may have started; inspect its prepared validation session"})
        return 2


def capture_prepare(args: argparse.Namespace) -> int:
    from radar_stack.profiles.registry import prepare_session
    _emit({"session": str(prepare_session(ROOT, args.name)), "hardware_action": "none"})
    return 0


def capture_preflight(args: argparse.Namespace) -> int:
    """Run the read-only gate for a prepared session; it cannot start capture."""
    from radar_stack.capture.preflight import run_capture_preflight

    session = Path(args.session)
    if not session.is_absolute():
        session = ROOT / session
    try:
        report = run_capture_preflight(
            ROOT,
            session,
            min_udp_receive_buffer_bytes=args.min_udp_receive_buffer_bytes,
            requested_udp_receive_buffer_bytes=args.requested_udp_receive_buffer_bytes,
            dca_timeout_s=args.timeout,
        )
    except Exception as exc:
        _emit({"session": str(session), "summary_status": "blocked", "error": repr(exc), "sensor_start_sent": False})
        return 2
    _emit(report)
    return 0 if report["summary_status"] == "preflight_passed_not_capture_authorized" else 2


def capture_discovery(args: argparse.Namespace) -> int:
    """Plan or run a bounded real-stream discovery; formal capture remains disabled."""
    from radar_stack.capture.discovery import discovery_plan, run_stream_discovery

    session = Path(args.session)
    if not session.is_absolute():
        session = ROOT / session
    try:
        if not args.execute:
            _emit({**discovery_plan(ROOT, session, args.frames), "hardware_action": "none; add --execute to run"})
            return 0
        result = run_stream_discovery(ROOT, session, args.frames)
    except Exception as exc:
        _emit({"session": str(session), "error": repr(exc), "sensor_start_sent": False})
        return 2
    _emit(result)
    return 0 if not result.get("error") else 2


def capture_discovery_assess(args: argparse.Namespace) -> int:
    from radar_stack.capture.discovery import assess_stream_discovery
    session = Path(args.session)
    if not session.is_absolute(): session = ROOT / session
    try:
        _emit(assess_stream_discovery(ROOT, session))
        return 0
    except Exception as exc:
        _emit({"session": str(session), "error": repr(exc)})
        return 2


def capture_discovery_accept(args: argparse.Namespace) -> int:
    from radar_stack.capture.discovery import accept_stream_discovery
    session = Path(args.session)
    if not session.is_absolute(): session = ROOT / session
    try:
        _emit(accept_stream_discovery(ROOT, session))
        return 0
    except Exception as exc:
        _emit({"session": str(session), "error": repr(exc)})
        return 2


def capture_start(args: argparse.Namespace) -> int:
    from radar_stack.capture.manager import start_capture
    try:
        _emit(start_capture(
            ROOT,
            args.name,
            dry_run=args.dry_run,
            allow_experimental_profile=args.allow_experimental_profile,
        ))
        return 0
    except Exception as exc:
        _emit({"error": repr(exc), "sensor_start_sent": False})
        return 2


def capture_stop(args: argparse.Namespace) -> int:
    from radar_stack.capture.manager import stop_capture
    try:
        _emit(stop_capture(ROOT, args.session))
        return 0
    except Exception as exc:
        _emit({"error": repr(exc)})
        return 2


def capture_status(_: argparse.Namespace) -> int:
    from radar_stack.capture.manager import capture_status
    _emit(capture_status(ROOT))
    return 0


def preview_run(args: argparse.Namespace) -> int:
    from radar_stack.preview.live import run_live_preview
    try:
        _emit(run_live_preview(
            ROOT,
            args.name,
            velocity_mps=args.velocity_mps,
            dry_run=args.dry_run,
            allow_experimental_profile=args.allow_experimental_profile,
        ))
        return 0
    except Exception as exc:
        _emit({"error": repr(exc), "sensor_start_sent": False})
        return 2


def experiment_new(_: argparse.Namespace) -> int:
    """Chinese-first experiment wizard from purpose to validated action."""
    from radar_stack.capture.manager import start_capture
    from radar_stack.preview.live import run_live_preview
    from radar_stack.profiles.plan import build_capture_plan
    from radar_stack.profiles.registry import list_profiles, prepare_session, profile_path, select_profile
    from radar_stack.profiles.validation import validate_active_profile, validation_status

    print("\n===== 新建雷达实验 / New Radar Experiment =====")
    purpose = input("实验目的 / Purpose: ").strip() or "radar acquisition experiment"
    profiles = list_profiles(ROOT)
    if not profiles:
        raise RuntimeError("no saved profiles; run `radarctl stress prepare` or create a profile first")
    print("\n可用配置 / Available profiles:")
    for index, item in enumerate(profiles, 1):
        marker = "*" if item.get("active") else " "
        fps = item.get("actual_frame_rate_hz") or item.get("target_frame_rate_hz") or "?"
        usage = item.get("profile_usage", "formal")
        readiness = item.get("capture_readiness_zh", item.get("capture_readiness", "unknown"))
        utilization = item.get("dca_utilization")
        util_text = f" DCA={float(utilization):.1%}" if isinstance(utilization, (int, float)) else ""
        print(f" {marker} [{index}] {item['name']}  {fps} fps  {usage}  {readiness}{util_text}")
    raw = input("配置编号 / Profile number: ").strip()
    try:
        selected_item = profiles[int(raw) - 1]
    except (ValueError, IndexError):
        raise RuntimeError("invalid profile selection")
    name = str(selected_item["name"])
    form_path = profile_path(ROOT, name)
    plan = build_capture_plan(form_path, project_root=ROOT)
    derived = plan["derived"]
    timing = derived["timing_model"]
    transport = derived["transport_budget"]
    print("\n自动推导摘要 / Derived summary:")
    print(f"  物理帧率 / physical fps: {timing['frame_rate_hz']:.6f}")
    print(f"  chirps/frame: {timing['chirps_per_frame']}")
    print(f"  frame blank: {timing['frame_blank_time_ms']:.6f} ms")
    print(f"  range resolution: {timing['range_resolution_m']:.4f} m")
    print(f"  max unambiguous range: {timing['max_unambiguous_range_m']:.2f} m")
    print(f"  ADC payload: {transport['planned_adc_payload_mbps']:.2f} Mb/s")
    print(f"  estimated Ethernet wire: {transport['estimated_ethernet_wire_mbps']:.2f} Mb/s")
    print(f"  DCA utilization: {transport['dca_utilization']:.1%}")
    print(f"  combined formal fps ceiling: {transport['max_formal_fps_combined']:.2f}")
    print(f"  profile usage: {derived.get('profile_usage', 'formal')}")
    print("\n[1] 只准备会话  [2] 原始数据采集  [3] 采集并即时预览")
    action_raw = input("实验动作 / Action: ").strip()
    action = {"1": "prepare_only", "2": "raw_capture", "3": "live_preview"}.get(action_raw)
    if not action:
        raise RuntimeError("invalid experiment action")
    select_profile(ROOT, name)

    if action != "prepare_only":
        station = json.loads((ROOT / "config" / "station.yaml").read_text(encoding="utf-8"))
        form = json.loads(form_path.read_text(encoding="utf-8"))
        readiness = validation_status(ROOT, form, plan, station)
        if readiness["next_action"] != "ready_for_capture":
            print("该配置需要先做有界真实数据验证 / Bounded stream validation is required.")
            if input("现在执行 10 帧验证？/ Run 10-frame validation now? [y/N]: ").strip().lower() != "y":
                raise RuntimeError("experiment stopped before required validation")
            _emit(validate_active_profile(ROOT, frames=10))

    usage = derived.get("profile_usage", "formal")
    allow_experimental = usage != "formal"
    if allow_experimental:
        print(f"警告：这是 {usage} 配置，不会作为日常正式配置。")
        if input("确认仅按实验用途继续？/ Continue experimentally? [y/N]: ").strip().lower() != "y":
            raise RuntimeError("experimental profile was not authorized")
    session_name = input("本次实验名称 / Session name: ").strip()
    notes = input("实验备注 / Notes: ").strip()
    metadata = {"purpose": purpose, "notes": notes, "profile": name, "action": action}
    if action == "prepare_only":
        _emit({"session": str(prepare_session(ROOT, session_name, session_metadata=metadata)), "hardware_action": "none"})
        return 0
    if action == "raw_capture":
        _emit(start_capture(
            ROOT,
            session_name,
            allow_experimental_profile=allow_experimental,
            session_metadata=metadata,
        ))
        return 0
    velocity = float(input("预览速度假设 m/s / Preview velocity [1.0]: ").strip() or "1.0")
    _emit(run_live_preview(
        ROOT,
        session_name,
        velocity_mps=velocity,
        allow_experimental_profile=allow_experimental,
        session_metadata=metadata,
    ))
    return 0


def experiment_list(args: argparse.Namespace) -> int:
    from radar_stack.experiment import list_experiments
    _emit(list_experiments(ROOT, args.limit))
    return 0


def experiment_inspect(args: argparse.Namespace) -> int:
    from radar_stack.experiment import summarize_experiment
    _emit(summarize_experiment(ROOT, args.session))
    return 0


def experiment_finish(args: argparse.Namespace) -> int:
    from radar_stack.experiment import finish_experiment
    _emit(finish_experiment(ROOT, args.session, timeout_s=args.timeout))
    return 0


def stress_prepare(_: argparse.Namespace) -> int:
    from radar_stack.stress import prepare_rate_profiles
    _emit(prepare_rate_profiles(ROOT))
    return 0


def stress_plan_command(_: argparse.Namespace) -> int:
    from radar_stack.stress import stress_plan
    _emit(stress_plan(ROOT))
    return 0


def stress_run_command(args: argparse.Namespace) -> int:
    from radar_stack.stress import run_stress_ladder, stress_plan
    if not args.execute:
        _emit({**stress_plan(ROOT), "hardware_action": "none; add --execute to run the ladder"})
        return 0
    try:
        result = run_stress_ladder(
            ROOT,
            validation_frames=args.validation_frames,
            soak_seconds=args.soak_seconds,
            maximum_temperature_c=args.maximum_temperature_c,
            profile_names=args.profiles,
        )
        _emit(result)
        return 2 if result.get("stopped_on_fault") else 0
    except Exception as exc:
        _emit({"error": repr(exc), "hardware_action": "stress ladder stopped or did not start"})
        return 2


def menu(_: argparse.Namespace) -> int:
    """One-command Chinese console for routine configuration and capture control."""
    from radar_stack.capture.manager import capture_status, start_capture, stop_capture
    from radar_stack.preview.live import run_live_preview
    from radar_stack.profiles.registry import create_profile, list_profiles, select_profile

    def show_profiles() -> list[dict[str, object]]:
        profiles = list_profiles(ROOT)
        if not profiles:
            print("尚无已保存配置 / No saved profiles")
            return profiles
        print("\n已保存配置 / Saved profiles:")
        for index, item in enumerate(profiles, 1):
            marker = "*" if item.get("active") else " "
            print(f" {marker} [{index}] {item['name']}  {item.get('capture_readiness_zh', '状态未知')}  mode={item.get('capture_mode')}")
            if item.get("validation_blockers"):
                print(f"       原因 / reason: {item['validation_blockers'][0]}")
        return profiles

    def choose_profile(profiles: list[dict[str, object]]) -> str | None:
        raw = input("配置编号（或配置名）/ Profile number (or name): ").strip()
        if raw.isdigit():
            index = int(raw) - 1
            if 0 <= index < len(profiles):
                return str(profiles[index]["name"])
        if any(str(item.get("name")) == raw for item in profiles):
            return raw
        print("无效选择 / Invalid profile selection")
        return None

    def active_profile_ready_for_start() -> bool:
        """Offer the bounded validation exactly when the user asks to capture."""
        from radar_stack.profiles.plan import build_capture_plan
        from radar_stack.profiles.registry import active_profile_path
        from radar_stack.profiles.validation import validate_active_profile, validation_status

        try:
            form_path = active_profile_path(ROOT)
            form = json.loads(form_path.read_text(encoding="utf-8"))
            station = json.loads((ROOT / "config" / "station.yaml").read_text(encoding="utf-8"))
            status = validation_status(ROOT, form, build_capture_plan(form_path, project_root=ROOT), station)
        except Exception as exc:
            print(f"当前配置无法生成采集计划 / Active profile is invalid: {exc}")
            return False
        if status["next_action"] == "ready_for_capture":
            return True
        if status["next_action"] == "fix_unsupported_mixed_geometry":
            print("当前配置不支持固定几何接收器；未执行任何硬件操作 / Unsupported fixed geometry; no hardware action taken.")
            for blocker in status["compatibility"]["blockers"]:
                print(f"  - {blocker}")
            return False
        print("当前配置尚未完成 10 帧真实数据格式验证。")
        print("验证会短暂启动雷达并写入验证证据；不会启动正式采集会话。")
        if input("现在执行 10 帧验证，然后继续本次采集？/ Validate now, then continue? [y/N]: ").strip().lower() != "y":
            print("已取消；未启动正式采集 / Capture was not started.")
            return False
        try:
            result = validate_active_profile(ROOT, frames=10)
            print(f"验证完成 / Validation complete: {result['session']}")
        except Exception as exc:
            print(f"验证未通过；未启动正式采集 / Validation failed: {exc}")
            return False
        return True

    def config_menu() -> None:
        while True:
            print("\n--- 配置管理 / Profile management ---")
            print("[1] 查看配置  [2] 新建配置  [3] 编辑配置  [4] 设为当前配置  [5] 验证当前配置  [b] 返回")
            action = input("请选择 / Select: ").strip().lower()
            if action == "b":
                return
            if action == "1":
                show_profiles()
                continue
            if action == "2":
                templates = sorted((ROOT / "config" / "profiles" / "templates").glob("*fill_form.json"))
                if not templates:
                    print("没有可用模板 / No templates found")
                    continue
                print("可用模板 / Available templates:")
                for index, template in enumerate(templates, 1):
                    print(f" [{index}] {template.name}")
                try:
                    selected = int(input("模板编号 / Template number: ").strip()) - 1
                    template = templates[selected]
                except (ValueError, IndexError):
                    print("无效选择 / Invalid selection")
                    continue
                name = input("新配置名称（英文、数字、-、_）/ New profile name: ").strip()
                try:
                    created = create_profile(ROOT, name, template)
                    select_profile(ROOT, name)
                    print(f"已创建并设为当前配置 / Created and selected: {created}")
                except Exception as exc:
                    print(f"创建失败 / Create failed: {exc}")
                continue
            if action in {"3", "4"}:
                profiles = show_profiles()
                name = choose_profile(profiles)
                if not name:
                    continue
                try:
                    if action == "3":
                        profile_edit(argparse.Namespace(name=name))
                    else:
                        select_profile(ROOT, name)
                        print(f"当前配置已更新 / Active profile: {name}")
                except Exception as exc:
                    print(f"操作失败 / Operation failed: {exc}")
                continue
            if action == "5":
                if input("会执行 10 帧短验证，确认开始？/ Run 10-frame validation? [y/N]: ").strip().lower() != "y":
                    continue
                try:
                    from radar_stack.profiles.validation import validate_active_profile
                    _emit(validate_active_profile(ROOT, frames=10))
                except Exception as exc:
                    _emit({"error": repr(exc)})
                continue
            print("无效选择 / Invalid selection")

    while True:
        print("\n===== NX 雷达采集菜单 / NX Radar Menu =====")
        print("[1] 配置管理  [2] 开始采集  [3] 停止采集  [4] 查看采集状态")
        print("[5] 采集并即时预览  [6] 新建完整实验  [q] 退出")
        choice = input("请选择 / Select: ").strip().lower()
        if choice == "6":
            try: experiment_new(argparse.Namespace())
            except Exception as exc: _emit({"error": repr(exc)})
            continue
        if choice == "5":
            name = input("Session name: ").strip()
            if name and active_profile_ready_for_start():
                try:
                    velocity = float(input("Preview velocity m/s [1.0]: ").strip() or "1.0")
                    _emit(run_live_preview(ROOT, name, velocity_mps=velocity))
                except Exception as exc:
                    _emit({"error": repr(exc)})
            continue
        if choice == "q": return 0
        if choice == "1":
            config_menu()
            continue
        if choice == "2":
            name = input("本次采集名称 / Session name: ").strip()
            if name and active_profile_ready_for_start():
                try: _emit(start_capture(ROOT, name))
                except Exception as exc: _emit({"error": repr(exc)})
            continue
        if choice == "3":
            try: _emit(stop_capture(ROOT))
            except Exception as exc: _emit({"error": repr(exc)})
            continue
        if choice == "4": _emit(capture_status(ROOT)); continue
        print("无效选择 / Invalid selection")


def workflow_guided(_: argparse.Namespace) -> int:
    """Interactive config-selection and session-preparation flow; never starts hardware."""
    from radar_stack.profiles.plan import build_capture_plan
    from radar_stack.profiles.registry import create_profile, list_profiles, prepare_session, profile_path, select_profile

    print("\nNX 雷达采集向导 / NX Radar Capture Wizard")
    print("本向导只选择配置并创建会话目录；不会启动雷达或 DCA 录制。")
    action = input("[1] 选择已有配置  [2] 从填写模板新建配置 : ").strip()
    if action == "2":
        templates = sorted((ROOT / "config" / "profiles" / "templates").glob("*fill_form.json"))
        if not templates:
            raise RuntimeError("no fill-in templates found")
        print("可用填写模板 / Available templates:")
        for index, template in enumerate(templates, 1): print(f"  {index}. {template.name}")
        selected = int(input("选择模板编号 / Template number: ").strip()) - 1
        name = input("新配置名称 / New profile name: ").strip()
        created = create_profile(ROOT, name, templates[selected])
        print(f"已保存配置 / Saved profile: {created}")
    elif action != "1":
        raise RuntimeError("cancelled")

    profiles = list_profiles(ROOT)
    if not profiles:
        raise RuntimeError("no saved profiles; create one first")
    print("\n已保存配置 / Saved profiles:")
    for index, item in enumerate(profiles, 1):
        marker = "*" if item.get("active") else " "
        print(f" {marker} {index}. {item['name']}  mode={item.get('capture_mode')}")
    selected = int(input("选择本次配置编号 / Profile number: ").strip()) - 1
    name = profiles[selected]["name"]
    form = profile_path(ROOT, name)
    plan = build_capture_plan(form, project_root=ROOT)
    derived = plan["derived"]
    print("\n自动计划摘要 / Derived plan:")
    print(f"  模式 / mode: {derived['capture_mode']}")
    print(f"  每 bin chirps / chirps per bin: {derived['physical_segment_pulses']}")
    print(f"  每 bin 字节 / bytes per bin: {derived['physical_segment_full_bytes']}")
    print(f"  计划数据上限 / planned bytes: {derived['total_expected_bytes']}")
    if input("确认选择此配置？/ Select this profile? [y/N]: ").strip().lower() != "y":
        raise RuntimeError("cancelled before profile selection")
    select_profile(ROOT, name)
    session_name = input("本次采集名称 / Session name: ").strip()
    if input("创建会话目录（不启动硬件）？/ Prepare session without hardware? [y/N]: ").strip().lower() != "y":
        raise RuntimeError("profile selected; session preparation cancelled")
    session = prepare_session(ROOT, session_name)
    print(f"\n会话已准备 / Session prepared: {session}")
    print("下一步：接收器完成后，开始采集只需确认这个会话名。")
    return 0


def doctor(_: argparse.Namespace) -> int:
    station_path = ROOT / "config" / "station.yaml"
    station = json.loads(station_path.read_text(encoding="utf-8"))
    network = station["network"]
    paths = station["paths"]
    interface = network["interface"]

    def run(command: list[str]) -> dict:
        result = subprocess.run(command, text=True, capture_output=True, check=False)
        return {"command": command, "returncode": result.returncode, "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}

    ip = run(["ip", "-br", "addr", "show", interface])
    link = run(["ethtool", interface])
    lsusb = run(["lsusb"])
    ports = run(["ss", "-u", "-l", "-n"])
    speed = next((line.strip().split(":", 1)[1].strip() for line in link["stdout"].splitlines() if "Speed:" in line), None)
    from radar_stack.capture.usb import usb_presence
    usb_interfaces = usb_presence(lsusb["stdout"])
    usb_lines = [line for line in lsusb["stdout"].splitlines() if any(usb_id in line.lower() for usb_id in ("0451:bef3", "0403:6010", "0451:fd03"))]
    nodes = sorted(glob.glob("/dev/ttyACM*"))
    path_checks = {key: Path(value).exists() for key, value in paths.items() if key.endswith("_root")}
    extension = next((ROOT / "fpga_udp").glob("fpga_udp*.so"), None)
    ftdi = {"header": Path("/usr/local/include/ftd2xx.h").exists(), "library": Path("/usr/local/lib/libftd2xx.so").exists(), "extension": str(extension) if extension else None}
    warnings: list[str] = []
    if ip["returncode"] != 0 or network["nx_ip"] not in ip["stdout"]:
        warnings.append(f"expected {network['nx_ip']}/{network['prefix_length']} is not active on {interface}")
    if not usb_interfaces['ti_xds110']:
        warnings.append("TI XDS110 control interface is not visible")
    if not usb_interfaces['ftdi_control']:
        warnings.append("FTDI control interface (TI DevPack or FT2232) is not visible")
    if not nodes:
        warnings.append("no /dev/ttyACM* control nodes are present")
    if speed != "1000Mb/s":
        warnings.append(f"link is {speed or 'unknown'}; capture remains blocked until configuration rate fits the link budget")
    if not all(path_checks.values()):
        warnings.append("one or more configured project paths are missing")
    if not all((ftdi["header"], ftdi["library"], ftdi["extension"])):
        warnings.append("FTDI D2XX or fpga_udp extension is incomplete")
    report = {
        "mode": "read-only-no-sudo-no-hardware-control",
        "station_config": str(station_path),
        "station": station,
        "network": {"address": ip, "link": link, "dca_target": f"{network['dca_ip']}:{network['config_port']}", "udp_listener_lines": [line for line in ports["stdout"].splitlines() if ":4096" in line or ":4098" in line]},
        "usb": {"control_device_lines": usb_lines, "interfaces": usb_interfaces, "tty_acm": nodes},
        "paths": path_checks,
        "ftdi": ftdi,
        "disk_free_bytes": shutil.disk_usage(paths["session_root"]).free,
        "summary_status": "ok" if not warnings else "not_ready",
        "warnings": warnings,
        "hardware_action": "none",
    }
    _emit(report)
    return 0 if report["summary_status"] == "ok" else 2


def packet_inspect(args: argparse.Namespace) -> int:
    raw = Path(args.input).read_bytes()
    chunks = (raw[index : index + args.packet_bytes] for index in range(0, len(raw), args.packet_bytes))
    quality = inspect_raw_datagrams(chunks, packet_bytes=args.packet_bytes)
    _emit({"input": str(Path(args.input)), "input_bytes": len(raw), "packet_bytes": args.packet_bytes, "quality": quality.to_dict()})
    return 0


def dca_probe(args: argparse.Namespace) -> int:
    station = json.loads((ROOT / "config" / "station.yaml").read_text(encoding="utf-8"))
    network = station["network"]
    _emit(probe_dca(
        args.ip or network["dca_ip"],
        args.port or network["config_port"],
        args.timeout,
        bind_ip=args.bind_ip or network["nx_ip"],
    ))
    return 0


def dca_reset(args: argparse.Namespace) -> int:
    station = json.loads((ROOT / "config" / "station.yaml").read_text(encoding="utf-8"))
    network = station["network"]
    result = reset_dca_target(
        args.ip or network["dca_ip"],
        args.port or network["config_port"],
        args.target,
        args.timeout,
        bind_ip=args.bind_ip or network["nx_ip"],
    )
    _emit(result)
    return 0 if result["ok"] else 2


def awr_init_check(args: argparse.Namespace) -> int:
    from radar_stack.control.awr2243 import initialization_check

    try:
        result = initialization_check(args.config)
    except Exception as exc:
        _emit({"config": args.config, "sensor_start_sent": False, "error": repr(exc)})
        return 2
    _emit(result)
    return 0 if result.get("init_ok") and result["cleanup"].get("poweroff_ok") else 2


def session_inspect(args: argparse.Namespace) -> int:
    session = Path(args.session)
    names = ("capture_plan.json", "session_manifest.json", "profile_summary.json", "radar/radar_quality_summary.json")
    payload: dict[str, object] = {"session": str(session), "exists": session.is_dir(), "artifacts": {}}
    for name in names:
        path = session / name
        if path.exists():
            try:
                payload["artifacts"][name] = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                payload["artifacts"][name] = {"error": str(exc)}
    _emit(payload)
    return 0 if session.is_dir() else 2


def reconstruct(args: argparse.Namespace) -> int:
    executable = ROOT / "imaging" / "fft_image_NX_live" / "build" / "fft_imaging_cli"
    if not executable.exists():
        print(f"reconstruction unavailable: expected built executable {executable}", file=sys.stderr)
        return 2
    print("reconstruction requires a real raw segment and VFIT input; no command was started.", file=sys.stderr)
    return 2


def capture_not_ready(_: argparse.Namespace) -> int:
    print("capture is intentionally disabled until the bounded C++ receiver and link-budget gate are complete.", file=sys.stderr)
    return 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="radarctl", description="AWR2243 + DCA1000 controlled radar stack")
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("doctor"); command.set_defaults(func=doctor)
    profile = sub.add_parser("profile").add_subparsers(dest="profile_command", required=True)
    for name, validate in (("decode", False), ("static-validate", True)):
        command = profile.add_parser(name); command.add_argument("--config", required=True); command.set_defaults(func=lambda a, v=validate: _legacy_profile(a, v))
    command = profile.add_parser("plan"); command.add_argument("--form", required=True); command.add_argument("--out"); command.set_defaults(func=profile_plan)
    command = profile.add_parser("create"); command.add_argument("--name", required=True); command.add_argument("--source", required=True); command.set_defaults(func=profile_create)
    command = profile.add_parser("set"); command.add_argument("--name", required=True); command.add_argument("--field", required=True); command.add_argument("--value", required=True); command.set_defaults(func=profile_set)
    command = profile.add_parser("list"); command.set_defaults(func=profile_list)
    command = profile.add_parser("show"); command.add_argument("--name", required=True); command.set_defaults(func=profile_show)
    command = profile.add_parser("select"); command.add_argument("--name", required=True); command.set_defaults(func=profile_select)
    command = profile.add_parser("sync"); command.add_argument("--name", required=True); command.set_defaults(func=profile_sync)
    command = profile.add_parser("edit", help="interactive bilingual profile editor; every change auto-syncs")
    command.add_argument("--name", required=True)
    command.set_defaults(func=profile_edit)
    command = profile.add_parser("validation-status", help="show whether selected radar/DCA config has current stream validation")
    command.set_defaults(func=profile_validation_status)
    command = profile.add_parser("validate", help="bounded real 1-20 frame validation of the selected profile")
    command.add_argument("--frames", type=int, default=10)
    command.set_defaults(func=profile_validate)
    packet = sub.add_parser("packet").add_subparsers(dest="packet_command", required=True)
    command = packet.add_parser("inspect"); command.add_argument("--input", required=True); command.add_argument("--packet-bytes", type=int, default=DEFAULT_PACKET_BYTES); command.set_defaults(func=packet_inspect)
    dca = sub.add_parser("dca").add_subparsers(dest="dca_command", required=True)
    command = dca.add_parser("probe"); command.add_argument("--ip"); command.add_argument("--port", type=int); command.add_argument("--bind-ip"); command.add_argument("--timeout", type=float, default=1.0); command.set_defaults(func=dca_probe)
    command = dca.add_parser("reset"); command.add_argument("--target", choices=("fpga", "radar"), required=True); command.add_argument("--ip"); command.add_argument("--port", type=int); command.add_argument("--bind-ip"); command.add_argument("--timeout", type=float, default=2.0); command.set_defaults(func=dca_reset)
    awr = sub.add_parser("awr").add_subparsers(dest="awr_command", required=True)
    command = awr.add_parser("init-check"); command.add_argument("--config", required=True); command.set_defaults(func=awr_init_check)
    capture = sub.add_parser("capture").add_subparsers(dest="capture_command", required=True)
    for name in ("one-shot", "chunked"):
        command = capture.add_parser(name); command.add_argument("--profile", required=True); command.add_argument("--frames", type=int, required=True); command.add_argument("--segment-pulses", type=int, default=128); command.set_defaults(func=capture_not_ready)
    command = capture.add_parser("prepare"); command.add_argument("--name", required=True); command.set_defaults(func=capture_prepare)
    command = capture.add_parser("preflight")
    command.add_argument("--session", required=True, help="prepared session path; this command performs no capture control")
    command.add_argument("--min-udp-receive-buffer-bytes", type=int, default=128 * 1024 * 1024, help="minimum Linux SO_RCVBUF reported value")
    command.add_argument("--requested-udp-receive-buffer-bytes", type=int, default=256 * 1024 * 1024)
    command.add_argument("--timeout", type=float, default=1.0)
    command.set_defaults(func=capture_preflight)
    command = capture.add_parser("discovery", help="bounded real 1-20 frame port/geometry discovery; never formalizes raw data")
    command.add_argument("--session", required=True)
    command.add_argument("--frames", type=int, default=10)
    command.add_argument("--execute", action="store_true", help="required before this command sends DCA/AWR control commands")
    command.set_defaults(func=capture_discovery)
    command = capture.add_parser("discovery-assess", help="read discovery evidence without hardware action")
    command.add_argument("--session", required=True)
    command.set_defaults(func=capture_discovery_assess)
    command = capture.add_parser("discovery-accept", help="lock accepted discovery facts into future station snapshots")
    command.add_argument("--session", required=True)
    command.set_defaults(func=capture_discovery_accept)
    command = capture.add_parser("start", help="start selected manual-stop profile in background")
    command.add_argument("--name", required=True, help="new session name; selected profile is snapshotted automatically")
    command.add_argument("--dry-run", action="store_true", help="prepare and preflight only; do not start the worker")
    command.add_argument("--allow-experimental-profile", action="store_true", help="explicitly allow stress-only or experimental profile")
    command.set_defaults(func=capture_start)
    command = capture.add_parser("stop", help="request aligned stop for the active capture")
    command.add_argument("--session")
    command.set_defaults(func=capture_stop)
    command = capture.add_parser("status", help="show active worker and current receiver quality")
    command.set_defaults(func=capture_status)
    preview = sub.add_parser("preview", help="capture and display-side live preview")
    preview_sub = preview.add_subparsers(dest="preview_command", required=True)
    command = preview_sub.add_parser("run", help="start capture, tail complete bins, and display preview until q/Esc")
    command.add_argument("--name", required=True)
    command.add_argument("--velocity-mps", type=float, default=1.0)
    command.add_argument("--dry-run", action="store_true", help="prepare/preflight and preview contract only")
    command.add_argument("--allow-experimental-profile", action="store_true", help="explicitly allow a stress-only single-TX profile")
    command.set_defaults(func=preview_run)
    experiment = sub.add_parser("experiment", help="human-oriented experiment workflow and history")
    experiment.set_defaults(func=experiment_new)
    experiment_sub = experiment.add_subparsers(dest="experiment_command")
    command = experiment_sub.add_parser("new", help="purpose -> profile -> validation -> session -> action")
    command.set_defaults(func=experiment_new)
    command = experiment_sub.add_parser("list", help="summarize recent experiment sessions")
    command.add_argument("--limit", type=int, default=20)
    command.set_defaults(func=experiment_list)
    command = experiment_sub.add_parser("inspect", help="inspect one experiment by path or session name")
    command.add_argument("--session", required=True)
    command.set_defaults(func=experiment_inspect)
    command = experiment_sub.add_parser("finish", help="request aligned stop if active and write experiment_summary.json")
    command.add_argument("--session", required=True)
    command.add_argument("--timeout", type=float, default=35.0)
    command.set_defaults(func=experiment_finish)
    stress = sub.add_parser("stress", help="prepare, inspect, or run the bounded 30-36 fps ladder").add_subparsers(dest="stress_command", required=True)
    command = stress.add_parser("prepare", help="create managed s30/s32/s34/s35/s36 profiles if absent")
    command.set_defaults(func=stress_prepare)
    command = stress.add_parser("plan", help="show throughput and timing for every stress rung; no hardware action")
    command.set_defaults(func=stress_plan_command)
    command = stress.add_parser("run", help="run validation and optional bounded soak; requires --execute")
    command.add_argument("--execute", action="store_true")
    command.add_argument("--validation-frames", type=int, default=10)
    command.add_argument("--soak-seconds", type=float, default=0.0)
    command.add_argument("--maximum-temperature-c", type=float, default=85.0)
    command.add_argument("--profiles", nargs="+", help="optional subset, for example s35-uniform")
    command.set_defaults(func=stress_run_command)
    command = sub.add_parser("menu", help="interactive Chinese-first routine control")
    command.set_defaults(func=menu)
    workflow = sub.add_parser("workflow")
    workflow_sub = workflow.add_subparsers(dest="workflow_command", required=True)
    command = workflow_sub.add_parser("guided"); command.set_defaults(func=workflow_guided)
    session = sub.add_parser("session").add_subparsers(dest="session_command", required=True)
    command = session.add_parser("inspect"); command.add_argument("--session", required=True); command.set_defaults(func=session_inspect)
    command = sub.add_parser("reconstruct"); command.add_argument("--session", required=True); command.add_argument("--window-pulses", type=int, choices=(256, 500), required=True); command.set_defaults(func=reconstruct)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
