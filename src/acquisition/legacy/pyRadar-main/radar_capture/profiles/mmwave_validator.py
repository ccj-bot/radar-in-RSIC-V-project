from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any

from radar_capture.profiles.mmwave_parser import MmwaveConfigSummary
from radar_capture.profiles.profile_schema import ConceptRadarProfile
from radar_capture.profiles.throughput import classify_raw_rate


@dataclass
class ValidationResult:
    passed: bool
    risk_level: str
    errors: list[str]
    warnings: list[str]
    manual_review_required: bool

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def validate_summary(summary: MmwaveConfigSummary, profile: ConceptRadarProfile | None = None) -> ValidationResult:
    errors: list[str] = []
    warnings: list[str] = list(summary.warnings)
    manual = False

    if not summary.effective_rx_channels:
        errors.append("effective_rx_channels is empty")
    if not summary.effective_tx_sequence:
        errors.append("effective_tx_sequence is empty")
    if not summary.adc_samples:
        errors.append("adc_samples could not be parsed")
    if not summary.chirps_per_frame:
        errors.append("chirps_per_frame could not be parsed")
    if not summary.frame_bytes:
        errors.append("frame_bytes could not be computed")
    if summary.estimated_raw_rate_MBps is None:
        warnings.append("raw rate could not be estimated")
        manual = True

    risk = classify_raw_rate(summary.estimated_raw_rate_MBps)
    if risk == "unsafe":
        warnings.append("raw throughput is above conservative long-run DCA1000 threshold")

    if profile is not None:
        if summary.effective_rx_channels != profile.rx_channels:
            errors.append(f"rx mismatch: config={summary.effective_rx_channels}, profile={profile.rx_channels}")
        if summary.effective_tx_sequence != profile.tx_sequence:
            if sorted(set(summary.effective_tx_sequence)) != sorted(set(profile.tx_sequence)):
                errors.append(f"tx mismatch: config={summary.effective_tx_sequence}, profile={profile.tx_sequence}")
            else:
                warnings.append("tx sequence order/repetition differs but selected TX set matches")
                manual = True
        if summary.adc_samples != profile.adc_samples:
            errors.append(f"adc_samples mismatch: config={summary.adc_samples}, profile={profile.adc_samples}")
        if summary.chirps_per_frame != profile.chirps_per_frame:
            errors.append(f"chirps_per_frame mismatch: config={summary.chirps_per_frame}, profile={profile.chirps_per_frame}")
        if profile.segment_pulses <= 0:
            errors.append("segment_pulses must be positive")

    return ValidationResult(
        passed=not errors,
        risk_level=risk,
        errors=errors,
        warnings=warnings,
        manual_review_required=manual,
    )
