# -----------------------------------------------------------------------------
# ps7_smart_zynq_sl_ref.tcl
#
# PS7 settings for Hello FPGA Smart ZYNQ SL.
# The board page lists XC7Z020-CLG484 and DDR "256M x 16bit (512MB)"; the
# vendor datasheet bundle contains MT41K256M16TW-107.pdf. Start from the
# existing onboard PS profile for MIO/peripheral defaults, then override the
# DDR device width/capacity fields that differ on Smart ZYNQ SL.
#
# The caller must define:
# - ps7_cell_obj : processing_system7 BD cell object
# - fclk_mhz     : requested FCLK0 frequency in MHz
# -----------------------------------------------------------------------------

set _smart_zynq_sl_dir [file dirname [info script]]
source [file join $_smart_zynq_sl_dir ps7_2dfft_onboard_ref.tcl]

set_property -dict [list \
    CONFIG.PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {16 Bit} \
    CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
    CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {4096 MBits} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 TW-107} \
    CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE {1} \
] $ps7_cell_obj
