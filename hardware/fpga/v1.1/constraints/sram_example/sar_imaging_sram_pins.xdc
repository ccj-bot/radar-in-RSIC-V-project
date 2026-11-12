# Board-level SRAM pinout for the SAR imaging top wrapper.
# This pinout follows the validated sram_pro_2 standalone SRAM demo on the
# new FPGA hardware platform. The full SAR system still generates the SRAM
# clock internally through sram_clk_wiz_0; sys_clk/sys_rst_n/key from the small
# demo are not top-level ports in the PS-based system.

set_property IOSTANDARD LVCMOS33 [get_ports {sram_*}]

set_property PACKAGE_PIN E20 [get_ports sram_WE_n]
set_property PACKAGE_PIN C20 [get_ports sram_CE_n]
set_property PACKAGE_PIN V13 [get_ports sram_OE_n]
set_property PACKAGE_PIN Y13 [get_ports sram_LB_n]
set_property PACKAGE_PIN AA13 [get_ports sram_UB_n]

set_property PACKAGE_PIN D17 [get_ports {sram_addr[0]}]
set_property PACKAGE_PIN D16 [get_ports {sram_addr[1]}]
set_property PACKAGE_PIN B15 [get_ports {sram_addr[2]}]
set_property PACKAGE_PIN C15 [get_ports {sram_addr[3]}]
set_property PACKAGE_PIN D20 [get_ports {sram_addr[4]}]
set_property PACKAGE_PIN E19 [get_ports {sram_addr[5]}]
set_property PACKAGE_PIN G19 [get_ports {sram_addr[6]}]
set_property PACKAGE_PIN F19 [get_ports {sram_addr[7]}]
set_property PACKAGE_PIN C17 [get_ports {sram_addr[8]}]
set_property PACKAGE_PIN C18 [get_ports {sram_addr[9]}]
set_property PACKAGE_PIN AB22 [get_ports {sram_addr[10]}]
set_property PACKAGE_PIN AA22 [get_ports {sram_addr[11]}]
set_property PACKAGE_PIN AB21 [get_ports {sram_addr[12]}]
set_property PACKAGE_PIN AA21 [get_ports {sram_addr[13]}]
set_property PACKAGE_PIN AB19 [get_ports {sram_addr[14]}]
set_property PACKAGE_PIN W13 [get_ports {sram_addr[15]}]
set_property PACKAGE_PIN W18 [get_ports {sram_addr[16]}]
set_property PACKAGE_PIN W17 [get_ports {sram_addr[17]}]
set_property PACKAGE_PIN AB20 [get_ports {sram_addr[18]}]

set_property PACKAGE_PIN A17 [get_ports {sram_data[0]}]
set_property PACKAGE_PIN A16 [get_ports {sram_data[1]}]
set_property PACKAGE_PIN B17 [get_ports {sram_data[2]}]
set_property PACKAGE_PIN B16 [get_ports {sram_data[3]}]
set_property PACKAGE_PIN B22 [get_ports {sram_data[4]}]
set_property PACKAGE_PIN B21 [get_ports {sram_data[5]}]
set_property PACKAGE_PIN D22 [get_ports {sram_data[6]}]
set_property PACKAGE_PIN C22 [get_ports {sram_data[7]}]
set_property PACKAGE_PIN AA19 [get_ports {sram_data[8]}]
set_property PACKAGE_PIN Y19 [get_ports {sram_data[9]}]
set_property PACKAGE_PIN AB16 [get_ports {sram_data[10]}]
set_property PACKAGE_PIN AA16 [get_ports {sram_data[11]}]
set_property PACKAGE_PIN Y18 [get_ports {sram_data[12]}]
set_property PACKAGE_PIN AA18 [get_ports {sram_data[13]}]
set_property PACKAGE_PIN AB14 [get_ports {sram_data[14]}]
set_property PACKAGE_PIN AB15 [get_ports {sram_data[15]}]
set_property PACKAGE_PIN G15 [get_ports {sram_data[16]}]
set_property PACKAGE_PIN G16 [get_ports {sram_data[17]}]
set_property PACKAGE_PIN E16 [get_ports {sram_data[18]}]
set_property PACKAGE_PIN F16 [get_ports {sram_data[19]}]
set_property PACKAGE_PIN D18 [get_ports {sram_data[20]}]
set_property PACKAGE_PIN C19 [get_ports {sram_data[21]}]
set_property PACKAGE_PIN D15 [get_ports {sram_data[22]}]
set_property PACKAGE_PIN E15 [get_ports {sram_data[23]}]
set_property PACKAGE_PIN AA17 [get_ports {sram_data[24]}]
set_property PACKAGE_PIN AB17 [get_ports {sram_data[25]}]
set_property PACKAGE_PIN W16 [get_ports {sram_data[26]}]
set_property PACKAGE_PIN Y16 [get_ports {sram_data[27]}]
set_property PACKAGE_PIN Y14 [get_ports {sram_data[28]}]
set_property PACKAGE_PIN AA14 [get_ports {sram_data[29]}]
set_property PACKAGE_PIN V15 [get_ports {sram_data[30]}]
set_property PACKAGE_PIN V14 [get_ports {sram_data[31]}]

