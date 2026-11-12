from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from radar_capture.core.path_utils import PROJECT_ROOT
from radar_capture.profiles.mmwave_parser import parse_mmwave_config


MINIMAL_TEMPLATE = """
channelTx=7;
channelRx=15;
#rlProfileCfg_t
profileId=0;
numAdcSamples=2048;
#END
#rlChirpCfg_t
chirpStartIdx=0;
chirpEndIdx=0;
profileIdCPCFG=0;
txEnable=1;
#END
#rlFrameCfg_t
chirpStartIdxFCF=0;
chirpEndIdxFCF=0;
loopCount=128;
{period_line}
numAdcSamples=2048;
#END
"""


class MmwaveParserPeriodicityTest(unittest.TestCase):
    def _parse_minimal(self, period_line: str):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "minimal_mmwave.txt"
            path.write_text(MINIMAL_TEMPLATE.format(period_line=period_line), encoding="utf-8")
            return parse_mmwave_config(path)

    def test_legacy_periodicity_is_preferred_over_subframe(self) -> None:
        summary = self._parse_minimal("periodicity=6666667;\nsubFramePeriodicity=5000000;")
        self.assertAlmostEqual(summary.frame_periodicity_ms or 0, 33.333335, places=6)
        self.assertTrue(any("5 ns ticks" in warning for warning in summary.warnings))

    def test_subframe_periodicity_is_fallback(self) -> None:
        summary = self._parse_minimal("subFramePeriodicity=5000000;")
        self.assertAlmostEqual(summary.frame_periodicity_ms or 0, 5.0, places=6)
        self.assertTrue(any("subFramePeriodicity" in warning for warning in summary.warnings))

    def test_explicit_frame_periodicity_wins(self) -> None:
        summary = self._parse_minimal("framePeriodicity=33.333;")
        self.assertAlmostEqual(summary.frame_periodicity_ms or 0, 33.0, places=6)


    def test_selected_profile_adc_samples_wins_over_frame_field(self) -> None:
        summary = self._parse_minimal("periodicity=4000000;")
        self.assertEqual(summary.adc_samples, 2048)
        self.assertEqual(summary.adc_samples_source, "profileId=0")

    def test_frame_adc_samples_mismatch_is_reported(self) -> None:
        template = MINIMAL_TEMPLATE.replace("numAdcSamples=2048;", "numAdcSamples=1024;", 1)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "frame_mismatch_mmwave.txt"
            path.write_text(template.format(period_line="periodicity=4000000;"), encoding="utf-8")
            summary = parse_mmwave_config(path)
        self.assertEqual(summary.adc_samples, 1024)
        self.assertEqual(summary.adc_samples_source, "profileId=0")
        self.assertTrue(any("frame numAdcSamples=2048 differs" in warning for warning in summary.warnings))

    def test_stable_config_matches_golden_key_fields(self) -> None:
        summary = parse_mmwave_config(PROJECT_ROOT / "configFiles/mmwaveconfig_0508_30f128_safe.txt")
        golden = json.loads((PROJECT_ROOT / "radar_capture/tests/fixtures/profile_decode_30f128_safe_golden.json").read_text())
        self.assertEqual(summary.effective_tx_sequence, golden["effective_tx_sequence"])
        self.assertEqual(summary.effective_rx_channels, golden["effective_rx_channels"])
        self.assertEqual(summary.adc_samples, golden["adc_samples"])
        self.assertEqual(summary.chirps_per_frame, golden["chirps_per_frame"])
        self.assertEqual(summary.frame_bytes, golden["frame_bytes"])
        self.assertEqual(summary.risk_level, golden["risk_level"])
        self.assertAlmostEqual(summary.frame_periodicity_ms or 0, golden["frame_periodicity_ms"], places=6)
        self.assertAlmostEqual(summary.frame_rate_hz or 0, golden["frame_rate_hz"], places=6)
        self.assertAlmostEqual(summary.estimated_raw_rate_MBps or 0, golden["estimated_raw_rate_MBps"], places=6)
        for needle in golden["required_warning_substrings"]:
            self.assertTrue(any(needle in warning for warning in summary.warnings), summary.warnings)


if __name__ == "__main__":
    unittest.main()
