"""Host/network evidence captured around every bounded or formal radar stream."""
from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
from typing import Any


_NIC_COUNTERS = (
    "rx_bytes", "rx_packets", "rx_errors", "rx_dropped", "rx_fifo_errors",
    "rx_frame_errors", "rx_length_errors", "rx_missed_errors", "rx_nohandler",
    "tx_bytes", "tx_packets", "tx_errors", "tx_dropped", "tx_fifo_errors",
)
_FAULT_NAME_MARKERS = (
    "drop", "error", "miss", "fifo", "no_buffer", "discard", "overflow",
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _read_int(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def _command(command: list[str], timeout: float = 3.0) -> dict[str, Any]:
    try:
        result = subprocess.run(command, text=True, capture_output=True, check=False, timeout=timeout)
        return {
            "command": command,
            "returncode": result.returncode,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
        }
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"command": command, "returncode": None, "error": repr(exc)}


def _ethtool_stats(interface: str) -> dict[str, int]:
    result = _command(["ethtool", "-S", interface])
    stats: dict[str, int] = {}
    if result.get("returncode") != 0:
        return stats
    for line in str(result.get("stdout", "")).splitlines():
        if ":" not in line:
            continue
        key, raw = line.split(":", 1)
        try:
            stats[key.strip()] = int(raw.strip())
        except ValueError:
            continue
    return stats


def _snmp_protocol(protocol: str) -> dict[str, int]:
    try:
        lines = Path("/proc/net/snmp").read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    prefix = protocol + ":"
    for index in range(len(lines) - 1):
        if lines[index].startswith(prefix) and lines[index + 1].startswith(prefix):
            names = lines[index].split()[1:]
            values = lines[index + 1].split()[1:]
            parsed: dict[str, int] = {}
            for name, raw in zip(names, values):
                try:
                    parsed[name] = int(raw)
                except ValueError:
                    pass
            return parsed
    return {}


def _thermal_snapshot() -> dict[str, float]:
    result: dict[str, float] = {}
    for zone in sorted(Path("/sys/class/thermal").glob("thermal_zone*")):
        try:
            name = (zone / "type").read_text(encoding="utf-8").strip()
            raw = float((zone / "temp").read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            continue
        result[name or zone.name] = raw / 1000.0 if abs(raw) >= 1000.0 else raw
    return result


def snapshot_host(interface: str) -> dict[str, Any]:
    sysfs_root = Path("/sys/class/net") / interface / "statistics"
    sysfs = {name: _read_int(sysfs_root / name) for name in _NIC_COUNTERS}
    sysfs = {key: value for key, value in sysfs.items() if value is not None}
    return {
        "schema": "nx-radar-host-evidence/v1",
        "timestamp": _now(),
        "interface": interface,
        "nic_sysfs": sysfs,
        "nic_driver": _ethtool_stats(interface),
        "udp_snmp": _snmp_protocol("Udp"),
        "thermal_c": _thermal_snapshot(),
        "link": _command(["ethtool", interface]),
    }


def _counter_delta(before: dict[str, Any], after: dict[str, Any]) -> dict[str, int]:
    result: dict[str, int] = {}
    for key in sorted(set(before) | set(after)):
        left, right = before.get(key), after.get(key)
        if isinstance(left, int) and isinstance(right, int):
            result[key] = right - left if right >= left else 0
    return result


def evidence_delta(before: dict[str, Any], after: dict[str, Any]) -> dict[str, Any]:
    sysfs = _counter_delta(before.get("nic_sysfs", {}), after.get("nic_sysfs", {}))
    driver = _counter_delta(before.get("nic_driver", {}), after.get("nic_driver", {}))
    udp = _counter_delta(before.get("udp_snmp", {}), after.get("udp_snmp", {}))
    faults: list[dict[str, Any]] = []
    for source, counters in (("nic_sysfs", sysfs), ("nic_driver", driver)):
        for name, value in counters.items():
            lower = name.lower()
            if value > 0 and any(marker in lower for marker in _FAULT_NAME_MARKERS):
                faults.append({"source": source, "counter": name, "delta": value})
    for name in ("InErrors", "RcvbufErrors", "SndbufErrors"):
        if udp.get(name, 0) > 0:
            faults.append({"source": "udp_snmp", "counter": name, "delta": udp[name]})
    temperatures = list(after.get("thermal_c", {}).values())
    return {
        "schema": "nx-radar-host-evidence-delta/v1",
        "before_timestamp": before.get("timestamp"),
        "after_timestamp": after.get("timestamp"),
        "interface": after.get("interface") or before.get("interface"),
        "nic_sysfs": sysfs,
        "nic_driver": driver,
        "udp_snmp": udp,
        "thermal_before_c": before.get("thermal_c", {}),
        "thermal_after_c": after.get("thermal_c", {}),
        "max_temperature_after_c": max(temperatures) if temperatures else None,
        "transport_faults": faults,
        "transport_clean": not faults,
    }


def write_evidence(path: Path, payload: dict[str, Any]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)
    return path
