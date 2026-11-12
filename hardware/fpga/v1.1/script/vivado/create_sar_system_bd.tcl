# -----------------------------------------------------------------------------
# create_sar_system_bd.tcl
#
# Creates the SAR system block design inside the current project.
# Assumes:
# - the custom IP repository has already been added and refreshed
# - rtl/system/axis_stream_sink.v has already been added as a source
# -----------------------------------------------------------------------------

proc _sar_require_ip {ip_vlnv} {
    if {[llength [get_ipdefs -all $ip_vlnv]] == 0} {
        error "Required IP not found in catalog: $ip_vlnv"
    }
}

proc _sar_require_module_ref {module_name} {
    if {[can_resolve_reference $module_name] == 0} {
        error "Required module reference not found in project sources: $module_name"
    }
}

proc _sar_configure_ps7_minimal {ps7_cell {fclk_mhz 10}} {
    set_property -dict [list \
        CONFIG.PCW_USE_M_AXI_GP0 {1} \
        CONFIG.PCW_USE_S_AXI_HP0 {1} \
        CONFIG.PCW_USE_S_AXI_HP1 {1} \
        CONFIG.PCW_USE_S_AXI_HP2 {1} \
        CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {32} \
        CONFIG.PCW_S_AXI_HP1_DATA_WIDTH {32} \
        CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {32} \
        CONFIG.PCW_EN_CLK0_PORT {1} \
        CONFIG.PCW_EN_RST0_PORT {1} \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk_mhz \
        CONFIG.PCW_FCLK0_PERIPHERAL_CLKSRC {IO PLL} \
        CONFIG.PCW_USE_FABRIC_INTERRUPT {0} \
    ] $ps7_cell
}

proc _sar_bool {value} {
    set normalized [string tolower [string trim $value]]
    return [expr {$normalized in {1 true yes on}}]
}

