from __future__ import annotations

import json
import time
import unittest
from pathlib import Path

from radar_capture.core.path_utils import PROJECT_ROOT
from radar_capture.profiles.mmwave_generator import generate_profile
from radar_capture.profiles.mmwave_parser import parse_mmwave_config
from radar_capture.profiles.mmwave_validator import validate_summary
from radar_capture.profiles.profile_schema import ConceptRadarProfile, load_profile_yaml


class OfflineProfileToolsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.template = PROJECT_ROOT / "configFiles/mmwaveconfig_0508_30f128_safe.txt"
        self.assertTrue(self.template.exists(), self.template)

    def test_decode_stable_config_effective_channels(self) -> None:
        summary = parse_mmwave_config(self.template)
        self.assertEqual(summary.effective_tx_sequence, [0])
        self.assertEqual(summary.effective_rx_channels, [0, 1, 2, 3])
        self.assertEqual(summary.adc_samples, 1024)
        self.assertEqual(summary.chirps_per_frame, 128)
        self.assertEqual(summary.frame_bytes, 2097152)
        self.assertIsNotNone(summary.estimated_raw_rate_MBps)
        self.assertIn(summary.risk_level, {"safe", "warning", "unsafe", "unknown"})

    def test_validate_stable_config_is_parseable(self) -> None:
        summary = parse_mmwave_config(self.template)
        validation = validate_summary(summary)
        self.assertTrue(validation.passed)
        self.assertEqual(validation.errors, [])

    def test_json_profile_fallback_loader(self) -> None:
        out_dir = PROJECT_ROOT / "configFiles/generated/regression_inputs"
        out_dir.mkdir(parents=True, exist_ok=True)
        path = out_dir / f"profile_json_fallback_{int(time.time())}.json"
        payload = {
            "profile_name": "json_fallback_test",
            "template_config": "configFiles/mmwaveconfig_0508_30f128_safe.txt",
            "device": "AWR2243",
            "rx_channels": [0, 1, 2, 3],
            "tx_sequence": [0],
            "adc_samples": 2048,
            "chirps_per_frame": 128,
            "frame_rate_hz": 30,
            "segment_pulses": 128,
            "dca_packet_delay_us": 5,
        }
        path.write_text(json.dumps(payload), encoding="utf-8")
        profile = load_profile_yaml(path)
        self.assertEqual(profile.profile_name, "json_fallback_test")
        self.assertEqual(profile.rx_channels, [0, 1, 2, 3])

    def test_generate_preserves_line_boundaries(self) -> None:
        profile = ConceptRadarProfile(
            profile_name=f"regression_line_boundaries_{int(time.time())}",
            template_config="configFiles/mmwaveconfig_0508_30f128_safe.txt",
            rx_channels=[0, 1, 2, 3],
            tx_sequence=[0],
            adc_samples=2048,
            chirps_per_frame=128,
            frame_rate_hz=30,
            segment_pulses=128,
            dca_packet_delay_us=5,
        )
        artifacts = generate_profile(profile, PROJECT_ROOT / "configFiles/generated/regression_checks")
        text = artifacts.generated_config.read_text(encoding="utf-8")
        self.assertNotIn("channelRx=15;cascading=0", text)
        self.assertNotIn("txEnable=1;#END", text)
        self.assertNotIn("numAdcSamplesAF=2048numChirpsInDataPacket", text)
        validation = json.loads(artifacts.validation_json.read_text(encoding="utf-8"))
        self.assertTrue(validation["passed"], validation)


if __name__ == "__main__":
    unittest.main()
