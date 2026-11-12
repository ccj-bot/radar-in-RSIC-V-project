from __future__ import annotations

import json
from pathlib import Path
from types import ModuleType, SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
import sys

from radar_stack.capture.evidence import evidence_delta
from radar_stack.profiles.sync import sync_profile
from radar_stack.profiles.timing import derive_radar_timing, dca_theoretical_throughput_mbps


MMWAVE_TEMPLATE = """#rlChanCfg_t
channelTx=7;
channelRx=15;
#END
#rlAdcOutCfg_t
adcFormat=1;
#END
#rlDevDataPathClkCfg_t
dataRate=1;
#END
#rlDevLaneEnable_t
laneEn=15;
#END
#rlProfileCfg_t
profileId=0;
startFreqConst=1416742684;
idleTimeConst=4000;
adcStartTimeConst=100;
rampEndTime=6000;
freqSlopeConst=1657;
numAdcSamples=1024;
digOutSampleRate=22500;
#END
#rlChirpCfg_t
chirpStartIdx=0;
chirpEndIdx=0;
profileIdCPCFG=0;
txEnable=1;
#END
#rlChirpCfg_t
chirpStartIdx=1;
chirpEndIdx=1;
profileIdCPCFG=0;
txEnable=2;
#END
#rlChirpCfg_t
chirpStartIdx=2;
chirpEndIdx=2;
profileIdCPCFG=0;
txEnable=4;
#END
#rlFrameCfg_t
chirpStartIdxFCF=0;
chirpEndIdxFCF=0;
frameCount=1;
loopCount=128;
periodicity=6666667;
numAdcSamples=1024;
#END
"""


def form(*, target_fps: float | None = None) -> dict:
    fields = {
        "profile_name": {"value": "test"},
        "radar_config_template": {"value": "template.cfg"},
        "dca_config_template": {"value": "template.json"},
        "radar_config": {"value": "generated/mmwave.cfg"},
        "dca_config": {"value": "generated/dca.json"},
        "radar_profile0_adc_samples": {"value": 1024},
        "radar_frame_loop_count": {"value": 128},
        "radar_frame_periodicity_ticks": {"value": 6666667},
        "radar_channel_rx_mask": {"value": 15},
        "radar_channel_tx_mask": {"value": 7},
        "radar_lvds_lane_mask": {"value": 15},
        "radar_lvds_data_rate_code": {"value": 1},
        "dca_packet_delay_us": {"value": 5},
        "radar_chirp_tx_sequence": {"value": [0]},
        "physical_segment_frames": {"value": 1},
        "physical_segment_pulses": {"value": 128},
    }
    if target_fps is not None:
        fields.update({
            "radar_target_frame_rate_hz": {"value": target_fps},
            "radar_target_frame_blank_time_ms": {"value": 0.5},
            "radar_profile0_ramp_end_time_ticks": {"value": 6000},
            "radar_profile0_idle_time_ticks": {"value": 4000},
        })
    return {"fields": fields}


