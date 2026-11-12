import unittest
from radar_stack.capture.usb import usb_presence

class UsbPresenceTests(unittest.TestCase):
    def test_one_ti_and_one_ftdi_are_the_expected_pair(self):
        result=usb_presence('Bus 001 ID 0451:bef3 Texas Instruments\nBus 001 ID 0403:6010 Future Technology Devices')
        self.assertTrue(result['ti_xds110'])
        self.assertTrue(result['ftdi_control'])
        self.assertTrue(result['ftdi_ft2232'])
        self.assertFalse(result['ti_devpack_ftdi'])

    def test_ti_devpack_custom_vid_pid_is_supported_by_sdk(self):
        result=usb_presence('0451:bef3 Texas Instruments XDS110\n0451:fd03 AR-DevPack-EVM-012')
        self.assertTrue(result['ti_xds110'])
        self.assertTrue(result['ftdi_control'])
        self.assertTrue(result['ti_devpack_ftdi'])
        self.assertFalse(result['ftdi_ft2232'])

    def test_two_ti_devices_do_not_replace_the_missing_ftdi(self):
        result=usb_presence('Bus 001 ID 0451:bef3 TI\nBus 002 ID 0451:bef3 TI')
        self.assertTrue(result['ti_xds110'])
        self.assertFalse(result['ftdi_ft2232'])
        self.assertFalse(result['ftdi_control'])

    def test_unrelated_usb_devices_do_not_report_ready(self):
        self.assertFalse(any(usb_presence('0bda:0489 Realtek Hub').values()))

if __name__=='__main__':unittest.main()
