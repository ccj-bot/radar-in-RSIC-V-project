`timescale 1ns / 1ps
//-----------------------------------------------------------------------------
// SAR Imaging AXI-Lite Register File
//
// Register map (byte-addressed, 32-bit data):
//   0x00  REG_CFG_ROI_SIZE   R/W  [31:16] nam, [15:0] nrm
//   0x04  REG_STAT_V         RO   [31] v_push_ready, [30] ps_req_valid,
//                                 [29] slot0_valid, [28] slot1_valid,
//                                 [27] slot0_desc_ready, [26] slot1_desc_ready,
//                                 [25:24] queue_depth, [23:16] req_id, [8:0] v_data
//   0x08  REG_STAT_FRAME     RO   [2] frame_idle, [1] mag_write_done, [0] irq_frame_done (W1C)
//   0x0C  REG_CFG_GRID_SIZE  R/W  [31:16] nx, [15:0] ny
//   0x10  REG_V_WRITE        WO   [8:0] v_data — debug V inject, single-cycle pulse
//   0x14  REG_PS_CTRL        R/W  [1] ps_desc_commit, [0] ps_init_done — PS toggles bit[1] for commit pulse
//   0x18  REG_DEBUG_CTRL     R/W  [0] image_loopback_enable,
//                                 [16] hdmi_enable, [10:9] hdmi_slot, [8] hdmi_frame_toggle
//   0x1C~0x3C  REG_DEBUG_RO*  RO   live debug/status registers
//   0x40~0x13C PERF_*         RO   per-frame performance counter snapshots
//   0x140 REG_CFG_HDMI_SIZE    R/W  [31:16] display_h, [15:0] display_w
//   0x148 REG_PL_IW_STATUS      RO   [31:16]=0x1101, [9]=cfg_error, [8:0]=V_Q4
//   0x14C REG_PL_IW_Q_SCALE     RO   compile-time Q14 coefficient per V_Q4
//   0x144 REG_CFG_HDMI_STRETCH R/W  [31:16] gain_q8, [15:0] knee
//
// AXI-Lite state machine pattern follows:
//   rtl/postproc/AXI4_MT_LITE_slave_lite_v1_0_S00_AXI_LITE.v
//-----------------------------------------------------------------------------

module sar_imaging_axil_regs #(
    parameter integer AXIL_ADDR_WIDTH = 16,
    parameter integer AXIL_DATA_WIDTH = 32,
    parameter integer AXIL_STRB_WIDTH = AXIL_DATA_WIDTH / 8,
    parameter integer PERF_REG_COUNT  = 29
) (
    input  wire                         aclk,
    input  wire                         aresetn,

    // AXI-Lite Slave Interface
    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire [2:0]                   s_axi_awprot,
    input  wire                         s_axi_awvalid,
    output wire                         s_axi_awready,
    input  wire [AXIL_DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire [AXIL_STRB_WIDTH-1:0]   s_axi_wstrb,
    input  wire                         s_axi_wvalid,
    output wire                         s_axi_wready,
    output wire [1:0]                   s_axi_bresp,
    output wire                         s_axi_bvalid,
    input  wire                         s_axi_bready,
    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire [2:0]                   s_axi_arprot,
    input  wire                         s_axi_arvalid,
    output wire                         s_axi_arready,
    output wire [AXIL_DATA_WIDTH-1:0]   s_axi_rdata,
    output wire [1:0]                   s_axi_rresp,
    output wire                         s_axi_rvalid,
    input  wire                         s_axi_rready,

    // Config outputs
    output wire [15:0]                  o_cfg_nrm,
    output wire [15:0]                  o_cfg_nam,
    output wire [15:0]                  o_cfg_ny,
    output wire [15:0]                  o_cfg_nx,
    output wire [15:0]                  o_cfg_hdmi_w,
    output wire [15:0]                  o_cfg_hdmi_h,
    output wire [15:0]                  o_cfg_hdmi_stretch_knee,
    output wire [15:0]                  o_cfg_hdmi_stretch_gain_q8,

    // V write-trigger outputs (debug inject into PL V request path)
    output reg                          o_v_valid,      // single-cycle pulse on REG_V_WRITE
    output reg  [8:0]                   o_v_data,

    // PS control outputs
    output wire                         o_ps_init_done, // sticky bit from REG_PS_CTRL[0]
    output wire                         o_ps_im_done,   // software-toggled commit bit from REG_PS_CTRL[1]
    output wire                         o_debug_image_loopback_enable,
    output wire [AXIL_DATA_WIDTH-1:0]   o_hdmi_ctrl,

    // Status inputs
    input  wire [8:0]                   i_v_data,
    input  wire                         i_v_push_ready,
    input  wire                         i_v_pending_valid,
    input  wire                         i_v_slot0_valid,
    input  wire                         i_v_slot1_valid,
    input  wire                         i_v_slot0_desc_ready,
    input  wire                         i_v_slot1_desc_ready,
    input  wire [1:0]                   i_v_queue_depth,
    input  wire [7:0]                   i_v_req_id,
    input  wire                         i_mag_write_done,
    input  wire                         i_frame_idle,
    input  wire                         i_irq_frame_done,   // single-cycle pulse from top
    input  wire [AXIL_DATA_WIDTH-1:0]   i_dbg_ro0,
    input  wire [AXIL_DATA_WIDTH-1:0]   i_dbg_ro1,
    input  wire [AXIL_DATA_WIDTH-1:0]   i_dbg_ro2,
    input  wire [AXIL_DATA_WIDTH-1:0]   i_dbg_ro3,
    input  wire [AXIL_DATA_WIDTH-1:0]   i_dbg_ro4,
    input  wire [AXIL_DATA_WIDTH-1:0]   i_dbg_ro5,
    input  wire [AXIL_DATA_WIDTH-1:0]   i_dbg_ro6,
    input  wire [AXIL_DATA_WIDTH-1:0]   i_dbg_ro7,
    input  wire [AXIL_DATA_WIDTH-1:0]   i_dbg_ro8,
    input  wire [PERF_REG_COUNT*AXIL_DATA_WIDTH-1:0] i_perf_ro_flat,
    input  wire [31:0] i_pl_iw_status,
    input  wire [31:0] i_pl_iw_q_scale
);

wire clk = aclk;
wire rst_n = aresetn;

// Address decode: ADDR_LSB = 2 (byte-addressed, word-aligned)
// Register index = addr[7:2], enough for control + perf snapshot windows.
localparam ADDR_LSB = 2;
localparam REG_IDX_BITS = 7;
localparam [REG_IDX_BITS-1:0] PERF_BASE_IDX = 7'd16;
localparam [REG_IDX_BITS-1:0] CFG_HDMI_SIZE_IDX = 7'd80;
localparam [REG_IDX_BITS-1:0] CFG_HDMI_STRETCH_IDX = 7'd81;

//-------------------------------------------------------------------------
// Write / Read FSM
//-------------------------------------------------------------------------
reg [AXIL_ADDR_WIDTH-1:0] axi_awaddr;
reg                       axi_awready;
reg                       axi_wready;
reg [1:0]                 axi_bresp;
reg                       axi_bvalid;
reg [AXIL_ADDR_WIDTH-1:0] axi_araddr;
reg                       axi_arready;
reg [1:0]                 axi_rresp;
reg                       axi_rvalid;

assign s_axi_awready = axi_awready;
assign s_axi_wready  = axi_wready;
assign s_axi_bresp   = axi_bresp;
assign s_axi_bvalid  = axi_bvalid;
assign s_axi_arready = axi_arready;
assign s_axi_rresp   = axi_rresp;
assign s_axi_rvalid  = axi_rvalid;

reg [1:0] state_write;
reg [1:0] state_read;
localparam S_IDLE  = 2'b00;
localparam S_ADDR  = 2'b10;
localparam S_DATA  = 2'b11;

//-------------------------------------------------------------------------
// Register storage (14 writable: 0x00 + 0x0C..0x3C)
//-------------------------------------------------------------------------
reg [AXIL_DATA_WIDTH-1:0] slv_reg [0:15];
reg [AXIL_DATA_WIDTH-1:0] cfg_hdmi_size_reg;
reg [AXIL_DATA_WIDTH-1:0] cfg_hdmi_stretch_reg;
integer byte_index;
reg [AXIL_DATA_WIDTH-1:0] rdata_mux_reg;

// Config outputs from reg 0 and reg 3
assign o_cfg_nrm = slv_reg[0][15:0];
assign o_cfg_nam = slv_reg[0][31:16];
assign o_cfg_ny  = slv_reg[3][15:0];
assign o_cfg_nx  = slv_reg[3][31:16];
assign o_cfg_hdmi_w = cfg_hdmi_size_reg[15:0];
assign o_cfg_hdmi_h = cfg_hdmi_size_reg[31:16];
assign o_cfg_hdmi_stretch_knee = cfg_hdmi_stretch_reg[15:0];
assign o_cfg_hdmi_stretch_gain_q8 = cfg_hdmi_stretch_reg[31:16];

// PS control from reg 5 (0x14)
assign o_ps_init_done = slv_reg[5][0];
assign o_ps_im_done   = slv_reg[5][1];

// Debug control from reg 6 (0x18)
assign o_debug_image_loopback_enable = slv_reg[6][0];
assign o_hdmi_ctrl = slv_reg[6];

//-------------------------------------------------------------------------
// Read-only register assembly
//-------------------------------------------------------------------------
wire [AXIL_DATA_WIDTH-1:0] ro_stat_v = {
    i_v_push_ready,
    i_v_pending_valid,
    i_v_slot0_valid,
    i_v_slot1_valid,
    i_v_slot0_desc_ready,
    i_v_slot1_desc_ready,
    i_v_queue_depth,
    i_v_req_id,
    7'd0,
    i_v_data
};

// REG_STAT_FRAME (0x08) — see irq_frame_done_sticky below (after wr_idx)
// Forward declaration
reg irq_frame_done_sticky;
wire [AXIL_DATA_WIDTH-1:0] ro_stat_frame = {29'd0, i_frame_idle, i_mag_write_done, irq_frame_done_sticky};

//-------------------------------------------------------------------------
// Write state machine
//-------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        axi_awready <= 1'b0;
        axi_wready  <= 1'b0;
        axi_bvalid  <= 1'b0;
        axi_bresp   <= 2'b00;
        axi_awaddr  <= {AXIL_ADDR_WIDTH{1'b0}};
        state_write <= S_IDLE;
    end else begin
        case (state_write)
            S_IDLE: begin
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
                state_write <= S_ADDR;
            end
            S_ADDR: begin
                if (s_axi_awvalid && axi_awready) begin
                    axi_awaddr <= s_axi_awaddr;
                    if (s_axi_wvalid) begin
                        // AW and W arrive together — fast path
                        axi_awready <= 1'b1;
                        axi_bvalid  <= 1'b1;
                        state_write <= S_ADDR;
                    end else begin
                        // AW first, wait for W
                        axi_awready <= 1'b0;
                        state_write <= S_DATA;
                        if (s_axi_bready && axi_bvalid)
                            axi_bvalid <= 1'b0;
                    end
                end else begin
                    if (s_axi_bready && axi_bvalid)
                        axi_bvalid <= 1'b0;
                end
            end
            S_DATA: begin
                if (s_axi_wvalid) begin
                    state_write <= S_ADDR;
                    axi_bvalid  <= 1'b1;
                    axi_awready <= 1'b1;
                end else begin
                    if (s_axi_bready && axi_bvalid)
                        axi_bvalid <= 1'b0;
                end
            end
            default: state_write <= S_IDLE;
        endcase
    end
end

//-------------------------------------------------------------------------
// Write data logic (byte-strobe aware)
//-------------------------------------------------------------------------
wire [REG_IDX_BITS-1:0] wr_idx = (s_axi_awvalid)
                               ? s_axi_awaddr[ADDR_LSB + REG_IDX_BITS - 1 : ADDR_LSB]
                               : axi_awaddr[ADDR_LSB + REG_IDX_BITS - 1 : ADDR_LSB];

always @(posedge clk) begin
    if (!rst_n) begin : reset_regs
        integer ri;
        for (ri = 0; ri < 16; ri = ri + 1)
            slv_reg[ri] <= 32'd0;
        cfg_hdmi_size_reg <= 32'd0;
        cfg_hdmi_stretch_reg <= 32'd0;
    end else if (s_axi_wvalid) begin
        // Only write to writable registers: index 0 and 3..15
        // Index 1 (0x04) and 2 (0x08) are read-only — skip
        if (wr_idx <= 6'd15 && (wr_idx == 6'd0 || wr_idx >= 6'd3)) begin
            for (byte_index = 0; byte_index < AXIL_STRB_WIDTH; byte_index = byte_index + 1)
                if (s_axi_wstrb[byte_index])
                    slv_reg[wr_idx][byte_index*8 +: 8] <= s_axi_wdata[byte_index*8 +: 8];
        end else if (wr_idx == CFG_HDMI_SIZE_IDX) begin
            for (byte_index = 0; byte_index < AXIL_STRB_WIDTH; byte_index = byte_index + 1)
                if (s_axi_wstrb[byte_index])
                    cfg_hdmi_size_reg[byte_index*8 +: 8] <= s_axi_wdata[byte_index*8 +: 8];
        end else if (wr_idx == CFG_HDMI_STRETCH_IDX) begin
            for (byte_index = 0; byte_index < AXIL_STRB_WIDTH; byte_index = byte_index + 1)
                if (s_axi_wstrb[byte_index])
                    cfg_hdmi_stretch_reg[byte_index*8 +: 8] <= s_axi_wdata[byte_index*8 +: 8];
        end
    end
end

//-------------------------------------------------------------------------
// IRQ frame done sticky (W1C via reg 0x08 bit[0])
// PS polls bit[0] to detect frame completion, then writes 1 to bit[0] to clear.
//-------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n)
        irq_frame_done_sticky <= 1'b0;
    else if (i_irq_frame_done)
        irq_frame_done_sticky <= 1'b1;
    else if (s_axi_wvalid && wr_idx == 6'd2 && s_axi_wdata[0])
        irq_frame_done_sticky <= 1'b0;  // W1C: write 1 to clear
end

//-------------------------------------------------------------------------
// V write-trigger: writing REG_V_WRITE (reg 4, 0x10) produces a
// single-cycle o_v_valid pulse with o_v_data = wdata[8:0].
//-------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        o_v_valid <= 1'b0;
        o_v_data  <= 9'd0;
    end else begin
        o_v_valid <= 1'b0;  // default: pulse off
        if (s_axi_wvalid && wr_idx == 6'd4) begin
            o_v_valid <= 1'b1;
            o_v_data  <= s_axi_wdata[8:0];
        end
    end
end

//-------------------------------------------------------------------------
// Read state machine
//-------------------------------------------------------------------------
always @(posedge clk) begin
    if (!rst_n) begin
        axi_arready <= 1'b0;
        axi_rvalid  <= 1'b0;
        axi_rresp   <= 2'b00;
        axi_araddr  <= {AXIL_ADDR_WIDTH{1'b0}};
        state_read  <= S_IDLE;
    end else begin
        case (state_read)
            S_IDLE: begin
                axi_arready <= 1'b1;
                state_read  <= S_ADDR;
            end
            S_ADDR: begin
                if (s_axi_arvalid && axi_arready) begin
                    axi_araddr  <= s_axi_araddr;
                    axi_rvalid  <= 1'b1;
                    axi_arready <= 1'b0;
                    state_read  <= S_DATA;
                end
            end
            S_DATA: begin
                if (axi_rvalid && s_axi_rready) begin
                    axi_rvalid  <= 1'b0;
                    axi_arready <= 1'b1;
                    state_read  <= S_ADDR;
                end
            end
            default: state_read <= S_IDLE;
        endcase
    end
end

//-------------------------------------------------------------------------
// Read data mux
//-------------------------------------------------------------------------
wire [REG_IDX_BITS-1:0] rd_idx = axi_araddr[ADDR_LSB + REG_IDX_BITS - 1 : ADDR_LSB];
wire perf_rd_hit = (rd_idx >= PERF_BASE_IDX) && (rd_idx < (PERF_BASE_IDX + PERF_REG_COUNT));

always @(*) begin
    case (rd_idx)
        6'd0:  rdata_mux_reg = slv_reg[0];
        6'd1:  rdata_mux_reg = ro_stat_v;
        6'd2:  rdata_mux_reg = ro_stat_frame;
        6'd3:  rdata_mux_reg = slv_reg[3];
        6'd4:  rdata_mux_reg = slv_reg[4];
        6'd5:  rdata_mux_reg = slv_reg[5];
        6'd6:  rdata_mux_reg = slv_reg[6];
        6'd7:  rdata_mux_reg = i_dbg_ro0;
        6'd8:  rdata_mux_reg = i_dbg_ro1;
        6'd9:  rdata_mux_reg = i_dbg_ro2;
        6'd10: rdata_mux_reg = i_dbg_ro3;
        6'd11: rdata_mux_reg = i_dbg_ro4;
        6'd12: rdata_mux_reg = i_dbg_ro5;
        6'd13: rdata_mux_reg = i_dbg_ro6;
        6'd14: rdata_mux_reg = i_dbg_ro7;
        6'd15: rdata_mux_reg = i_dbg_ro8;
        default: begin
            if (rd_idx == CFG_HDMI_SIZE_IDX)
                rdata_mux_reg = cfg_hdmi_size_reg;
            else if (rd_idx == CFG_HDMI_STRETCH_IDX)
                rdata_mux_reg = cfg_hdmi_stretch_reg;
            else if (rd_idx == 7'd82)
                rdata_mux_reg = i_pl_iw_status;
            else if (rd_idx == 7'd83)
                rdata_mux_reg = i_pl_iw_q_scale;
            else if (perf_rd_hit)
                rdata_mux_reg = i_perf_ro_flat[(rd_idx - PERF_BASE_IDX) * AXIL_DATA_WIDTH +: AXIL_DATA_WIDTH];
            else
                rdata_mux_reg = {AXIL_DATA_WIDTH{1'b0}};
        end
    endcase
end

assign s_axi_rdata = rdata_mux_reg;

// Unused signals
wire _unused = &{s_axi_awprot, s_axi_arprot};

endmodule
