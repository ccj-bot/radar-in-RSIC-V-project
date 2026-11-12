from __future__ import annotations

import glob
import json
import subprocess
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from radar_capture.core.path_utils import resolve_project_path

@dataclass
class CheckResult:
    name: str
    status: str
    details: dict[str, Any]
    warnings: list[str]

@dataclass
class DoctorReport:
    generated_at: str
    mode: str
    checks: list[CheckResult]
    summary_status: str
    warnings: list[str]
    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

def _run(command: list[str], timeout: float = 3.0) -> dict[str, Any]:
    try:
        cp = subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=False)
        return {"returncode": cp.returncode, "stdout": cp.stdout, "stderr": cp.stderr, "command": command}
    except Exception as exc:
        return {"returncode": None, "stdout": "", "stderr": repr(exc), "command": command}

def _load_station_config() -> dict[str, Any]:
    path = resolve_project_path("radar_station_config.json")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"_error": repr(exc)}

def check_network(config: dict[str, Any]) -> CheckResult:
    interface = str(config.get("radar_interface", "eno1"))
    cidr = str(config.get("radar_interface_cidr", "192.168.33.30/24"))
    dca_ip = str(config.get("dca_adc_ip", "192.168.33.180"))
    ip_result = _run(["ip", "-br", "addr", "show", interface])
    ping_result = _run(["ping", "-c", "1", "-W", "1", dca_ip], timeout=2.0)
    warnings: list[str] = []
    diagnostic_warnings: list[str] = []
    status = "ok"
    stdout = ip_result["stdout"].strip()
    parts = stdout.split()
    if ip_result["returncode"] != 0 or not stdout:
        status = "missing"
        warnings.append(f"interface {interface} not found")
    elif len(parts) > 1 and parts[1] == "DOWN":
        status = "not_ready"
        warnings.append(f"interface {interface} is down")
    if cidr.split("/")[0] not in stdout:
        if status == "ok":
            status = "not_ready"
        warnings.append(f"expected {cidr} not visible on {interface}")
    if ping_result["returncode"] != 0:
        diagnostic_warnings.append(
            f"DCA1000 target {dca_ip} did not respond to ICMP ping; this is diagnostic only and is not used as readiness failure"
        )
    return CheckResult(
        "dca_network",
        status,
        {
            "interface": interface,
            "expected_cidr": cidr,
            "dca_ip": dca_ip,
            "ip_addr": ip_result,
            "ping": ping_result,
            "diagnostic_warnings": diagnostic_warnings,
        },
        warnings,
    )

def check_usb() -> CheckResult:
    result = _run(["lsusb"])
    text = result["stdout"]
    radar_lines = [line for line in text.splitlines() if any(token in line.lower() for token in ["texas", "xds", "0451", "awr", "dca"])]
    camera_lines = [line for line in text.splitlines() if any(token in line.lower() for token in ["camera", "webcam", "09da"])]
    warnings: list[str] = []
    status = "ok" if radar_lines else "not_ready"
    if not radar_lines:
        warnings.append("no TI/XDS/AWR/DCA USB device found in lsusb")
    return CheckResult("usb_devices", status, {"radar_lines": radar_lines, "camera_lines": camera_lines, "lsusb": result}, warnings)

def check_device_nodes() -> CheckResult:
    tty_acm = sorted(glob.glob("/dev/ttyACM*"))
    tty_usb = sorted(glob.glob("/dev/ttyUSB*"))
    video = sorted(glob.glob("/dev/video*"))
    warnings: list[str] = []
    status = "ok"
    if not tty_acm:
        status = "not_ready"
        warnings.append("no /dev/ttyACM* nodes for TI control path")
    if not video:
        warnings.append("no /dev/video* camera nodes")
    return CheckResult("device_nodes", status, {"tty_acm": tty_acm, "tty_usb": tty_usb, "video": video}, warnings)

def check_station_config(config: dict[str, Any]) -> CheckResult:
    warnings: list[str] = []
    for label in ["radar_config", "dca_config"]:
        value = config.get(label)
        if value and not Path(str(value)).exists():
            warnings.append(f"{label} does not exist: {value}")
    fields = {k: config.get(k) for k in ["station_id", "radar_config", "radar_mode", "dca_config", "dca_static_ip", "dca_adc_ip", "radar_interface", "radar_interface_cidr", "skip_network_setup", "camera_enabled", "imu_port", "imu_baud"]}
    return CheckResult("station_config", "ok" if not warnings else "not_ready", fields, warnings)

def run_doctor() -> DoctorReport:
    config = _load_station_config()
    checks = [check_station_config(config), check_network(config), check_usb(), check_device_nodes()]
    warnings = [warning for check in checks for warning in check.warnings]
    summary = "ok" if all(check.status == "ok" for check in checks) else "not_ready"
    return DoctorReport(datetime.now(timezone.utc).isoformat(), "read-only-no-sudo-no-hardware-control", checks, summary, warnings)
