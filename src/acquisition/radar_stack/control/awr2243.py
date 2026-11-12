from __future__ import annotations

from pathlib import Path
from typing import Any


def _ok(value: Any) -> bool:
    return value in (None, 0, True)


def initialization_check(config: str | Path) -> dict[str, Any]:
    """Configure AWR2243 from an existing config, never start it, then power it off."""
    config_path = Path(config).resolve()
    if not config_path.is_file():
        raise FileNotFoundError(config_path)
    import fpga_udp

    result: dict[str, Any] = {
        "config": str(config_path),
        "sensor_start_sent": False,
        "cleanup": {"poweroff_attempted": False},
    }
    try:
        init_result = fpga_udp.AWR2243_init(str(config_path))
        result["init_return"] = init_result
        result["init_ok"] = _ok(init_result)
        result["sensor_started_after_init"] = bool(fpga_udp.AWR2243_isSensorStarted())
        if result["sensor_started_after_init"]:
            result["warning"] = "sensor reports started after init; no start command was sent"
        return result
    except Exception as exc:
        result["error"] = repr(exc)
        result["init_ok"] = False
        return result
    finally:
        result["cleanup"]["poweroff_attempted"] = True
        try:
            poweroff_result = fpga_udp.AWR2243_poweroff()
            result["cleanup"]["poweroff_return"] = poweroff_result
            result["cleanup"]["poweroff_ok"] = _ok(poweroff_result)
        except Exception as exc:  # cleanup failures must remain visible to the caller
            result["cleanup"]["poweroff_error"] = repr(exc)
