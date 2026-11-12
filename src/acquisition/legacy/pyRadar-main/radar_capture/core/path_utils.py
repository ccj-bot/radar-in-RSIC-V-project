from __future__ import annotations

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def resolve_project_path(path: str | Path) -> Path:
    p = Path(path)
    return p if p.is_absolute() else PROJECT_ROOT / p


def timestamp_slug() -> str:
    from datetime import datetime
    return datetime.now().strftime("%Y%m%d_%H%M%S")
