//-----------------------------------------------------------------------------
// SAR Imaging Top Module
//
// Description:
//   Top-level module for SAR (Synthetic Aperture Radar) imaging system.
//   Integrates 2D FFT + Mag Writer + Bilinear Interpolation + Post-processing.
//   Processing: Echo -> 2D_FFT -> Scale -> MagWriter -> interp2 -> postproc -> result
//
//   Interface groups:
//     S_AXI               x1  - control/status registers (config, V readback, FSM state)
//     S_AXIS_ECHO         x1  - input echo stream
//     M_AXIS_IMAGE        x1  - final image output stream
//     S_AXIS_INDEX_WEIGHT x1  - velocity header + pixel geometry metadata (v1.1)
//     M_AXI_MAG_DDR       x1  - mag write/read (mag_writer write, interp2 read)
//     M_AXI_TRANSPOSE_DDR x1  - transpose intermediate frame read/write
//
//   Top-level ports follow Xilinx AXI/AXIS naming so Vivado can infer bus
//   interfaces without manual signal-by-signal remapping.
//
//   Author: Auto-generated. Date: 2026-01-14 (Interface refactor for DDR)
//   Refactored: 2026-03-10 (Port cleanup per PL/PS frame control design)
//   Refactored: 2026-03-12 (Xilinx-convention top-level port naming)
//-----------------------------------------------------------------------------

module sar_imaging_top #(
    parameter DATA_WIDTH = 16,
    parameter NR         = 1024,
    parameter NA         = 512,
    parameter integer PL_IW_Q_SCALE_PER_VQ4_Q14 = 26564,
    parameter RANGE_IFFT_MODE = 0,
    parameter MAG_SCALE_LEFT_SHIFT = 4,
    parameter MAG_RAM_ADDR_WIDTH = 19,   // 2^19 = 512K >= 512*1024
    // Default Zynq-7020 DDR map:
    //   MAG bank 0 : 0x0C00_0000 .. 0x0C1F_FFFF (2 MB)
    //   MAG bank 1 : 0x0C20_0000 .. 0x0C3F_FFFF (2 MB)
    //   TRANSPOSE  : 0x0C40_0000 .. 0x0C5F_FFFF (2 MB)
    parameter [31:0] MAG_DDR_BASE_ADDR       = 32'h0C00_0000,
    parameter [31:0] MAG_DDR_BANK_STRIDE     = 32'h0020_0000,
    parameter [31:0] TRANSPOSE_DDR_BASE_ADDR = 32'h0C40_0000,
    parameter USE_SRAM_STORAGE               = 1,
    parameter USE_EXT_SRAM_TRANSPOSE         = 0,
    parameter MAG_SRAM_SINGLE_CLOCK_CTRL     = 0,
    parameter ENABLE_HDMI_DDR_PREVIEW        = 1,
    // AXI parameters
    parameter AXI_ADDR_WIDTH  = 32,
    parameter AXI_DATA_WIDTH  = 32,
    parameter AXI_STRB_WIDTH  = AXI_DATA_WIDTH / 8,
    parameter AXI_ID_WIDTH    = 4,
    // AXI-Lite parameters
    parameter AXIL_ADDR_WIDTH = 16,
    parameter AXIL_DATA_WIDTH = 32,
    parameter AXIL_STRB_WIDTH = AXIL_DATA_WIDTH / 8
) (
    input wire                      aclk,
    input wire                      sram_clk,
    input wire                      sram_clk_locked,
    input wire                      hdmi_pix_clk,
    input wire                      hdmi_ser_clk,
    input wire                      aresetn,

    // =========================================================================
    // Frame-level PS/PL handshake (directly exposed, accent on frame-level control)
    // =========================================================================
    output wire                     processing_done,  // Full-frame image output complete (legacy compat)
    output wire                     frame_idle,       // Frame FSM idle, ready for next frame
    output wire [3:0]               frame_state,      // Frame FSM state encoding
    output wire                     irq_frame_done,   // Pulse: one frame fully complete

    // =========================================================================
    // S_AXI: Control Register Interface
    // =========================================================================
    input  wire [AXIL_ADDR_WIDTH-1:0]  s_axi_awaddr,
    input  wire [2:0]                  s_axi_awprot,
    input  wire                        s_axi_awvalid,
    output wire                        s_axi_awready,
    input  wire [AXIL_DATA_WIDTH-1:0]  s_axi_wdata,
    input  wire [AXIL_STRB_WIDTH-1:0]  s_axi_wstrb,
    input  wire                        s_axi_wvalid,
    output wire                        s_axi_wready,
    output wire [1:0]                  s_axi_bresp,
    output wire                        s_axi_bvalid,
    input  wire                        s_axi_bready,
    input  wire [AXIL_ADDR_WIDTH-1:0]  s_axi_araddr,
    input  wire [2:0]                  s_axi_arprot,
    input  wire                        s_axi_arvalid,
    output wire                        s_axi_arready,
    output wire [AXIL_DATA_WIDTH-1:0]  s_axi_rdata,
    output wire [1:0]                  s_axi_rresp,
    output wire                        s_axi_rvalid,
    input  wire                        s_axi_rready,

    // =========================================================================
    // S_AXIS_ECHO: Input Echo Stream (tdata = {real[31:16], imag[15:0]})
    // =========================================================================
    input  wire [DATA_WIDTH*2-1:0]  s_axis_echo_tdata,
    input  wire                     s_axis_echo_tvalid,
    output wire                     s_axis_echo_tready,
    input  wire                     s_axis_echo_tlast,
    input  wire [DATA_WIDTH*2/8-1:0] s_axis_echo_tkeep,

    // =========================================================================
    // S_AXIS_INDEX_WEIGHT: Interp2 AXI-Stream Slave (descriptor from PS)
    // =========================================================================
    input  wire [63:0]              s_axis_index_weight_tdata,
    input  wire                     s_axis_index_weight_tvalid,
    output wire                     s_axis_index_weight_tready,
    input  wire                     s_axis_index_weight_tlast,
    input  wire [7:0]               s_axis_index_weight_tkeep,
    input  wire                     s_axis_index_weight_tuser,

    // =========================================================================
    // Interp2 AXI-Stream Master (result output) - kept for debug tap
    // =========================================================================
    output wire [15:0]              m_axis_interp2_tdata,
    output wire                     m_axis_interp2_tvalid,
    input  wire                     m_axis_interp2_tready,
    output wire                     m_axis_interp2_tlast,
    output wire [1:0]               m_axis_interp2_tkeep,

    // =========================================================================
    // M_AXIS_IMAGE: Post-processing AXI-Stream Master (final image output)
    // =========================================================================
    output wire [15:0]              m_axis_image_tdata,
    output wire                     m_axis_image_tvalid,
    input  wire                     m_axis_image_tready,
    output wire                     m_axis_image_tlast,
    output wire [1:0]               m_axis_image_tkeep,

    // =========================================================================
    // HDMI preview: DDR-backed grayscale display
    // =========================================================================
    output wire [2:0]               hdmi_d_p,
    output wire [2:0]               hdmi_d_n,
    output wire                     hdmi_clk_p,
    output wire                     hdmi_clk_n,

    // =========================================================================
    // M_AXI_MAG_DDR: Mag write/read AXI4 Master (mag_writer write, interp2 read)
    // =========================================================================
    // Write address channel
    output wire [AXI_ID_WIDTH-1:0]    m_axi_mag_awid,
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_mag_awaddr,
    output wire [7:0]                 m_axi_mag_awlen,
    output wire [2:0]                 m_axi_mag_awsize,
    output wire [1:0]                 m_axi_mag_awburst,
    output wire                       m_axi_mag_awlock,
    output wire [3:0]                 m_axi_mag_awcache,
    output wire [2:0]                 m_axi_mag_awprot,
    output wire                       m_axi_mag_awvalid,
    input  wire                       m_axi_mag_awready,
    // Write data channel
    output wire [AXI_DATA_WIDTH-1:0]  m_axi_mag_wdata,
    output wire [AXI_STRB_WIDTH-1:0]  m_axi_mag_wstrb,
    output wire                       m_axi_mag_wlast,
    output wire                       m_axi_mag_wvalid,
    input  wire                       m_axi_mag_wready,
    // Write response channel
    input  wire [AXI_ID_WIDTH-1:0]    m_axi_mag_bid,
    input  wire [1:0]                 m_axi_mag_bresp,
    input  wire                       m_axi_mag_bvalid,
    output wire                       m_axi_mag_bready,
    // Read address channel
    output wire [AXI_ID_WIDTH-1:0]    m_axi_mag_arid,
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_mag_araddr,
    output wire [7:0]                 m_axi_mag_arlen,
    output wire [2:0]                 m_axi_mag_arsize,
    output wire [1:0]                 m_axi_mag_arburst,
    output wire                       m_axi_mag_arlock,
    output wire [3:0]                 m_axi_mag_arcache,
    output wire [2:0]                 m_axi_mag_arprot,
    output wire                       m_axi_mag_arvalid,
    input  wire                       m_axi_mag_arready,
    // Read data channel
    input  wire [AXI_ID_WIDTH-1:0]    m_axi_mag_rid,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_mag_rdata,
    input  wire [1:0]                 m_axi_mag_rresp,
    input  wire                       m_axi_mag_rlast,
    input  wire                       m_axi_mag_rvalid,
    output wire                       m_axi_mag_rready,

    // =========================================================================
    // M_AXI_TRANSPOSE_DDR: Transpose intermediate frame AXI4 Master
    // =========================================================================
    // Write address channel
    output wire [AXI_ID_WIDTH-1:0]    m_axi_trans_awid,
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_trans_awaddr,
    output wire [7:0]                 m_axi_trans_awlen,
    output wire [2:0]                 m_axi_trans_awsize,
    output wire [1:0]                 m_axi_trans_awburst,
    output wire                       m_axi_trans_awlock,
    output wire [3:0]                 m_axi_trans_awcache,
    output wire [2:0]                 m_axi_trans_awprot,
    output wire                       m_axi_trans_awvalid,
    input  wire                       m_axi_trans_awready,
    // Write data channel
    output wire [AXI_DATA_WIDTH-1:0]  m_axi_trans_wdata,
    output wire [AXI_STRB_WIDTH-1:0]  m_axi_trans_wstrb,
    output wire                       m_axi_trans_wlast,
    output wire                       m_axi_trans_wvalid,
    input  wire                       m_axi_trans_wready,
    // Write response channel
    input  wire [AXI_ID_WIDTH-1:0]    m_axi_trans_bid,
    input  wire [1:0]                 m_axi_trans_bresp,
    input  wire                       m_axi_trans_bvalid,
    output wire                       m_axi_trans_bready,
    // Read address channel
    output wire [AXI_ID_WIDTH-1:0]    m_axi_trans_arid,
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_trans_araddr,
    output wire [7:0]                 m_axi_trans_arlen,
    output wire [2:0]                 m_axi_trans_arsize,
    output wire [1:0]                 m_axi_trans_arburst,
    output wire                       m_axi_trans_arlock,
    output wire [3:0]                 m_axi_trans_arcache,
    output wire [2:0]                 m_axi_trans_arprot,
    output wire                       m_axi_trans_arvalid,
    input  wire                       m_axi_trans_arready,
    // Read data channel
    input  wire [AXI_ID_WIDTH-1:0]    m_axi_trans_rid,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_trans_rdata,
    input  wire [1:0]                 m_axi_trans_rresp,
    input  wire                       m_axi_trans_rlast,
    input  wire                       m_axi_trans_rvalid,
    output wire                       m_axi_trans_rready,

    // =========================================================================
    // M_AXI_HDMI_DDR: HDMI framebuffer read AXI4 Master
    // =========================================================================
    output wire [AXI_ID_WIDTH-1:0]    m_axi_hdmi_awid,
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_hdmi_awaddr,
    output wire [7:0]                 m_axi_hdmi_awlen,
    output wire [2:0]                 m_axi_hdmi_awsize,
    output wire [1:0]                 m_axi_hdmi_awburst,
    output wire                       m_axi_hdmi_awlock,
    output wire [3:0]                 m_axi_hdmi_awcache,
    output wire [2:0]                 m_axi_hdmi_awprot,
    output wire                       m_axi_hdmi_awvalid,
    input  wire                       m_axi_hdmi_awready,
    output wire [AXI_DATA_WIDTH-1:0]  m_axi_hdmi_wdata,
    output wire [AXI_STRB_WIDTH-1:0]  m_axi_hdmi_wstrb,
    output wire                       m_axi_hdmi_wlast,
    output wire                       m_axi_hdmi_wvalid,
    input  wire                       m_axi_hdmi_wready,
    input  wire [AXI_ID_WIDTH-1:0]    m_axi_hdmi_bid,
    input  wire [1:0]                 m_axi_hdmi_bresp,
    input  wire                       m_axi_hdmi_bvalid,
    output wire                       m_axi_hdmi_bready,
    output wire [AXI_ID_WIDTH-1:0]    m_axi_hdmi_arid,
    output wire [AXI_ADDR_WIDTH-1:0]  m_axi_hdmi_araddr,
    output wire [7:0]                 m_axi_hdmi_arlen,
    output wire [2:0]                 m_axi_hdmi_arsize,
    output wire [1:0]                 m_axi_hdmi_arburst,
    output wire                       m_axi_hdmi_arlock,
    output wire [3:0]                 m_axi_hdmi_arcache,
    output wire [2:0]                 m_axi_hdmi_arprot,
    output wire                       m_axi_hdmi_arvalid,
    input  wire                       m_axi_hdmi_arready,
    input  wire [AXI_ID_WIDTH-1:0]    m_axi_hdmi_rid,
    input  wire [AXI_DATA_WIDTH-1:0]  m_axi_hdmi_rdata,
    input  wire [1:0]                 m_axi_hdmi_rresp,
    input  wire                       m_axi_hdmi_rlast,
    input  wire                       m_axi_hdmi_rvalid,
    output wire                       m_axi_hdmi_rready,

    // =========================================================================
    // External SRAM: hybrid board bring-up path for transpose storage
    // =========================================================================
    output wire                       sram_WE_n,
    output wire                       sram_CE_n,
    output wire                       sram_CE_2,
    output wire                       sram_OE_n,
    output wire                       sram_LB_n,
    output wire                       sram_UB_n,
    output wire [18:0]                sram_addr,
    inout  wire [31:0]                sram_data
);

wire clk = aclk;
wire rst_n = aresetn;
reg [2:0] sram_lock_clk_sync;
reg [2:0] sram_lock_sram_sync;
wire mag_sram_clk_rst_n = sram_lock_clk_sync[2];
wire mag_sram_rst_n = sram_lock_sram_sync[2];
localparam TOTAL_OUTPUT = NR * NA;
localparam USE_MAG_EXT_SRAM = USE_SRAM_STORAGE && !USE_EXT_SRAM_TRANSPOSE;

