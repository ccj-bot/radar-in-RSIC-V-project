from __future__ import annotations

import difflib
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass
class DiffReport:
    diff_text: str
    changed_lines: list[str]

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


def build_diff(template_path: str | Path, generated_path: str | Path) -> DiffReport:
    t = Path(template_path)
    g = Path(generated_path)
    template_lines = t.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    generated_lines = g.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    diff = list(difflib.unified_diff(template_lines, generated_lines, fromfile=str(t), tofile=str(g)))
    changed = [line.rstrip("\n") for line in diff if line.startswith(("+", "-")) and not line.startswith(("+++", "---"))]
    return DiffReport(diff_text="".join(diff), changed_lines=changed)
