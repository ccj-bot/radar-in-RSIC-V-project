from __future__ import annotations

import argparse

from radar_capture.core.json_utils import write_json
from radar_capture.core.path_utils import resolve_project_path
from radar_capture.profiles.mmwave_generator import generate_profile
from radar_capture.profiles.mmwave_parser import parse_mmwave_config, summary_to_dict
from radar_capture.profiles.mmwave_validator import validate_summary
from radar_capture.profiles.profile_schema import load_profile_yaml
from radar_capture.profiles.config_matrix import build_matrix, write_matrix_reports
from radar_capture.profiles.session_correlation import build_session_correlation, write_session_correlation_reports
from radar_capture.doctor.read_only import run_doctor


def _print_summary(payload: dict) -> None:
    for key in [
        "effective_tx_sequence",
        "effective_rx_channels",
        "adc_samples",
        "chirps_per_frame",
        "frame_bytes",
        "estimated_raw_rate_MBps",
        "risk_level",
        "warnings",
    ]:
        print(f"{key}: {payload.get(key)}")


def profile_decode(args: argparse.Namespace) -> int:
    summary = parse_mmwave_config(resolve_project_path(args.config))
    payload = summary_to_dict(summary)
    _print_summary(payload)
    if args.out:
        write_json(resolve_project_path(args.out), payload)
        print(f"wrote {args.out}")
    return 0


def profile_validate(args: argparse.Namespace) -> int:
    summary = parse_mmwave_config(resolve_project_path(args.config))
    result = validate_summary(summary)
    payload = result.to_dict()
    print(f"passed: {payload['passed']}")
    print(f"risk_level: {payload['risk_level']}")
    print(f"errors: {payload['errors']}")
    print(f"warnings: {payload['warnings']}")
    print(f"manual_review_required: {payload['manual_review_required']}")
    if args.out:
        write_json(resolve_project_path(args.out), payload)
        print(f"wrote {args.out}")
    return 0 if result.passed else 2


def profile_generate(args: argparse.Namespace) -> int:
    profile = load_profile_yaml(resolve_project_path(args.profile))
    artifacts = generate_profile(profile, args.out_dir)
    print(f"generated_config: {artifacts.generated_config}")
    print(f"summary_json: {artifacts.summary_json}")
    print(f"diff_txt: {artifacts.diff_txt}")
    print(f"validation_json: {artifacts.validation_json}")
    if artifacts.warnings:
        print(f"warnings: {artifacts.warnings}")
    return 0


def profile_list_examples(args: argparse.Namespace) -> int:
    profile_dir = resolve_project_path(args.dir)
    for path in sorted(profile_dir.glob("*")):
        if path.suffix.lower() in (".yaml", ".yml", ".json"):
            print(path.relative_to(resolve_project_path(".")))
    return 0



def doctor(args: argparse.Namespace) -> int:
    report = run_doctor()
    payload = report.to_dict()
    print(f"summary_status: {payload['summary_status']}")
    for warning in payload.get("warnings", []):
        print(f"warning: {warning}")
    if args.out:
        write_json(resolve_project_path(args.out), payload)
        print(f"wrote {args.out}")
    return 0 if payload["summary_status"] == "ok" else 2


def profile_matrix(args: argparse.Namespace) -> int:
    matrix = build_matrix(args.config_root)
    write_matrix_reports(matrix, args.json_out, args.md_out)
    print(f"decoded configs: {matrix['count']}")
    print(f"json_out: {args.json_out}")
    print(f"md_out: {args.md_out}")
    for row in matrix.get("rows", []):
        print(f"{row.get('name')}: {row.get('parse_status')} risk={row.get('risk_level')} warnings={len(row.get('warnings', [])) if row.get('warnings') else 0}")
    return 0


def profile_correlate_sessions(args: argparse.Namespace) -> int:
    report = build_session_correlation(args.session_root, args.limit)
    write_session_correlation_reports(report, args.json_out, args.md_out)
    print(f"correlated configs: {report['config_count']}")
    print(f"json_out: {args.json_out}")
    print(f"md_out: {args.md_out}")
    for row in report.get("rows", []):
        print(f"{row.get('config_name')}: sessions={row.get('session_count')} mismatches={len(row.get('mismatches', []))}")
    return 0

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="radarctl", description="Offline radar capture profile tools")
    sub = parser.add_subparsers(dest="command")
    doctor_parser = sub.add_parser("doctor")
    doctor_parser.add_argument("--out")
    doctor_parser.set_defaults(func=doctor)

    profile = sub.add_parser("profile")
    profile_sub = profile.add_subparsers(dest="profile_command")
    decode = profile_sub.add_parser("decode")
    decode.add_argument("--config", required=True)
    decode.add_argument("--out")
    decode.set_defaults(func=profile_decode)
    validate = profile_sub.add_parser("validate")
    validate.add_argument("--config", required=True)
    validate.add_argument("--out")
    validate.set_defaults(func=profile_validate)
    generate = profile_sub.add_parser("generate")
    generate.add_argument("--profile", required=True)
    generate.add_argument("--out-dir", default="configFiles/generated")
    generate.set_defaults(func=profile_generate)
    list_examples = profile_sub.add_parser("list-examples")
    list_examples.add_argument("--dir", default="radar_capture/configs/profiles")
    list_examples.set_defaults(func=profile_list_examples)

    matrix = profile_sub.add_parser("matrix")
    matrix.add_argument("--config-root", default="configFiles")
    matrix.add_argument("--json-out", default="docs/mmwave_config_decode_matrix_latest.json")
    matrix.add_argument("--md-out", default="docs/mmwave_config_decode_matrix_latest.md")
    matrix.set_defaults(func=profile_matrix)

    correlate = profile_sub.add_parser("correlate-sessions")
    correlate.add_argument("--session-root", default="/home/radar/capture_sessions")
    correlate.add_argument("--limit", type=int, default=None)
    correlate.add_argument("--json-out", default="docs/session_config_correlation_latest.json")
    correlate.add_argument("--md-out", default="docs/session_config_correlation_latest.md")
    correlate.set_defaults(func=profile_correlate_sessions)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not hasattr(args, "func"):
        parser.print_help()
        return 2
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