class TimingSyncEvidenceTests(unittest.TestCase):
    def _root(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        (root / "config/profiles/saved").mkdir(parents=True)
        (root / "template.cfg").write_text(MMWAVE_TEMPLATE, encoding="utf-8")
        (root / "template.json").write_text(json.dumps({"DCA1000Config": {"packetDelay_us": 5}}), encoding="utf-8")
        return temporary, root

    def test_target_frame_rate_derives_ti_ticks_and_blank(self) -> None:
        temporary, root = self._root()
        with temporary:
            (root / "config/profiles/saved/test.json").write_text(json.dumps(form(target_fps=35)), encoding="utf-8")
            manifest = sync_profile(root, "test")
            timing = manifest["physical_timing"]
            self.assertAlmostEqual(timing["frame_rate_hz"], 35.0, places=4)
            self.assertGreaterEqual(timing["frame_blank_time_ms"], 0.3)
            self.assertAlmostEqual(timing["frame_blank_time_ms"], 0.5, places=2)
            saved = json.loads((root / "config/profiles/saved/test.json").read_text(encoding="utf-8"))
            self.assertEqual(saved["fields"]["physical_segment_pulses"]["value"], 128)
            self.assertNotEqual(saved["fields"]["radar_profile0_idle_time_ticks"]["value"], 4000)
            generated = Path(manifest["generated_radar_config"]).read_text(encoding="utf-8")
            self.assertIn("numAdcSamples=2048;", generated)

    def test_legacy_form_without_idle_or_ramp_fields_remains_compatible(self) -> None:
        temporary, root = self._root()
        with temporary:
            (root / "config/profiles/saved/test.json").write_text(json.dumps(form()), encoding="utf-8")
            manifest = sync_profile(root, "test")
            timing = derive_radar_timing(manifest["generated_radar_config"])
            self.assertAlmostEqual(timing["frame_rate_hz"], 30.0, places=4)
            self.assertEqual(timing["idle_time_us"], 40.0)

    def test_36_fps_is_below_90_percent_but_38_is_not(self) -> None:
        capacity = dca_theoretical_throughput_mbps(5)
        frame_bytes = 2 * 1024 * 1024
        utilization_36 = frame_bytes * 36 * 8 / 1e6 / capacity
        utilization_38 = frame_bytes * 38 * 8 / 1e6 / capacity
        self.assertLess(utilization_36, 0.90)
        self.assertGreaterEqual(utilization_38, 0.90)

    def test_evidence_delta_flags_missed_and_udp_buffer_errors(self) -> None:
        before = {
            "timestamp": "a", "interface": "eth0",
            "nic_sysfs": {"rx_packets": 10, "rx_missed_errors": 2},
            "nic_driver": {"rx_missed": 3},
            "udp_snmp": {"InDatagrams": 4, "RcvbufErrors": 0},
            "thermal_c": {"cpu": 40.0},
        }
        after = {
            "timestamp": "b", "interface": "eth0",
            "nic_sysfs": {"rx_packets": 20, "rx_missed_errors": 3},
            "nic_driver": {"rx_missed": 5},
            "udp_snmp": {"InDatagrams": 14, "RcvbufErrors": 1},
            "thermal_c": {"cpu": 55.0},
        }
        delta = evidence_delta(before, after)
        self.assertFalse(delta["transport_clean"])
        self.assertEqual(delta["nic_sysfs"]["rx_missed_errors"], 1)
        self.assertEqual(delta["udp_snmp"]["RcvbufErrors"], 1)
        self.assertEqual(delta["max_temperature_after_c"], 55.0)

    def test_capture_plan_accepts_36_but_blocks_38_fps(self) -> None:
        from radar_stack.profiles.plan import FormError, build_capture_plan

        temporary, root = self._root()
        with temporary:
            (root / "sessions").mkdir()
            package = ModuleType("radar_capture")
            profiles = ModuleType("radar_capture.profiles")
            parser = ModuleType("radar_capture.profiles.mmwave_parser")

            def parse(path: Path) -> SimpleNamespace:
                timing = derive_radar_timing(path)
                frame_bytes = timing["chirps_per_frame"] * 16384
                return SimpleNamespace(
                    chirps_per_frame=timing["chirps_per_frame"],
                    frame_bytes=frame_bytes,
                    frame_periodicity_ms=timing["frame_period_ms"],
                    estimated_raw_rate_MBps=frame_bytes / (timing["frame_period_ms"] / 1000.0) / 1e6,
                    effective_tx_sequence=[0], tx_count_effective=1, adc_samples=1024,
                    rx_count=4, warnings=[], frame_rate_hz=timing["frame_rate_hz"],
                )

            parser.parse_mmwave_config = parse
            parser.summary_to_dict = lambda value: dict(value.__dict__)
            modules = {
                "radar_capture": package,
                "radar_capture.profiles": profiles,
                "radar_capture.profiles.mmwave_parser": parser,
            }
            with patch.dict(sys.modules, modules):
                for fps, should_pass in ((36.0, True), (38.0, False)):
                    current = form(target_fps=fps)
                    current["fields"].update({
                        "capture_mode": {"value": "manual_stop_with_data_cap"},
                        "frames": {"value": None},
                        "stop_after_gib": {"value": 1},
                        "reserve_disk_gib": {"value": 0},
                        "reconstruction_windows": {"value": [128]},
                        "profile_usage": {"value": "stress_only"},
                    })
                    saved = root / "config/profiles/saved/test.json"
                    saved.write_text(json.dumps(current), encoding="utf-8")
                    sync_profile(root, "test")
                    if should_pass:
                        plan = build_capture_plan(saved, project_root=root)
                        self.assertLess(plan["derived"]["transport_budget"]["dca_utilization"], 0.90)
                    else:
                        with self.assertRaises(FormError):
                            build_capture_plan(saved, project_root=root)


if __name__ == "__main__":
    unittest.main()