set_property DRIVE 8 [get_ports {sram_*}]
set_property OFFCHIP_TERM NONE [get_ports {sram_*}]
set_property SLEW SLOW [get_ports {sram_*}]

# Smart ZYNQ SL V1.0/V1.1/V1.2 HDMI(DVI) TMDS outputs.
# The local schematic states V1.1 uses the same HDMI pinout as V1.0/V1.2.
set_property PACKAGE_PIN M21 [get_ports {hdmi_d_p[0]}]
set_property PACKAGE_PIN L21 [get_ports {hdmi_d_p[1]}]
set_property PACKAGE_PIN J21 [get_ports {hdmi_d_p[2]}]
set_property PACKAGE_PIN N22 [get_ports hdmi_clk_p]

set_property PACKAGE_PIN M22 [get_ports {hdmi_d_n[0]}]
set_property PACKAGE_PIN L22 [get_ports {hdmi_d_n[1]}]
set_property PACKAGE_PIN J22 [get_ports {hdmi_d_n[2]}]
set_property PACKAGE_PIN P22 [get_ports hdmi_clk_n]

set_property IOSTANDARD TMDS_33 [get_ports {hdmi_d_p[*] hdmi_d_n[*] hdmi_clk_p hdmi_clk_n}]

set sram_clk [get_clocks -quiet clk_out1_system_sram_clk_wiz_0_0]

# Match the sram_pro_2 standalone timing model. Its output-delay equations are
# left disabled; keep the full SAR build aligned until the new board is
# functionally verified.
set sram_data_fast_ports [get_ports {sram_data[0] sram_data[1] sram_data[2] sram_data[3] \
                                     sram_data[4] sram_data[5] sram_data[6] sram_data[7] \
                                     sram_data[8] sram_data[9] sram_data[10] sram_data[11] \
                                     sram_data[16] sram_data[17] sram_data[18] sram_data[19] \
                                     sram_data[20] sram_data[21] sram_data[22] sram_data[23] \
                                     sram_data[24] sram_data[25] sram_data[26] sram_data[27] \
                                     sram_data[28] sram_data[29] sram_data[30] sram_data[31]}]
set sram_data_zero_delay_ports [get_ports {sram_data[12] sram_data[13] sram_data[14] sram_data[15]}]

set board_delay_max 0.385
set board_delay_min 0.275
set T_AA  8.0
set T_OHA 2.5

set_input_delay -clock $sram_clk -max [expr {$T_AA + $board_delay_max}] $sram_data_fast_ports
set_input_delay -clock $sram_clk -min [expr {$T_OHA + $board_delay_min}] $sram_data_fast_ports
set_input_delay -clock $sram_clk -max 0 $sram_data_zero_delay_ports
set_input_delay -clock $sram_clk -min 0 $sram_data_zero_delay_ports

# The HDMI direct-DDR preview has explicit CDC synchronizers and XPM async FIFO
# between the 100 MHz SAR/AXI domain and the HDMI pixel/serializer domains.
set hdmi_pix_clk [get_clocks -quiet clk_out1_system_hdmi_clk_wiz_0_0_1]
set hdmi_ser_clk [get_clocks -quiet clk_out2_system_hdmi_clk_wiz_0_0_1]
set_clock_groups -asynchronous \
    -group $sram_clk \
    -group [get_clocks -quiet {clk_out1_system_hdmi_clk_wiz_0_0_1 clk_out2_system_hdmi_clk_wiz_0_0_1}]