proc create_sar_system_bd {design_name {ps_init_tcl ""} {fclk_mhz 10} {common_sram_clock 0} {enable_hdmi_preview 0} {range_ifft_mode 0} {pl_iw_q_scale 26564}} {
    foreach ip_vlnv {
        xilinx.com:ip:axi_dma:7.1
        xilinx.com:ip:clk_wiz:6.0
        xilinx.com:ip:proc_sys_reset:5.0
        xilinx.com:ip:processing_system7:5.5
        xilinx.com:ip:smartconnect:1.0
        user.org:sar:sar_imaging_top:1.1
    } {
        _sar_require_ip $ip_vlnv
    }
    _sar_require_module_ref axis_stream_sink

    if {[get_files -quiet ${design_name}.bd] ne ""} {
        error "Block design ${design_name}.bd already exists in the project"
    }

    create_bd_design $design_name
    current_bd_design $design_name

    set DDR      [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR]
    set FIXED_IO [create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO]

    set processing_system7_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
    _sar_configure_ps7_minimal $processing_system7_0 $fclk_mhz

    set sram_clk_wiz_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 sram_clk_wiz_0]
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ $fclk_mhz \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $fclk_mhz \
        CONFIG.CLKOUT1_REQUESTED_DUTY_CYCLE {20.000} \
    ] $sram_clk_wiz_0

    set hdmi_clk_wiz_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 hdmi_clk_wiz_0]
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ $fclk_mhz \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {65.000} \
        CONFIG.CLKOUT2_USED {true} \
        CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {325.000} \
    ] $hdmi_clk_wiz_0

    if {$ps_init_tcl ne ""} {
        if {![file exists $ps_init_tcl]} {
            error "PS init Tcl not found: $ps_init_tcl"
        }
        set ps7_cell_name processing_system7_0
        set ps7_cell_obj  $processing_system7_0
        source $ps_init_tcl
    }
    set_property -dict [list \
        CONFIG.PCW_USE_S_AXI_HP2 {1} \
        CONFIG.PCW_S_AXI_HP2_DATA_WIDTH {32} \
    ] $processing_system7_0

    set proc_sys_reset_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]
    if {[_sar_bool $common_sram_clock]} {
        set proc_sys_reset_clk_wiz_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_clk_wiz_0]
    }

    set gp0_interconnect [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 gp0_interconnect]
    set_property -dict [list CONFIG.NUM_MI {4} CONFIG.NUM_SI {1}] $gp0_interconnect

    set hp0_interconnect [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 hp0_interconnect]
    set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {2}] $hp0_interconnect

    set hp1_interconnect [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 hp1_interconnect]
    set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {5}] $hp1_interconnect

    set hp2_interconnect [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 hp2_interconnect]
    set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] $hp2_interconnect

    set dma_echo [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma_echo]
    set_property -dict [list \
        CONFIG.c_include_sg {1} \
        CONFIG.c_sg_include_stscntrl_strm {0} \
        CONFIG.c_sg_length_width {26} \
        CONFIG.c_include_mm2s {1} \
        CONFIG.c_include_s2mm {0} \
        CONFIG.c_m_axi_mm2s_data_width {32} \
        CONFIG.c_m_axis_mm2s_tdata_width {32} \
        CONFIG.c_mm2s_burst_size {16} \
    ] $dma_echo

    set dma_desc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma_desc]
    set_property -dict [list \
        CONFIG.c_include_sg {0} \
        CONFIG.c_sg_length_width {26} \
        CONFIG.c_include_mm2s {1} \
        CONFIG.c_include_s2mm {0} \
        CONFIG.c_m_axi_mm2s_data_width {64} \
        CONFIG.c_m_axis_mm2s_tdata_width {64} \
        CONFIG.c_mm2s_burst_size {16} \
    ] $dma_desc

    set dma_image [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma_image]
    set_property -dict [list \
        CONFIG.c_include_sg {1} \
        CONFIG.c_sg_include_stscntrl_strm {0} \
        CONFIG.c_sg_length_width {26} \
        CONFIG.c_include_mm2s {0} \
        CONFIG.c_include_s2mm {1} \
        CONFIG.c_m_axi_s2mm_data_width {32} \
        CONFIG.c_s_axis_s2mm_tdata_width {16} \
        CONFIG.c_s2mm_burst_size {16} \
    ] $dma_image

    set sar_imaging_top_0 [create_bd_cell -type ip -vlnv user.org:sar:sar_imaging_top:1.1 sar_imaging_top_0]
    set_property -dict [list \
        CONFIG.USE_SRAM_STORAGE {1} \
        CONFIG.PL_IW_Q_SCALE_PER_VQ4_Q14 $pl_iw_q_scale \
        CONFIG.USE_EXT_SRAM_TRANSPOSE {0} \
        CONFIG.RANGE_IFFT_MODE $range_ifft_mode \
        CONFIG.ENABLE_HDMI_DDR_PREVIEW [expr {[_sar_bool $enable_hdmi_preview] ? 1 : 0}] \
    ] $sar_imaging_top_0
    if {[_sar_bool $common_sram_clock]} {
        set_property CONFIG.MAG_SRAM_SINGLE_CLOCK_CTRL {1} $sar_imaging_top_0
    }

    set axis_stream_sink_0 [create_bd_cell -type module -reference axis_stream_sink axis_stream_sink_0]
    set_property -dict [list CONFIG.DATA_WIDTH {16} CONFIG.KEEP_WIDTH {2}] $axis_stream_sink_0

    connect_bd_intf_net [get_bd_intf_ports DDR]      [get_bd_intf_pins processing_system7_0/DDR]
    connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins processing_system7_0/FIXED_IO]

    connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins gp0_interconnect/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins gp0_interconnect/M00_AXI] [get_bd_intf_pins sar_imaging_top_0/s_axi]
    connect_bd_intf_net [get_bd_intf_pins gp0_interconnect/M01_AXI] [get_bd_intf_pins dma_echo/S_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins gp0_interconnect/M02_AXI] [get_bd_intf_pins dma_desc/S_AXI_LITE]
    connect_bd_intf_net [get_bd_intf_pins gp0_interconnect/M03_AXI] [get_bd_intf_pins dma_image/S_AXI_LITE]

    connect_bd_intf_net [get_bd_intf_pins sar_imaging_top_0/m_axi_mag]   [get_bd_intf_pins hp0_interconnect/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins sar_imaging_top_0/m_axi_trans] [get_bd_intf_pins hp0_interconnect/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins hp0_interconnect/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP0]

    connect_bd_intf_net [get_bd_intf_pins dma_echo/M_AXI_MM2S]  [get_bd_intf_pins hp1_interconnect/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_desc/M_AXI_MM2S]  [get_bd_intf_pins hp1_interconnect/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_image/M_AXI_S2MM] [get_bd_intf_pins hp1_interconnect/S02_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_echo/M_AXI_SG]    [get_bd_intf_pins hp1_interconnect/S03_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_image/M_AXI_SG]   [get_bd_intf_pins hp1_interconnect/S04_AXI]
    connect_bd_intf_net [get_bd_intf_pins hp1_interconnect/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP1]

    connect_bd_intf_net [get_bd_intf_pins sar_imaging_top_0/m_axi_hdmi] [get_bd_intf_pins hp2_interconnect/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins hp2_interconnect/M00_AXI] [get_bd_intf_pins processing_system7_0/S_AXI_HP2]

    connect_bd_intf_net [get_bd_intf_pins dma_echo/M_AXIS_MM2S] [get_bd_intf_pins sar_imaging_top_0/s_axis_echo]
    connect_bd_intf_net [get_bd_intf_pins dma_desc/M_AXIS_MM2S] [get_bd_intf_pins sar_imaging_top_0/s_axis_index_weight]
    connect_bd_intf_net [get_bd_intf_pins sar_imaging_top_0/m_axis_image] [get_bd_intf_pins dma_image/S_AXIS_S2MM]
    connect_bd_intf_net [get_bd_intf_pins sar_imaging_top_0/m_axis_interp2] [get_bd_intf_pins axis_stream_sink_0/s_axis]

    set sram_WE_n_port [create_bd_port -dir O sram_WE_n]
    set sram_CE_n_port [create_bd_port -dir O sram_CE_n]
    set sram_OE_n_port [create_bd_port -dir O sram_OE_n]
    set sram_LB_n_port [create_bd_port -dir O sram_LB_n]
    set sram_UB_n_port [create_bd_port -dir O sram_UB_n]
    set sram_addr_port [create_bd_port -dir O -from 18 -to 0 sram_addr]
    set sram_data_port [create_bd_port -dir IO -from 31 -to 0 sram_data]

    connect_bd_net [get_bd_ports sram_WE_n] [get_bd_pins sar_imaging_top_0/sram_WE_n]
    connect_bd_net [get_bd_ports sram_CE_n] [get_bd_pins sar_imaging_top_0/sram_CE_n]
    connect_bd_net [get_bd_ports sram_OE_n] [get_bd_pins sar_imaging_top_0/sram_OE_n]
    connect_bd_net [get_bd_ports sram_LB_n] [get_bd_pins sar_imaging_top_0/sram_LB_n]
    connect_bd_net [get_bd_ports sram_UB_n] [get_bd_pins sar_imaging_top_0/sram_UB_n]
    connect_bd_net [get_bd_ports sram_addr] [get_bd_pins sar_imaging_top_0/sram_addr]
    connect_bd_net [get_bd_ports sram_data] [get_bd_pins sar_imaging_top_0/sram_data]

    if {[_sar_bool $enable_hdmi_preview]} {
        set hdmi_d_p_port   [create_bd_port -dir O -from 2 -to 0 hdmi_d_p]
        set hdmi_d_n_port   [create_bd_port -dir O -from 2 -to 0 hdmi_d_n]
        set hdmi_clk_p_port [create_bd_port -dir O hdmi_clk_p]
        set hdmi_clk_n_port [create_bd_port -dir O hdmi_clk_n]

        connect_bd_net [get_bd_ports hdmi_d_p]   [get_bd_pins sar_imaging_top_0/hdmi_d_p]
        connect_bd_net [get_bd_ports hdmi_d_n]   [get_bd_pins sar_imaging_top_0/hdmi_d_n]
        connect_bd_net [get_bd_ports hdmi_clk_p] [get_bd_pins sar_imaging_top_0/hdmi_clk_p]
        connect_bd_net [get_bd_ports hdmi_clk_n] [get_bd_pins sar_imaging_top_0/hdmi_clk_n]
    }

    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins sram_clk_wiz_0/clk_in1]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins hdmi_clk_wiz_0/clk_in1]
    connect_bd_net [get_bd_pins hdmi_clk_wiz_0/clk_out1] [get_bd_pins sar_imaging_top_0/hdmi_pix_clk]
    connect_bd_net [get_bd_pins hdmi_clk_wiz_0/clk_out2] [get_bd_pins sar_imaging_top_0/hdmi_ser_clk]

    if {[_sar_bool $common_sram_clock]} {
        puts "INFO: Using common 20 percent duty clk_wiz output for SAR fabric aclk and sram_clk."
        connect_bd_net [get_bd_pins sram_clk_wiz_0/clk_out1] \
            [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
            [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] \
            [get_bd_pins processing_system7_0/S_AXI_HP1_ACLK] \
            [get_bd_pins processing_system7_0/S_AXI_HP2_ACLK] \
            [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
            [get_bd_pins gp0_interconnect/aclk] \
            [get_bd_pins hp0_interconnect/aclk] \
            [get_bd_pins hp1_interconnect/aclk] \
            [get_bd_pins hp2_interconnect/aclk] \
            [get_bd_pins dma_echo/s_axi_lite_aclk] \
            [get_bd_pins dma_echo/m_axi_mm2s_aclk] \
            [get_bd_pins dma_echo/m_axi_sg_aclk] \
            [get_bd_pins dma_desc/s_axi_lite_aclk] \
            [get_bd_pins dma_desc/m_axi_mm2s_aclk] \
            [get_bd_pins dma_image/s_axi_lite_aclk] \
            [get_bd_pins dma_image/m_axi_s2mm_aclk] \
            [get_bd_pins dma_image/m_axi_sg_aclk] \
            [get_bd_pins sar_imaging_top_0/aclk] \
            [get_bd_pins sar_imaging_top_0/sram_clk] \
            [get_bd_pins axis_stream_sink_0/aclk]
    } else {
        connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
            [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
            [get_bd_pins processing_system7_0/S_AXI_HP0_ACLK] \
            [get_bd_pins processing_system7_0/S_AXI_HP1_ACLK] \
            [get_bd_pins processing_system7_0/S_AXI_HP2_ACLK] \
            [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
            [get_bd_pins gp0_interconnect/aclk] \
            [get_bd_pins hp0_interconnect/aclk] \
            [get_bd_pins hp1_interconnect/aclk] \
            [get_bd_pins hp2_interconnect/aclk] \
            [get_bd_pins dma_echo/s_axi_lite_aclk] \
            [get_bd_pins dma_echo/m_axi_mm2s_aclk] \
            [get_bd_pins dma_echo/m_axi_sg_aclk] \
            [get_bd_pins dma_desc/s_axi_lite_aclk] \
            [get_bd_pins dma_desc/m_axi_mm2s_aclk] \
            [get_bd_pins dma_image/s_axi_lite_aclk] \
            [get_bd_pins dma_image/m_axi_s2mm_aclk] \
            [get_bd_pins dma_image/m_axi_sg_aclk] \
            [get_bd_pins sar_imaging_top_0/aclk] \
            [get_bd_pins axis_stream_sink_0/aclk]

        connect_bd_net [get_bd_pins sram_clk_wiz_0/clk_out1] [get_bd_pins sar_imaging_top_0/sram_clk]
    }
    connect_bd_net [get_bd_pins sram_clk_wiz_0/locked] [get_bd_pins sar_imaging_top_0/sram_clk_locked]

    connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins proc_sys_reset_0/ext_reset_in]
    if {[_sar_bool $common_sram_clock]} {
        connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
            [get_bd_pins proc_sys_reset_clk_wiz_0/slowest_sync_clk]
        connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
            [get_bd_pins proc_sys_reset_clk_wiz_0/ext_reset_in]
        connect_bd_net [get_bd_pins proc_sys_reset_clk_wiz_0/peripheral_reset] \
            [get_bd_pins sram_clk_wiz_0/reset]
        connect_bd_net [get_bd_pins proc_sys_reset_clk_wiz_0/peripheral_reset] \
            [get_bd_pins hdmi_clk_wiz_0/reset]
    } else {
        connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_reset] [get_bd_pins sram_clk_wiz_0/reset]
        connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_reset] [get_bd_pins hdmi_clk_wiz_0/reset]
    }

    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
        [get_bd_pins gp0_interconnect/aresetn] \
        [get_bd_pins hp0_interconnect/aresetn] \
        [get_bd_pins hp1_interconnect/aresetn] \
        [get_bd_pins hp2_interconnect/aresetn] \
        [get_bd_pins dma_echo/axi_resetn] \
        [get_bd_pins dma_desc/axi_resetn] \
        [get_bd_pins dma_image/axi_resetn] \
        [get_bd_pins sar_imaging_top_0/aresetn] \
        [get_bd_pins axis_stream_sink_0/aresetn]

    assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces sar_imaging_top_0/m_axi_mag] \
        [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] -force
    assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces sar_imaging_top_0/m_axi_trans] \
        [get_bd_addr_segs processing_system7_0/S_AXI_HP0/HP0_DDR_LOWOCM] -force

    assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces dma_echo/Data_MM2S] \
        [get_bd_addr_segs processing_system7_0/S_AXI_HP1/HP1_DDR_LOWOCM] -force
    assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces dma_desc/Data_MM2S] \
        [get_bd_addr_segs processing_system7_0/S_AXI_HP1/HP1_DDR_LOWOCM] -force
    assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces dma_image/Data_S2MM] \
        [get_bd_addr_segs processing_system7_0/S_AXI_HP1/HP1_DDR_LOWOCM] -force
    assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces dma_echo/Data_SG] \
        [get_bd_addr_segs processing_system7_0/S_AXI_HP1/HP1_DDR_LOWOCM] -force
    assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces dma_image/Data_SG] \
        [get_bd_addr_segs processing_system7_0/S_AXI_HP1/HP1_DDR_LOWOCM] -force
    assign_bd_address -offset 0x00000000 -range 0x20000000 -target_address_space [get_bd_addr_spaces sar_imaging_top_0/m_axi_hdmi] \
        [get_bd_addr_segs processing_system7_0/S_AXI_HP2/HP2_DDR_LOWOCM] -force

    assign_bd_address -offset 0x43C00000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
        [get_bd_addr_segs sar_imaging_top_0/s_axi/reg0] -force
    assign_bd_address -offset 0x40400000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
        [get_bd_addr_segs dma_echo/S_AXI_LITE/Reg] -force
    assign_bd_address -offset 0x40410000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
        [get_bd_addr_segs dma_desc/S_AXI_LITE/Reg] -force
    assign_bd_address -offset 0x40420000 -range 0x00010000 -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
        [get_bd_addr_segs dma_image/S_AXI_LITE/Reg] -force

    regenerate_bd_layout
    save_bd_design
}
