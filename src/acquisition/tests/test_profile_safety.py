from __future__ import annotations

import unittest

from radar_stack.profiles.sync import SyncError, _integer_value, _positive_finite_float, _synchronize_frame_aligned_bin


class ProfileSafetyTests(unittest.TestCase):
    def form(self, value: object) -> dict:
        return {"fields": {"value": {"value": value}}}

    def test_integer_rejects_boolean_and_fraction(self) -> None:
        with self.assertRaises(SyncError):
            _integer_value(self.form(True), "value")
        with self.assertRaises(SyncError):
            _integer_value(self.form(1.5), "value")

    def test_integer_honours_mask_limits(self) -> None:
        self.assertEqual(_integer_value(self.form("15"), "value", maximum=15), 15)
        with self.assertRaises(SyncError):
            _integer_value(self.form(16), "value", maximum=15)

    def test_packet_delay_must_be_finite_and_positive(self) -> None:
        self.assertEqual(_positive_finite_float(self.form("5"), "value"), 5.0)
        for invalid in (0, -1, "nan", "inf", True):
            with self.subTest(invalid=invalid):
                with self.assertRaises(SyncError):
                    _positive_finite_float(self.form(invalid), "value")

    def test_frame_aligned_bin_is_derived_from_frames(self) -> None:
        fields = {
            "physical_segment_frames": {"value": 2},
            "physical_segment_pulses": {"value": 999},
        }
        self.assertEqual(_synchronize_frame_aligned_bin(fields, chirps_per_frame=120), (2, 240))
        self.assertEqual(fields["physical_segment_pulses"]["value"], 240)

    def test_legacy_cross_frame_bin_is_not_silently_migrated(self) -> None:
        fields = {"physical_segment_pulses": {"value": 500}}
        with self.assertRaises(SyncError):
            _synchronize_frame_aligned_bin(fields, chirps_per_frame=128)


if __name__ == "__main__":
    unittest.main()
