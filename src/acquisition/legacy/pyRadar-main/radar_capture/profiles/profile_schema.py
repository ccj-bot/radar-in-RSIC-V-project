from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from radar_capture.core.errors import ProfileParseError


@dataclass
class ConceptRadarProfile:
    profile_name: str
    template_config: str
    device: str = "AWR2243"
    rx_channels: list[int] | None = None
    tx_sequence: list[int] | None = None
    adc_samples: int = 0
    chirps_per_frame: int = 0
    frame_rate_hz: float = 0.0
    segment_pulses: int = 0
    adc_bits: int = 16
    iq_components: int = 2
    dca_packet_delay_us: int = 5
    notes: str | None = None

    def __post_init__(self) -> None:
        self.rx_channels = list(self.rx_channels or [])
        self.tx_sequence = list(self.tx_sequence or [])
        self.validate()

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ConceptRadarProfile":
        return cls(
            profile_name=str(data.get("profile_name", "")).strip(),
            template_config=str(data.get("template_config", "")).strip(),
            device=str(data.get("device", "AWR2243")).strip() or "AWR2243",
            rx_channels=list(data.get("rx_channels") or []),
            tx_sequence=list(data.get("tx_sequence") or []),
            adc_samples=int(data.get("adc_samples", 0)),
            chirps_per_frame=int(data.get("chirps_per_frame", 0)),
            frame_rate_hz=float(data.get("frame_rate_hz", 0.0)),
            segment_pulses=int(data.get("segment_pulses", 0)),
            adc_bits=int(data.get("adc_bits", 16)),
            iq_components=int(data.get("iq_components", 2)),
            dca_packet_delay_us=int(data.get("dca_packet_delay_us", 5)),
            notes=data.get("notes"),
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def validate(self) -> None:
        errors: list[str] = []
        if not self.profile_name:
            errors.append("profile_name is required")
        if not self.template_config:
            errors.append("template_config is required")
        if any(ch not in (0, 1, 2, 3) for ch in self.rx_channels):
            errors.append("rx_channels may only contain 0..3")
        if any(ch not in (0, 1, 2) for ch in self.tx_sequence):
            errors.append("tx_sequence may only contain 0..2")
        if self.adc_samples <= 0:
            errors.append("adc_samples must be > 0")
        if self.chirps_per_frame <= 0:
            errors.append("chirps_per_frame must be > 0")
        if self.frame_rate_hz <= 0:
            errors.append("frame_rate_hz must be > 0")
        if self.segment_pulses <= 0:
            errors.append("segment_pulses must be > 0")
        if self.adc_bits <= 0:
            errors.append("adc_bits must be > 0")
        if self.iq_components <= 0:
            errors.append("iq_components must be > 0")
        if errors:
            raise ProfileParseError("; ".join(errors))


def _load_yaml_or_json_text(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".json":
        return json.loads(text)
    try:
        import yaml  # type: ignore
    except ImportError as exc:
        raise ProfileParseError("PyYAML is required for YAML profiles; use JSON fallback or install PyYAML outside this tool.") from exc
    loaded = yaml.safe_load(text)
    if not isinstance(loaded, dict):
        raise ProfileParseError("profile file must contain a mapping/object")
    return loaded


def load_profile_yaml(path: str | Path) -> ConceptRadarProfile:
    return ConceptRadarProfile.from_dict(_load_yaml_or_json_text(Path(path)))
