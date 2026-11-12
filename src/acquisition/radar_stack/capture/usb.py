"""Presence checks for the installed AWR2243/DCA1000 control interfaces."""
def usb_presence(lsusb_output):
    output = lsusb_output.lower()
    dual = '0403:6010' in output
    devpack = '0451:fd03' in output
    return {'ti_xds110': '0451:bef3' in output, 'ftdi_ft2232': dual,
            'ti_devpack_ftdi': devpack, 'ftdi_control': dual or devpack}
