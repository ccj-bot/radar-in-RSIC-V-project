//-----------------------------------------------------------------------------
// DDR-backed SAR HDMI scanout
//
// PL reads the completed AXI DMA image slot directly from DDR and scans it out
// as a 1024x768 DVI/HDMI frame. The SAR image is 1024x591, centered vertically.
// This version expects the DMA image buffer to be row-major so each frame can be
// fetched with efficient incremental AXI bursts.
//-----------------------------------------------------------------------------

module sar_hdmi_ddr_preview #(
    parameter AXI_ADDR_WIDTH      = 32,
    parameter AXI_DATA_WIDTH      = 32,
    parameter AXI_STRB_WIDTH      = AXI_DATA_WIDTH / 8,
    parameter AXI_ID_WIDTH        = 4,
    parameter DISPLAY_BASE_ADDR   = 32'h0800_0000,
    parameter DISPLAY_SLOT_STRIDE = 32'h0012_7800,
    parameter DISPLAY_W           = 1024,
    parameter DISPLAY_H           = 591,
    parameter H_VISIBLE           = 1024,
    parameter H_FRONT             = 24,
    parameter H_SYNC              = 136,
    parameter H_BACK              = 160,
    parameter V_VISIBLE           = 768,
    parameter V_FRONT             = 3,
    parameter V_SYNC              = 6,
    parameter V_BACK              = 29,
    parameter AXI_BURST_BEATS     = 64,
    parameter AXI_CLK_HZ          = 100000000,
    parameter RGB2DVI_INTERNAL_CLK = 0,
    parameter RGB2DVI_CLK_RANGE    = 2
) (
    input  wire                         axi_clk,
    input  wire                         pix_clk,
    input  wire                         ser_clk,
    input  wire                         rst_n,
    input  wire [31:0]                  ctrl,
    input  wire [15:0]                  cfg_display_w,
    input  wire [15:0]                  cfg_display_h,
    input  wire [15:0]                  cfg_stretch_knee,
    input  wire [15:0]                  cfg_stretch_gain_q8,
    output wire [31:0]                  status,

    output wire [AXI_ID_WIDTH-1:0]      m_axi_awid,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_awaddr,
    output wire [7:0]                   m_axi_awlen,
    output wire [2:0]                   m_axi_awsize,
    output wire [1:0]                   m_axi_awburst,
    output wire                         m_axi_awlock,
    output wire [3:0]                   m_axi_awcache,
    output wire [2:0]                   m_axi_awprot,
    output wire                         m_axi_awvalid,
    input  wire                         m_axi_awready,
    output wire [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
    output wire [AXI_STRB_WIDTH-1:0]    m_axi_wstrb,
    output wire                         m_axi_wlast,
    output wire                         m_axi_wvalid,
    input  wire                         m_axi_wready,
    input  wire [AXI_ID_WIDTH-1:0]      m_axi_bid,
    input  wire [1:0]                   m_axi_bresp,
    input  wire                         m_axi_bvalid,
    output wire                         m_axi_bready,
    output wire [AXI_ID_WIDTH-1:0]      m_axi_arid,
    output wire [AXI_ADDR_WIDTH-1:0]    m_axi_araddr,
    output wire [7:0]                   m_axi_arlen,
    output wire [2:0]                   m_axi_arsize,
    output wire [1:0]                   m_axi_arburst,
    output wire                         m_axi_arlock,
    output wire [3:0]                   m_axi_arcache,
    output wire [2:0]                   m_axi_arprot,
    output wire                         m_axi_arvalid,
    input  wire                         m_axi_arready,
    input  wire [AXI_ID_WIDTH-1:0]      m_axi_rid,
    input  wire [AXI_DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire [1:0]                   m_axi_rresp,
    input  wire                         m_axi_rlast,
    input  wire                         m_axi_rvalid,
    output wire                         m_axi_rready,

    output wire [2:0]                   hdmi_d_p,
    output wire [2:0]                   hdmi_d_n,
    output wire                         hdmi_clk_p,
    output wire                         hdmi_clk_n
);

localparam H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;
localparam V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;
localparam H_SYNC_START = H_VISIBLE + H_FRONT;
localparam H_SYNC_END   = H_VISIBLE + H_FRONT + H_SYNC;
localparam V_SYNC_START = V_VISIBLE + V_FRONT;
localparam V_SYNC_END   = V_VISIBLE + V_FRONT + V_SYNC;
localparam DISPLAY_PIXELS_MAX = DISPLAY_W * DISPLAY_H;
localparam DISPLAY_AXI_WORDS_MAX = (DISPLAY_PIXELS_MAX + 1) / 2;
localparam WORD_COUNT_WIDTH = $clog2(DISPLAY_AXI_WORDS_MAX + 1);
localparam FIFO_DEPTH = 4096;
localparam FIFO_COUNT_WIDTH = $clog2(FIFO_DEPTH) + 1;
localparam [15:0] DISPLAY_W_DEFAULT = DISPLAY_W;
localparam [15:0] DISPLAY_H_DEFAULT = DISPLAY_H;
localparam [15:0] H_VISIBLE_LIMIT = H_VISIBLE;
localparam [15:0] V_VISIBLE_LIMIT = V_VISIBLE;
localparam [WORD_COUNT_WIDTH-1:0] AXI_BURST_BEATS_L = AXI_BURST_BEATS;
localparam [FIFO_COUNT_WIDTH-1:0] FIFO_BURST_ROOM_THRESHOLD = FIFO_DEPTH - (AXI_BURST_BEATS * 2);
localparam [1:0] ZERO_HOLD_MAX = 2'd3;

assign m_axi_awid    = {AXI_ID_WIDTH{1'b0}};
assign m_axi_awaddr  = {AXI_ADDR_WIDTH{1'b0}};
assign m_axi_awlen   = 8'd0;
assign m_axi_awsize  = 3'd0;
assign m_axi_awburst = 2'd0;
assign m_axi_awlock  = 1'b0;
assign m_axi_awcache = 4'b0010;
assign m_axi_awprot  = 3'b000;
assign m_axi_awvalid = 1'b0;
assign m_axi_wdata   = {AXI_DATA_WIDTH{1'b0}};
assign m_axi_wstrb   = {AXI_STRB_WIDTH{1'b0}};
assign m_axi_wlast   = 1'b0;
assign m_axi_wvalid  = 1'b0;
assign m_axi_bready  = 1'b1;

(* ASYNC_REG = "TRUE" *) reg [2:0] axi_resetn_sync_reg = 3'b000;
(* ASYNC_REG = "TRUE" *) reg [2:0] pix_resetn_sync_reg = 3'b000;

always @(posedge axi_clk) begin
    axi_resetn_sync_reg <= {axi_resetn_sync_reg[1:0], rst_n};
end

always @(posedge pix_clk) begin
    pix_resetn_sync_reg <= {pix_resetn_sync_reg[1:0], rst_n};
end

wire axi_reset = !axi_resetn_sync_reg[2];
wire pix_reset = !pix_resetn_sync_reg[2];

wire ctrl_hdmi_enable = ctrl[16];
wire [1:0] ctrl_hdmi_slot = ctrl[10:9];
wire ctrl_frame_toggle = ctrl[8];
wire [3:0] ctrl_fps_digit_hundreds = ctrl[31:28];
wire [3:0] ctrl_fps_digit_tens = ctrl[27:24];
wire [3:0] ctrl_fps_digit_ones = ctrl[23:20];
reg [1:0] display_slot_reg;
reg [1:0] pending_slot_reg;
reg       pending_valid_reg;
reg       pending_toggle_reg;
reg       accepted_toggle_reg;
reg       ctrl_toggle_seen_reg;
reg       missed_frame_boundary_reg;
reg [15:0] missed_frame_boundary_count_reg;
reg [7:0] underflow_last_count_axi_meta_reg;
reg [7:0] underflow_last_count_axi_reg;
reg       underflow_seen_axi_meta_reg;
reg       underflow_seen_axi_reg;
wire [15:0] cfg_display_w_axi =
    (cfg_display_w != 16'd0 && cfg_display_w <= DISPLAY_W_DEFAULT) ? cfg_display_w : DISPLAY_W_DEFAULT;
wire [15:0] cfg_display_h_axi =
    (cfg_display_h != 16'd0 && cfg_display_h <= DISPLAY_H_DEFAULT) ? cfg_display_h : DISPLAY_H_DEFAULT;
wire [31:0] cfg_display_pixels_axi = cfg_display_w_axi * cfg_display_h_axi;
wire [31:0] cfg_display_axi_words32 = (cfg_display_pixels_axi + 32'd1) >> 1;
wire [WORD_COUNT_WIDTH-1:0] cfg_display_axi_words = cfg_display_axi_words32[WORD_COUNT_WIDTH-1:0];

reg [3:0]  fps_digit_hundreds_axi_reg;
reg [3:0]  fps_digit_tens_axi_reg;
reg [3:0]  fps_digit_ones_axi_reg;

always @(posedge axi_clk) begin
    if (axi_reset) begin
        fps_digit_hundreds_axi_reg <= 4'd0;
        fps_digit_tens_axi_reg <= 4'd0;
        fps_digit_ones_axi_reg <= 4'd0;
    end else begin
        fps_digit_hundreds_axi_reg <= (ctrl_fps_digit_hundreds <= 4'd9) ? ctrl_fps_digit_hundreds : 4'd9;
        fps_digit_tens_axi_reg <= (ctrl_fps_digit_tens <= 4'd9) ? ctrl_fps_digit_tens : 4'd9;
        fps_digit_ones_axi_reg <= (ctrl_fps_digit_ones <= 4'd9) ? ctrl_fps_digit_ones : 4'd9;
    end
end

reg [11:0] h_cnt_reg;
reg [11:0] v_cnt_reg;
reg [7:0]  underflow_frame_count_pix_reg;
reg [7:0]  underflow_last_count_pix_reg;
reg        underflow_seen_pix_reg;
reg [3:0] fps_digit_hundreds_pix_meta_reg;
reg [3:0] fps_digit_tens_pix_meta_reg;
reg [3:0] fps_digit_ones_pix_meta_reg;
reg [3:0] fps_digit_hundreds_pix_reg;
reg [3:0] fps_digit_tens_pix_reg;
reg [3:0] fps_digit_ones_pix_reg;
reg       frame_req_toggle_pix_reg;
reg [15:0] display_w_pix_meta_reg;
reg [15:0] display_h_pix_meta_reg;
reg [15:0] stretch_knee_pix_meta_reg;
reg [15:0] stretch_gain_q8_pix_meta_reg;
reg [15:0] display_w_pix_reg;
reg [15:0] display_h_pix_reg;
reg [15:0] stretch_knee_pix_reg;
reg [15:0] stretch_gain_q8_pix_reg;

wire video_active_now = (h_cnt_reg < H_VISIBLE) && (v_cnt_reg < V_VISIBLE);
wire [15:0] display_w_pix =
    (display_w_pix_reg != 16'd0 && display_w_pix_reg <= H_VISIBLE_LIMIT) ? display_w_pix_reg : DISPLAY_W_DEFAULT;
wire [15:0] display_h_pix =
    (display_h_pix_reg != 16'd0 && display_h_pix_reg <= V_VISIBLE_LIMIT) ? display_h_pix_reg : DISPLAY_H_DEFAULT;
wire [15:0] display_y0_pix =
    (display_h_pix < V_VISIBLE_LIMIT) ? ((V_VISIBLE_LIMIT - display_h_pix) >> 1) : 16'd0;
wire [15:0] stretch_knee_pix =
    (stretch_knee_pix_reg != 16'd0) ? stretch_knee_pix_reg : 16'd16;
wire [15:0] stretch_gain_q8_pix =
    (stretch_gain_q8_pix_reg != 16'd0) ? stretch_gain_q8_pix_reg : 16'd4064;
wire image_active_now = video_active_now &&
                        (v_cnt_reg >= display_y0_pix[11:0]) &&
                        (v_cnt_reg < (display_y0_pix[11:0] + display_h_pix[11:0])) &&
                        (h_cnt_reg < display_w_pix[11:0]);
wire frame_start_pix = (h_cnt_reg == 12'd0) && (v_cnt_reg == 12'd0);

always @(posedge pix_clk) begin
    if (pix_reset) begin
        h_cnt_reg <= 12'd0;
        v_cnt_reg <= 12'd0;
        fps_digit_hundreds_pix_meta_reg <= 4'd0;
        fps_digit_tens_pix_meta_reg <= 4'd0;
        fps_digit_ones_pix_meta_reg <= 4'd0;
        fps_digit_hundreds_pix_reg <= 4'd0;
        fps_digit_tens_pix_reg <= 4'd0;
        fps_digit_ones_pix_reg <= 4'd0;
        frame_req_toggle_pix_reg <= 1'b0;
        display_w_pix_meta_reg <= DISPLAY_W_DEFAULT;
        display_h_pix_meta_reg <= DISPLAY_H_DEFAULT;
        stretch_knee_pix_meta_reg <= 16'd16;
        stretch_gain_q8_pix_meta_reg <= 16'd4064;
        display_w_pix_reg <= DISPLAY_W_DEFAULT;
        display_h_pix_reg <= DISPLAY_H_DEFAULT;
        stretch_knee_pix_reg <= 16'd16;
        stretch_gain_q8_pix_reg <= 16'd4064;
    end else begin
        fps_digit_hundreds_pix_meta_reg <= fps_digit_hundreds_axi_reg;
        fps_digit_tens_pix_meta_reg <= fps_digit_tens_axi_reg;
        fps_digit_ones_pix_meta_reg <= fps_digit_ones_axi_reg;
        fps_digit_hundreds_pix_reg <= fps_digit_hundreds_pix_meta_reg;
        fps_digit_tens_pix_reg <= fps_digit_tens_pix_meta_reg;
        fps_digit_ones_pix_reg <= fps_digit_ones_pix_meta_reg;
        display_w_pix_meta_reg <= cfg_display_w_axi;
        display_h_pix_meta_reg <= cfg_display_h_axi;
        stretch_knee_pix_meta_reg <= (cfg_stretch_knee != 16'd0) ? cfg_stretch_knee : 16'd16;
        stretch_gain_q8_pix_meta_reg <= (cfg_stretch_gain_q8 != 16'd0) ? cfg_stretch_gain_q8 : 16'd4064;
        display_w_pix_reg <= display_w_pix_meta_reg;
        display_h_pix_reg <= display_h_pix_meta_reg;
        stretch_knee_pix_reg <= stretch_knee_pix_meta_reg;
        stretch_gain_q8_pix_reg <= stretch_gain_q8_pix_meta_reg;

        if (frame_start_pix)
            frame_req_toggle_pix_reg <= ~frame_req_toggle_pix_reg;

        if (h_cnt_reg == H_TOTAL - 1) begin
            h_cnt_reg <= 12'd0;
            if (v_cnt_reg == V_TOTAL - 1)
                v_cnt_reg <= 12'd0;
            else
                v_cnt_reg <= v_cnt_reg + 1'b1;
        end else begin
            h_cnt_reg <= h_cnt_reg + 1'b1;
        end
    end
end

reg frame_req_toggle_axi_meta_reg;
reg frame_req_toggle_axi_reg;
reg frame_req_toggle_axi_seen_reg;

always @(posedge axi_clk) begin
    if (axi_reset) begin
        frame_req_toggle_axi_meta_reg <= 1'b0;
        frame_req_toggle_axi_reg <= 1'b0;
    end else begin
        frame_req_toggle_axi_meta_reg <= frame_req_toggle_pix_reg;
        frame_req_toggle_axi_reg <= frame_req_toggle_axi_meta_reg;
    end
end

wire frame_req_axi_event = (frame_req_toggle_axi_reg != frame_req_toggle_axi_seen_reg);

wire [31:0] fifo_din;
wire [31:0] fifo_dout;
wire fifo_full;
wire fifo_empty;
wire fifo_wr_en;
wire fifo_rd_en;
wire fifo_rd_valid;
wire fifo_rst;
wire fifo_wr_rst_busy;
wire fifo_rd_rst_busy;
wire [FIFO_COUNT_WIDTH-1:0] fifo_wr_count;
wire [FIFO_COUNT_WIDTH-1:0] fifo_rd_count;

xpm_fifo_async #(
    .CDC_SYNC_STAGES      (2),
    .DOUT_RESET_VALUE     ("0"),
    .ECC_MODE             ("no_ecc"),
    .FIFO_MEMORY_TYPE     ("auto"),
    .FIFO_READ_LATENCY    (0),
    .FIFO_WRITE_DEPTH     (FIFO_DEPTH),
    .FULL_RESET_VALUE     (0),
    .PROG_EMPTY_THRESH    (10),
    .PROG_FULL_THRESH     (FIFO_DEPTH - 128),
    .RD_DATA_COUNT_WIDTH  (FIFO_COUNT_WIDTH),
    .READ_DATA_WIDTH      (32),
    .READ_MODE            ("fwft"),
    .RELATED_CLOCKS       (0),
    .SIM_ASSERT_CHK       (0),
    .USE_ADV_FEATURES     ("0707"),
    .WAKEUP_TIME          (0),
    .WRITE_DATA_WIDTH     (32),
    .WR_DATA_COUNT_WIDTH  (FIFO_COUNT_WIDTH)
) u_scan_fifo (
    .almost_empty  (),
    .almost_full   (),
    .data_valid    (fifo_rd_valid),
    .dbiterr       (),
    .dout          (fifo_dout),
    .empty         (fifo_empty),
    .full          (fifo_full),
    .overflow      (),
    .prog_empty    (),
    .prog_full     (),
    .rd_data_count (fifo_rd_count),
    .rd_rst_busy   (fifo_rd_rst_busy),
    .sbiterr       (),
    .underflow     (),
    .wr_ack        (),
    .wr_data_count (fifo_wr_count),
    .wr_rst_busy   (fifo_wr_rst_busy),
    .din           (fifo_din),
    .injectdbiterr (1'b0),
    .injectsbiterr (1'b0),
    .rd_clk        (pix_clk),
    .rd_en         (fifo_rd_en),
    .rst           (fifo_rst),
    .sleep         (1'b0),
    .wr_clk        (axi_clk),
    .wr_en         (fifo_wr_en)
);

reg fifo_rst_reg;
reg [4:0] fifo_rst_count_reg;
reg fetch_active_reg;
reg [AXI_ADDR_WIDTH-1:0] read_addr_reg;
reg [WORD_COUNT_WIDTH-1:0] words_left_reg;
reg [WORD_COUNT_WIDTH-1:0] words_issue_left_reg;
reg arvalid_reg;
reg [7:0] arlen_reg;
reg [7:0] ar_beats_reg;
reg [FIFO_COUNT_WIDTH-1:0] outstanding_beats_reg;

wire [WORD_COUNT_WIDTH-1:0] next_burst_beats =
    (words_issue_left_reg > AXI_BURST_BEATS_L) ? AXI_BURST_BEATS_L : words_issue_left_reg;
wire [FIFO_COUNT_WIDTH:0] fifo_reserved_words =
    {1'b0, fifo_wr_count} + {1'b0, outstanding_beats_reg};
wire [FIFO_COUNT_WIDTH:0] next_burst_room_words =
    {{(FIFO_COUNT_WIDTH-7){1'b0}}, next_burst_beats[7:0]};
wire fifo_has_burst_room =
    (fifo_reserved_words + next_burst_room_words) < FIFO_BURST_ROOM_THRESHOLD;
wire fifo_can_write = !fifo_full && !fifo_wr_rst_busy && !fifo_rst_reg;
wire r_hs = fetch_active_reg && m_axi_rvalid && m_axi_rready;
wire outstanding_active = (outstanding_beats_reg != {FIFO_COUNT_WIDTH{1'b0}});
wire [FIFO_COUNT_WIDTH-1:0] outstanding_after_r =
    r_hs ? (outstanding_beats_reg - {{(FIFO_COUNT_WIDTH-1){1'b0}}, 1'b1})
         : outstanding_beats_reg;
wire reader_idle = !fetch_active_reg && !arvalid_reg && !outstanding_active &&
                   !fifo_rst_reg && (fifo_rst_count_reg == 5'd0);
wire ctrl_new_publish = ctrl_hdmi_enable && (ctrl_frame_toggle != ctrl_toggle_seen_reg);
wire pending_valid_next = pending_valid_reg || ctrl_new_publish;
wire [1:0] pending_slot_next = ctrl_new_publish ? ctrl_hdmi_slot : pending_slot_reg;
wire pending_toggle_next = ctrl_new_publish ? ctrl_frame_toggle : pending_toggle_reg;
wire [1:0] frame_start_slot = pending_valid_next ? pending_slot_next : display_slot_reg;
wire [AXI_ADDR_WIDTH-1:0] frame_start_addr =
    DISPLAY_BASE_ADDR + (frame_start_slot * DISPLAY_SLOT_STRIDE);

assign fifo_rst = fifo_rst_reg || axi_reset;
assign fifo_din = m_axi_rdata;
assign fifo_wr_en = r_hs;

assign status = {
    underflow_last_count_axi_reg,
    missed_frame_boundary_count_reg[7:0],
    2'd0,
    underflow_seen_axi_reg,
    |underflow_last_count_axi_reg,
    missed_frame_boundary_reg,
    ctrl_toggle_seen_reg,
    pending_slot_reg,
    display_slot_reg,
    accepted_toggle_reg,
    pending_valid_reg,
    outstanding_active,
    arvalid_reg,
    fetch_active_reg,
    ctrl_hdmi_enable
};

assign m_axi_arid = {AXI_ID_WIDTH{1'b0}};
assign m_axi_araddr = read_addr_reg;
assign m_axi_arlen = arlen_reg;
assign m_axi_arsize = 3'd2;
assign m_axi_arburst = 2'b01;
assign m_axi_arlock = 1'b0;
assign m_axi_arcache = 4'b0011;
assign m_axi_arprot = 3'b000;
assign m_axi_arvalid = arvalid_reg;
assign m_axi_rready = fetch_active_reg && fifo_can_write;

always @(posedge axi_clk) begin
    if (axi_reset) begin
        frame_req_toggle_axi_seen_reg <= 1'b0;
        fifo_rst_reg <= 1'b1;
        fifo_rst_count_reg <= 5'd0;
        fetch_active_reg <= 1'b0;
        read_addr_reg <= DISPLAY_BASE_ADDR;
        words_left_reg <= {WORD_COUNT_WIDTH{1'b0}};
        words_issue_left_reg <= {WORD_COUNT_WIDTH{1'b0}};
        arvalid_reg <= 1'b0;
        arlen_reg <= 8'd0;
        ar_beats_reg <= 8'd0;
        outstanding_beats_reg <= {FIFO_COUNT_WIDTH{1'b0}};
        display_slot_reg <= 2'd0;
        pending_slot_reg <= 2'd0;
        pending_valid_reg <= 1'b0;
        pending_toggle_reg <= 1'b0;
        accepted_toggle_reg <= 1'b0;
        ctrl_toggle_seen_reg <= 1'b0;
        missed_frame_boundary_reg <= 1'b0;
        missed_frame_boundary_count_reg <= 16'd0;
        underflow_last_count_axi_meta_reg <= 8'd0;
        underflow_last_count_axi_reg <= 8'd0;
        underflow_seen_axi_meta_reg <= 1'b0;
        underflow_seen_axi_reg <= 1'b0;
    end else begin
        underflow_last_count_axi_meta_reg <= underflow_last_count_pix_reg;
        underflow_last_count_axi_reg <= underflow_last_count_axi_meta_reg;
        underflow_seen_axi_meta_reg <= underflow_seen_pix_reg;
        underflow_seen_axi_reg <= underflow_seen_axi_meta_reg;

        if (ctrl_new_publish) begin
            pending_slot_reg <= ctrl_hdmi_slot;
            pending_toggle_reg <= ctrl_frame_toggle;
            pending_valid_reg <= 1'b1;
            ctrl_toggle_seen_reg <= ctrl_frame_toggle;
        end

        if (frame_req_axi_event && reader_idle) begin
            frame_req_toggle_axi_seen_reg <= frame_req_toggle_axi_reg;
            fifo_rst_reg <= 1'b1;
            fifo_rst_count_reg <= 5'd16;
            fetch_active_reg <= 1'b0;
            arvalid_reg <= 1'b0;
            outstanding_beats_reg <= {FIFO_COUNT_WIDTH{1'b0}};
            ar_beats_reg <= 8'd0;
            if (pending_valid_next) begin
                display_slot_reg <= pending_slot_next;
                accepted_toggle_reg <= pending_toggle_next;
                pending_valid_reg <= 1'b0;
            end
            read_addr_reg <= frame_start_addr;
            words_left_reg <= cfg_display_axi_words;
            words_issue_left_reg <= cfg_display_axi_words;
        end else if (frame_req_axi_event) begin
            frame_req_toggle_axi_seen_reg <= frame_req_toggle_axi_reg;
            missed_frame_boundary_reg <= 1'b1;
            if (missed_frame_boundary_count_reg != 16'hFFFF)
                missed_frame_boundary_count_reg <= missed_frame_boundary_count_reg + 1'b1;
        end else if (fifo_rst_count_reg != 5'd0) begin
            fifo_rst_count_reg <= fifo_rst_count_reg - 1'b1;
            fifo_rst_reg <= 1'b1;
        end else if (fifo_rst_reg) begin
            fifo_rst_reg <= 1'b0;
            fetch_active_reg <= ctrl_hdmi_enable;
        end else if (fetch_active_reg) begin
            if (r_hs) begin
                if (words_left_reg != 0)
                    words_left_reg <= words_left_reg - 1'b1;
                outstanding_beats_reg <= outstanding_after_r;
                if (words_left_reg == 1) begin
                    fetch_active_reg <= 1'b0;
                end
            end

            if (arvalid_reg && m_axi_arready) begin
                arvalid_reg <= 1'b0;
                read_addr_reg <= read_addr_reg + {{(AXI_ADDR_WIDTH-10){1'b0}}, ar_beats_reg, 2'b00};
                if (words_issue_left_reg > {{(WORD_COUNT_WIDTH-8){1'b0}}, ar_beats_reg})
                    words_issue_left_reg <= words_issue_left_reg - {{(WORD_COUNT_WIDTH-8){1'b0}}, ar_beats_reg};
                else
                    words_issue_left_reg <= {WORD_COUNT_WIDTH{1'b0}};
                outstanding_beats_reg <= outstanding_after_r + {{(FIFO_COUNT_WIDTH-8){1'b0}}, ar_beats_reg};
            end else if (!arvalid_reg &&
                         fifo_has_burst_room &&
                         (words_issue_left_reg != 0)) begin
                ar_beats_reg <= next_burst_beats[7:0];
                arlen_reg <= next_burst_beats[7:0] - 1'b1;
                arvalid_reg <= 1'b1;
            end
        end
    end
end

function [7:0] stretch_color_index;
    input [15:0] value;
    input [15:0] knee;
    input [15:0] gain_q8;
    reg [31:0] scaled;
    reg [15:0] lifted;
    begin
        if (value == 16'd0) begin
            stretch_color_index = 8'd0;
        end else if (value <= knee) begin
            stretch_color_index = 8'd1;
        end else begin
            lifted = value - knee;
            scaled = (lifted * gain_q8) + 32'd128;
            if (scaled[31:8] >= 32'd254)
                stretch_color_index = 8'd255;
            else
                stretch_color_index = 8'd1 + scaled[15:8];
        end
    end
endfunction

function [4:0] font5x7_row;
    input [7:0] char_code;
    input [2:0] row;
    begin
        case (char_code)
            8'h30: case (row) 3'd0: font5x7_row = 5'b01110; 3'd1: font5x7_row = 5'b10001; 3'd2: font5x7_row = 5'b10011; 3'd3: font5x7_row = 5'b10101; 3'd4: font5x7_row = 5'b11001; 3'd5: font5x7_row = 5'b10001; default: font5x7_row = 5'b01110; endcase
            8'h31: case (row) 3'd0: font5x7_row = 5'b00100; 3'd1: font5x7_row = 5'b01100; 3'd2: font5x7_row = 5'b00100; 3'd3: font5x7_row = 5'b00100; 3'd4: font5x7_row = 5'b00100; 3'd5: font5x7_row = 5'b00100; default: font5x7_row = 5'b01110; endcase
            8'h32: case (row) 3'd0: font5x7_row = 5'b01110; 3'd1: font5x7_row = 5'b10001; 3'd2: font5x7_row = 5'b00001; 3'd3: font5x7_row = 5'b00010; 3'd4: font5x7_row = 5'b00100; 3'd5: font5x7_row = 5'b01000; default: font5x7_row = 5'b11111; endcase
            8'h33: case (row) 3'd0: font5x7_row = 5'b11110; 3'd1: font5x7_row = 5'b00001; 3'd2: font5x7_row = 5'b00001; 3'd3: font5x7_row = 5'b01110; 3'd4: font5x7_row = 5'b00001; 3'd5: font5x7_row = 5'b00001; default: font5x7_row = 5'b11110; endcase
            8'h34: case (row) 3'd0: font5x7_row = 5'b00010; 3'd1: font5x7_row = 5'b00110; 3'd2: font5x7_row = 5'b01010; 3'd3: font5x7_row = 5'b10010; 3'd4: font5x7_row = 5'b11111; 3'd5: font5x7_row = 5'b00010; default: font5x7_row = 5'b00010; endcase
            8'h35: case (row) 3'd0: font5x7_row = 5'b11111; 3'd1: font5x7_row = 5'b10000; 3'd2: font5x7_row = 5'b11110; 3'd3: font5x7_row = 5'b00001; 3'd4: font5x7_row = 5'b00001; 3'd5: font5x7_row = 5'b10001; default: font5x7_row = 5'b01110; endcase
            8'h36: case (row) 3'd0: font5x7_row = 5'b00110; 3'd1: font5x7_row = 5'b01000; 3'd2: font5x7_row = 5'b10000; 3'd3: font5x7_row = 5'b11110; 3'd4: font5x7_row = 5'b10001; 3'd5: font5x7_row = 5'b10001; default: font5x7_row = 5'b01110; endcase
            8'h37: case (row) 3'd0: font5x7_row = 5'b11111; 3'd1: font5x7_row = 5'b00001; 3'd2: font5x7_row = 5'b00010; 3'd3: font5x7_row = 5'b00100; 3'd4: font5x7_row = 5'b01000; 3'd5: font5x7_row = 5'b01000; default: font5x7_row = 5'b01000; endcase
            8'h38: case (row) 3'd0: font5x7_row = 5'b01110; 3'd1: font5x7_row = 5'b10001; 3'd2: font5x7_row = 5'b10001; 3'd3: font5x7_row = 5'b01110; 3'd4: font5x7_row = 5'b10001; 3'd5: font5x7_row = 5'b10001; default: font5x7_row = 5'b01110; endcase
            8'h39: case (row) 3'd0: font5x7_row = 5'b01110; 3'd1: font5x7_row = 5'b10001; 3'd2: font5x7_row = 5'b10001; 3'd3: font5x7_row = 5'b01111; 3'd4: font5x7_row = 5'b00001; 3'd5: font5x7_row = 5'b00010; default: font5x7_row = 5'b01100; endcase
            8'h46: case (row) 3'd0: font5x7_row = 5'b11111; 3'd1: font5x7_row = 5'b10000; 3'd2: font5x7_row = 5'b10000; 3'd3: font5x7_row = 5'b11110; 3'd4: font5x7_row = 5'b10000; 3'd5: font5x7_row = 5'b10000; default: font5x7_row = 5'b10000; endcase
            8'h50: case (row) 3'd0: font5x7_row = 5'b11110; 3'd1: font5x7_row = 5'b10001; 3'd2: font5x7_row = 5'b10001; 3'd3: font5x7_row = 5'b11110; 3'd4: font5x7_row = 5'b10000; 3'd5: font5x7_row = 5'b10000; default: font5x7_row = 5'b10000; endcase
            8'h53: case (row) 3'd0: font5x7_row = 5'b01111; 3'd1: font5x7_row = 5'b10000; 3'd2: font5x7_row = 5'b10000; 3'd3: font5x7_row = 5'b01110; 3'd4: font5x7_row = 5'b00001; 3'd5: font5x7_row = 5'b00001; default: font5x7_row = 5'b11110; endcase
            default: font5x7_row = 5'b00000;
        endcase
    end
endfunction

function [7:0] osd_char;
    input [3:0] idx;
    begin
        case (idx)
            4'd0: osd_char = 8'h46;
            4'd1: osd_char = 8'h50;
            4'd2: osd_char = 8'h53;
            4'd3: osd_char = 8'h20;
            4'd4: osd_char = 8'h30 + fps_digit_hundreds_pix_reg;
            4'd5: osd_char = 8'h30 + fps_digit_tens_pix_reg;
            4'd6: osd_char = 8'h30 + fps_digit_ones_pix_reg;
            default: osd_char = 8'h20;
        endcase
    end
endfunction

wire hsync_now = (h_cnt_reg >= H_SYNC_START) && (h_cnt_reg < H_SYNC_END);
wire vsync_now = (v_cnt_reg >= V_SYNC_START) && (v_cnt_reg < V_SYNC_END);
localparam [11:0] OSD_X0 = 12'd12;
localparam [11:0] OSD_Y0 = 12'd12;
localparam [11:0] OSD_W  = 12'd92;
localparam [11:0] OSD_H  = 12'd22;
wire osd_region = video_active_now &&
                  (h_cnt_reg >= OSD_X0) && (h_cnt_reg < (OSD_X0 + OSD_W)) &&
                  (v_cnt_reg >= OSD_Y0) && (v_cnt_reg < (OSD_Y0 + OSD_H));
wire osd_inner = osd_region &&
                 (h_cnt_reg >= (OSD_X0 + 12'd4)) &&
                 (v_cnt_reg >= (OSD_Y0 + 12'd4));
wire [11:0] osd_x = h_cnt_reg - OSD_X0 - 12'd4;
wire [11:0] osd_y = v_cnt_reg - OSD_Y0 - 12'd4;
wire [3:0] osd_char_idx =
    (osd_x < 12'd12) ? 4'd0 :
    (osd_x < 12'd24) ? 4'd1 :
    (osd_x < 12'd36) ? 4'd2 :
    (osd_x < 12'd48) ? 4'd3 :
    (osd_x < 12'd60) ? 4'd4 :
    (osd_x < 12'd72) ? 4'd5 :
    (osd_x < 12'd84) ? 4'd6 : 4'd15;
wire [11:0] osd_char_x =
    (osd_char_idx == 4'd0) ? osd_x :
    (osd_char_idx == 4'd1) ? (osd_x - 12'd12) :
    (osd_char_idx == 4'd2) ? (osd_x - 12'd24) :
    (osd_char_idx == 4'd3) ? (osd_x - 12'd36) :
    (osd_char_idx == 4'd4) ? (osd_x - 12'd48) :
    (osd_char_idx == 4'd5) ? (osd_x - 12'd60) :
    (osd_char_idx == 4'd6) ? (osd_x - 12'd72) : 12'd15;
wire [2:0] osd_col = osd_char_x[3:1];
wire [2:0] osd_row = osd_y[3:1];
wire [4:0] osd_bits = font5x7_row(osd_char(osd_char_idx), osd_row);
wire osd_text = osd_inner &&
                (osd_char_idx < 4'd7) &&
                (osd_char_x < 12'd10) &&
                (osd_y < 12'd14) &&
                (osd_col < 3'd5) &&
                osd_bits[4 - osd_col];

reg        fifo_high_half_valid_reg;
reg [15:0] fifo_high_half_reg;
reg        fifo_rd_en_reg;
reg        scan_word_valid_reg;
reg [31:0] scan_word_reg;

wire fifo_can_pop_pix = !fifo_empty && !fifo_rd_rst_busy;
wire image_low_half_needed = image_active_now && !fifo_high_half_valid_reg;
wire image_underflow_now = image_low_half_needed && !scan_word_valid_reg && !fifo_can_pop_pix;
assign fifo_rd_en = fifo_rd_en_reg;

reg [7:0] red_reg;
reg [7:0] green_reg;
reg [7:0] blue_reg;
reg       de_reg;
reg       hsync_reg;
reg       vsync_reg;
reg       osd_text_reg;
reg       osd_bg_reg;
reg       image_active_reg;
reg [7:0] color_index_reg;
reg [15:0] last_nonzero_pixel_reg;
reg [1:0] zero_hold_count_reg;
wire [7:0] cusjet_red;
wire [7:0] cusjet_green;
wire [7:0] cusjet_blue;

sar_cusjet_lut u_sar_cusjet_lut (
    .index (color_index_reg),
    .red   (cusjet_red),
    .green (cusjet_green),
    .blue  (cusjet_blue)
);

task consume_image_pixel;
    input [15:0] value;
    begin
        if (value != 16'd0) begin
            color_index_reg <= stretch_color_index(value, stretch_knee_pix, stretch_gain_q8_pix);
            last_nonzero_pixel_reg <= value;
            zero_hold_count_reg <= 2'd0;
        end else if ((last_nonzero_pixel_reg != 16'd0) &&
                     (zero_hold_count_reg < ZERO_HOLD_MAX)) begin
            color_index_reg <= stretch_color_index(last_nonzero_pixel_reg, stretch_knee_pix, stretch_gain_q8_pix);
            zero_hold_count_reg <= zero_hold_count_reg + 1'b1;
        end else begin
            color_index_reg <= 8'd0;
            last_nonzero_pixel_reg <= 16'd0;
            zero_hold_count_reg <= 2'd0;
        end
    end
endtask

always @(posedge pix_clk) begin
    if (pix_reset) begin
        red_reg <= 8'd0;
        green_reg <= 8'd0;
        blue_reg <= 8'd0;
        de_reg <= 1'b0;
        hsync_reg <= 1'b1;
        vsync_reg <= 1'b1;
        osd_text_reg <= 1'b0;
        osd_bg_reg <= 1'b0;
        image_active_reg <= 1'b0;
        color_index_reg <= 8'd0;
        last_nonzero_pixel_reg <= 16'd0;
        zero_hold_count_reg <= 2'd0;
        fifo_high_half_valid_reg <= 1'b0;
        fifo_high_half_reg <= 16'd0;
        fifo_rd_en_reg <= 1'b0;
        scan_word_valid_reg <= 1'b0;
        scan_word_reg <= 32'd0;
        underflow_frame_count_pix_reg <= 8'd0;
        underflow_last_count_pix_reg <= 8'd0;
        underflow_seen_pix_reg <= 1'b0;
    end else begin
        fifo_rd_en_reg <= 1'b0;
        de_reg <= video_active_now;
        hsync_reg <= ~hsync_now;
        vsync_reg <= ~vsync_now;
        osd_text_reg <= osd_text;
        osd_bg_reg <= osd_region;
        image_active_reg <= image_active_now;

        if (frame_start_pix) begin
            underflow_last_count_pix_reg <= underflow_frame_count_pix_reg;
            underflow_frame_count_pix_reg <= 8'd0;
            scan_word_valid_reg <= 1'b0;
            fifo_high_half_valid_reg <= 1'b0;
            last_nonzero_pixel_reg <= 16'd0;
            zero_hold_count_reg <= 2'd0;
        end

        if (image_underflow_now) begin
            underflow_seen_pix_reg <= 1'b1;
            if (underflow_frame_count_pix_reg != 8'hFF)
                underflow_frame_count_pix_reg <= underflow_frame_count_pix_reg + 1'b1;
        end

        if (fifo_rd_rst_busy) begin
            fifo_high_half_valid_reg <= 1'b0;
            scan_word_valid_reg <= 1'b0;
            color_index_reg <= 8'd0;
            last_nonzero_pixel_reg <= 16'd0;
            zero_hold_count_reg <= 2'd0;
        end else if (!image_active_now) begin
            fifo_high_half_valid_reg <= 1'b0;
            color_index_reg <= 8'd0;
            last_nonzero_pixel_reg <= 16'd0;
            zero_hold_count_reg <= 2'd0;
            if (!frame_start_pix && !scan_word_valid_reg && fifo_can_pop_pix) begin
                scan_word_reg <= fifo_dout;
                scan_word_valid_reg <= 1'b1;
                fifo_rd_en_reg <= 1'b1;
            end
        end else if (image_underflow_now) begin
            color_index_reg <= color_index_reg;
        end else if (fifo_high_half_valid_reg) begin
            consume_image_pixel(fifo_high_half_reg);
            fifo_high_half_valid_reg <= 1'b0;
            if (!frame_start_pix && !scan_word_valid_reg && fifo_can_pop_pix) begin
                scan_word_reg <= fifo_dout;
                scan_word_valid_reg <= 1'b1;
                fifo_rd_en_reg <= 1'b1;
            end
        end else if (scan_word_valid_reg) begin
            consume_image_pixel(scan_word_reg[15:0]);
            fifo_high_half_reg <= scan_word_reg[31:16];
            fifo_high_half_valid_reg <= 1'b1;
            scan_word_valid_reg <= 1'b0;
        end else if (fifo_can_pop_pix) begin
            consume_image_pixel(fifo_dout[15:0]);
            fifo_high_half_reg <= fifo_dout[31:16];
            fifo_high_half_valid_reg <= 1'b1;
            fifo_rd_en_reg <= 1'b1;
        end else begin
            color_index_reg <= 8'd0;
            last_nonzero_pixel_reg <= 16'd0;
            zero_hold_count_reg <= 2'd0;
        end

        if (osd_text_reg) begin
            red_reg <= 8'hff;
            green_reg <= 8'hff;
            blue_reg <= 8'hff;
        end else if (osd_bg_reg) begin
            red_reg <= 8'h00;
            green_reg <= 8'h00;
            blue_reg <= 8'h00;
        end else if (image_active_reg) begin
            red_reg <= cusjet_red;
            green_reg <= cusjet_green;
            blue_reg <= cusjet_blue;
        end else begin
            red_reg <= 8'h00;
            green_reg <= 8'h00;
            blue_reg <= 8'h00;
        end
    end
end

wire tmds_clk_unused_p;
wire tmds_clk_unused_n;
wire unused_axi_inputs = &{1'b0, m_axi_awready, m_axi_wready, m_axi_bid,
                           m_axi_bresp, m_axi_bvalid, m_axi_rid, m_axi_rresp,
                           m_axi_rlast, fifo_rd_count, fifo_rd_valid};

rgb2dvi #(
    .kGenerateSerialClk (RGB2DVI_INTERNAL_CLK != 0),
    .kClkPrimitive      ("MMCM"),
    .kClkRange          (RGB2DVI_CLK_RANGE),
    .kRstActiveHigh     (1'b0),
    .kD0Swap            (1'b0),
    .kD1Swap            (1'b0),
    .kD2Swap            (1'b0),
    .kClkSwap           (1'b0)
) u_rgb2dvi (
    .TMDS_Clk_p   (tmds_clk_unused_p),
    .TMDS_Clk_n   (tmds_clk_unused_n),
    .TMDS_Clk_b_p (hdmi_clk_p),
    .TMDS_Clk_b_n (hdmi_clk_n),
    .TMDS_Data_p  (hdmi_d_p),
    .TMDS_Data_n  (hdmi_d_n),
    .aRst         (1'b0),
    .aRst_n       (!pix_reset),
    .vid_pData    ({red_reg, blue_reg, green_reg}),
    .vid_pVDE     (de_reg),
    .vid_pHSync   (hsync_reg),
    .vid_pVSync   (vsync_reg),
    .PixelClk     (pix_clk),
    .SerialClk    (ser_clk)
);

endmodule