always @(posedge clk) begin
    if (!aresetn || !sram_clk_locked)
        sram_lock_clk_sync <= 3'b000;
    else
        sram_lock_clk_sync <= {sram_lock_clk_sync[1:0], 1'b1};
end

always @(posedge sram_clk) begin
    if (!aresetn || !sram_clk_locked)
        sram_lock_sram_sync <= 3'b000;
    else
        sram_lock_sram_sync <= {sram_lock_sram_sync[1:0], 1'b1};
end

//-----------------------------------------------------------------------------
// Internal: mode/config placeholders (will be driven by AXI-Lite reg file)
//-----------------------------------------------------------------------------
wire cfg_transpose_store = 1'b1;  // fixed, not runtime-configurable

// Postproc image size: driven by AXI-Lite register file (reg 0x0C)
wire [15:0] post_cfg_ny;
wire [15:0] post_cfg_nx;

// Postproc ROI size: still exposed through AXI-Lite for PS/reporting, but the
// current gamma-only postproc no longer consumes these fields.
wire [15:0] post_cfg_nrm;
wire [15:0] post_cfg_nam;
wire [15:0] hdmi_cfg_display_w;
wire [15:0] hdmi_cfg_display_h;
wire [15:0] hdmi_cfg_stretch_knee;
wire [15:0] hdmi_cfg_stretch_gain_q8;
localparam integer PERF_REG_COUNT = 64;

// Postproc frame-geometry shadow registers.
//
// Software programs these values during bring-up and keeps them fixed while the
// datapath runs. Even with "write once" software behavior, STA still sees the
// AXI-Lite register outputs as live timing sources. If we feed those live
// register outputs directly into the per-sample postproc logic, the control path
// becomes part of the image datapath.
//
// To keep the datapath timing local and predictable, the top level copies the
// software-visible registers into dedicated postproc shadow registers whenever
// the frame pipeline is idle. The postproc block then runs from these local
// shadow registers only; AXI-Lite never drives the data-path boundary logic
// directly.
reg [15:0] post_cfg_ny_shadow;
reg [15:0] post_cfg_nx_shadow;

// Magnitude writer activity/debug �?internal only
wire       o_mw_active;

//-----------------------------------------------------------------------------
// PS control signals �?driven by AXI-Lite register file
//-----------------------------------------------------------------------------
wire        i_ps_init_done;   // from REG_PS_CTRL[0]
wire        i_ps_im_done;     // from REG_PS_CTRL[1]
wire        debug_image_loopback_enable; // from REG_DEBUG_CTRL[0]
wire [AXIL_DATA_WIDTH-1:0] hdmi_ctrl; // from REG_DEBUG_CTRL high bits
wire [31:0] hdmi_debug_status;
wire        reg_v_valid;      // single-cycle pulse from REG_V_WRITE
wire [8:0]  reg_v_data;       // data from REG_V_WRITE

//-----------------------------------------------------------------------------
// V request / frame-context control
//
// Two in-flight frame contexts are sufficient for the current MAG ping-pong
// design. V enters PL first, becomes a frame request token, is exposed to PS
// for runtime descriptor generation, then gets bound to a MAG bank when the
// corresponding echo frame starts.
//-----------------------------------------------------------------------------
reg [AXI_ADDR_WIDTH-1:0]    mw_mag_base_addr_reg;
reg [AXI_ADDR_WIDTH-1:0]    interp2_mag_base_addr_reg;
reg                         interp2_start_internal;
reg                         ps_desc_commit_d;
reg                         mag_write_complete_d;
reg [7:0]                   next_v_req_id_reg;
localparam integer MAG_READY_DELAY_CYCLES = 256;
localparam integer MAG_READY_DELAY_W = (MAG_READY_DELAY_CYCLES <= 1) ? 1 : $clog2(MAG_READY_DELAY_CYCLES + 1);

reg                         slot0_valid;
reg [7:0]                   slot0_req_id;
reg [8:0]                   slot0_v_data;
reg                         slot0_desc_ready;
reg                         slot0_started;
reg                         slot0_mag_ready;
reg                         slot0_bank_valid;
reg                         slot0_bank_select;
reg                         slot0_interp2_launched;

reg                         slot1_valid;
reg [7:0]                   slot1_req_id;
reg [8:0]                   slot1_v_data;
reg                         slot1_desc_ready;
reg                         slot1_started;
reg                         slot1_mag_ready;
reg                         slot1_bank_valid;
reg                         slot1_bank_select;
reg                         slot1_interp2_launched;

reg                         mw_active_slot_valid;
reg                         mw_active_slot_is_slot1;
reg                         interp2_active_slot_valid;
reg                         mag_ready_pending_reg;
reg                         mag_ready_pending_slot1_reg;
reg [MAG_READY_DELAY_W-1:0] mag_ready_delay_reg;

wire [AXI_ADDR_WIDTH-1:0] mag_bank0_base_addr = MAG_DDR_BASE_ADDR;
wire [AXI_ADDR_WIDTH-1:0] mag_bank1_base_addr = MAG_DDR_BASE_ADDR + MAG_DDR_BANK_STRIDE;

wire [1:0] v_queue_depth = {1'b0, slot0_valid} + {1'b0, slot1_valid};
wire       v_push_ready_internal = !(slot0_valid && slot1_valid);
wire       ps_req_slot0 = slot0_valid && !slot0_desc_ready;
wire       ps_req_slot1 = !ps_req_slot0 && slot1_valid && !slot1_desc_ready;
wire       v_ps_pending_valid = ps_req_slot0 || ps_req_slot1;
wire [7:0] v_ps_pending_req_id = ps_req_slot0 ? slot0_req_id : slot1_req_id;
wire [8:0] v_ps_pending_data = ps_req_slot0 ? slot0_v_data : slot1_v_data;

wire bank0_reserved = (slot0_valid && slot0_bank_valid && !slot0_bank_select) ||
                      (slot1_valid && slot1_bank_valid && !slot1_bank_select);
wire bank1_reserved = (slot0_valid && slot0_bank_valid && slot0_bank_select) ||
                      (slot1_valid && slot1_bank_valid && slot1_bank_select);
wire mw_bank_available = !bank0_reserved || !bank1_reserved;
wire mw_next_bank_select = !bank0_reserved ? 1'b0 : 1'b1;
wire [AXI_ADDR_WIDTH-1:0] mw_next_bank_base_addr =
    mw_next_bank_select ? mag_bank1_base_addr : mag_bank0_base_addr;

wire mw_imird_ready_internal;
wire mag_write_complete;
wire interp2_done_internal;
wire interp2_busy_internal;
wire mw_slot0_available = slot0_valid && !slot0_started;
wire mw_slot1_available = !mw_slot0_available && slot1_valid && !slot1_started;
wire mw_can_start_frame = mw_bank_available &&
                                (mw_slot0_available || mw_slot1_available) &&
                                !mw_active_slot_valid;
wire mw_frame_gate = o_mw_active || mw_can_start_frame;
wire mw_frame_start_hs;
wire ps_desc_commit_rise = i_ps_im_done && !ps_desc_commit_d;
wire mag_write_complete_rise = mag_write_complete && !mag_write_complete_d;
// Do not gate start on interp2_busy_internal: the descriptor FIFO may already
// be preloaded before start, which intentionally makes the core "busy".
wire interp2_start_fire = !interp2_active_slot_valid &&
                          slot0_valid &&
                          slot0_started &&
                          slot0_mag_ready &&
                          slot0_desc_ready &&
                          !slot0_interp2_launched;

always @(posedge clk) begin
    if (!rst_n) begin
        mw_mag_base_addr_reg <= MAG_DDR_BASE_ADDR;
        interp2_mag_base_addr_reg  <= MAG_DDR_BASE_ADDR;
        interp2_start_internal     <= 1'b0;
        ps_desc_commit_d           <= 1'b0;
        mag_write_complete_d       <= 1'b0;
        next_v_req_id_reg          <= 8'd0;
        slot0_valid                <= 1'b0;
        slot0_req_id               <= 8'd0;
        slot0_v_data               <= 9'd0;
        slot0_desc_ready           <= 1'b0;
        slot0_started              <= 1'b0;
        slot0_mag_ready            <= 1'b0;
        slot0_bank_valid           <= 1'b0;
        slot0_bank_select          <= 1'b0;
        slot0_interp2_launched     <= 1'b0;
        slot1_valid                <= 1'b0;
        slot1_req_id               <= 8'd0;
        slot1_v_data               <= 9'd0;
        slot1_desc_ready           <= 1'b0;
        slot1_started              <= 1'b0;
        slot1_mag_ready            <= 1'b0;
        slot1_bank_valid           <= 1'b0;
        slot1_bank_select          <= 1'b0;
        slot1_interp2_launched     <= 1'b0;
        mw_active_slot_valid <= 1'b0;
        mw_active_slot_is_slot1 <= 1'b0;
        interp2_active_slot_valid  <= 1'b0;
        mag_ready_pending_reg      <= 1'b0;
        mag_ready_pending_slot1_reg <= 1'b0;
        mag_ready_delay_reg        <= {MAG_READY_DELAY_W{1'b0}};
    end else begin
        interp2_start_internal <= 1'b0;
        ps_desc_commit_d <= i_ps_im_done;
        mag_write_complete_d <= mag_write_complete;

        if (mag_ready_pending_reg) begin
            if (mag_ready_delay_reg != 0) begin
                mag_ready_delay_reg <= mag_ready_delay_reg - 1'b1;
            end else begin
                if (mag_ready_pending_slot1_reg) begin
                    slot1_mag_ready <= 1'b1;
                end else begin
                    slot0_mag_ready <= 1'b1;
                end
                mag_ready_pending_reg <= 1'b0;
            end
        end

        if (reg_v_valid && v_push_ready_internal) begin
            if (!slot0_valid) begin
                slot0_valid            <= 1'b1;
                slot0_req_id           <= next_v_req_id_reg;
                slot0_v_data           <= reg_v_data;
                slot0_desc_ready       <= 1'b0;
                slot0_started          <= 1'b0;
                slot0_mag_ready        <= 1'b0;
                slot0_bank_valid       <= 1'b0;
                slot0_bank_select      <= 1'b0;
                slot0_interp2_launched <= 1'b0;
            end else if (!slot1_valid) begin
                slot1_valid            <= 1'b1;
                slot1_req_id           <= next_v_req_id_reg;
                slot1_v_data           <= reg_v_data;
                slot1_desc_ready       <= 1'b0;
                slot1_started          <= 1'b0;
                slot1_mag_ready        <= 1'b0;
                slot1_bank_valid       <= 1'b0;
                slot1_bank_select      <= 1'b0;
                slot1_interp2_launched <= 1'b0;
            end
            next_v_req_id_reg <= next_v_req_id_reg + 1'b1;
        end

        if (ps_desc_commit_rise) begin
            if (ps_req_slot0) begin
                slot0_desc_ready <= 1'b1;
            end else if (ps_req_slot1) begin
                slot1_desc_ready <= 1'b1;
            end
        end

        if (mw_frame_start_hs) begin
            mw_mag_base_addr_reg <= mw_next_bank_base_addr;
            mw_active_slot_valid <= 1'b1;
            mw_active_slot_is_slot1 <= mw_slot1_available;
            if (mw_slot0_available) begin
                slot0_started     <= 1'b1;
                slot0_mag_ready   <= 1'b0;
                slot0_bank_valid  <= 1'b1;
                slot0_bank_select <= mw_next_bank_select;
            end else if (mw_slot1_available) begin
                slot1_started     <= 1'b1;
                slot1_mag_ready   <= 1'b0;
                slot1_bank_valid  <= 1'b1;
                slot1_bank_select <= mw_next_bank_select;
            end
        end

        if (mag_write_complete_rise && mw_active_slot_valid) begin
            mw_active_slot_valid <= 1'b0;
            mag_ready_pending_reg <= 1'b1;
            mag_ready_pending_slot1_reg <= mw_active_slot_is_slot1;
            mag_ready_delay_reg <= MAG_READY_DELAY_CYCLES - 1;
        end

        if (interp2_start_fire) begin
            interp2_start_internal    <= 1'b1;
            interp2_active_slot_valid <= 1'b1;
            interp2_mag_base_addr_reg <= slot0_bank_select ? mag_bank1_base_addr
                                                            : mag_bank0_base_addr;
            slot0_interp2_launched    <= 1'b1;
        end

        if (interp2_done_internal && interp2_active_slot_valid) begin
            interp2_active_slot_valid <= 1'b0;
            if (slot1_valid) begin
                slot0_valid            <= slot1_valid;
                slot0_req_id           <= slot1_req_id;
                slot0_v_data           <= slot1_v_data;
                slot0_desc_ready       <= slot1_desc_ready;
                slot0_started          <= slot1_started;
                slot0_mag_ready        <= slot1_mag_ready;
                slot0_bank_valid       <= slot1_bank_valid;
                slot0_bank_select      <= slot1_bank_select;
                slot0_interp2_launched <= slot1_interp2_launched;

                slot1_valid            <= 1'b0;
                slot1_req_id           <= 8'd0;
                slot1_v_data           <= 9'd0;
                slot1_desc_ready       <= 1'b0;
                slot1_started          <= 1'b0;
                slot1_mag_ready        <= 1'b0;
                slot1_bank_valid       <= 1'b0;
                slot1_bank_select      <= 1'b0;
                slot1_interp2_launched <= 1'b0;

                if (mw_active_slot_valid && mw_active_slot_is_slot1) begin
                    mw_active_slot_is_slot1 <= 1'b0;
                end
            end else begin
                slot0_valid            <= 1'b0;
                slot0_req_id           <= 8'd0;
                slot0_v_data           <= 9'd0;
                slot0_desc_ready       <= 1'b0;
                slot0_started          <= 1'b0;
                slot0_mag_ready        <= 1'b0;
                slot0_bank_valid       <= 1'b0;
                slot0_bank_select      <= 1'b0;
                slot0_interp2_launched <= 1'b0;
            end
        end
    end
end

//-----------------------------------------------------------------------------
// Internal Signals - 2DFFT
//-----------------------------------------------------------------------------
wire fft_2d_echo_ready;
wire [DATA_WIDTH-1:0] fft_2d_result_real;
wire [DATA_WIDTH-1:0] fft_2d_result_imag;
wire fft_2d_result_valid;
wire fft_2coord_hs;
wire fft_2d_downstream_ready;
wire [1:0]                fft_dbg_transpose_state;
wire [18:0]               fft_dbg_transpose_wr_addr;
wire [18:0]               fft_dbg_transpose_rd_issue_count;
wire [18:0]               fft_dbg_transpose_rd_emit_count;
wire                      fft_dbg_transpose_req_ready;
wire                      fft_dbg_transpose_rsp_valid;
wire                      fft_dbg_transpose_rd_pipe_valid;
wire [1:0]                fft_dbg_fft512_state;
wire [9:0]                fft_dbg_fft512_collect_count;
wire [9:0]                fft_dbg_fft512_feed_sent_count;
wire [9:0]                fft_dbg_fft512_core_out_count;
wire [9:0]                fft_dbg_fft512_out_stream_count;
wire [15:0]               fft_dbg_fft512_run_cycle_count;
wire                      fft_dbg_fft512_ready_to_upstream;
wire                      fft_dbg_fft512_output_valid;
wire                      fft_dbg_fft512_ready_from_downstream;
wire                      fft_dbg_mod2_valid;
wire                      fft_dbg_mod2_ready;
wire                      fft_dbg_reorder2_valid;
wire                      fft_dbg_reorder2_ready;
wire [1:0]                fft_dbg_reorder2_wr_buf_ptr;
wire [1:0]                fft_dbg_reorder2_rd_buf_ptr;
wire [8:0]                fft_dbg_reorder2_wr_addr;
wire [9:0]                fft_dbg_reorder2_rd_issue_count;
wire [9:0]                fft_dbg_reorder2_rd_send_count;
wire [2:0]                fft_dbg_reorder2_buf_full;
wire                      fft_dbg_reorder2_rd_active;
wire                      fft_dbg_reorder2_out_valid;
wire                      fft_dbg_reorder2_rsp_valid;
wire                      fft_dbg_reorder2_input_ready;
wire [1:0]                fft_dbg_fft1024_state;
wire [10:0]               fft_dbg_fft1024_collect_count;
wire [10:0]               fft_dbg_fft1024_feed_sent_count;
wire [10:0]               fft_dbg_fft1024_core_out_count;
wire [10:0]               fft_dbg_fft1024_out_stream_count;
wire [15:0]               fft_dbg_fft1024_run_cycle_count;
wire                      fft_dbg_fft1024_ready_to_upstream;
wire                      fft_dbg_fft1024_output_valid;
wire                      fft_dbg_fft1024_ready_from_downstream;
wire                      fft_dbg_ifft_raw_output_valid;
wire                      fft_dbg_ifft_out_stage_ready;
wire                      fft_dbg_ifft_temp_data_valid;
wire [18:0]               fft_dbg_hs_ifft_mod1;
wire [18:0]               fft_dbg_hs_mod1_reorder1;
wire [18:0]               fft_dbg_hs_reorder1_trans;
wire [18:0]               fft_dbg_hs_trans_fft512;
wire [18:0]               fft_dbg_hs_fft512_mod2;
wire [31:0]               fft_dbg_hrrp_first_pair;
wire [31:0]               fft_dbg_hrrp_last_pair;
wire [31:0]               fft_dbg_hrrp_max_abs_pair;
wire [15:0]               fft_dbg_hrrp_nonzero_count;
wire [31:0]               fft_dbg_transpose_first_pair;
wire [31:0]               fft_dbg_transpose_last_pair;
wire [31:0]               fft_dbg_transpose_max_abs_pair;
wire [15:0]               fft_dbg_transpose_nonzero_count;
wire [31:0]               fft_dbg_fft512_first_pair;
wire [31:0]               fft_dbg_fft512_last_pair;
wire [31:0]               fft_dbg_fft512_max_abs_pair;
wire [15:0]               fft_dbg_fft512_nonzero_count;
wire [31:0]               fft_dbg_mod2_first_pair;
wire [31:0]               fft_dbg_mod2_last_pair;
wire [31:0]               fft_dbg_mod2_max_abs_pair;
wire [15:0]               fft_dbg_mod2_nonzero_count;
wire [31:0]               fft_dbg_out_first_pair;
wire [31:0]               fft_dbg_out_last_pair;
wire [31:0]               fft_dbg_out_max_abs_pair;
wire [15:0]               fft_dbg_out_nonzero_count;
wire [31:0]               fft_dbg_sram_wr_first_data;
wire [31:0]               fft_dbg_sram_wr_last_data;
wire [15:0]               fft_dbg_sram_wr_nonzero_count;
wire [15:0]               fft_dbg_sram_wr_event_count;
wire [18:0]               fft_dbg_sram_wr_first_addr;
wire [18:0]               fft_dbg_sram_wr_last_addr;
wire [31:0]               fft_dbg_sram_rd_first_data;
wire [31:0]               fft_dbg_sram_rd_last_data;
wire [15:0]               fft_dbg_sram_rd_nonzero_count;
wire [15:0]               fft_dbg_sram_rd_event_count;
wire [18:0]               fft_dbg_sram_rd_first_addr;
wire [18:0]               fft_dbg_sram_rd_last_addr;
wire                      fft_sram_WE_n;
wire                      fft_sram_CE_n;
wire                      fft_sram_CE_2;
wire                      fft_sram_OE_n;
wire [18:0]               fft_sram_addr;
wire                      mag_sram_WE_n;
wire                      mag_sram_CE_n;
wire                      mag_sram_CE_2;
wire                      mag_sram_OE_n;
wire [18:0]               mag_sram_addr;
wire [AXI_ADDR_WIDTH-1:0] trans_axi_awaddr;
wire [7:0]                trans_axi_awlen;
wire [2:0]                trans_axi_awsize;
wire [1:0]                trans_axi_awburst;
wire                      trans_axi_awvalid;
wire [AXI_DATA_WIDTH-1:0] trans_axi_wdata;
wire [AXI_STRB_WIDTH-1:0] trans_axi_wstrb;
wire                      trans_axi_wlast;
wire                      trans_axi_wvalid;
wire                      trans_axi_bready;
wire [AXI_ADDR_WIDTH-1:0] trans_axi_araddr;
wire [7:0]                trans_axi_arlen;
wire [2:0]                trans_axi_arsize;
wire [1:0]                trans_axi_arburst;
wire                      trans_axi_arvalid;
wire                      trans_axi_rready;

// [修改] 转置模块信号不再使用
// wire transpose_ready_for_input;
// wire [DATA_WIDTH*2-1:0] transpose_out_data;
// wire transpose_out_valid;

wire mw_imird_ready;
wire mw_imird_valid;
wire signed [DATA_WIDTH-1:0] mw_in_real;
wire signed [DATA_WIDTH-1:0] mw_in_imag;

//-----------------------------------------------------------------------------
// Internal Signals - mag_writer AXI write / interp2 AXI read
//-----------------------------------------------------------------------------
wire                         mw_debug_mag_valid;
wire [15:0]                  mw_debug_mag_data;
wire                         mw_debug_sqrt_valid;
wire [15:0]                  mw_debug_sqrt_data;
wire                         mw_mag_overflow;
wire [MAG_RAM_ADDR_WIDTH:0]  mw_mag_write_count;
wire                         mw_mag_store_done;

wire [AXI_ADDR_WIDTH-1:0]    mw_mag_awaddr;
wire [7:0]                   mw_mag_awlen;
wire [2:0]                   mw_mag_awsize;
wire [1:0]                   mw_mag_awburst;
wire                         mw_mag_awvalid;
wire [AXI_DATA_WIDTH-1:0]    mw_mag_wdata;
wire [AXI_STRB_WIDTH-1:0]    mw_mag_wstrb;
wire                         mw_mag_wlast;
wire                         mw_mag_wvalid;
wire                         mw_mag_bready;

wire [AXI_ADDR_WIDTH-1:0]    interp2_mag_araddr;
wire [7:0]                   interp2_mag_arlen;
wire [2:0]                   interp2_mag_arsize;
wire [1:0]                   interp2_mag_arburst;
wire                         interp2_mag_arvalid;
wire                         interp2_mag_rready;
wire                         mw_mag_bank_sel = (mw_mag_base_addr_reg == mag_bank1_base_addr);
wire                         interp2_mag_bank_sel = (interp2_mag_base_addr_reg == mag_bank1_base_addr);
wire                         interp2_read_req_valid;
wire                         interp2_read_req_ready;
wire [MAG_RAM_ADDR_WIDTH-1:0] interp2_read_req_addr;
wire                         interp2_read_req_burst2;
wire [2:0]                   interp2_read_req_len;
wire [5:0]                   interp2_read_req_tag;
wire                         interp2_read_rsp_valid;
wire                         interp2_read_rsp_ready;
wire [15:0]                  interp2_read_rsp_data;
wire [5:0]                   interp2_read_rsp_tag;

//-----------------------------------------------------------------------------
// Internal Signals - interp2
//-----------------------------------------------------------------------------
// interp2_done_internal declared earlier (forward declaration)
wire interp2_m_ready_combined;
wire post_s_axis_tready;
wire [15:0] post_m_axis_image_tdata;
wire        post_m_axis_image_tvalid;
wire        post_m_axis_image_tlast;

// Debug loopback mode short-circuits the algorithm and forwards the low 16-bit
// lane of the echo stream directly to the final image output stream. This gives
// PS a deterministic board-level data-path test:
//   DDR -> DMA echo -> s_axis_echo -> loopback mux -> m_axis_image -> DMA image -> DDR
//
// The FFT / mag_writer / interp2 / postproc chain stays idle in this mode because
// the FFT input valid is force-gated low below. That keeps the loopback case
// independent from the imaging algorithm and from descriptor generation.
wire        echo_to_fft_valid;
wire        loopback_image_valid;
wire        loopback_image_last;
wire image_out_last_hs;

// Status tracking
reg processing_started;
reg processing_done_reg;
wire frame_idle_internal;

wire [31:0] mag_wr_count = {{(32-(MAG_RAM_ADDR_WIDTH+1)){1'b0}}, mw_mag_write_count};
// mag_write_complete declared earlier (forward declaration)
assign mag_write_complete = mw_mag_store_done;
assign frame_idle_internal = ~processing_started | processing_done_reg;

wire echo_in_hs = s_axis_echo_tvalid && s_axis_echo_tready;
wire fft_out_stall = fft_2d_result_valid && !mw_imird_ready;
wire fft_in_stall = echo_to_fft_valid && !fft_2d_echo_ready && i_ps_init_done;
wire fft_trans_aw_stall = trans_axi_awvalid && !m_axi_trans_awready;
wire fft_trans_w_stall = trans_axi_wvalid && !m_axi_trans_wready;
wire fft_trans_ar_stall = trans_axi_arvalid && !m_axi_trans_arready;
wire fft_trans_r_wait = trans_axi_rready && !m_axi_trans_rvalid;
wire coord_wait_prev_interp2 = fft_2d_result_valid &&
                               !o_mw_active &&
                               !mw_can_start_frame &&
                               !mw_bank_available;
wire coord_aw_stall = mw_mag_awvalid && !m_axi_mag_awready;
wire coord_w_stall = mw_mag_wvalid && !m_axi_mag_wready;
wire interp2_wait_ps = slot0_valid &&
                       slot0_started &&
                       slot0_mag_ready &&
                       !slot0_desc_ready &&
                       !slot0_interp2_launched &&
                       !interp2_busy_internal;
wire interp2_wait_desc = interp2_busy_internal && interp_desc_tready && !interp_desc_tvalid;
wire interp2_ar_stall = interp2_mag_arvalid && !m_axi_mag_arready;
wire interp2_r_wait = interp2_busy_internal && interp2_mag_rready && !m_axi_mag_rvalid;
wire interp2_out_hs = m_axis_interp2_tvalid && interp2_m_ready_combined;
wire interp2_out_stall = m_axis_interp2_tvalid && !interp2_m_ready_combined;
wire post_in_hs = m_axis_interp2_tvalid && post_s_axis_tready;
wire image_out_hs = m_axis_image_tvalid && m_axis_image_tready;
wire post_out_stall = post_m_axis_image_tvalid && !m_axis_image_tready;
reg  perf_echo_frame_open_reg;
reg  perf_post_frame_open_reg;
wire perf_frame_start_hs = echo_in_hs && !perf_echo_frame_open_reg;
wire perf_post_start_hs = post_in_hs && !perf_post_frame_open_reg;
wire [31:0] perf_snapshot_status;
wire [31:0] perf_frame_seq;
wire [31:0] perf_frame_cycles;
wire [31:0] perf_fft_cycles;
wire [31:0] perf_mw_cycles;
wire [31:0] perf_interp2_cycles;
wire [31:0] perf_postproc_cycles;
wire [31:0] perf_fft_input_stall_cycles;
wire [31:0] perf_fft_output_stall_cycles;
wire [31:0] perf_fft_trans_aw_stall_cycles;
wire [31:0] perf_fft_trans_w_stall_cycles;
wire [31:0] perf_fft_trans_ar_stall_cycles;
wire [31:0] perf_fft_trans_r_wait_cycles;
wire [31:0] perf_coord_wait_prev_interp2_cycles;
wire [31:0] perf_coord_active_cycles;
wire [31:0] perf_coord_aw_stall_cycles;
wire [31:0] perf_coord_w_stall_cycles;
wire [31:0] perf_interp2_wait_ps_cycles;
wire [31:0] perf_interp2_busy_cycles;
wire [31:0] perf_interp2_wait_desc_cycles;
wire [31:0] perf_interp2_ar_stall_cycles;
wire [31:0] perf_interp2_r_wait_cycles;
wire [31:0] perf_interp2_output_stall_cycles;
wire [31:0] perf_postproc_active_cycles;
wire [31:0] perf_postproc_output_stall_cycles;
wire [31:0] perf_fft_output_count;
wire [31:0] perf_coord_mag_write_count;
wire [31:0] perf_interp2_output_count;
wire [31:0] perf_postproc_output_count;
wire [31:0] perf_fft_done_offset_cycles;
wire [31:0] perf_mw_start_offset_cycles;
wire [31:0] perf_mw_done_offset_cycles;
wire [31:0] perf_interp2_start_offset_cycles;
wire [31:0] perf_interp2_done_offset_cycles;
wire [31:0] perf_post_start_offset_cycles;
wire [PERF_REG_COUNT*32-1:0] perf_ro_flat;
localparam [1:0] FFT_DBG_ST_COLLECT = 2'd0;
localparam [1:0] FFT_DBG_ST_RESET   = 2'd1;
localparam [1:0] FFT_DBG_ST_RUN     = 2'd2;
localparam [1:0] FFT_DBG_ST_STREAM  = 2'd3;
localparam [1:0] TRANS_DBG_ST_WRITE      = 2'd0;
localparam [1:0] TRANS_DBG_ST_TURN       = 2'd1;
localparam [1:0] TRANS_DBG_ST_READ_FILL  = 2'd2;
localparam [1:0] TRANS_DBG_ST_READ_DRAIN = 2'd3;
reg         perf_fft_detail_active_reg;
reg [31:0] perf_fft_detail_out_count_reg;
reg [31:0] perf_fft1024_collect_cycles_reg;
reg [31:0] perf_fft1024_reset_cycles_reg;
reg [31:0] perf_fft1024_run_cycles_reg;
reg [31:0] perf_fft1024_stream_cycles_reg;
reg [31:0] perf_fft512_collect_cycles_reg;
reg [31:0] perf_fft512_reset_cycles_reg;
reg [31:0] perf_fft512_run_cycles_reg;
reg [31:0] perf_fft512_stream_cycles_reg;
reg [31:0] perf_fft_transpose_write_cycles_reg;
reg [31:0] perf_fft_transpose_turn_cycles_reg;
reg [31:0] perf_fft_transpose_read_fill_cycles_reg;
reg [31:0] perf_fft_transpose_read_drain_cycles_reg;
reg [31:0] perf_fft_transpose_to_fft512_stall_cycles_reg;
reg [31:0] perf_fft512_output_stall_detail_cycles_reg;
reg [31:0] perf_fft_reorder2_output_stall_cycles_reg;
reg  [31:0] dbg_interp2_sum_reg;
reg  [31:0] dbg_interp2_xor_reg;
reg  [31:0] dbg_interp2_nonzero_reg;
reg  [31:0] dbg_interp2_first_last_reg;
reg  [31:0] dbg_post_sum_reg;
reg  [31:0] dbg_post_xor_reg;
reg  [31:0] dbg_post_nonzero_reg;
reg  [31:0] dbg_post_first_last_reg;
reg         dbg_interp2_seen_reg;
reg         dbg_post_seen_reg;
reg  [31:0] dbg_fft_in_count_reg;
reg  [31:0] dbg_fft_out_count_reg;
reg  [31:0] dbg_interp2_out_count_reg;
reg  [15:0] dbg_fft_first_real_reg;
reg  [15:0] dbg_fft_first_imag_reg;
reg  [15:0] dbg_fft_last_real_reg;
reg  [15:0] dbg_fft_last_imag_reg;
reg  [15:0] dbg_fft_max_real_abs_reg;
reg  [15:0] dbg_fft_max_imag_abs_reg;
reg  [15:0] dbg_fft_nonzero_count_reg;
reg  [15:0] dbg_mwin_first_real_reg;
reg  [15:0] dbg_mwin_first_imag_reg;
reg  [15:0] dbg_mwin_last_real_reg;
reg  [15:0] dbg_mwin_last_imag_reg;
reg  [15:0] dbg_mwin_max_real_abs_reg;
reg  [15:0] dbg_mwin_max_imag_abs_reg;
reg  [15:0] dbg_mwin_nonzero_count_reg;
reg         dbg_mwin_seen_reg;
reg  [15:0] dbg_sqrt_first_reg;
reg  [15:0] dbg_sqrt_last_reg;
reg  [15:0] dbg_sqrt_max_reg;
reg  [15:0] dbg_sqrt_nonzero_count_reg;
reg         dbg_sqrt_seen_reg;
reg         dbg_fft_seen_reg;
wire [31:0] dbg_ro0;
wire [31:0] dbg_ro1;
wire [31:0] dbg_ro2;
wire [31:0] dbg_ro3;
wire [31:0] dbg_ro4;
wire [31:0] dbg_ro5;
wire [31:0] dbg_ro6;
wire [31:0] dbg_ro7;
wire [31:0] dbg_ro8;
wire [31:0] interp2_debug_ro0;
wire [31:0] interp2_debug_ro1;
wire [31:0] interp2_debug_ro2;
wire [31:0] interp2_debug_ro3;
wire [31:0] interp2_debug_ro4;
wire [31:0] interp2_debug_ro5;
wire [31:0] interp2_debug_ro6;
wire [31:0] interp2_debug_ro7;
wire [31:0] mag_sram_debug_ro0;
wire [31:0] mag_sram_debug_ro1;
wire [31:0] mag_sram_debug_ro2;
wire [31:0] mag_sram_debug_ro3;
wire [15:0] dbg_fft_real_abs = fft_2d_result_real[15] ? (~fft_2d_result_real + 16'd1) : fft_2d_result_real;
wire [15:0] dbg_fft_imag_abs = fft_2d_result_imag[15] ? (~fft_2d_result_imag + 16'd1) : fft_2d_result_imag;
wire [15:0] dbg_mwin_real_abs = mw_in_real[15] ? (~mw_in_real + 16'd1) : mw_in_real;
wire [15:0] dbg_mwin_imag_abs = mw_in_imag[15] ? (~mw_in_imag + 16'd1) : mw_in_imag;
wire mw_in_hs = mw_imird_valid && mw_imird_ready;
wire [31:0] dbg_interp2_data_ext = {16'd0, m_axis_interp2_tdata};
wire [31:0] dbg_post_data_ext = {16'd0, post_m_axis_image_tdata};
wire perf_fft_detail_last_out_hs = perf_fft_detail_active_reg &&
                                   fft_2coord_hs &&
                                   (perf_fft_detail_out_count_reg == (TOTAL_OUTPUT - 1));
wire perf_fft_transpose_write_active = USE_EXT_SRAM_TRANSPOSE ?
                                       (fft_dbg_transpose_state == TRANS_DBG_ST_WRITE) :
                                       (trans_axi_awvalid || trans_axi_wvalid);
wire perf_fft_transpose_turn_active = USE_EXT_SRAM_TRANSPOSE &&
                                      (fft_dbg_transpose_state == TRANS_DBG_ST_TURN);
wire perf_fft_transpose_read_fill_active = (fft_dbg_transpose_state == TRANS_DBG_ST_READ_FILL);
wire perf_fft_transpose_read_drain_active = (fft_dbg_transpose_state == TRANS_DBG_ST_READ_DRAIN);

always @(posedge clk) begin
    if (!rst_n) begin
        perf_fft_detail_active_reg <= 1'b0;
        perf_fft_detail_out_count_reg <= 32'd0;
        perf_fft1024_collect_cycles_reg <= 32'd0;
        perf_fft1024_reset_cycles_reg <= 32'd0;
        perf_fft1024_run_cycles_reg <= 32'd0;
        perf_fft1024_stream_cycles_reg <= 32'd0;
        perf_fft512_collect_cycles_reg <= 32'd0;
        perf_fft512_reset_cycles_reg <= 32'd0;
        perf_fft512_run_cycles_reg <= 32'd0;
        perf_fft512_stream_cycles_reg <= 32'd0;
        perf_fft_transpose_write_cycles_reg <= 32'd0;
        perf_fft_transpose_turn_cycles_reg <= 32'd0;
        perf_fft_transpose_read_fill_cycles_reg <= 32'd0;
        perf_fft_transpose_read_drain_cycles_reg <= 32'd0;
        perf_fft_transpose_to_fft512_stall_cycles_reg <= 32'd0;
        perf_fft512_output_stall_detail_cycles_reg <= 32'd0;
        perf_fft_reorder2_output_stall_cycles_reg <= 32'd0;
    end else if (perf_frame_start_hs) begin
        perf_fft_detail_active_reg <= 1'b1;
        perf_fft_detail_out_count_reg <= 32'd0;
        perf_fft1024_collect_cycles_reg <= 32'd0;
        perf_fft1024_reset_cycles_reg <= 32'd0;
        perf_fft1024_run_cycles_reg <= 32'd0;
        perf_fft1024_stream_cycles_reg <= 32'd0;
        perf_fft512_collect_cycles_reg <= 32'd0;
        perf_fft512_reset_cycles_reg <= 32'd0;
        perf_fft512_run_cycles_reg <= 32'd0;
        perf_fft512_stream_cycles_reg <= 32'd0;
        perf_fft_transpose_write_cycles_reg <= 32'd0;
        perf_fft_transpose_turn_cycles_reg <= 32'd0;
        perf_fft_transpose_read_fill_cycles_reg <= 32'd0;
        perf_fft_transpose_read_drain_cycles_reg <= 32'd0;
        perf_fft_transpose_to_fft512_stall_cycles_reg <= 32'd0;
        perf_fft512_output_stall_detail_cycles_reg <= 32'd0;
        perf_fft_reorder2_output_stall_cycles_reg <= 32'd0;
    end else if (perf_fft_detail_active_reg) begin
        case (fft_dbg_fft1024_state)
            FFT_DBG_ST_COLLECT: perf_fft1024_collect_cycles_reg <= perf_fft1024_collect_cycles_reg + 1'b1;
            FFT_DBG_ST_RESET:   perf_fft1024_reset_cycles_reg <= perf_fft1024_reset_cycles_reg + 1'b1;
            FFT_DBG_ST_RUN:     perf_fft1024_run_cycles_reg <= perf_fft1024_run_cycles_reg + 1'b1;
            FFT_DBG_ST_STREAM:  perf_fft1024_stream_cycles_reg <= perf_fft1024_stream_cycles_reg + 1'b1;
            default: begin end
        endcase

        case (fft_dbg_fft512_state)
            FFT_DBG_ST_COLLECT: perf_fft512_collect_cycles_reg <= perf_fft512_collect_cycles_reg + 1'b1;
            FFT_DBG_ST_RESET:   perf_fft512_reset_cycles_reg <= perf_fft512_reset_cycles_reg + 1'b1;
            FFT_DBG_ST_RUN:     perf_fft512_run_cycles_reg <= perf_fft512_run_cycles_reg + 1'b1;
            FFT_DBG_ST_STREAM:  perf_fft512_stream_cycles_reg <= perf_fft512_stream_cycles_reg + 1'b1;
            default: begin end
        endcase

        if (perf_fft_transpose_write_active) begin
            perf_fft_transpose_write_cycles_reg <= perf_fft_transpose_write_cycles_reg + 1'b1;
        end
        if (perf_fft_transpose_turn_active) begin
            perf_fft_transpose_turn_cycles_reg <= perf_fft_transpose_turn_cycles_reg + 1'b1;
        end
        if (perf_fft_transpose_read_fill_active) begin
            perf_fft_transpose_read_fill_cycles_reg <= perf_fft_transpose_read_fill_cycles_reg + 1'b1;
        end
        if (perf_fft_transpose_read_drain_active) begin
            perf_fft_transpose_read_drain_cycles_reg <= perf_fft_transpose_read_drain_cycles_reg + 1'b1;
        end

        if (fft_dbg_transpose_rsp_valid && !fft_dbg_fft512_ready_to_upstream) begin
            perf_fft_transpose_to_fft512_stall_cycles_reg <= perf_fft_transpose_to_fft512_stall_cycles_reg + 1'b1;
        end

        if (fft_dbg_fft512_output_valid && !fft_dbg_fft512_ready_from_downstream) begin
            perf_fft512_output_stall_detail_cycles_reg <= perf_fft512_output_stall_detail_cycles_reg + 1'b1;
        end

        if (fft_dbg_reorder2_valid && !fft_dbg_reorder2_ready) begin
            perf_fft_reorder2_output_stall_cycles_reg <= perf_fft_reorder2_output_stall_cycles_reg + 1'b1;
        end

        if (fft_2coord_hs) begin
            if (perf_fft_detail_last_out_hs) begin
                perf_fft_detail_active_reg <= 1'b0;
            end
            perf_fft_detail_out_count_reg <= perf_fft_detail_out_count_reg + 1'b1;
        end
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        dbg_interp2_sum_reg <= 32'd0;
        dbg_interp2_xor_reg <= 32'd0;
        dbg_interp2_nonzero_reg <= 32'd0;
        dbg_interp2_first_last_reg <= 32'd0;
        dbg_post_sum_reg <= 32'd0;
        dbg_post_xor_reg <= 32'd0;
        dbg_post_nonzero_reg <= 32'd0;
        dbg_post_first_last_reg <= 32'd0;
        dbg_interp2_seen_reg <= 1'b0;
        dbg_post_seen_reg <= 1'b0;
        dbg_fft_in_count_reg <= 32'd0;
        dbg_fft_out_count_reg <= 32'd0;
        dbg_interp2_out_count_reg <= 32'd0;
        dbg_fft_first_real_reg <= 16'd0;
        dbg_fft_first_imag_reg <= 16'd0;
        dbg_fft_last_real_reg <= 16'd0;
        dbg_fft_last_imag_reg <= 16'd0;
        dbg_fft_max_real_abs_reg <= 16'd0;
        dbg_fft_max_imag_abs_reg <= 16'd0;
        dbg_fft_nonzero_count_reg <= 16'd0;
        dbg_mwin_first_real_reg <= 16'd0;
        dbg_mwin_first_imag_reg <= 16'd0;
        dbg_mwin_last_real_reg <= 16'd0;
        dbg_mwin_last_imag_reg <= 16'd0;
        dbg_mwin_max_real_abs_reg <= 16'd0;
        dbg_mwin_max_imag_abs_reg <= 16'd0;
        dbg_mwin_nonzero_count_reg <= 16'd0;
        dbg_mwin_seen_reg <= 1'b0;
        dbg_sqrt_first_reg <= 16'd0;
        dbg_sqrt_last_reg <= 16'd0;
        dbg_sqrt_max_reg <= 16'd0;
        dbg_sqrt_nonzero_count_reg <= 16'd0;
        dbg_sqrt_seen_reg <= 1'b0;
        dbg_fft_seen_reg <= 1'b0;
    end else begin
        if (!processing_started) begin
            dbg_interp2_sum_reg <= 32'd0;
            dbg_interp2_xor_reg <= 32'd0;
            dbg_interp2_nonzero_reg <= 32'd0;
            dbg_interp2_first_last_reg <= 32'd0;
            dbg_post_sum_reg <= 32'd0;
            dbg_post_xor_reg <= 32'd0;
            dbg_post_nonzero_reg <= 32'd0;
            dbg_post_first_last_reg <= 32'd0;
            dbg_interp2_seen_reg <= 1'b0;
            dbg_post_seen_reg <= 1'b0;
            dbg_fft_in_count_reg <= 32'd0;
            dbg_fft_out_count_reg <= 32'd0;
            dbg_interp2_out_count_reg <= 32'd0;
            dbg_fft_first_real_reg <= 16'd0;
            dbg_fft_first_imag_reg <= 16'd0;
            dbg_fft_last_real_reg <= 16'd0;
            dbg_fft_last_imag_reg <= 16'd0;
            dbg_fft_max_real_abs_reg <= 16'd0;
            dbg_fft_max_imag_abs_reg <= 16'd0;
            dbg_fft_nonzero_count_reg <= 16'd0;
            dbg_mwin_first_real_reg <= 16'd0;
            dbg_mwin_first_imag_reg <= 16'd0;
            dbg_mwin_last_real_reg <= 16'd0;
            dbg_mwin_last_imag_reg <= 16'd0;
            dbg_mwin_max_real_abs_reg <= 16'd0;
            dbg_mwin_max_imag_abs_reg <= 16'd0;
            dbg_mwin_nonzero_count_reg <= 16'd0;
            dbg_mwin_seen_reg <= 1'b0;
            dbg_sqrt_first_reg <= 16'd0;
            dbg_sqrt_last_reg <= 16'd0;
            dbg_sqrt_max_reg <= 16'd0;
            dbg_sqrt_nonzero_count_reg <= 16'd0;
            dbg_sqrt_seen_reg <= 1'b0;
            dbg_fft_seen_reg <= 1'b0;
        end else begin
            if (interp2_out_hs) begin
                dbg_interp2_sum_reg <= dbg_interp2_sum_reg + dbg_interp2_data_ext;
                dbg_interp2_xor_reg <= dbg_interp2_xor_reg ^ {m_axis_interp2_tdata, m_axis_interp2_tdata};
                if (!dbg_interp2_seen_reg) begin
                    dbg_interp2_first_last_reg[31:16] <= m_axis_interp2_tdata;
                    dbg_interp2_seen_reg <= 1'b1;
                end
                dbg_interp2_first_last_reg[15:0] <= m_axis_interp2_tdata;
                if (m_axis_interp2_tdata != 16'd0) begin
                    dbg_interp2_nonzero_reg <= dbg_interp2_nonzero_reg + 1'b1;
                end
            end
            if (image_out_hs) begin
                dbg_post_sum_reg <= dbg_post_sum_reg + dbg_post_data_ext;
                dbg_post_xor_reg <= dbg_post_xor_reg ^ {post_m_axis_image_tdata, post_m_axis_image_tdata};
                if (!dbg_post_seen_reg) begin
                    dbg_post_first_last_reg[31:16] <= post_m_axis_image_tdata;
                    dbg_post_seen_reg <= 1'b1;
                end
                dbg_post_first_last_reg[15:0] <= post_m_axis_image_tdata;
                if (post_m_axis_image_tdata != 16'd0) begin
                    dbg_post_nonzero_reg <= dbg_post_nonzero_reg + 1'b1;
                end
            end
            if (echo_in_hs) begin
                dbg_fft_in_count_reg <= dbg_fft_in_count_reg + 1'b1;
            end
            if (fft_2coord_hs) begin
                dbg_fft_out_count_reg <= dbg_fft_out_count_reg + 1'b1;
                if (((fft_2d_result_real != 16'd0) || (fft_2d_result_imag != 16'd0)) && !dbg_fft_seen_reg) begin
                    dbg_fft_first_real_reg <= fft_2d_result_real;
                    dbg_fft_first_imag_reg <= fft_2d_result_imag;
                    dbg_fft_seen_reg <= 1'b1;
                end
                if ((fft_2d_result_real != 16'd0) || (fft_2d_result_imag != 16'd0)) begin
                    dbg_fft_last_real_reg <= fft_2d_result_real;
                    dbg_fft_last_imag_reg <= fft_2d_result_imag;
                end
                if (dbg_fft_real_abs > dbg_fft_max_real_abs_reg) begin
                    dbg_fft_max_real_abs_reg <= dbg_fft_real_abs;
                end
                if (dbg_fft_imag_abs > dbg_fft_max_imag_abs_reg) begin
                    dbg_fft_max_imag_abs_reg <= dbg_fft_imag_abs;
                end
                if (((fft_2d_result_real != 16'd0) || (fft_2d_result_imag != 16'd0)) &&
                    (dbg_fft_nonzero_count_reg != 16'hFFFF)) begin
                    dbg_fft_nonzero_count_reg <= dbg_fft_nonzero_count_reg + 1'b1;
                end
            end
            if (mw_in_hs) begin
                if (((mw_in_real != 16'sd0) || (mw_in_imag != 16'sd0)) && !dbg_mwin_seen_reg) begin
                    dbg_mwin_first_real_reg <= mw_in_real;
                    dbg_mwin_first_imag_reg <= mw_in_imag;
                    dbg_mwin_seen_reg <= 1'b1;
                end
                if ((mw_in_real != 16'sd0) || (mw_in_imag != 16'sd0)) begin
                    dbg_mwin_last_real_reg <= mw_in_real;
                    dbg_mwin_last_imag_reg <= mw_in_imag;
                end
                if (dbg_mwin_real_abs > dbg_mwin_max_real_abs_reg) begin
                    dbg_mwin_max_real_abs_reg <= dbg_mwin_real_abs;
                end
                if (dbg_mwin_imag_abs > dbg_mwin_max_imag_abs_reg) begin
                    dbg_mwin_max_imag_abs_reg <= dbg_mwin_imag_abs;
                end
                if (((mw_in_real != 16'sd0) || (mw_in_imag != 16'sd0)) &&
                    (dbg_mwin_nonzero_count_reg != 16'hFFFF)) begin
                    dbg_mwin_nonzero_count_reg <= dbg_mwin_nonzero_count_reg + 1'b1;
                end
            end
            if (mw_debug_sqrt_valid) begin
                if ((mw_debug_sqrt_data != 16'd0) && !dbg_sqrt_seen_reg) begin
                    dbg_sqrt_first_reg <= mw_debug_sqrt_data;
                    dbg_sqrt_seen_reg <= 1'b1;
                end
                if (mw_debug_sqrt_data != 16'd0) begin
                    dbg_sqrt_last_reg <= mw_debug_sqrt_data;
                end
                if (mw_debug_sqrt_data > dbg_sqrt_max_reg) begin
                    dbg_sqrt_max_reg <= mw_debug_sqrt_data;
                end
                if ((mw_debug_sqrt_data != 16'd0) && (dbg_sqrt_nonzero_count_reg != 16'hFFFF)) begin
                    dbg_sqrt_nonzero_count_reg <= dbg_sqrt_nonzero_count_reg + 1'b1;
                end
            end
            if (mw_debug_mag_valid) begin
                dbg_interp2_out_count_reg <= dbg_interp2_out_count_reg + 1'b1;
            end
        end
    end
end

assign dbg_ro0 = {
    16'd0,
    slot0_desc_ready,
    slot0_valid,
    echo_to_fft_valid,
    fft_2d_echo_ready,
    frame_idle_internal,
    image_out_last_hs,
    interp2_active_slot_valid,
    interp2_start_fire,
    mag_write_complete,
    o_mw_active,
    mw_frame_start_hs,
    mw_can_start_frame,
    fft_2coord_hs,
    fft_2d_result_valid,
    processing_done_reg,
    processing_started
};
assign dbg_ro1 = interp2_debug_ro0;
assign dbg_ro2 = interp2_debug_ro1;
assign dbg_ro3 = interp2_debug_ro2;
assign dbg_ro4 = interp2_debug_ro3;
assign dbg_ro5 = mag_sram_debug_ro0;
assign dbg_ro6 = mag_sram_debug_ro1;
assign dbg_ro7 = mag_sram_debug_ro2;
assign dbg_ro8 = hdmi_debug_status;

// Capture postproc frame geometry only while the frame pipeline is idle.
//
// This block is intentionally simple:
// - when the design is idle, keep shadow registers synchronized with the
//   software-visible AXI-Lite registers;
// - once a frame starts, freeze the shadow values for the whole run;
// - when the frame completes and the pipeline becomes idle again, software may
//   safely update the registers for the next run.
//
// The data path therefore sees stable local registers instead of a direct path
// from AXI-Lite control flops into the frame-last logic.
always @(posedge clk) begin
    if (!rst_n) begin
        post_cfg_ny_shadow  <= 16'd0;
        post_cfg_nx_shadow  <= 16'd0;
        perf_echo_frame_open_reg <= 1'b0;
        perf_post_frame_open_reg <= 1'b0;
    end else if (frame_idle_internal) begin
        post_cfg_ny_shadow  <= post_cfg_ny;
        post_cfg_nx_shadow  <= post_cfg_nx;
        if (echo_in_hs) begin
            perf_echo_frame_open_reg <= !s_axis_echo_tlast;
        end
        if (post_in_hs) begin
            perf_post_frame_open_reg <= !m_axis_interp2_tlast;
        end
    end else begin
        if (echo_in_hs) begin
            perf_echo_frame_open_reg <= !s_axis_echo_tlast;
        end
        if (post_in_hs) begin
            perf_post_frame_open_reg <= !m_axis_interp2_tlast;
        end
    end
end

//-----------------------------------------------------------------------------
// 2D FFT Processing Module
//-----------------------------------------------------------------------------
fft_2D #(
    .DATA_WIDTH     (DATA_WIDTH),
    .NR             (NR),
    .NA             (NA),
    .RANGE_CUT_OFF  (35),
    .RANGE_IFFT_MODE(RANGE_IFFT_MODE),
    .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
    .TRANSPOSE_BASE_ADDR(TRANSPOSE_DDR_BASE_ADDR),
    .USE_SRAM_TRANSPOSE(1'b0),
    .USE_EXT_SRAM_TRANSPOSE(USE_EXT_SRAM_TRANSPOSE)
) u_fft_2D (
    .clk                (clk),
    .sram_clk           (sram_clk),
    .sram_clk_locked    (sram_clk_locked),
    .rst_n              (rst_n),

    // Input interface �?unpack s_axis_echo_tdata
    .i_echo_valid       (echo_to_fft_valid),
    .o_echo_ready       (fft_2d_echo_ready),
    .i_echo_real        (s_axis_echo_tdata[DATA_WIDTH*2-1:DATA_WIDTH]),
    .i_echo_imag        (s_axis_echo_tdata[DATA_WIDTH-1:0]),

    // Output interface
    .o_result_real      (fft_2d_result_real),
    .o_result_imag      (fft_2d_result_imag),
    .o_result_valid     (fft_2d_result_valid),
    .i_downstream_ready (fft_2d_downstream_ready),
    .cfg_transpose_store(cfg_transpose_store),
    .m_axi_trans_awaddr (trans_axi_awaddr),
    .m_axi_trans_awlen  (trans_axi_awlen),
    .m_axi_trans_awsize (trans_axi_awsize),
    .m_axi_trans_awburst(trans_axi_awburst),
    .m_axi_trans_awvalid(trans_axi_awvalid),
    .m_axi_trans_awready(m_axi_trans_awready),
    .m_axi_trans_wdata  (trans_axi_wdata),
    .m_axi_trans_wstrb  (trans_axi_wstrb),
    .m_axi_trans_wlast  (trans_axi_wlast),
    .m_axi_trans_wvalid (trans_axi_wvalid),
    .m_axi_trans_wready (m_axi_trans_wready),
    .m_axi_trans_bresp  (m_axi_trans_bresp),
    .m_axi_trans_bvalid (m_axi_trans_bvalid),
    .m_axi_trans_bready (trans_axi_bready),
    .m_axi_trans_araddr (trans_axi_araddr),
    .m_axi_trans_arlen  (trans_axi_arlen),
    .m_axi_trans_arsize (trans_axi_arsize),
    .m_axi_trans_arburst(trans_axi_arburst),
    .m_axi_trans_arvalid(trans_axi_arvalid),
    .m_axi_trans_arready(m_axi_trans_arready),
    .m_axi_trans_rdata  (m_axi_trans_rdata),
    .m_axi_trans_rresp  (m_axi_trans_rresp),
    .m_axi_trans_rlast  (m_axi_trans_rlast),
    .m_axi_trans_rvalid (m_axi_trans_rvalid),
    .m_axi_trans_rready (trans_axi_rready),
    .sram_WE_n          (fft_sram_WE_n),
    .sram_CE_n          (fft_sram_CE_n),
    .sram_CE_2          (fft_sram_CE_2),
    .sram_OE_n          (fft_sram_OE_n),
    .sram_addr          (fft_sram_addr),
    .sram_data          (sram_data),
    .o_dbg_transpose_state        (fft_dbg_transpose_state),
    .o_dbg_transpose_wr_addr      (fft_dbg_transpose_wr_addr),
    .o_dbg_transpose_rd_issue_count(fft_dbg_transpose_rd_issue_count),
    .o_dbg_transpose_rd_emit_count(fft_dbg_transpose_rd_emit_count),
    .o_dbg_transpose_req_ready    (fft_dbg_transpose_req_ready),
    .o_dbg_transpose_rsp_valid    (fft_dbg_transpose_rsp_valid),
    .o_dbg_transpose_rd_pipe_valid(fft_dbg_transpose_rd_pipe_valid),
    .o_dbg_fft512_state           (fft_dbg_fft512_state),
    .o_dbg_fft512_collect_count   (fft_dbg_fft512_collect_count),
    .o_dbg_fft512_feed_sent_count (fft_dbg_fft512_feed_sent_count),
    .o_dbg_fft512_core_out_count  (fft_dbg_fft512_core_out_count),
    .o_dbg_fft512_out_stream_count(fft_dbg_fft512_out_stream_count),
    .o_dbg_fft512_run_cycle_count (fft_dbg_fft512_run_cycle_count),
    .o_dbg_fft512_ready_to_upstream(fft_dbg_fft512_ready_to_upstream),
    .o_dbg_fft512_output_valid    (fft_dbg_fft512_output_valid),
    .o_dbg_fft512_ready_from_downstream(fft_dbg_fft512_ready_from_downstream),
    .o_dbg_mod2_valid             (fft_dbg_mod2_valid),
    .o_dbg_mod2_ready             (fft_dbg_mod2_ready),
    .o_dbg_reorder2_valid         (fft_dbg_reorder2_valid),
    .o_dbg_reorder2_ready         (fft_dbg_reorder2_ready),
    .o_dbg_reorder2_wr_buf_ptr    (fft_dbg_reorder2_wr_buf_ptr),
    .o_dbg_reorder2_rd_buf_ptr    (fft_dbg_reorder2_rd_buf_ptr),
    .o_dbg_reorder2_wr_addr       (fft_dbg_reorder2_wr_addr),
    .o_dbg_reorder2_rd_issue_count(fft_dbg_reorder2_rd_issue_count),
    .o_dbg_reorder2_rd_send_count (fft_dbg_reorder2_rd_send_count),
    .o_dbg_reorder2_buf_full      (fft_dbg_reorder2_buf_full),
    .o_dbg_reorder2_rd_active     (fft_dbg_reorder2_rd_active),
    .o_dbg_reorder2_out_valid     (fft_dbg_reorder2_out_valid),
    .o_dbg_reorder2_rsp_valid     (fft_dbg_reorder2_rsp_valid),
    .o_dbg_reorder2_input_ready   (fft_dbg_reorder2_input_ready),
    .o_dbg_fft1024_state          (fft_dbg_fft1024_state),
    .o_dbg_fft1024_collect_count  (fft_dbg_fft1024_collect_count),
    .o_dbg_fft1024_feed_sent_count(fft_dbg_fft1024_feed_sent_count),
    .o_dbg_fft1024_core_out_count (fft_dbg_fft1024_core_out_count),
    .o_dbg_fft1024_out_stream_count(fft_dbg_fft1024_out_stream_count),
    .o_dbg_fft1024_run_cycle_count(fft_dbg_fft1024_run_cycle_count),
    .o_dbg_fft1024_ready_to_upstream(fft_dbg_fft1024_ready_to_upstream),
    .o_dbg_fft1024_output_valid   (fft_dbg_fft1024_output_valid),
    .o_dbg_fft1024_ready_from_downstream(fft_dbg_fft1024_ready_from_downstream),
    .o_dbg_ifft_raw_output_valid  (fft_dbg_ifft_raw_output_valid),
    .o_dbg_ifft_out_stage_ready   (fft_dbg_ifft_out_stage_ready),
    .o_dbg_ifft_temp_data_valid   (fft_dbg_ifft_temp_data_valid),
    .o_dbg_hs_ifft_mod1           (fft_dbg_hs_ifft_mod1),
    .o_dbg_hs_mod1_reorder1       (fft_dbg_hs_mod1_reorder1),
    .o_dbg_hs_reorder1_trans      (fft_dbg_hs_reorder1_trans),
    .o_dbg_hs_trans_fft512        (fft_dbg_hs_trans_fft512),
    .o_dbg_hs_fft512_mod2         (fft_dbg_hs_fft512_mod2),
    .o_dbg_hrrp_first_pair        (fft_dbg_hrrp_first_pair),
    .o_dbg_hrrp_last_pair         (fft_dbg_hrrp_last_pair),
    .o_dbg_hrrp_max_abs_pair      (fft_dbg_hrrp_max_abs_pair),
    .o_dbg_hrrp_nonzero_count     (fft_dbg_hrrp_nonzero_count),
    .o_dbg_transpose_first_pair   (fft_dbg_transpose_first_pair),
    .o_dbg_transpose_last_pair    (fft_dbg_transpose_last_pair),
    .o_dbg_transpose_max_abs_pair (fft_dbg_transpose_max_abs_pair),
    .o_dbg_transpose_nonzero_count(fft_dbg_transpose_nonzero_count),
    .o_dbg_fft512_first_pair      (fft_dbg_fft512_first_pair),
    .o_dbg_fft512_last_pair       (fft_dbg_fft512_last_pair),
    .o_dbg_fft512_max_abs_pair    (fft_dbg_fft512_max_abs_pair),
    .o_dbg_fft512_nonzero_count   (fft_dbg_fft512_nonzero_count),
    .o_dbg_mod2_first_pair        (fft_dbg_mod2_first_pair),
    .o_dbg_mod2_last_pair         (fft_dbg_mod2_last_pair),
    .o_dbg_mod2_max_abs_pair      (fft_dbg_mod2_max_abs_pair),
    .o_dbg_mod2_nonzero_count     (fft_dbg_mod2_nonzero_count),
    .o_dbg_out_first_pair         (fft_dbg_out_first_pair),
    .o_dbg_out_last_pair          (fft_dbg_out_last_pair),
    .o_dbg_out_max_abs_pair       (fft_dbg_out_max_abs_pair),
    .o_dbg_out_nonzero_count      (fft_dbg_out_nonzero_count),
    .o_dbg_sram_wr_first_data     (fft_dbg_sram_wr_first_data),
    .o_dbg_sram_wr_last_data      (fft_dbg_sram_wr_last_data),
    .o_dbg_sram_wr_nonzero_count  (fft_dbg_sram_wr_nonzero_count),
    .o_dbg_sram_wr_event_count    (fft_dbg_sram_wr_event_count),
    .o_dbg_sram_wr_first_addr     (fft_dbg_sram_wr_first_addr),
    .o_dbg_sram_wr_last_addr      (fft_dbg_sram_wr_last_addr),
    .o_dbg_sram_rd_first_data     (fft_dbg_sram_rd_first_data),
    .o_dbg_sram_rd_last_data      (fft_dbg_sram_rd_last_data),
    .o_dbg_sram_rd_nonzero_count  (fft_dbg_sram_rd_nonzero_count),
    .o_dbg_sram_rd_event_count    (fft_dbg_sram_rd_event_count),
    .o_dbg_sram_rd_first_addr     (fft_dbg_sram_rd_first_addr),
    .o_dbg_sram_rd_last_addr      (fft_dbg_sram_rd_last_addr)
);


// [修改] 移除了矩阵转置模块，2DFFT直连MagWriter
/*
//-----------------------------------------------------------------------------
// 2DFFT Output Transpose: 1024x512 -> 512x1024 (for MagWriter) - 已移�?
//-----------------------------------------------------------------------------
matrix_transpose_ideal #(
    .DATA_WIDTH  (DATA_WIDTH * 2),
    .ROW_SIZE    (NR),
    .COL_SIZE    (NA)
) u_transpose_to_mag_writer (
    .clk               (clk),
    .rst_n             (rst_n),
    .data_in           ({fft_2d_result_real, fft_2d_result_imag}),
    .data_in_valid     (fft_2d_result_valid),
    .ready_for_input   (transpose_ready_for_input),
    .data_out          (transpose_out_data),
    .data_out_valid    (transpose_out_valid),
    .ready_for_output  (mw_imird_ready)
);
*/

// 直连: 2DFFT 输出缩放后送模长写 DDR（无转置�?
wire signed [19:0] expanded_real = $signed(fft_2d_result_real) <<< MAG_SCALE_LEFT_SHIFT;
wire signed [19:0] expanded_imag = $signed(fft_2d_result_imag) <<< MAG_SCALE_LEFT_SHIFT;

// 饱和截断逻辑：如果超过了 int16 的最大�?32767，则强行固定�?32767
assign mw_in_real = (expanded_real > 32767)  ? 16'sh7FFF :
                          (expanded_real < -32768) ? 16'sh8000 :
                          expanded_real[15:0];

assign mw_in_imag = (expanded_imag > 32767)  ? 16'sh7FFF :
                          (expanded_imag < -32768) ? 16'sh8000 :
                          expanded_imag[15:0];
assign mw_imird_valid = fft_2d_result_valid && mw_frame_gate;
assign mw_imird_ready = mw_imird_ready_internal && mw_frame_gate;
assign mw_frame_start_hs = fft_2d_result_valid &&
                                 mw_imird_ready &&
                                 !o_mw_active &&
                                 mw_can_start_frame;
assign fft_2coord_hs = fft_2d_result_valid && mw_imird_ready;

//-----------------------------------------------------------------------------
// Magnitude Writer Module
//-----------------------------------------------------------------------------
generate
    if (USE_MAG_EXT_SRAM) begin : gen_mag_sram
        mag_ext_sram_pingpong #(
            .MAG_ADDR_WIDTH (MAG_RAM_ADDR_WIDTH),
            .FRAME_WORDS    (TOTAL_OUTPUT),
            .REQ_TAG_WIDTH  (6),
            .SRAM_ADDR_WIDTH(19),
            .USE_SINGLE_CLOCK_CTRL(MAG_SRAM_SINGLE_CLOCK_CTRL)
        ) u_mag_ext_sram_pingpong (
            .clk            (clk),
            .sram_clk       (sram_clk),
            .rst_n          (mag_sram_clk_rst_n),
            .sram_rst_n     (mag_sram_rst_n),
            .wr_bank_sel    (mw_mag_bank_sel),
            .rd_bank_sel    (interp2_mag_bank_sel),
            .i_imird_valid  (mw_imird_valid),
            .i_imird_real   (mw_in_real),
            .i_imird_imag   (mw_in_imag),
            .o_imird_ready  (mw_imird_ready_internal),
            .mw_active      (o_mw_active),
            .debug_mag_valid(mw_debug_mag_valid),
            .debug_mag_data (mw_debug_mag_data),
            .mag_overflow   (mw_mag_overflow),
            .mag_store_done (mw_mag_store_done),
            .mag_write_count(mw_mag_write_count),
            .req_valid      (interp2_read_req_valid),
            .req_ready      (interp2_read_req_ready),
            .req_addr       (interp2_read_req_addr),
            .req_burst2     (interp2_read_req_burst2),
            .req_len        (interp2_read_req_len),
            .req_tag        (interp2_read_req_tag),
            .rsp_valid      (interp2_read_rsp_valid),
            .rsp_ready      (interp2_read_rsp_ready),
            .rsp_data       (interp2_read_rsp_data),
            .rsp_tag        (interp2_read_rsp_tag),
            .sram_WE_n      (mag_sram_WE_n),
            .sram_CE_n      (mag_sram_CE_n),
            .sram_CE_2      (mag_sram_CE_2),
            .sram_OE_n      (mag_sram_OE_n),
            .sram_addr      (mag_sram_addr),
            .sram_data      (sram_data),
            .debug_ro0      (mag_sram_debug_ro0),
            .debug_ro1      (mag_sram_debug_ro1),
            .debug_ro2      (mag_sram_debug_ro2),
            .debug_ro3      (mag_sram_debug_ro3)
        );
        assign mw_mag_awaddr = {AXI_ADDR_WIDTH{1'b0}};
        assign mw_mag_awlen = 8'd0;
        assign mw_mag_awsize = 3'd0;
        assign mw_mag_awburst = 2'd0;
        assign mw_mag_awvalid = 1'b0;
        assign mw_mag_wdata = {AXI_DATA_WIDTH{1'b0}};
        assign mw_mag_wstrb = {AXI_STRB_WIDTH{1'b0}};
        assign mw_mag_wlast = 1'b0;
        assign mw_mag_wvalid = 1'b0;
        assign mw_mag_bready = 1'b0;
    end else begin : gen_mag_axi
        assign mag_sram_WE_n = 1'b1;
        assign mag_sram_CE_n = 1'b1;
        assign mag_sram_CE_2 = 1'b0;
        assign mag_sram_OE_n = 1'b1;
        assign mag_sram_addr = 19'd0;
        assign mag_sram_debug_ro0 = 32'd0;
        assign mag_sram_debug_ro1 = 32'd0;
        assign mag_sram_debug_ro2 = 32'd0;
        assign mag_sram_debug_ro3 = 32'd0;
        mag_writer_axi_full #(
            .AXI_ADDR_WIDTH             (AXI_ADDR_WIDTH),
            .AXI_DATA_WIDTH             (AXI_DATA_WIDTH),
            .AXI_STRB_WIDTH             (AXI_STRB_WIDTH),
            .MAG_ADDR_WIDTH             (MAG_RAM_ADDR_WIDTH),
            .MAG_FIFO_DEPTH             (64),
            .FRAME_WORDS                (TOTAL_OUTPUT)
        ) u_mag_writer_axi_full (
            .clk                        (clk),
            .rst_n                      (rst_n),
            .i_mag_base_addr            (mw_mag_base_addr_reg),
            .i_imird_valid              (mw_imird_valid),
            .i_imird_real               (mw_in_real),
            .i_imird_imag               (mw_in_imag),
            .o_imird_ready              (mw_imird_ready_internal),
            .mw_active                  (o_mw_active),
            .m_axi_awaddr               (mw_mag_awaddr),
            .m_axi_awlen                (mw_mag_awlen),
            .m_axi_awsize               (mw_mag_awsize),
            .m_axi_awburst              (mw_mag_awburst),
            .m_axi_awvalid              (mw_mag_awvalid),
            .m_axi_awready              (m_axi_mag_awready),
            .m_axi_wdata                (mw_mag_wdata),
            .m_axi_wstrb                (mw_mag_wstrb),
            .m_axi_wlast                (mw_mag_wlast),
            .m_axi_wvalid               (mw_mag_wvalid),
            .m_axi_wready               (m_axi_mag_wready),
            .m_axi_bresp                (m_axi_mag_bresp),
            .m_axi_bvalid               (m_axi_mag_bvalid),
            .m_axi_bready               (mw_mag_bready),
            .debug_sqrt_valid           (mw_debug_sqrt_valid),
            .debug_sqrt_data            (mw_debug_sqrt_data),
            .debug_mag_valid            (mw_debug_mag_valid),
            .debug_mag_data             (mw_debug_mag_data),
            .mag_overflow               (mw_mag_overflow),
            .mag_store_done             (mw_mag_store_done),
            .mag_write_count            (mw_mag_write_count)
        );
    end
endgenerate

// Debug signals �?internal only (no longer top-level ports)
wire o_mag_valid = mw_debug_mag_valid;
wire [DATA_WIDTH-1:0] o_mag_q115 = mw_debug_mag_data;

//-----------------------------------------------------------------------------
// Interp2 Module (AXI mag read, AXIS descriptor input)
//-----------------------------------------------------------------------------
wire [63:0] interp_desc_tdata;
wire interp_desc_tvalid, interp_desc_tready, interp_desc_tlast;
wire [7:0] interp_desc_tkeep;
wire interp_desc_tuser;
wire pl_iw_cfg_error;
wire [8:0] pl_iw_active_v_q4;

// v1.1: every frame starts with a velocity header; remaining words are fixed
// geometry metadata. Only generated descriptors reach either interp2 branch.
sar_pl_iw_generator #(
    .NA(NA),
    .Q_SCALE_PER_VQ4_Q14(PL_IW_Q_SCALE_PER_VQ4_Q14)
) u_pl_iw_generator (
    .clk(clk), .rst_n(rst_n),
    .s_axis_tdata(s_axis_index_weight_tdata),
    .s_axis_tvalid(s_axis_index_weight_tvalid),
    .s_axis_tready(s_axis_index_weight_tready),
    .s_axis_tlast(s_axis_index_weight_tlast),
    .s_axis_tkeep(s_axis_index_weight_tkeep),
    .s_axis_tuser(s_axis_index_weight_tuser),
    .m_axis_tdata(interp_desc_tdata),
    .m_axis_tvalid(interp_desc_tvalid),
    .m_axis_tready(interp_desc_tready),
    .m_axis_tlast(interp_desc_tlast),
    .m_axis_tkeep(interp_desc_tkeep),
    .m_axis_tuser(interp_desc_tuser),
    .cfg_error(pl_iw_cfg_error), .active_v_q4(pl_iw_active_v_q4)
);

generate
    if (USE_MAG_EXT_SRAM) begin : gen_interp2_sram
        interp2_axi_core #(
            .MAG_ADDR_WIDTH       (MAG_RAM_ADDR_WIDTH),
            .MAG_NR               (NR),
            .MAG_NA               (NA),
            .DESC_FIFO_DEPTH      (256),
            .OUT_FIFO_DEPTH       (64),
            .SAMPLE_CACHE_DEPTH   (512),
            .ENABLE_BURST2        (1),
            .REQ_TAG_WIDTH        (6),
            .DEBUG_COUNTER_WIDTH  (24)
        ) u_interp2_sram_core (
            .clk                  (clk),
            .rst_n                (rst_n),
            .interp2_start        (interp2_start_internal),
            .interp2_done         (interp2_done_internal),
            .busy                 (interp2_busy_internal),
            .s_axis_tdata         (interp_desc_tdata),
            .s_axis_tvalid        (interp_desc_tvalid),
            .s_axis_tready        (interp_desc_tready),
            .s_axis_tlast         (interp_desc_tlast),
            .s_axis_tkeep         (interp_desc_tkeep),
            .s_axis_tuser         (interp_desc_tuser),
            .m_axis_tdata         (m_axis_interp2_tdata),
            .m_axis_tvalid        (m_axis_interp2_tvalid),
            .m_axis_tready        (interp2_m_ready_combined),
            .m_axis_tlast         (m_axis_interp2_tlast),
            .m_axis_tkeep         (m_axis_interp2_tkeep),
            .read_req_valid       (interp2_read_req_valid),
            .read_req_ready       (interp2_read_req_ready),
            .read_req_addr        (interp2_read_req_addr),
            .read_req_burst2      (interp2_read_req_burst2),
            .read_req_len         (interp2_read_req_len),
            .read_req_tag         (interp2_read_req_tag),
            .read_rsp_valid       (interp2_read_rsp_valid),
            .read_rsp_ready       (interp2_read_rsp_ready),
            .read_rsp_data        (interp2_read_rsp_data),
            .read_rsp_tag         (interp2_read_rsp_tag),
            .debug_ro0            (interp2_debug_ro0),
            .debug_ro1            (interp2_debug_ro1),
            .debug_ro2            (interp2_debug_ro2),
            .debug_ro3            (interp2_debug_ro3),
            .debug_ro4            (interp2_debug_ro4),
            .debug_ro5            (interp2_debug_ro5),
            .debug_ro6            (interp2_debug_ro6),
            .debug_ro7            (interp2_debug_ro7)
        );
        assign interp2_mag_araddr = {AXI_ADDR_WIDTH{1'b0}};
        assign interp2_mag_arlen = 8'd0;
        assign interp2_mag_arsize = 3'd0;
        assign interp2_mag_arburst = 2'd0;
        assign interp2_mag_arvalid = 1'b0;
        assign interp2_mag_rready = 1'b0;
    end else begin : gen_interp2_axi
        interp2_axi_top #(
            .AXI_ADDR_WIDTH             (AXI_ADDR_WIDTH),
            .AXI_DATA_WIDTH             (AXI_DATA_WIDTH),
            .MAG_ADDR_WIDTH             (MAG_RAM_ADDR_WIDTH),
            .MAG_NR                     (NR),
            .MAG_NA                     (NA),
            .DESC_FIFO_DEPTH            (64),
            .OUT_FIFO_DEPTH             (64),
            .SAMPLE_CACHE_DEPTH         (2048),
            .DEBUG_COUNTER_WIDTH        (24)
        ) u_interp2_axi (
            .clk                        (clk),
            .rst_n                      (rst_n),
            .mag_base_addr              (interp2_mag_base_addr_reg),
            .interp2_start              (interp2_start_internal),
            .interp2_done               (interp2_done_internal),
            .busy                       (interp2_busy_internal),
            .s_axis_tdata               (interp_desc_tdata),
            .s_axis_tvalid              (interp_desc_tvalid),
            .s_axis_tready              (interp_desc_tready),
            .s_axis_tlast               (interp_desc_tlast),
            .s_axis_tkeep               (interp_desc_tkeep),
            .s_axis_tuser               (interp_desc_tuser),
            .m_axis_tdata               (m_axis_interp2_tdata),
            .m_axis_tvalid              (m_axis_interp2_tvalid),
            .m_axis_tready              (interp2_m_ready_combined),
            .m_axis_tlast               (m_axis_interp2_tlast),
            .m_axis_tkeep               (m_axis_interp2_tkeep),
            .m_axi_araddr               (interp2_mag_araddr),
            .m_axi_arlen                (interp2_mag_arlen),
            .m_axi_arsize               (interp2_mag_arsize),
            .m_axi_arburst              (interp2_mag_arburst),
            .m_axi_arvalid              (interp2_mag_arvalid),
            .m_axi_arready              (m_axi_mag_arready),
            .m_axi_rdata                (m_axi_mag_rdata),
            .m_axi_rresp                (m_axi_mag_rresp),
            .m_axi_rlast                (m_axi_mag_rlast),
            .m_axi_rvalid               (m_axi_mag_rvalid),
            .m_axi_rready               (interp2_mag_rready)
        );
        assign interp2_debug_ro0 = 32'd0;
        assign interp2_debug_ro1 = 32'd0;
        assign interp2_debug_ro2 = 32'd0;
        assign interp2_debug_ro3 = 32'd0;
        assign interp2_debug_ro4 = 32'd0;
        assign interp2_debug_ro5 = 32'd0;
        assign interp2_debug_ro6 = 32'd0;
        assign interp2_debug_ro7 = 32'd0;
    end
endgenerate

//-----------------------------------------------------------------------------
// Post-processing module (gamma + frame-level TLAST) in top-level dataflow
//-----------------------------------------------------------------------------
sar_postproc_gamma_stream u_sar_postproc_gamma_stream (
    .clk            (clk),
    .rst_n          (rst_n),
    .i_ny           (post_cfg_ny_shadow),
    .i_nx           (post_cfg_nx_shadow),
    .s_axis_tdata   (m_axis_interp2_tdata),
    .s_axis_tvalid  (m_axis_interp2_tvalid),
    .s_axis_tready  (post_s_axis_tready),
    .s_axis_tlast   (m_axis_interp2_tlast),
    .m_axis_tdata   (post_m_axis_image_tdata),
    .m_axis_tvalid  (post_m_axis_image_tvalid),
    .m_axis_tready  (m_axis_image_tready),
    .m_axis_tlast   (post_m_axis_image_tlast)
);

// Keep raw interp2 stream externally visible while feeding postproc.
// Interp2 advances only when both sinks are ready.
assign interp2_m_ready_combined = m_axis_interp2_tready & post_s_axis_tready;

//-----------------------------------------------------------------------------
// Output Assignments
//-----------------------------------------------------------------------------
assign echo_to_fft_valid = debug_image_loopback_enable ? 1'b0 : s_axis_echo_tvalid;

// S_AXIS_ECHO �?gated by ps_init_done. In debug loopback mode the consumer is
// the final image DMA path instead of the FFT pipeline, so ready follows the
// image sink backpressure directly.
assign s_axis_echo_tready = debug_image_loopback_enable
                          ? (m_axis_image_tready & i_ps_init_done)
                          : (fft_2d_echo_ready & i_ps_init_done);

// M_AXIS_FFT (debug checkpoint)
// Export only samples that were actually accepted by mag_writer so stage dumps
// reflect the committed FFT->mag_writer stream under backpressure.
// FFT debug tap �?internal only (no longer a top-level port)
wire [DATA_WIDTH*2-1:0] m_axis_fft_tdata = {fft_2d_result_real, fft_2d_result_imag};
wire m_axis_fft_tvalid = fft_2coord_hs;
wire m_axis_fft_tlast  = 1'b0;
wire [DATA_WIDTH*2/8-1:0] m_axis_fft_tkeep = {(DATA_WIDTH*2/8){1'b1}};

// M_AXIS_IMAGE tkeep �?always all-valid
assign m_axis_image_tkeep  = 2'b11;

assign loopback_image_valid = debug_image_loopback_enable && i_ps_init_done && s_axis_echo_tvalid;
assign loopback_image_last  = debug_image_loopback_enable && s_axis_echo_tlast;

// The loopback payload intentionally uses the low 16-bit lane of the incoming
// 32-bit echo word. PS fills that lane with the expected pattern, so image DMA
// readback can be checked without needing a width-conversion buffer in PL.
assign m_axis_image_tdata  = debug_image_loopback_enable
                           ? s_axis_echo_tdata[DATA_WIDTH-1:0]
                           : post_m_axis_image_tdata;
assign m_axis_image_tvalid = debug_image_loopback_enable
                           ? loopback_image_valid
                           : post_m_axis_image_tvalid;
assign m_axis_image_tlast  = debug_image_loopback_enable
                           ? loopback_image_last
                           : post_m_axis_image_tlast;

// [修改] 2D-FFT 的下游现在直接是 MagWriter
generate
if (ENABLE_HDMI_DDR_PREVIEW) begin : gen_hdmi_ddr_preview
sar_hdmi_ddr_preview #(
    .AXI_ADDR_WIDTH        (AXI_ADDR_WIDTH),
    .AXI_DATA_WIDTH        (AXI_DATA_WIDTH),
    .AXI_STRB_WIDTH        (AXI_STRB_WIDTH),
    .AXI_ID_WIDTH          (AXI_ID_WIDTH),
    .DISPLAY_BASE_ADDR     (32'h0800_0000),
    .DISPLAY_SLOT_STRIDE   (32'h0012_7800),
    .DISPLAY_W             (1024),
    .DISPLAY_H             (591),
    .H_VISIBLE             (1024),
    .H_FRONT               (24),
    .H_SYNC                (136),
    .H_BACK                (160),
    .V_VISIBLE             (768),
    .V_FRONT               (3),
    .V_SYNC                (6),
    .V_BACK                (29)
) u_sar_hdmi_preview (
    .axi_clk       (clk),
    .pix_clk       (hdmi_pix_clk),
    .ser_clk       (hdmi_ser_clk),
    .rst_n         (rst_n),
    .ctrl          (hdmi_ctrl),
    .cfg_display_w (hdmi_cfg_display_w),
    .cfg_display_h (hdmi_cfg_display_h),
    .cfg_stretch_knee(hdmi_cfg_stretch_knee),
    .cfg_stretch_gain_q8(hdmi_cfg_stretch_gain_q8),
    .status        (hdmi_debug_status),
    .m_axi_awid    (m_axi_hdmi_awid),
    .m_axi_awaddr  (m_axi_hdmi_awaddr),
    .m_axi_awlen   (m_axi_hdmi_awlen),
    .m_axi_awsize  (m_axi_hdmi_awsize),
    .m_axi_awburst (m_axi_hdmi_awburst),
    .m_axi_awlock  (m_axi_hdmi_awlock),
    .m_axi_awcache (m_axi_hdmi_awcache),
    .m_axi_awprot  (m_axi_hdmi_awprot),
    .m_axi_awvalid (m_axi_hdmi_awvalid),
    .m_axi_awready (m_axi_hdmi_awready),
    .m_axi_wdata   (m_axi_hdmi_wdata),
    .m_axi_wstrb   (m_axi_hdmi_wstrb),
    .m_axi_wlast   (m_axi_hdmi_wlast),
    .m_axi_wvalid  (m_axi_hdmi_wvalid),
    .m_axi_wready  (m_axi_hdmi_wready),
    .m_axi_bid     (m_axi_hdmi_bid),
    .m_axi_bresp   (m_axi_hdmi_bresp),
    .m_axi_bvalid  (m_axi_hdmi_bvalid),
    .m_axi_bready  (m_axi_hdmi_bready),
    .m_axi_arid    (m_axi_hdmi_arid),
    .m_axi_araddr  (m_axi_hdmi_araddr),
    .m_axi_arlen   (m_axi_hdmi_arlen),
    .m_axi_arsize  (m_axi_hdmi_arsize),
    .m_axi_arburst (m_axi_hdmi_arburst),
    .m_axi_arlock  (m_axi_hdmi_arlock),
    .m_axi_arcache (m_axi_hdmi_arcache),
    .m_axi_arprot  (m_axi_hdmi_arprot),
    .m_axi_arvalid (m_axi_hdmi_arvalid),
    .m_axi_arready (m_axi_hdmi_arready),
    .m_axi_rid     (m_axi_hdmi_rid),
    .m_axi_rdata   (m_axi_hdmi_rdata),
    .m_axi_rresp   (m_axi_hdmi_rresp),
    .m_axi_rlast   (m_axi_hdmi_rlast),
    .m_axi_rvalid  (m_axi_hdmi_rvalid),
    .m_axi_rready  (m_axi_hdmi_rready),
    .hdmi_d_p      (hdmi_d_p),
    .hdmi_d_n      (hdmi_d_n),
    .hdmi_clk_p    (hdmi_clk_p),
    .hdmi_clk_n    (hdmi_clk_n)
);
end else begin : gen_no_hdmi_ddr_preview
    assign hdmi_debug_status = 32'h4844_4D30; // "HDM0": preview disabled
    assign m_axi_hdmi_awid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_hdmi_awaddr  = {AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_hdmi_awlen   = 8'd0;
    assign m_axi_hdmi_awsize  = 3'b010;
    assign m_axi_hdmi_awburst = 2'b01;
    assign m_axi_hdmi_awlock  = 1'b0;
    assign m_axi_hdmi_awcache = 4'b0011;
    assign m_axi_hdmi_awprot  = 3'b000;
    assign m_axi_hdmi_awvalid = 1'b0;
    assign m_axi_hdmi_wdata   = {AXI_DATA_WIDTH{1'b0}};
    assign m_axi_hdmi_wstrb   = {AXI_STRB_WIDTH{1'b0}};
    assign m_axi_hdmi_wlast   = 1'b0;
    assign m_axi_hdmi_wvalid  = 1'b0;
    assign m_axi_hdmi_bready  = 1'b1;
    assign m_axi_hdmi_arid    = {AXI_ID_WIDTH{1'b0}};
    assign m_axi_hdmi_araddr  = {AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_hdmi_arlen   = 8'd0;
    assign m_axi_hdmi_arsize  = 3'b010;
    assign m_axi_hdmi_arburst = 2'b01;
    assign m_axi_hdmi_arlock  = 1'b0;
    assign m_axi_hdmi_arcache = 4'b0011;
    assign m_axi_hdmi_arprot  = 3'b000;
    assign m_axi_hdmi_arvalid = 1'b0;
    assign m_axi_hdmi_rready  = 1'b0;
    assign hdmi_d_p           = 3'b000;
    assign hdmi_d_n           = 3'b000;
    assign hdmi_clk_p         = 1'b0;
    assign hdmi_clk_n         = 1'b0;
end
endgenerate

assign fft_2d_downstream_ready = mw_imird_ready;
assign image_out_last_hs = m_axis_image_tvalid && m_axis_image_tready && m_axis_image_tlast;

sar_perf_counters #(
    .COUNTER_WIDTH (32),
    .FRAME_WORDS   (TOTAL_OUTPUT)
) u_sar_perf_counters (
    .clk                               (clk),
    .rst_n                             (rst_n),
    .i_frame_start                     (perf_frame_start_hs),
    .i_frame_done                      (image_out_last_hs),
    .i_fft_in_hs                       (echo_in_hs),
    .i_fft_out_hs                      (fft_2coord_hs),
    .i_fft_in_stall                    (fft_in_stall),
    .i_fft_out_stall                   (fft_out_stall),
    .i_fft_trans_aw_stall              (fft_trans_aw_stall),
    .i_fft_trans_w_stall               (fft_trans_w_stall),
    .i_fft_trans_ar_stall              (fft_trans_ar_stall),
    .i_fft_trans_r_wait                (fft_trans_r_wait),
    .i_mw_start                        (mw_frame_start_hs),
    .i_mw_done                         (mag_write_complete_rise),
    .i_mw_active                       (o_mw_active),
    .i_coord_wait_prev_interp2         (coord_wait_prev_interp2),
    .i_coord_aw_stall                  (coord_aw_stall),
    .i_coord_w_stall                   (coord_w_stall),
    .i_coord_mag_write_count           (mag_wr_count),
    .i_interp2_start                   (interp2_start_internal),
    .i_interp2_done                    (interp2_done_internal),
    .i_interp2_busy                    (interp2_busy_internal),
    .i_interp2_wait_ps                 (interp2_wait_ps),
    .i_interp2_wait_desc               (interp2_wait_desc),
    .i_interp2_ar_stall                (interp2_ar_stall),
    .i_interp2_r_wait                  (interp2_r_wait),
    .i_interp2_out_hs                  (interp2_out_hs),
    .i_interp2_out_stall               (interp2_out_stall),
    .i_post_start                      (perf_post_start_hs),
    .i_post_out_hs                     (image_out_hs),
    .i_post_out_stall                  (post_out_stall),
    .o_snapshot_status                 (perf_snapshot_status),
    .o_frame_seq                       (perf_frame_seq),
    .o_frame_cycles                    (perf_frame_cycles),
    .o_fft_cycles                      (perf_fft_cycles),
    .o_mw_cycles                 (perf_mw_cycles),
    .o_interp2_cycles                  (perf_interp2_cycles),
    .o_postproc_cycles                 (perf_postproc_cycles),
    .o_fft_input_stall_cycles          (perf_fft_input_stall_cycles),
    .o_fft_output_stall_cycles         (perf_fft_output_stall_cycles),
    .o_fft_trans_aw_stall_cycles       (perf_fft_trans_aw_stall_cycles),
    .o_fft_trans_w_stall_cycles        (perf_fft_trans_w_stall_cycles),
    .o_fft_trans_ar_stall_cycles       (perf_fft_trans_ar_stall_cycles),
    .o_fft_trans_r_wait_cycles         (perf_fft_trans_r_wait_cycles),
    .o_coord_wait_prev_interp2_cycles  (perf_coord_wait_prev_interp2_cycles),
    .o_coord_active_cycles             (perf_coord_active_cycles),
    .o_coord_aw_stall_cycles           (perf_coord_aw_stall_cycles),
    .o_coord_w_stall_cycles            (perf_coord_w_stall_cycles),
    .o_interp2_wait_ps_cycles          (perf_interp2_wait_ps_cycles),
    .o_interp2_busy_cycles             (perf_interp2_busy_cycles),
    .o_interp2_wait_desc_cycles        (perf_interp2_wait_desc_cycles),
    .o_interp2_ar_stall_cycles         (perf_interp2_ar_stall_cycles),
    .o_interp2_r_wait_cycles           (perf_interp2_r_wait_cycles),
    .o_interp2_output_stall_cycles     (perf_interp2_output_stall_cycles),
    .o_postproc_active_cycles          (perf_postproc_active_cycles),
    .o_postproc_output_stall_cycles    (perf_postproc_output_stall_cycles),
    .o_fft_output_count                (perf_fft_output_count),
    .o_coord_mag_write_count           (perf_coord_mag_write_count),
    .o_interp2_output_count            (perf_interp2_output_count),
    .o_postproc_output_count           (perf_postproc_output_count),
    .o_fft_done_offset_cycles          (perf_fft_done_offset_cycles),
    .o_mw_start_offset_cycles          (perf_mw_start_offset_cycles),
    .o_mw_done_offset_cycles           (perf_mw_done_offset_cycles),
    .o_interp2_start_offset_cycles     (perf_interp2_start_offset_cycles),
    .o_interp2_done_offset_cycles      (perf_interp2_done_offset_cycles),
    .o_post_start_offset_cycles        (perf_post_start_offset_cycles)
);

assign perf_ro_flat[32*0  +: 32] = perf_snapshot_status;
assign perf_ro_flat[32*1  +: 32] = perf_frame_seq;
assign perf_ro_flat[32*2  +: 32] = perf_frame_cycles;
assign perf_ro_flat[32*3  +: 32] = perf_fft_cycles;
assign perf_ro_flat[32*4  +: 32] = perf_mw_cycles;
assign perf_ro_flat[32*5  +: 32] = perf_interp2_cycles;
assign perf_ro_flat[32*6  +: 32] = perf_postproc_cycles;
assign perf_ro_flat[32*7  +: 32] = perf_fft_input_stall_cycles;
assign perf_ro_flat[32*8  +: 32] = perf_fft_output_stall_cycles;
assign perf_ro_flat[32*9  +: 32] = perf_fft_trans_aw_stall_cycles;
assign perf_ro_flat[32*10 +: 32] = perf_fft_trans_w_stall_cycles;
assign perf_ro_flat[32*11 +: 32] = perf_fft_trans_ar_stall_cycles;
assign perf_ro_flat[32*12 +: 32] = perf_fft_trans_r_wait_cycles;
assign perf_ro_flat[32*13 +: 32] = perf_coord_wait_prev_interp2_cycles;
assign perf_ro_flat[32*14 +: 32] = perf_coord_active_cycles;
assign perf_ro_flat[32*15 +: 32] = perf_coord_aw_stall_cycles;
assign perf_ro_flat[32*16 +: 32] = perf_coord_w_stall_cycles;
assign perf_ro_flat[32*17 +: 32] = perf_interp2_wait_ps_cycles;
assign perf_ro_flat[32*18 +: 32] = perf_interp2_busy_cycles;
assign perf_ro_flat[32*19 +: 32] = perf_interp2_wait_desc_cycles;
assign perf_ro_flat[32*20 +: 32] = perf_interp2_ar_stall_cycles;
assign perf_ro_flat[32*21 +: 32] = perf_interp2_r_wait_cycles;
assign perf_ro_flat[32*22 +: 32] = perf_interp2_output_stall_cycles;
assign perf_ro_flat[32*23 +: 32] = perf_postproc_active_cycles;
assign perf_ro_flat[32*24 +: 32] = perf_postproc_output_stall_cycles;
assign perf_ro_flat[32*25 +: 32] = perf_fft_output_count;
assign perf_ro_flat[32*26 +: 32] = perf_coord_mag_write_count;
assign perf_ro_flat[32*27 +: 32] = perf_interp2_output_count;
assign perf_ro_flat[32*28 +: 32] = perf_postproc_output_count;
assign perf_ro_flat[32*29 +: 32] = dbg_interp2_sum_reg;
assign perf_ro_flat[32*30 +: 32] = dbg_interp2_xor_reg;
assign perf_ro_flat[32*31 +: 32] = dbg_interp2_nonzero_reg;
assign perf_ro_flat[32*32 +: 32] = dbg_interp2_first_last_reg;
assign perf_ro_flat[32*33 +: 32] = dbg_post_sum_reg;
assign perf_ro_flat[32*34 +: 32] = dbg_post_xor_reg;
assign perf_ro_flat[32*35 +: 32] = dbg_post_nonzero_reg;
assign perf_ro_flat[32*36 +: 32] = dbg_post_first_last_reg;
assign perf_ro_flat[32*37 +: 32] = interp2_debug_ro3;
assign perf_ro_flat[32*38 +: 32] = interp2_debug_ro4;
assign perf_ro_flat[32*39 +: 32] = interp2_debug_ro5;
assign perf_ro_flat[32*40 +: 32] = interp2_debug_ro6;
assign perf_ro_flat[32*41 +: 32] = interp2_debug_ro7;
assign perf_ro_flat[32*42 +: 32] = perf_fft_done_offset_cycles;
assign perf_ro_flat[32*43 +: 32] = perf_mw_start_offset_cycles;
assign perf_ro_flat[32*44 +: 32] = perf_mw_done_offset_cycles;
assign perf_ro_flat[32*45 +: 32] = perf_interp2_start_offset_cycles;
assign perf_ro_flat[32*46 +: 32] = perf_interp2_done_offset_cycles;
assign perf_ro_flat[32*47 +: 32] = perf_post_start_offset_cycles;
assign perf_ro_flat[32*48 +: 32] = perf_fft1024_collect_cycles_reg;
assign perf_ro_flat[32*49 +: 32] = perf_fft1024_reset_cycles_reg;
assign perf_ro_flat[32*50 +: 32] = perf_fft1024_run_cycles_reg;
assign perf_ro_flat[32*51 +: 32] = perf_fft1024_stream_cycles_reg;
assign perf_ro_flat[32*52 +: 32] = perf_fft512_collect_cycles_reg;
assign perf_ro_flat[32*53 +: 32] = perf_fft512_reset_cycles_reg;
assign perf_ro_flat[32*54 +: 32] = perf_fft512_run_cycles_reg;
assign perf_ro_flat[32*55 +: 32] = perf_fft512_stream_cycles_reg;
assign perf_ro_flat[32*56 +: 32] = perf_fft_transpose_write_cycles_reg;
assign perf_ro_flat[32*57 +: 32] = perf_fft_transpose_turn_cycles_reg;
assign perf_ro_flat[32*58 +: 32] = perf_fft_transpose_read_fill_cycles_reg;
assign perf_ro_flat[32*59 +: 32] = perf_fft_transpose_read_drain_cycles_reg;
assign perf_ro_flat[32*60 +: 32] = perf_fft_transpose_to_fft512_stall_cycles_reg;
assign perf_ro_flat[32*61 +: 32] = perf_fft512_output_stall_detail_cycles_reg;
assign perf_ro_flat[32*62 +: 32] = perf_fft_reorder2_output_stall_cycles_reg;
assign perf_ro_flat[32*63 +: 32] = perf_fft_detail_out_count_reg;

//-----------------------------------------------------------------------------
// System Status Logic
//-----------------------------------------------------------------------------
assign processing_done = processing_done_reg;

// Frame FSM placeholders �?will be replaced by real FSM implementation
assign frame_idle      = frame_idle_internal;
assign frame_state     = 4'd0;  // TODO: drive from frame FSM
assign irq_frame_done  = image_out_last_hs; // single-cycle pulse

always @(posedge clk) begin
    if (!rst_n)
        processing_started <= 1'b0;
    else if (s_axis_echo_tvalid && s_axis_echo_tready)
        processing_started <= 1'b1;
end

always @(posedge clk) begin
    if (!rst_n) begin
        processing_done_reg <= 1'b0;
    end else if (s_axis_echo_tvalid && s_axis_echo_tready) begin
        processing_done_reg <= 1'b0;
    end else if (image_out_last_hs) begin
        processing_done_reg <= 1'b1;
    end
end

//-----------------------------------------------------------------------------
// Debug Interface
//-----------------------------------------------------------------------------
`ifdef DEBUG
    wire [31:0] dbg_mag_wr_count = mag_wr_count;
    wire dbg_mag_write_complete = mag_write_complete;
    wire dbg_processing_active = processing_started & ~mag_write_complete;
`endif

//=============================================================================
// S_AXI: Register File
//=============================================================================
sar_imaging_axil_regs #(
    .AXIL_ADDR_WIDTH (AXIL_ADDR_WIDTH),
    .AXIL_DATA_WIDTH (AXIL_DATA_WIDTH),
    .AXIL_STRB_WIDTH (AXIL_STRB_WIDTH),
    .PERF_REG_COUNT  (PERF_REG_COUNT)
) u_axil_regs (
    .aclk             (aclk),
    .aresetn          (aresetn),
    .s_axi_awaddr     (s_axi_awaddr),
    .s_axi_awprot     (s_axi_awprot),
    .s_axi_awvalid    (s_axi_awvalid),
    .s_axi_awready    (s_axi_awready),
    .s_axi_wdata      (s_axi_wdata),
    .s_axi_wstrb      (s_axi_wstrb),
    .s_axi_wvalid     (s_axi_wvalid),
    .s_axi_wready     (s_axi_wready),
    .s_axi_bresp      (s_axi_bresp),
    .s_axi_bvalid     (s_axi_bvalid),
    .s_axi_bready     (s_axi_bready),
    .s_axi_araddr     (s_axi_araddr),
    .s_axi_arprot     (s_axi_arprot),
    .s_axi_arvalid    (s_axi_arvalid),
    .s_axi_arready    (s_axi_arready),
    .s_axi_rdata      (s_axi_rdata),
    .s_axi_rresp      (s_axi_rresp),
    .s_axi_rvalid     (s_axi_rvalid),
    .s_axi_rready     (s_axi_rready),
    .o_cfg_nrm        (post_cfg_nrm),
    .o_cfg_nam        (post_cfg_nam),
    .o_cfg_ny         (post_cfg_ny),
    .o_cfg_nx         (post_cfg_nx),
    .o_cfg_hdmi_w     (hdmi_cfg_display_w),
    .o_cfg_hdmi_h     (hdmi_cfg_display_h),
    .o_cfg_hdmi_stretch_knee(hdmi_cfg_stretch_knee),
    .o_cfg_hdmi_stretch_gain_q8(hdmi_cfg_stretch_gain_q8),
    .o_v_valid        (reg_v_valid),
    .o_v_data         (reg_v_data),
    .o_ps_init_done   (i_ps_init_done),
    .o_ps_im_done     (i_ps_im_done),
    .o_debug_image_loopback_enable(debug_image_loopback_enable),
    .o_hdmi_ctrl      (hdmi_ctrl),
    .i_v_data         (v_ps_pending_data),
    .i_v_push_ready   (v_push_ready_internal),
    .i_v_pending_valid(v_ps_pending_valid),
    .i_v_slot0_valid  (slot0_valid),
    .i_v_slot1_valid  (slot1_valid),
    .i_v_slot0_desc_ready(slot0_desc_ready),
    .i_v_slot1_desc_ready(slot1_desc_ready),
    .i_v_queue_depth  (v_queue_depth),
    .i_v_req_id       (v_ps_pending_req_id),
    .i_mag_write_done (mag_write_complete),
    .i_frame_idle     (frame_idle),
    .i_irq_frame_done (image_out_last_hs),
    .i_dbg_ro0        (dbg_ro0),
    .i_dbg_ro1        (dbg_ro1),
    .i_dbg_ro2        (dbg_ro2),
    .i_dbg_ro3        (dbg_ro3),
    .i_dbg_ro4        (dbg_ro4),
    .i_dbg_ro5        (dbg_ro5),
    .i_dbg_ro6        (dbg_ro6),
    .i_dbg_ro7        (dbg_ro7),
    .i_dbg_ro8        (dbg_ro8),
    .i_perf_ro_flat   (perf_ro_flat),
    .i_pl_iw_status   ({16'h1101, 6'd0, pl_iw_cfg_error, pl_iw_active_v_q4}),
    .i_pl_iw_q_scale  (PL_IW_Q_SCALE_PER_VQ4_Q14)
);

//=============================================================================
// M_AXI_MAG_DDR: mag_writer write + interp2 read
//=============================================================================
assign m_axi_mag_awid    = {AXI_ID_WIDTH{1'b0}};
assign m_axi_mag_awaddr  = USE_MAG_EXT_SRAM ? {AXI_ADDR_WIDTH{1'b0}} : mw_mag_awaddr;
assign m_axi_mag_awlen   = USE_MAG_EXT_SRAM ? 8'd0 : mw_mag_awlen;
assign m_axi_mag_awsize  = USE_MAG_EXT_SRAM ? 3'd0 : mw_mag_awsize;
assign m_axi_mag_awburst = USE_MAG_EXT_SRAM ? 2'd0 : mw_mag_awburst;
assign m_axi_mag_awlock  = 1'b0;
assign m_axi_mag_awcache = 4'b0010;
assign m_axi_mag_awprot  = 3'b000;
assign m_axi_mag_awvalid = USE_MAG_EXT_SRAM ? 1'b0 : mw_mag_awvalid;
assign m_axi_mag_wdata   = USE_MAG_EXT_SRAM ? {AXI_DATA_WIDTH{1'b0}} : mw_mag_wdata;
assign m_axi_mag_wstrb   = USE_MAG_EXT_SRAM ? {AXI_STRB_WIDTH{1'b0}} : mw_mag_wstrb;
assign m_axi_mag_wlast   = USE_MAG_EXT_SRAM ? 1'b0 : mw_mag_wlast;
assign m_axi_mag_wvalid  = USE_MAG_EXT_SRAM ? 1'b0 : mw_mag_wvalid;
assign m_axi_mag_bready  = USE_MAG_EXT_SRAM ? 1'b0 : mw_mag_bready;
assign m_axi_mag_arid    = {AXI_ID_WIDTH{1'b0}};
assign m_axi_mag_araddr  = USE_MAG_EXT_SRAM ? {AXI_ADDR_WIDTH{1'b0}} : interp2_mag_araddr;
assign m_axi_mag_arlen   = USE_MAG_EXT_SRAM ? 8'd0 : interp2_mag_arlen;
assign m_axi_mag_arsize  = USE_MAG_EXT_SRAM ? 3'd0 : interp2_mag_arsize;
assign m_axi_mag_arburst = USE_MAG_EXT_SRAM ? 2'd0 : interp2_mag_arburst;
assign m_axi_mag_arlock  = 1'b0;
assign m_axi_mag_arcache = 4'b0010;
assign m_axi_mag_arprot  = 3'b000;
assign m_axi_mag_arvalid = USE_MAG_EXT_SRAM ? 1'b0 : interp2_mag_arvalid;
assign m_axi_mag_rready  = USE_MAG_EXT_SRAM ? 1'b0 : interp2_mag_rready;

//=============================================================================
// M_AXI_TRANSPOSE_DDR: Connected to fft_2D transpose AXI path
//=============================================================================
assign m_axi_trans_awid    = {AXI_ID_WIDTH{1'b0}};
assign m_axi_trans_awaddr  = trans_axi_awaddr;
assign m_axi_trans_awlen   = trans_axi_awlen;
assign m_axi_trans_awsize  = trans_axi_awsize;
assign m_axi_trans_awburst = trans_axi_awburst;
assign m_axi_trans_awlock  = 1'b0;
assign m_axi_trans_awcache = 4'b0010;
assign m_axi_trans_awprot  = 3'b000;
assign m_axi_trans_awvalid = trans_axi_awvalid;
assign m_axi_trans_wdata   = trans_axi_wdata;
assign m_axi_trans_wstrb   = trans_axi_wstrb;
assign m_axi_trans_wlast   = trans_axi_wlast;
assign m_axi_trans_wvalid  = trans_axi_wvalid;
assign m_axi_trans_bready  = trans_axi_bready;
assign m_axi_trans_arid    = {AXI_ID_WIDTH{1'b0}};
assign m_axi_trans_araddr  = trans_axi_araddr;
assign m_axi_trans_arlen   = trans_axi_arlen;
assign m_axi_trans_arsize  = trans_axi_arsize;
assign m_axi_trans_arburst = trans_axi_arburst;
assign m_axi_trans_arlock  = 1'b0;
assign m_axi_trans_arcache = 4'b0010;
assign m_axi_trans_arprot  = 3'b000;
assign m_axi_trans_arvalid = trans_axi_arvalid;
assign m_axi_trans_rready  = trans_axi_rready;

// The single external SRAM bus is assigned to the random-access MAG path in
// the new storage split. If MAG stays on DDR, the bus remains available for the
// legacy external transpose path.
assign sram_WE_n = USE_MAG_EXT_SRAM ? mag_sram_WE_n : fft_sram_WE_n;
assign sram_CE_n = USE_MAG_EXT_SRAM ? mag_sram_CE_n : fft_sram_CE_n;
assign sram_CE_2 = USE_MAG_EXT_SRAM ? mag_sram_CE_2 : fft_sram_CE_2;
assign sram_OE_n = USE_MAG_EXT_SRAM ? mag_sram_OE_n : fft_sram_OE_n;
assign sram_LB_n = 1'b0;
assign sram_UB_n = 1'b0;
assign sram_addr = USE_MAG_EXT_SRAM ? mag_sram_addr : fft_sram_addr;

endmodule
